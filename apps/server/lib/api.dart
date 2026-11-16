import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:core/core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth/auth_store.dart';
import 'auth/oidc.dart';
import 'calendar_feed.dart';
import 'remote/remote_access.dart';
import 'settings_store.dart';
import 'sync_store.dart';
import 'web/qr_svg.dart';
import 'web/icons.dart';
import 'web/setup_page.dart';

/// Builds the HTTP handler.
///
/// Public routes: `/`, `/health`, `/auth/info`, `/auth/login`,
/// `/auth/redeem` and the OIDC routes. Everything else needs
/// `Authorization: Bearer <session token>`.
Handler buildHandler(
  SyncStore store,
  AuthStore auth, {
  OidcProvider? oidc,
  String serverName = 'OpenHabits',

  /// Which header names the client's address when a reverse proxy or
  /// tunnel on the home network passes requests on. See [ProxyTrust].
  ProxyTrust trustProxy = ProxyTrust.none,

  /// This server's identity (the id of its signing key). Devices remember
  /// it and check it before sending their sign-in token to an address, so
  /// they don't hand it to some other device that happens to answer there.
  String? serverId,

  /// The signing key's public half, for devices to check the addresses the
  /// directory gives them.
  String? serverKey,

  /// The server's public address, if it has one, for pairing QR codes.
  String? publicUrl,

  /// Settings changed from the setup page. Without them the admin routes
  /// are unavailable.
  SettingsStore? settings,
  RemoteAccess? remote,

  /// Fingerprint of the self-signed certificate used for remote access.
  String? fingerprint,

  /// The current single sign-on provider; it changes when the owner edits
  /// the settings. Falls back to [oidc].
  OidcProvider? Function()? currentOidc,

  /// Called after settings change, so the server can rebuild what depends
  /// on them.
  void Function()? onSettingsChanged,
}) {
  OidcProvider? sso() => currentOidc != null ? currentOidc() : oidc;

  /// Where devices can reach this server away from home. The fingerprint is
  /// only included for the automatic address, which uses our own
  /// certificate; a custom address has a normal one.
  Map<String, Object?>? remoteInfo() {
    final url = remote?.url ?? publicUrl;
    if (url == null) return null;
    final selfSigned = remote?.url != null && settings?.publicUrl == null;
    return {'url': url, 'fingerprint': selfSigned ? fingerprint : null};
  }

  Map<String, Object?> remoteJson() => {
    'status': remote!.status.toJson(),
    'port': settings!.remotePort,
    'publicUrl': settings.publicUrl,
    'httpsPort': remote.httpsPort,
    'fingerprint': fingerprint,
  };
  User userOf(Request r) => r.context['user'] as User;

  Map<String, Object?> calendarLink(Request r, {required bool reset}) {
    final id = userOf(r).id;
    final token = reset ? auth.resetCalendarToken(id) : auth.calendarToken(id);
    final public = settings?.publicUrl ?? publicUrl;
    final base = (public ?? r.requestedUri.origin).replaceAll(
      RegExp(r'/+$'),
      '',
    );
    return {'url': '$base/calendar/$token.ics', 'anywhere': public != null};
  }

  var warnedAboutProxy = false;
  String clientOf(Request r) {
    final info = r.context['shelf.io.connection_info'];
    final peer = info is HttpConnectionInfo ? info.remoteAddress : null;
    // Forwarded headers are only believed from a proxy on this machine or
    // the home network. Anyone else could write whatever they like there.
    final fromProxy =
        peer != null && (peer.isLoopback || isPrivateAddress(peer.address));
    final forwarded = clientFromHeaders(r.headers, trustProxy);
    if (fromProxy && forwarded != null) return forwarded;
    if (trustProxy == ProxyTrust.none &&
        fromProxy &&
        !warnedAboutProxy &&
        r.headers.containsKey('x-forwarded-for')) {
      warnedAboutProxy = true;
      stderr.writeln(
        'Requests are arriving through a reverse proxy, so everyone looks '
        'like the same address and one person typing wrong passwords can '
        'slow sign-in for everyone. Set TRUST_PROXY=true (or '
        'TRUST_PROXY=cloudflare for a Cloudflare tunnel) to fix that.',
      );
    }
    return peer?.address ?? '';
  }

  Future<Map<String, Object?>> body(Request r) async {
    final text = await readLimited(r);
    if (text.isEmpty) return {};
    // Browsers can send plain-text forms to any site without asking, but
    // not JSON. Insisting on JSON stops another web page from submitting
    // requests here on a visitor's behalf.
    if (!(r.mimeType ?? '').startsWith('application/json')) {
      throw const _UnsupportedBody();
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Expected a JSON object.');
    }
    return decoded;
  }

  Response signedIn(User user, String device) => _json({
    'token': auth.createSession(user.id, device),
    'user': user.toJson(),
    'server': {'id': serverId},
  });

  final router = Router()
    ..get(
      '/',
      (Request _) => Response.ok(
        setupPageHtml,
        headers: {
          'content-type': 'text/html; charset=utf-8',
          'x-frame-options': 'DENY',
          'referrer-policy': 'no-referrer',
          'cache-control': 'no-store',
        },
      ),
    )
    ..get('/health', (Request _) => Response.ok('ok'))
    // The app icon for the setup page and browser tabs.
    ..get('/icon.png', (Request _) => _png(iconPng))
    ..get('/apple-touch-icon.png', (Request _) => _png(appleTouchIconPng))
    // What the app needs before signing in.
    ..get(
      '/auth/info',
      (Request _) => _json({
        'name': serverName,
        'id': serverId,
        'hasUsers': auth.hasUsers,
        'needsSetup': !auth.hasUsers,
        'oidc': switch (sso()) {
          final p? => {'label': p.config.label},
          null => null,
        },
        'remote': remoteInfo(),
      }),
    )
    ..post('/auth/login', (Request r) async {
      final b = await body(r);
      final user = await auth.signIn(
        b['username'] as String? ?? '',
        b['password'] as String? ?? '',
        client: clientOf(r),
      );
      return signedIn(user, b['device'] as String? ?? '');
    })
    // Exchanges a one-time code (QR pairing or OIDC) for a session.
    ..post('/auth/redeem', (Request r) async {
      final b = await body(r);
      return signedIn(
        auth.redeemCode(b['code'] as String? ?? '', client: clientOf(r)),
        b['device'] as String? ?? '',
      );
    })
    ..get('/auth/oidc/start', (Request r) async {
      final oidc = sso();
      if (oidc == null) {
        return Response.notFound(
          "Single sign-on hasn't been set up on this server yet.",
        );
      }
      final redirect = Uri.tryParse(
        r.url.queryParameters['redirect_uri'] ?? '',
      );
      if (redirect == null || !OidcProvider.isAllowedAppRedirect(redirect)) {
        return Response.badRequest(body: 'Invalid redirect_uri.');
      }
      return Response.found(await oidc.start(redirect));
    })
    ..get('/auth/oidc/callback', (Request r) async {
      final oidc = sso();
      if (oidc == null) {
        return Response.notFound(
          "Single sign-on hasn't been set up on this server yet.",
        );
      }
      final q = r.url.queryParameters;
      if (q['error'] != null) {
        return _htmlError(
          'Sign-in was cancelled',
          q['error_description'] ?? q['error']!,
        );
      }
      try {
        final result = await oidc.finish(q['state'] ?? '', q['code'] ?? '');
        final user = auth.userByEmail(result.email);
        if (user == null) {
          return _htmlError(
            "There's no account here for ${result.email}.",
            'Ask the server owner to add this email to your account in Settings → People.',
          );
        }
        final code = auth.createCode(user.id);
        final back = Uri.parse(result.appRedirect);
        return Response.found(
          back.replace(
            queryParameters: {...back.queryParameters, 'code': code},
          ),
        );
      } on OidcException catch (e) {
        return _htmlError("Couldn't sign in", e.message);
      }
    })
    // A person's habits as a calendar file, for calendar apps to subscribe
    // to. Calendar apps can't sign in, so the long random token in the
    // address is what keeps it private.
    ..get('/calendar/<file>', (Request r, String file) {
      final token = file.endsWith('.ics')
          ? file.substring(0, file.length - 4)
          : file;
      final user = auth.userForCalendarToken(token);
      if (user == null) return Response.notFound('Not found');
      return Response.ok(
        habitsCalendar(store.rows(user.id, Tables.habits)),
        headers: {
          'content-type': 'text/calendar; charset=utf-8',
          'cache-control': 'no-cache',
        },
      );
    })
    // ---- Signed-in routes ----
    ..get(
      '/auth/me',
      (Request r) => _json({
        'user': userOf(r).toJson(),
        'sessions': auth.sessionsFor(userOf(r).id, current: _bearer(r)),
      }),
    )
    ..post('/auth/logout', (Request r) {
      auth.endSession(_bearer(r)!);
      return _json({'ok': true});
    })
    // Signs out one of your own devices, e.g. a lost phone.
    ..delete('/auth/sessions/<id>', (Request r, String id) {
      if (!auth.endSessionById(userOf(r).id, id)) {
        return _jsonError(404, "That device isn't signed in anymore.");
      }
      return _json({'ok': true});
    })
    // Changing your password signs out your other devices, in case the
    // old one was known to someone else.
    ..post('/auth/password', (Request r) async {
      final b = await body(r);
      final user = userOf(r);
      await auth.signIn(
        user.username,
        b['current'] as String? ?? '',
        client: clientOf(r),
      );
      auth.setPassword(user.id, b['new'] as String? ?? '');
      auth.endSessionsFor(user.id, keep: _bearer(r));
      return _json({'ok': true});
    })
    ..post('/auth/email', (Request r) async {
      final b = await body(r);
      auth.setEmail(userOf(r).id, b['email'] as String?);
      return _json({'user': auth.userById(userOf(r).id)!.toJson()});
    })
    // The person's private calendar link. "anywhere" says whether it works
    // away from home (and for Google Calendar, which fetches it from
    // Google's servers): only with a public address that has a real
    // certificate.
    ..get('/calendar-link', (Request r) => _json(calendarLink(r, reset: false)))
    ..post(
      '/calendar-link/reset',
      (Request r) => _json(calendarLink(r, reset: true)),
    )
    // A one-time code for adding another device, shown as a QR code.
    ..post(
      '/auth/pairing-code',
      (Request r) => _json({
        'code': auth.createCode(userOf(r).id),
        'expiresInSeconds': AuthStore.codeLifetime.inSeconds,
        'publicUrl': remoteInfo()?['url'],
        'remoteUrl': remoteInfo()?['url'],
        'fingerprint': remoteInfo()?['fingerprint'],
      }),
    )
    // First run: the setup page creates the owner account. Only works
    // while the server has no accounts at all.
    ..post('/setup', (Request r) async {
      if (auth.hasUsers) throw const SetupDoneException();
      final b = await body(r);
      // Checked again after reading the request: another setup may have
      // finished in the meantime.
      final user = auth.createOwner(
        b['username'] as String? ?? '',
        password: b['password'] as String? ?? '',
        email: b['email'] as String?,
      );
      return signedIn(user, b['device'] as String? ?? 'Setup page');
    })
    ..get('/qr.svg', (Request r) {
      final data = r.url.queryParameters['data'] ?? '';
      if (data.isEmpty || data.length > 1000) {
        return _jsonError(400, 'Nothing to encode.');
      }
      return Response.ok(
        qrSvg(data),
        headers: {'content-type': 'image/svg+xml'},
      );
    })
    // ---- Server settings (owner only) ----
    ..get(
      '/admin/remote',
      (Request r) => _ownerOnly(r, () {
        if (remote == null || settings == null) {
          return _jsonError(404, 'Not available.');
        }
        return _json(remoteJson());
      }),
    )
    ..post(
      '/admin/remote',
      (Request r) => _ownerOnly(r, () async {
        if (remote == null || settings == null) {
          return _jsonError(404, 'Not available.');
        }
        final b = await body(r);
        switch (b['action']) {
          case 'enable':
            await remote.enable();
          case 'manual':
            await remote.enable(manual: true);
          case 'disable':
            await remote.disable();
          default:
            await remote.refresh();
        }
        return _json(remoteJson());
      }),
    )
    ..put(
      '/admin/remote',
      (Request r) => _ownerOnly(r, () async {
        if (remote == null || settings == null) {
          return _jsonError(404, 'Not available.');
        }
        final b = await body(r);
        final port = b['port'] as int?;
        if (port != null) {
          if (port < 1 || port > 65535) {
            return _jsonError(
              400,
              'Port numbers need to be between 1 and 65535.',
            );
          }
          settings.remotePort = port;
        }
        if (b.containsKey('publicUrl')) {
          final url = (b['publicUrl'] as String? ?? '').trim();
          if (url.isNotEmpty && !RegExp(r'^https?://[^\s/]+').hasMatch(url)) {
            return _jsonError(
              400,
              'Enter a full address, like https://habits.example.com',
            );
          }
          settings.publicUrl = url;
          if (url.isNotEmpty) settings.remoteEnabled = true;
        }
        await remote.refresh();
        onSettingsChanged?.call();
        return _json(remoteJson());
      }),
    )
    ..get(
      '/admin/sso',
      (Request r) => _ownerOnly(r, () {
        if (settings == null) return _jsonError(404, 'Not available.');
        final s = settings.sso;
        final base = settings.publicUrl;
        return _json({
          'enabled': sso() != null,
          'issuer': s['issuer'],
          'clientId': s['clientId'],
          'label': s['label'],
          'hasSecret': (s['clientSecret'] ?? '').isNotEmpty,
          'callbackUrl': base == null ? null : '$base/auth/oidc/callback',
        });
      }),
    )
    ..put(
      '/admin/sso',
      (Request r) => _ownerOnly(r, () async {
        if (settings == null) return _jsonError(404, 'Not available.');
        final b = await body(r);
        final current = settings.sso;
        final issuer = (b['issuer'] as String? ?? '').trim();
        final clientId = (b['clientId'] as String? ?? '').trim();
        if (issuer.isEmpty || clientId.isEmpty) {
          settings.sso = {};
        } else {
          final secret = b['clientSecret'] as String? ?? '';
          settings.sso = {
            'issuer': issuer,
            'clientId': clientId,
            'clientSecret': secret.isEmpty
                ? (current['clientSecret'] ?? '')
                : secret,
            'label': (b['label'] as String? ?? '').trim().isEmpty
                ? 'SSO'
                : (b['label'] as String).trim(),
          };
        }
        onSettingsChanged?.call();
        return _json({'ok': true});
      }),
    )
    // ---- Household management (owner only) ----
    ..get(
      '/users',
      (Request r) => _ownerOnly(
        r,
        () => _json({
          'users': [for (final u in auth.users) u.toJson()],
        }),
      ),
    )
    ..post(
      '/users',
      (Request r) => _ownerOnly(r, () async {
        final b = await body(r);
        final user = auth.createUser(
          b['username'] as String? ?? '',
          password: b['password'] as String?,
          email: b['email'] as String?,
        );
        return _json({'user': user.toJson()});
      }),
    )
    ..delete(
      '/users/<id>',
      (Request r, String id) => _ownerOnly(r, () {
        auth.deleteUser(id);
        return _json({'ok': true});
      }),
    )
    // Signs a person out on all their devices without touching their data,
    // e.g. when a family member loses their phone.
    ..post(
      '/users/<id>/sign-out',
      (Request r, String id) => _ownerOnly(r, () {
        if (auth.userById(id) == null) {
          return _jsonError(404, "That person isn't on this server.");
        }
        auth.endSessionsFor(id);
        return _json({'ok': true});
      }),
    )
    // One round trip does both directions: the device pushes its pending
    // changes and gets back everything after its cursor.
    //
    // Request:  {"since": 0, "changes": [Change, ...]}
    // Response: {"cursor": 42, "changes": [Change, ...]}
    ..post('/sync', (Request r) async {
      final b = await body(r);
      final userId = userOf(r).id;
      final since = b['since'] as int? ?? 0;
      final changes = [
        for (final c in b['changes'] as List? ?? const [])
          Change.fromJson(c as Map<String, Object?>),
      ];
      store.apply(userId, changes);
      return _json({
        'cursor': store.cursor,
        // Lets devices follow the server's remote address if it changes.
        // remoteEnabled tells devices to forget the remote address only
        // when remote access is really off, not during a temporary problem.
        'server': {
          'remote': remoteInfo(),
          // Where to ask for this server's address if it changes while a
          // device is away from home.
          'id': serverId,
          'directory': remote?.directory == null
              ? null
              : {
                  'lookup': remote!.directory!.lookupUrl.toString(),
                  // Devices check that answers from the directory were
                  // signed with this key, i.e. published by this server.
                  'key': serverKey,
                },
          'remoteEnabled': settings?.remoteEnabled ?? remoteInfo() != null,
        },
        'changes': [
          for (final c in store.changesSince(userId, since)) c.toJson(),
        ],
      });
    });

  return const Pipeline()
      .addMiddleware(_identify(serverId))
      .addMiddleware(_errors())
      .addMiddleware(_authenticate(auth))
      .addHandler(router.call);
}

