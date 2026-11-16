import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:core/core.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'directory_record.dart';
import 'local_store.dart';

enum SyncStatus { notConfigured, idle, syncing, error, signedOut }

/// What a server says about itself before you sign in.
class ServerInfo {
  final String url;
  final String name;

  /// Label for the single sign-on button (e.g. "Google"), or null if the
  /// server doesn't offer it.
  final String? oidcLabel;

  ServerInfo(this.url, Map<String, Object?> json)
    : name = json['name'] as String? ?? 'OpenHabits',
      oidcLabel = (json['oidc'] as Map?)?['label'] as String?;
}

class Account {
  final String id;
  final String username;
  final String? email;
  final bool isOwner;

  Account.fromJson(Map<String, Object?> json)
    : id = json['id'] as String,
      username = json['username'] as String,
      email = json['email'] as String?,
      isOwner = json['isOwner'] == true;

  Map<String, Object?> toJson() => {
    'id': id,
    'username': username,
    'email': email,
    'isOwner': isOwner,
  };
}

/// The server uses its own certificate for remote access, and this device
/// hasn't been told to trust it yet. Show [fingerprint] so the person can
/// compare it with the security code on the server's setup page.
class UntrustedServerException implements Exception {
  final String url;
  final String fingerprint;
  const UntrustedServerException(this.url, this.fingerprint);

  /// The first 8 pairs, as the setup page shows them.
  String get shortCode => fingerprint.split(':').take(8).join(':');

  @override
  String toString() => "This server's security code isn't trusted yet.";
}

/// SHA-256 of a certificate, formatted as the server does ("3F:A2:…").
String fingerprintOf(List<int> der) => sha256
    .convert(der)
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(':');

/// Signs in to the server and keeps the [LocalStore] in step with it:
/// pushes queued local edits and pulls everything new, shortly after each
/// edit and every 30 seconds.
///
/// A device knows up to two addresses for its server: the one it signed in
/// with (usually the home network) and a remote one for when it's away.
/// Requests try the address that last worked, then the others.
class SyncEngine extends ChangeNotifier {
  final LocalStore store;
  late final http.Client _http;
  final String deviceName;
  Timer? _timer;
  Timer? _debounce;
  Future<void>? _inFlight;
  bool _again = false;
  String? _activeUrl;

  /// Addresses that have shown they're this device's server since the app
  /// started. Once the server's id is known, the sign-in token is only sent
  /// to these.
  final _verified = <String>{};

  /// An address where a different OpenHabits server answered, e.g. after
  /// the server was reinstalled, for a clearer message.
  String? _otherServerAt;

  /// A certificate the person just agreed to trust while signing in, and
  /// the address it's for. It's only accepted from that address, and is
  /// forgotten when the sign-in finishes, whether or not it worked.
  ({String host, String fingerprint})? _trustOnce;
  String? _lastSeenFingerprint;

  SyncStatus status = SyncStatus.notConfigured;
  String? lastError;
  DateTime? lastSynced;

  SyncEngine(this.store, {http.Client? client, String? deviceName})
    : deviceName = deviceName ?? _defaultDeviceName() {
    _http = client ?? IOClient(_pinningClient());
    store.addListener(_onLocalChange);
    if (isConfigured) status = SyncStatus.idle;
  }

  /// Accepts normal, valid certificates as usual, plus the server's own
  /// certificate when its fingerprint matches the one this device pinned.
  HttpClient _pinningClient() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..badCertificateCallback = (cert, host, port) {
      final fingerprint = fingerprintOf(cert.der);
      _lastSeenFingerprint = fingerprint;
      return fingerprint == store.meta('fingerprint') ||
          (fingerprint == _trustOnce?.fingerprint && host == _trustOnce?.host);
    };

  static String _defaultDeviceName() => switch (defaultTargetPlatform) {
    TargetPlatform.iOS => 'iPhone',
    TargetPlatform.android => 'Android',
    TargetPlatform.macOS => 'Mac',
    TargetPlatform.windows => 'Windows PC',
    TargetPlatform.linux => 'Linux PC',
    _ => 'Device',
  };

