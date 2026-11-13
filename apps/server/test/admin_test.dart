import 'dart:convert';
import 'dart:io';

import 'package:server/api.dart';
import 'package:server/auth/auth_store.dart';
import 'package:server/calendar/calendar_sync.dart';
import 'package:server/remote/remote_access.dart';
import 'package:server/remote/tls.dart';
import 'package:server/remote/upnp.dart';
import 'package:server/settings_store.dart';
import 'package:server/sync_store.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:test/test.dart';

/// A router for tests: answers UPnP (or not) with a chosen address.
class FakeUpnp extends UpnpClient {
  bool present = true;
  String externalIp = '203.0.113.7';
  final mapped = <int>[];

  @override
  Future<UpnpGateway?> discover({
    Duration timeout = const Duration(seconds: 3),
  }) async => present
      ? UpnpGateway(
          Uri.parse('http://192.168.1.1/ctl'),
          'WANIPConnection:1',
          '192.168.1.20',
        )
      : null;

  @override
  Future<void> addPortMapping(
    UpnpGateway gw, {
    required int externalPort,
    required int internalPort,
    String description = '',
    int leaseSeconds = 3600,
  }) async {
    mapped.add(externalPort);
  }

  @override
  Future<String> externalAddress(UpnpGateway gw) async => externalIp;

  @override
  Future<void> deletePortMapping(UpnpGateway gw, int externalPort) async =>
      mapped.remove(externalPort);
}

class Api {
  final Handler handler;
  String? token;
  Api(this.handler);

  Future<(int, Map<String, Object?>)> call(
    String method,
    String path, [
    Object? body,
  ]) async {
    final response = await handler(
      Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: {'authorization': ?(token == null ? null : 'Bearer $token')},
        body: body == null ? null : jsonEncode(body),
      ),
    );
    final text = await response.readAsString();
    return (
      response.statusCode,
      text.startsWith('{')
          ? jsonDecode(text) as Map<String, Object?>
          : {'body': text},
    );
  }
}

