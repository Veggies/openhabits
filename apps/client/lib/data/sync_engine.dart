import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:core/core.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

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
    : name = json['name'] as String? ?? 'Tasks',
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

  /// A certificate the person just agreed to trust while signing in.
  String? _trustOnce;
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
          fingerprint == _trustOnce;
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

  /// Accepts "tasks.example.com", "192.168.1.10:8080" or a full URL. Bare
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
        "$url doesn't look like a Tasks server (HTTP ${response.statusCode}).",
      );
    }
    try {
      return ServerInfo(url, jsonDecode(response.body) as Map<String, Object?>);
    } on FormatException {
      throw SyncException("$url doesn't look like a Tasks server.");
    }
  }

  Exception _untrusted(String url) => _lastSeenFingerprint == null
      ? SyncException("Couldn't make a secure connection to $url.")
      : UntrustedServerException(url, _lastSeenFingerprint!);

  /// Trusts a server certificate the person confirmed, for signing in.
  void trustCertificate(String fingerprint) => _trustOnce = fingerprint;

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
    if (fingerprint != null) _trustOnce = fingerprint;
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
    final callback = desktop ? 'http://localhost:43823' : 'tasks';
    final redirect = desktop ? 'http://localhost:43823/' : 'tasks://auth';
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
    final (url, response) = await _sendFirst(
      urls,
      'POST',
      path,
      body: {...body, 'device': deviceName},
      auth: false,
    );
    final account = Account.fromJson(response['user'] as Map<String, Object?>);
    // A different person on this device: don't mix their data with the
    // previous person's. (Data made offline before any sign-in is kept and
    // uploaded to the new account.)
    final previous = this.account;
    if (previous != null && previous.id != account.id) store.reset();
    if (urls.first != serverUrl) {
      // A different server: forget the old one's cursor and addresses.
      store.setMeta('cursor', '0');
      store.setMeta('remoteUrl', null);
      store.setMeta('fingerprint', null);
    }
    store.setMeta('serverUrl', urls.first);
    store.setMeta('token', response['token'] as String);
    store.setMeta('account', jsonEncode(account.toJson()));
    if (urls.length > 1) store.setMeta('remoteUrl', urls[1]);
    // Pin the certificate the person confirmed or the QR code carried, even
    // when signing in over the home network, for use when away.
    if (_trustOnce != null) store.setMeta('fingerprint', _trustOnce);
    _trustOnce = null;
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

  Future<List<Account>> people() async {
    final b = await _send('GET', '/users');
    return [
      for (final u in b['users'] as List)
        Account.fromJson(u as Map<String, Object?>),
    ];
  }

  Future<void> addPerson(String username, String password, String email) =>
      _post('/users', {
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
  }) async {
    Object? lastError;
    for (final url in urls) {
      try {
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
    throw lastError is _Unreachable && lastError.timedOut
        ? const SyncException('The server took too long to respond.')
        : const SyncException("Couldn't reach the server.");
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
      // With another address to fall back on, don't wait long for this one.
      response = await _http
          .send(request)
          .then(http.Response.fromStream)
          .timeout(Duration(seconds: quick ? 6 : 30));
    } on TimeoutException {
      throw const _Unreachable(timedOut: true);
    } catch (_) {
      throw const _Unreachable();
    }
    Map<String, Object?>? decoded;
    try {
      decoded =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, Object?>;
    } catch (_) {}
    if (response.statusCode == 401 && auth && isConfigured) {
      // The session was revoked: signed out elsewhere, or account removed.
      store.setMeta('token', null);
      status = SyncStatus.signedOut;
      notifyListeners();
    }
    if (response.statusCode != 200) {
      throw SyncException(
        decoded?['error'] as String? ??
            'Server returned HTTP ${response.statusCode}.',
      );
    }
    return decoded ?? const {};
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
    final body = await _post('/sync', {
      'since': store.cursor,
      'changes': [for (final c in pending.changes) c.toJson()],
    });
    if (pending.lastId > 0) store.markSent(pending.lastId);
    _followRemote(body['server']);
    store.applyRemote([
      for (final c in body['changes'] as List)
        Change.fromJson(c as Map<String, Object?>),
    ], body['cursor'] as int);
  }

  /// Keeps the remote address current, e.g. after the home internet address
  /// changes or remote access is turned on or off.
  void _followRemote(Object? server) {
    if (server is! Map) return;
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

  /// Asks the server to re-import external calendars now.
  Future<String> refreshCalendars() async {
    if (!isConfigured) return 'Connect to a server first.';
    try {
      final body = await _post('/calendars/refresh', const {});
      final errors = (body['errors'] as Map).cast<String, String>();
      await syncNow();
      if (body['sources'] == 0) return 'No calendars set up on the server yet.';
      if (errors.isEmpty) return 'Calendars refreshed.';
      return errors.entries.map((e) => '${e.key}: ${e.value}').join('\n');
    } catch (e) {
      return '$e';
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