const _publicPaths = {
  '',
  'setup',
  'health',
  'icon.png',
  'apple-touch-icon.png',
  'auth/info',
  'auth/login',
  'auth/redeem',
  'auth/oidc/start',
  'auth/oidc/callback',
};

String? _bearer(Request r) {
  final header = r.headers['authorization'];
  return header != null && header.startsWith('Bearer ')
      ? header.substring(7)
      : null;
}

Middleware _authenticate(AuthStore auth) =>
    (inner) => (request) {
      final path = request.url.path;
      // Calendar links carry their own secret; see /calendar/<file>.
      if (_publicPaths.contains(path) || path.startsWith('calendar/')) {
        return inner(request);
      }
      final token = _bearer(request);
      final user = token == null ? null : auth.userForToken(token);
      if (user == null) {
        return Response.unauthorized(
          jsonEncode({'error': 'Please sign in again.'}),
          headers: {'content-type': 'application/json'},
        );
      }
      return inner(request.change(context: {'user': user}));
    };

/// Labels every answer with this server's id, so a device can tell its
/// own server from something else that answers at the same address (on
/// another network, the home address can belong to anything).
Middleware _identify(String? serverId) =>
    (inner) => (request) async {
      final response = await inner(request);
      return serverId == null
          ? response
          : response.change(headers: {'x-openhabits-server': serverId});
    };