void main() {
  late SyncStore store;
  late AuthStore auth;
  late SettingsStore settings;
  late FakeUpnp router;
  late RemoteAccess remote;
  late CalendarSync calendars;
  late Api api;
  String? publicIp;

  setUp(() {
    store = SyncStore.inMemory();
    auth = AuthStore(store);
    settings = SettingsStore(store.db);
    router = FakeUpnp();
    publicIp = '203.0.113.7';
    remote = RemoteAccess(
      settings,
      httpsPort: 8443,
      upnp: router,
      publicIp: () async => publicIp,
    );
    calendars = CalendarSync(store, [], userIdFor: (_) => auth.owner?.id);
    api = Api(
      buildHandler(
        store,
        auth,
        settings: settings,
        remote: remote,
        calendars: calendars,
        fingerprint: 'AA:BB',
      ),
    );
  });

  tearDown(() => store.close());

  Future<void> setUpOwner() async {
    final (status, b) = await api.call('POST', '/setup', {
      'username': 'ryan',
      'password': 'correct horse',
    });
    expect(status, 200, reason: '$b');
    api.token = b['token'] as String;
  }

  group('first run', () {
    test('the setup page creates the owner, once', () async {
      expect((await api.call('GET', '/auth/info')).$2['needsSetup'], isTrue);
      await setUpOwner();
      expect(auth.owner!.username, 'ryan');
      expect((await api.call('GET', '/auth/info')).$2['needsSetup'], isFalse);

      api.token = null;
      final (status, b) = await api.call('POST', '/setup', {
        'username': 'mallory',
        'password': 'takeover!!',
      });
      expect(status, 409);
      expect(b['error'], contains('already set up'));
    });

    test('the setup page itself is served with protective headers', () async {
      final response = await api.handler(
        Request('GET', Uri.parse('http://localhost/')),
      );
      expect(response.headers['x-frame-options'], 'DENY');
      expect(await response.readAsString(), contains('Create your account'));
    });
  });

  group('remote access', () {
    setUp(setUpOwner);

    Future<Map<String, Object?>> act(String action) async {
      final (status, b) = await api.call('POST', '/admin/remote', {
        'action': action,
      });
      expect(status, 200, reason: '$b');
      return (b['status'] as Map).cast<String, Object?>();
    }

    test('enabling opens the router port and publishes the address', () async {
      final status = await act('enable');
      expect(status['state'], 'on');
      expect(status['url'], 'https://203.0.113.7:8443');
      expect(router.mapped, [8443]);

      final info = (await api.call('GET', '/auth/info')).$2;
      expect(info['remote'], {
        'url': 'https://203.0.113.7:8443',
        'fingerprint': 'AA:BB',
      });
      final (_, pairing) = await api.call('POST', '/auth/pairing-code');
      expect(pairing['remoteUrl'], 'https://203.0.113.7:8443');
      expect(pairing['fingerprint'], 'AA:BB');
    });

    test(
      "no answer from the router asks for a port forward, then trusts it",
      () async {
        router.present = false;
        expect((await act('enable'))['state'], 'needsPortForward');
        final manual = await act('manual');
        expect(manual['state'], 'on');
        expect(manual['url'], 'https://203.0.113.7:8443');
      },
    );

    test('a shared provider address (CGNAT) is explained plainly', () async {
      router.externalIp = '100.72.15.3';
      final status = await act('enable');
      expect(status['state'], 'cgnat');
      expect(status['message'], contains('CGNAT'));
      expect((await api.call('GET', '/auth/info')).$2['remote'], isNull);
    });

    test(
      "a router address that isn't what the internet sees also means CGNAT",
      () async {
        router.externalIp = '198.51.100.4';
        publicIp = '203.0.113.99';
        expect((await act('enable'))['state'], 'cgnat');
      },
    );

    test(
      'a custom address (Tailscale Funnel) wins and needs no pinning',
      () async {
        final (status, b) = await api.call('PUT', '/admin/remote', {
          'publicUrl': 'https://nas.tail1234.ts.net/',
        });
        expect(status, 200);
        expect((b['status'] as Map)['state'], 'on');
        expect((await api.call('GET', '/auth/info')).$2['remote'], {
          'url': 'https://nas.tail1234.ts.net',
          'fingerprint': null,
        });
      },
    );

    test(
      'after a restart, the last address is offered while re-checking',
      () async {
        await act('enable');
        final restarted = RemoteAccess(
          settings,
          httpsPort: 8443,
          upnp: router,
          publicIp: () async => publicIp,
        );
        expect(restarted.url, 'https://203.0.113.7:8443');
      },
    );

    test('turning it off removes the router mapping', () async {
      await act('enable');
      expect((await act('disable'))['state'], 'off');
      expect(router.mapped, isEmpty);
    });

    test(
      'sync responses carry the remote address so devices can follow it',
      () async {
        await act('enable');
        final (_, b) = await api.call('POST', '/sync', {
          'since': 0,
          'changes': [],
        });
        expect((b['server'] as Map)['remote'], {
          'url': 'https://203.0.113.7:8443',
          'fingerprint': 'AA:BB',
        });
      },
    );

    test('only the owner can change it', () async {
      await api.call('POST', '/users', {
        'username': 'sam',
        'password': 'sam password',
      });
      final (_, login) = await api.call('POST', '/auth/login', {
        'username': 'sam',
        'password': 'sam password',
      });
      api.token = login['token'] as String;
      expect(
        (await api.call('POST', '/admin/remote', {'action': 'enable'})).$1,
        403,
      );
    });
  });

  group('calendars and single sign-on', () {
    setUp(setUpOwner);

    test("calendar passwords are kept but never sent back", () async {
      await api.call('PUT', '/admin/calendars', {
        'calendars': [
          {
            'name': 'iCloud',
            'type': 'caldav',
            'url': 'https://caldav.icloud.com',
            'username': 'me',
            'password': 'app-pass',
          },
        ],
      });
      final (_, listed) = await api.call('GET', '/admin/calendars');
      final entry = (listed['calendars'] as List).single as Map;
      expect(entry['password'], isNull);

      // Saving the list back (as the page does) keeps the password.
      await api.call('PUT', '/admin/calendars', {
        'calendars': listed['calendars'],
      });
      expect(settings.calendars.single['password'], 'app-pass');
      expect(calendars.sources.single.password, 'app-pass');
    });

    test('single sign-on needs a public address with a domain', () async {
      expect((await api.call('GET', '/admin/sso')).$2['callbackUrl'], isNull);
      await api.call('PUT', '/admin/remote', {
        'publicUrl': 'https://tasks.example.com',
      });
      expect(
        (await api.call('GET', '/admin/sso')).$2['callbackUrl'],
        'https://tasks.example.com/auth/oidc/callback',
      );

      await api.call('PUT', '/admin/sso', {
        'issuer': 'https://accounts.google.com',
        'clientId': 'id',
        'clientSecret': 's3cret',
        'label': 'Google',
      });
      // A blank secret on a later save keeps the stored one.
      await api.call('PUT', '/admin/sso', {
        'issuer': 'https://accounts.google.com',
        'clientId': 'id',
        'clientSecret': '',
        'label': 'Google',
      });
      expect(settings.sso['clientSecret'], 's3cret');
      expect((await api.call('GET', '/admin/sso')).$2['hasSecret'], isTrue);
    });

    test('QR codes are drawn as SVG', () async {
      final response = await api.handler(
        Request(
          'GET',
          Uri.parse('http://localhost/qr.svg?data=tasks%3A%2F%2Fpair'),
          headers: {'authorization': 'Bearer ${api.token}'},
        ),
      );
      expect(response.headers['content-type'], 'image/svg+xml');
      expect(await response.readAsString(), startsWith('<svg'));
    });
  });

  test('the self-signed certificate is served and can be pinned', () async {
    final dir = Directory.systemTemp.createTempSync('tls_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cert = ServerCertificate.loadOrCreate(dir);
    expect(
      ServerCertificate.loadOrCreate(dir).fingerprint,
      cert.fingerprint,
    ); // stable

    final server = await serve(
      (_) => Response.ok('ok'),
      InternetAddress.loopbackIPv4,
      0,
      securityContext: cert.securityContext,
    );
    addTearDown(server.close);

    Future<int> get({required String pin}) async {
      final client = HttpClient()
        ..badCertificateCallback = (c, host, port) =>
            fingerprintOf(c.der) == pin;
      try {
        final response = await (await client.getUrl(
          Uri.parse('https://127.0.0.1:${server.port}/'),
        )).close();
        return response.statusCode;
      } finally {
        client.close(force: true);
      }
    }

    expect(await get(pin: cert.fingerprint), 200);
    await expectLater(get(pin: 'AA:BB'), throwsA(isA<HandshakeException>()));
  });

  test('private and CGNAT ranges are recognised', () {
    for (final ip in [
      '10.0.0.1',
      '172.20.1.1',
      '192.168.1.1',
      '100.64.0.1',
      '100.127.255.255',
    ]) {
      expect(isPrivateAddress(ip), isTrue, reason: ip);
    }
    for (final ip in ['203.0.113.7', '100.128.0.1', '172.32.0.1', '8.8.8.8']) {
      expect(isPrivateAddress(ip), isFalse, reason: ip);
    }
  });
}