  /// The address this device signed in with.
  String? get serverUrl => store.meta('serverUrl');

  /// The address for when the device is away from home, if the server has
  /// remote access on.
  String? get remoteUrl => store.meta('remoteUrl');

  String? get _token => store.meta('token');
  bool get isConfigured =>
      (serverUrl ?? '').isNotEmpty && (_token ?? '').isNotEmpty;

  Account? get account {
    final json = store.meta('account');
    return json == null
        ? null
        : Account.fromJson(jsonDecode(json) as Map<String, Object?>);
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => syncNow());
    unawaited(syncNow());
  }

  /// Accepts "habits.example.com", "192.168.1.10:8080" or a full URL. Bare
  /// LAN addresses and anything with a port default to http; public names
  /// default to https.
  static String normalizeUrl(String input) {
    var url = input.trim().replaceAll(RegExp(r'/+$'), '');
    if (!url.contains('://')) {
      final local =
          RegExp(
            r'^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)',
          ).hasMatch(url) ||
          RegExp(r':\d+$').hasMatch(url);
      url = '${local ? 'http' : 'https'}://$url';
    }
    return url;
  }

  /// Looks up a server before signing in. Throws [UntrustedServerException]
  /// for a server using its own certificate that this device doesn't know.
  Future<ServerInfo> serverInfo(String input) async {
    final url = normalizeUrl(input);
    final http.Response response;
    try {
      _lastSeenFingerprint = null;
      response = await _http
          .get(Uri.parse('$url/auth/info'))
          .timeout(const Duration(seconds: 10));
    } on HandshakeException {
      throw _untrusted(url);
    } catch (e) {
      if (_lastSeenFingerprint != null) throw _untrusted(url);
      throw SyncException(
        "Couldn't reach $url. Check the address and that the server is running.",
      );
    }
    if (response.statusCode != 200) {
      throw SyncException(
        "$url doesn't look like an OpenHabits server (HTTP ${response.statusCode}).",
      );
    }
    try {
      return ServerInfo(url, jsonDecode(response.body) as Map<String, Object?>);
    } on FormatException {
      throw SyncException("$url doesn't look like an OpenHabits server.");
    }
  }

  Exception _untrusted(String url) => _lastSeenFingerprint == null
      ? SyncException("Couldn't make a secure connection to $url.")
      : UntrustedServerException(url, _lastSeenFingerprint!);

  /// What to tell the person before signing in to [server] from a pairing
  /// QR code, if this device is already signed in somewhere else: that it
  /// replaces that, and what could be lost. Null when there's nothing to
  /// warn about. Matches replacementWarning in SyncEngine.swift.
  String? replacementWarning(String server) {
    final current = serverUrl;
    if (!isConfigured || current == null || normalizeUrl(server) == current) {
      return null;
    }
    final who = account == null ? '' : ' as ${account!.username}';
    final waiting = store.pendingCount;
    final unsent = switch (waiting) {
      0 => '',
      1 => ", including 1 change that hasn't been sent yet",
      _ => ", including $waiting changes that haven't been sent yet",
    };
    return 'This device is signed in to $current$who. Connecting switches it '
        "to $server. If that's a different account, the habits on this "
        'device will be removed from it$unsent.';
  }

  /// Trusts a server certificate the person confirmed, for signing in to
  /// [url].
  void trustCertificate(String fingerprint, {required String url}) =>
      _trustOnce = (host: Uri.parse(url).host, fingerprint: fingerprint);

  Future<Account> signIn(String url, String username, String password) =>
      _finishSignIn(
        [url],
        '/auth/login',
        {'username': username, 'password': password},
      );

  /// Signs in with a one-time code from another device's QR code or screen.
  /// The QR code also carries the server's remote address and certificate,
  /// so the device works away from home straight away.
  Future<Account> redeemCode(
    String url,
    String code, {
    String? remoteUrl,
    String? fingerprint,
  }) {
    // The QR code's certificate is for the remote address.
    if (fingerprint != null && remoteUrl != null) {
      trustCertificate(fingerprint, url: remoteUrl);
    }
    return _finishSignIn([url, ?remoteUrl], '/auth/redeem', {'code': code});
  }

  /// Signs in through the server's single sign-on provider in a browser.
  Future<Account> signInWithOidc(String url) async {
    // Desktop Windows/Linux can't receive custom-scheme links, so the browser
    // returns to a temporary local web server instead.
    final desktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux);
    final callback = desktop ? 'http://localhost:43823' : 'openhabits';
    final redirect = desktop ? 'http://localhost:43823/' : 'openhabits://auth';
    final result = await FlutterWebAuth2.authenticate(
      url: '$url/auth/oidc/start?redirect_uri=${Uri.encodeComponent(redirect)}',
      callbackUrlScheme: callback,
    );
    final code = Uri.parse(result).queryParameters['code'];
    if (code == null) throw const SyncException('Sign-in was cancelled.');
    return redeemCode(url, code);
  }

  Future<Account> _finishSignIn(
    List<String> urls,
    String path,
    Map<String, Object?> body,
  ) async {
    // Accepted while this sign-in runs, then forgotten either way.
    final trusted = _trustOnce;
    final String url;
    final Map<String, Object?> response;
    try {
      // Only the addresses being signed in to: not the previous server's
      // directory, which could sign this device in to the wrong server.
      (url, response) = await _sendFirst(
        urls,
        'POST',
        path,
        body: {...body, 'device': deviceName},
        auth: false,
        askDirectory: false,
      );
    } finally {
      _trustOnce = null;
    }
    final user = response['user'];
    final token = response['token'];
    if (user is! Map<String, Object?> || token is! String) {
      throw const SyncException(
        'The server sent back something unexpected. Try again.',
      );
    }
    final account = Account.fromJson(user);
    final sameServer = urls.first == serverUrl;
    final previous = this.account;
    if (previous != null && previous.id != account.id) {
      if (previous.username.toLowerCase() == account.username.toLowerCase()) {
        // The same person, but their account is new: the server was
        // reinstalled or reset, perhaps at a new address. This device may
        // hold the only copy of their habits, so send it all rather than
        // deleting it.
        store.requeueAll();
      } else {
        // A different person on this device: don't mix their data with the
        // previous person's. (Data made offline before any sign-in is kept
        // and uploaded to the new account.)
        store.reset();
      }
    }
    if (!sameServer) {
      // A different server: forget the old one's cursor and addresses.
      store.setMeta('cursor', '0');
      store.setMeta('remoteUrl', null);
      store.setMeta('fingerprint', null);
      store.setMeta('directoryLookup', null);
      store.setMeta('directoryKey', null);
      store.setMeta('directoryTs', null);
    }
    store.setMeta('serverId', (response['server'] as Map?)?['id'] as String?);
    _verified
      ..clear()
      ..add(url);
    _otherServerAt = null;
    store.setMeta('serverUrl', urls.first);
    store.setMeta('token', token);
    store.setMeta('account', jsonEncode(account.toJson()));
    if (urls.length > 1) store.setMeta('remoteUrl', urls[1]);
    // Pin the certificate the person confirmed or the QR code carried, even
    // when signing in over the home network, for use when away. Only if it
    // was confirmed for one of the addresses signed in to.
    if (trusted != null &&
        urls.any((u) => Uri.parse(u).host == trusted.host)) {
      store.setMeta('fingerprint', trusted.fingerprint);
    }
    _activeUrl = url;
    status = SyncStatus.idle;
    notifyListeners();
    unawaited(syncNow());
    return account;
  }

  /// Signs out. Local data stays on the device until someone else signs in.
  Future<void> signOut() async {
    try {
      if (isConfigured) await _post('/auth/logout', const {});
    } catch (_) {
      // Signing out locally matters more than telling the server.
    }
    store.setMeta('token', null);
    status = SyncStatus.notConfigured;
    notifyListeners();
  }

  /// A one-time code for adding another device, plus the server's remote
  /// address and certificate fingerprint for the QR code.
  Future<({String code, String url, String? remoteUrl, String? fingerprint})>
  pairingCode() async {
    final b = await _post('/auth/pairing-code', const {});
    return (
      code: b['code'] as String,
      url: serverUrl!,
      remoteUrl: b['remoteUrl'] as String?,
      fingerprint: b['fingerprint'] as String?,
    );
  }

  /// The private link that shows this person's habits in a calendar app.
  /// [anywhere] is false when the server has no public address: the link
  /// then only works on the home network (and not in Google Calendar).
  /// [replace] makes a new link and turns the old one off.
  Future<({String url, bool anywhere})> calendarLink({
    bool replace = false,
  }) async {
    final b = replace
        ? await _post('/calendar-link/reset', const {})
        : await _send('GET', '/calendar-link');
    return (url: b['url'] as String, anywhere: b['anywhere'] == true);
  }

  Future<List<Account>> people() async {
    final b = await _send('GET', '/users');
    return [
      for (final u in b['users'] as List)
        Account.fromJson(u as Map<String, Object?>),
    ];
  }

  Future<void> addPerson(
    String username,
    String password, [
    String email = '',
  ]) => _post('/users', {
    'username': username,
    'password': password,
    'email': email,
  });

  Future<void> removePerson(String id) => _send('DELETE', '/users/$id');

  Future<void> changePassword(String current, String next) =>
      _post('/auth/password', {'current': current, 'new': next});

  Future<void> setEmail(String email) async {
    final b = await _post('/auth/email', {'email': email});
    store.setMeta('account', jsonEncode(b['user']));
    notifyListeners();
  }

  /// The address of the server's own settings page.
  String? get setupPageUrl => _activeUrl ?? serverUrl;

  void _onLocalChange() {
    if (!isConfigured || store.pendingCount == 0) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), syncNow);
  }

  Future<Map<String, Object?>> _post(String path, Map<String, Object?> body) =>
      _send('POST', path, body: body);

  /// Sends to the server, trying the address that last worked first, then
  /// the home and remote addresses.
  Future<Map<String, Object?>> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final urls = <String>{?_activeUrl, ?serverUrl, ?remoteUrl}.toList();
    _otherServerAt = null;
    final (url, result) = await _sendFirst(urls, method, path, body: body);
    _activeUrl = url;
    return result;
  }

  /// Tries each base URL in turn until one can be reached. Only connection
  /// failures move on to the next; a real answer from the server (even an
  /// error) is final.
  Future<(String, Map<String, Object?>)> _sendFirst(
    List<String> urls,
    String method,
    String path, {
    Map<String, Object?>? body,
    bool auth = true,
    bool askDirectory = true,
  }) async {
    Object? lastError;
    for (final url in urls) {
      try {
        if (auth) await _verify(url, quick: urls.length > 1);
        return (
          url,
          await _sendTo(
            Uri.parse('$url$path'),
            method,
            body: body,
            auth: auth,
            quick: urls.length > 1,
          ),
        );
      } on _Unreachable catch (e) {
        lastError = e;
      }
    }
    // None of the known addresses answer. The home's internet address may
    // have changed while this device was away: ask the directory where the
    // server is now. Only addresses the server signed are tried, and each
    // must still show it's this server before the token is sent.
    if (askDirectory) {
      final moved = [
        for (final url in await _directoryUrls())
          if (!urls.contains(url)) url,
      ];
      if (moved.isNotEmpty) {
        try {
          final found = await _sendFirst(
            moved,
            method,
            path,
            body: body,
            auth: auth,
            askDirectory: false,
          );
          store.setMeta('remoteUrl', found.$1);
          return found;
        } on SyncException {
          // Fall through to the usual message.
        }
      }
    }
    if (_otherServerAt case final other?) {
      throw SyncException(
        "A different OpenHabits server answered at $other. If you reinstalled "
        'your server, sign in again to send it the habits on this device.',
      );
    }
    throw lastError is _Unreachable && lastError.timedOut
        ? const SyncException(
            "The server's taking too long to answer. Make sure it's running, then try again.",
          )
        : const SyncException(
            "Couldn't reach your server. Check that it's running and that you're online.",
          );
  }

  /// Checks that [url] is this device's server before the sign-in token
  /// goes there. Away from home, the home address may belong to some other
  /// device on whatever network this one has joined, and a hotel or café
  /// network may answer every address with its own sign-in page.
  Future<void> _verify(String url, {required bool quick}) async {
    final id = store.meta('serverId');
    // Signed in before servers had ids; learned at the next sync.
    if (id == null || _verified.contains(url)) return;
    final Map<String, Object?> info;
    try {
      info = await _sendTo(
        Uri.parse('$url/auth/info'),
        'GET',
        auth: false,
        quick: quick,
      );
    } on SyncException {
      // An error page from something that isn't this server.
      throw const _Unreachable();
    }
    if (info['id'] != id) {
      if (info['id'] is String) _otherServerAt = url;
      throw const _Unreachable();
    }
    _verified.add(url);
  }

  Future<Map<String, Object?>> _sendTo(
    Uri url,
    String method, {
    Map<String, Object?>? body,
    bool auth = true,
    bool quick = false,
  }) async {
    final request = http.Request(method, url)
      ..headers.addAll({
        'content-type': 'application/json',
        if (auth) 'authorization': 'Bearer $_token',
      });
    if (body != null) request.body = jsonEncode(body);
    final http.Response response;
    try {
      // With another address to fall back on, don't wait long for this one
      // to start answering. Once it does, give it time to send everything:
      // a first sync of years of check-ins can be large on a slow link.
      final streamed = await _http
          .send(request)
          .timeout(Duration(seconds: quick ? 6 : 30));
      response = await http.Response.fromStream(
        streamed,
      ).timeout(const Duration(minutes: 2));
    } on TimeoutException {
      throw const _Unreachable(timedOut: true);
    } catch (_) {
      throw const _Unreachable();
    }
    // Every answer from this device's server says which server it is.
    // Something else answering at the address (after moving to another
    // network) is treated as if nothing answered: its errors don't sign
    // this device out and its answers aren't trusted.
    // (Signing in is exempt: the person is choosing a server then.)
    final expected = auth ? store.meta('serverId') : null;
    final answeredBy = response.headers['x-openhabits-server'];
    if (expected != null && answeredBy != expected) {
      _verified.remove('${url.scheme}://${url.authority}');
      if (answeredBy != null) _otherServerAt = '${url.scheme}://${url.authority}';
      throw const _Unreachable();
    }
    Map<String, Object?>? decoded;
    try {
      decoded =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, Object?>;
    } catch (_) {}
    // Every answer from the server is JSON. Anything else came from
    // something else at this address (a hotel sign-in page, a proxy's error
    // page), so carry on as if nothing answered.
    if (decoded == null) throw const _Unreachable();
    if (response.statusCode == 401 && auth && isConfigured) {
      // The session was revoked: signed out elsewhere, or account removed.
      store.setMeta('token', null);
      status = SyncStatus.signedOut;
      notifyListeners();
    }
    if (response.statusCode != 200) {
      throw SyncException(
        decoded['error'] as String? ??
            'Something went wrong on the server (error ${response.statusCode}). Try again in a little while.',
      );
    }
    return decoded;
  }

  /// Syncs now. If a sync is already running, another pass is queued and
  /// the returned future completes when everything has been synced.
  Future<void> syncNow() {
    if (!isConfigured) return Future.value();
    if (_inFlight case final running?) {
      _again = true;
      return running;
    }
    return _inFlight = _sync().whenComplete(() => _inFlight = null);
  }

  Future<void> _sync() async {
    status = SyncStatus.syncing;
    // Plain http addresses are checked again on every sync: this device may
    // have moved to another network since, where the same home address is
    // something else. (https addresses prove themselves with their
    // certificate.)
    _verified.removeWhere((url) => url.startsWith('http://'));
    notifyListeners();
    try {
      do {
        _again = false;
        await _roundTrip();
      } while (_again || store.pendingCount > 0);
      status = SyncStatus.idle;
      lastError = null;
      lastSynced = DateTime.now();
    } catch (e) {
      if (status != SyncStatus.signedOut) status = SyncStatus.error;
      lastError = '$e';
    } finally {
      notifyListeners();
    }
  }

  Future<void> _roundTrip() async {
    final pending = store.pending();
    final since = store.cursor;
    final body = await _post('/sync', {
      'since': since,
      'changes': [for (final c in pending.changes) c.toJson()],
    });
    // Check the answer before forgetting what was sent: if it isn't a real
    // sync answer, the queued edits stay queued and go again next time.
    final cursor = body['cursor'];
    final changes = body['changes'];
    if (cursor is! int || changes is! List) {
      throw const SyncException(
        "The server sent back something unexpected. Your changes are safe on "
        'this device and will be sent again.',
      );
    }
    final incoming = <Change>[];
    for (final c in changes) {
      try {
        incoming.add(Change.fromJson(c as Map<String, Object?>));
      } catch (_) {
        // One unreadable change shouldn't stop all the others.
      }
    }
    if (pending.lastId > 0) store.markSent(pending.lastId);
    _followRemote(body['server']);
    if (cursor < since) {
      // The server has gone back in time: restored from a backup. It may be
      // missing changes this device already sent, so send everything again
      // and fetch everything it has.
      store.requeueAll();
      return;
    }
    store.applyRemote(incoming, cursor);
  }

  /// Where the directory says this server can be reached now. Only
  /// addresses the server itself signed are used: the directory just passes
  /// them on, and a directory that was tampered with can't add its own.
  Future<List<String>> _directoryUrls() async {
    final lookup = store.meta('directoryLookup');
    final key = store.meta('directoryKey');
    if (lookup == null || key == null) return const [];
    try {
      final response = await _http
          .get(Uri.parse(lookup))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return const [];
      final record = DirectoryRecord.verify(
        jsonDecode(response.body) as Map<String, Object?>,
        key: key,
        id: Uri.parse(lookup).pathSegments.last,
        notBefore: int.tryParse(store.meta('directoryTs') ?? '') ?? 0,
      );
      if (record == null) return const [];
      // An older record can't be replayed later to send this device to an
      // address the server has since given up.
      store.setMeta('directoryTs', '${record.ts}');
      return record.urls;
    } catch (_) {
      return const [];
    }
  }

  /// Keeps the remote address current, e.g. after the home internet address
  /// changes or remote access is turned on or off.
  void _followRemote(Object? server) {
    if (server is! Map) return;
    // Signed in before servers had ids: learn it from the server this
    // device is already talking to.
    if (store.meta('serverId') == null && server['id'] is String) {
      store.setMeta('serverId', server['id'] as String);
    }
    if (server.containsKey('directory')) {
      final directory = server['directory'];
      store.setMeta(
        'directoryLookup',
        directory is Map ? directory['lookup'] as String? : null,
      );
      store.setMeta(
        'directoryKey',
        directory is Map ? directory['key'] as String? : null,
      );
    }
    final remote = server['remote'];
    if (remote is Map && remote['url'] is String) {
      store.setMeta('remoteUrl', remote['url'] as String);
      // A custom address has a normal certificate, so nothing is pinned.
      if (remote['fingerprint'] case final String fp) {
        store.setMeta('fingerprint', fp);
      }
    } else if (server['remoteEnabled'] == false) {
      // Only forget it when remote access was really turned off; a missing
      // address can also mean the server is re-checking its router.
      store.setMeta('remoteUrl', null);
    }
  }

  bool _disposed = false;

  /// A sync can still be finishing when the engine is disposed (e.g. the
  /// app closes mid-sync); its late updates are dropped.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _debounce?.cancel();
    store.removeListener(_onLocalChange);
    super.dispose();
  }
}

class _Unreachable implements Exception {
  final bool timedOut;
  const _Unreachable({this.timedOut = false});
}

class SyncException implements Exception {
  final String message;
  const SyncException(this.message);

  @override
  String toString() => message;
}