/// Turns known failures into JSON errors the app can show.
Middleware _errors() =>
    (inner) => (request) async {
      try {
        return await inner(request);
      } on SetupDoneException catch (e) {
        return _jsonError(409, e.message);
      } on AuthException catch (e) {
        return _jsonError(400, e.message);
      } on _UnsupportedBody {
        return _jsonError(415, 'Send the request as JSON.');
      } on _TooLarge {
        return _jsonError(413, 'That request is too large.');
      } on FormatException catch (e) {
        return _jsonError(400, 'Invalid request: ${e.message}');
      } on TypeError catch (_) {
        return _jsonError(400, "That request didn't look right.");
      }
    };

Future<Response> _ownerOnly(
  Request r,
  FutureOr<Response> Function() action,
) async {
  if (!(r.context['user'] as User).isOwner) {
    return _jsonError(403, 'Only the server owner can manage people.');
  }
  return await action();
}

Response _json(Object body) => Response.ok(
  jsonEncode(body),
  headers: {'content-type': 'application/json'},
);

Response _jsonError(int status, String message) => Response(
  status,
  body: jsonEncode({'error': message}),
  headers: {'content-type': 'application/json'},
);

const _htmlEscape = HtmlEscape();

Response _htmlError(String title, String detail) => Response(
  400,
  body: _page(title, detail),
  headers: {'content-type': 'text/html; charset=utf-8'},
);

String _page(String title, String detail) =>
    '''<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${_htmlEscape.convert(title)}</title>
<style>body{font-family:system-ui,sans-serif;max-width:32rem;margin:15vh auto;padding:0 1rem;color:#222}
@media(prefers-color-scheme:dark){body{background:#111;color:#eee}}h1{font-size:1.4rem}</style></head>
<body><h1>${_htmlEscape.convert(title)}</h1><p>${_htmlEscape.convert(detail)}</p></body></html>''';

Response _png(List<int> bytes) => Response.ok(
  bytes,
  headers: {
    'content-type': 'image/png',
    'cache-control': 'public, max-age=86400',
  },
);

class _UnsupportedBody implements Exception {
  const _UnsupportedBody();
}

/// Which header, if any, says who the client is when requests come through
/// a reverse proxy or tunnel.
enum ProxyTrust {
  /// Use the connection's own address.
  none,

  /// The last address in X-Forwarded-For: the one the nearest proxy added.
  /// Earlier ones were sent by the client and can say anything.
  forwardedFor,

  /// CF-Connecting-IP, which a Cloudflare tunnel sets and visitors can't.
  cloudflare;

  /// From the TRUST_PROXY setting: "true" or "cloudflare".
  static ProxyTrust parse(String? value) => switch (value?.toLowerCase()) {
    'true' || 'yes' || '1' => forwardedFor,
    'cloudflare' => cloudflare,
    _ => none,
  };
}

/// The client address a trusted proxy reported, if any.
String? clientFromHeaders(Map<String, String> headers, ProxyTrust trust) {
  final value = switch (trust) {
    ProxyTrust.none => null,
    ProxyTrust.forwardedFor => headers['x-forwarded-for']?.split(',').last,
    ProxyTrust.cloudflare => headers['cf-connecting-ip'],
  }?.trim();
  return value == null || value.isEmpty ? null : value;
}

class _TooLarge implements Exception {
  const _TooLarge();
}

/// The most a request body may hold. A sync sends at most 500 changes at a
/// time, far below this; anything bigger is refused before it's read into
/// memory, so one huge request can't take the server down.
const maxBodyBytes = 2 * 1024 * 1024;

/// Reads a request body as text, refusing anything over [maxBodyBytes].
Future<String> readLimited(Request r, {int limit = maxBodyBytes}) async {
  if ((r.contentLength ?? 0) > limit) throw const _TooLarge();
  final bytes = <int>[];
  await for (final chunk in r.read()) {
    bytes.addAll(chunk);
    if (bytes.length > limit) throw const _TooLarge();
  }
  return utf8.decode(bytes);
}

/// A request log line with secrets taken out: private calendar links and
/// the pairing codes inside QR code requests.
String redactLogLine(String line) => line
    .replaceAll(RegExp(r'/calendar/[^\s?]+'), '/calendar/…')
    .replaceAll(RegExp(r'/qr\.svg\?\S*'), '/qr.svg?…');
