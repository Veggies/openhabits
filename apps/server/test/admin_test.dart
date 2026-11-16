import 'dart:async';
import 'dart:io';

import 'package:server/api.dart';
import 'package:server/auth/auth_store.dart';
import 'package:server/remote/directory.dart';
import 'package:server/remote/remote_access.dart';
import 'package:server/remote/tls.dart';
import 'package:server/remote/upnp.dart';
import 'package:server/settings_store.dart';
import 'package:server/sync_store.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:test/test.dart';

import 'support/requests.dart';

/// A router for tests: answers UPnP (or not) with a chosen address.
class FakeUpnp extends UpnpClient {
  bool present = true;
  String externalIp = '203.0.113.7';
  final mapped = <int>[];

  /// Outside ports already forwarded elsewhere (by hand, or the router's own).
  final taken = <int>{};

  /// When set, the router takes until this completes to answer a request
  /// to forward a port, like a slow real router.
  Completer<void>? slow;

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
    if (slow case final gate?) await gate.future;
    if (taken.contains(externalPort)) {
      throw const UpnpException(
        'Router refused AddPortMapping (718: ConflictInMappingEntry)',
        code: 718,
      );
    }
    // Renewing a forward replaces it, as on a real router.
    if (!mapped.contains(externalPort)) mapped.add(externalPort);
  }

  @override
  Future<String> externalAddress(UpnpGateway gw) async => externalIp;

  @override
  Future<void> deletePortMapping(UpnpGateway gw, int externalPort) async =>
      mapped.remove(externalPort);
}

/// The directory, recording what the server publishes.
class FakeDirectory extends DirectoryClient {
  final published = <List<String>>[];
  bool down = false;
  FakeDirectory(DirectoryIdentity identity)
    : super(Uri.parse('https://directory.example'), identity);

  @override
  Future<void> publish(List<String> urls) async {
    if (down) throw const HttpException('down');
    published.add(urls);
  }
}

final _identityDir = Directory.systemTemp.createTempSync('directory-key');
final _identity = DirectoryIdentity.loadOrCreate(_identityDir);

class Api {
  final Handler handler;
  String? token;
  Api(this.handler);

  Future<(int, Map<String, Object?>)> call(
    String method,
    String path, [
    Object? body,
  ]) => send(handler, method, path, body: body, token: token);
}

void main() {
  tearDownAll(() => _identityDir.deleteSync(recursive: true));
  late SyncStore store;
  late AuthStore auth;
  late SettingsStore settings;
  late FakeUpnp router;
  late RemoteAccess remote;
  late Api api;
  String? publicIp;

  late FakeDirectory directory;

  setUp(() {
    directory = FakeDirectory(_identity);
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
      directory: directory,
    );
    api = Api(
      buildHandler(
        store,
        auth,
        settings: settings,
        remote: remote,
        fingerprint: 'AA:BB',
        serverId: _identity.id,
        serverKey: _identity.publicKeyBase64Url,
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
      'a port already forwarded elsewhere moves to a free one and keeps it',
      () async {
        router.taken.add(8443);
        final status = await act('enable');
        expect(status['state'], 'on');
        final port = router.mapped.single;
        expect(port, isNot(8443));
        expect(status['url'], 'https://203.0.113.7:$port');
        expect((await api.call('GET', '/admin/remote')).$2['port'], port);

        // Renewing asks for the same port again, not a new one each time.
        await act('enable');
        expect(router.mapped.toSet(), {port});
      },
    );

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

    group('the directory', () {
      test('hears the address when remote access starts working', () async {
        await act('enable');
        expect(directory.published, [
          ['https://203.0.113.7:8443'],
        ]);
      });

      test('is only told again when the address changes', () async {
        await act('enable');
        await act('refresh');
        expect(directory.published, hasLength(1));
        router.externalIp = publicIp = '198.51.100.30';
        await act('refresh');
        expect(directory.published.last, ['https://198.51.100.30:8443']);
      });

      test('forgets the server when remote access is turned off', () async {
        await act('enable');
        await act('disable');
        expect(directory.published.last, isEmpty);
      });

      test('keeps the old address while the router has a bad moment', () async {
        await act('enable');
        router.present = false;
        expect((await act('refresh'))['state'], 'needsPortForward');
        expect(directory.published, hasLength(1));
      });

      test('being unreachable never breaks remote access', () async {
        directory.down = true;
        expect((await act('enable'))['state'], 'on');
        directory.down = false;
        await act('refresh');
        expect(directory.published, hasLength(1));
      });

      test('devices are told where to look the server up', () async {
        final (_, b) = await api.call('POST', '/sync', {
          'since': 0,
          'changes': [],
        });
        expect((b['server'] as Map)['directory'], {
          'lookup': 'https://directory.example/v1/servers/${_identity.id}',
          'key': _identity.publicKeyBase64Url,
        });
        expect((b['server'] as Map)['id'], _identity.id);
      });
    });

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

    test('turning it off during a check keeps it off', () async {
      await act('enable');
      router.slow = Completer();
      // The 15-minute check starts and waits on the router...
      final check = remote.refresh();
      // ...while the owner turns remote access off.
      final off = remote.disable();
      router.slow!.complete();
      await check;
      expect((await off).state, RemoteState.off);
      expect(remote.status.state, RemoteState.off);
      expect(remote.url, isNull);
      expect(router.mapped, isEmpty);
      expect(directory.published.last, isEmpty);
    });

    test('changing the port closes the old one on the router', () async {
      await act('enable');
      final (status, _) = await api.call('PUT', '/admin/remote', {
        'port': 9443,
      });
      expect(status, 200);
      expect(router.mapped, [9443]);
      await act('disable');
      expect(router.mapped, isEmpty);
    });

    test('a forward from before ports were tracked is still closed', () async {
      router.mapped.add(8443); // made by an older version
      settings.remoteEnabled = true;
      await act('disable');
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

  group('single sign-on', () {
    setUp(setUpOwner);

    test('single sign-on needs a public address with a domain', () async {
      expect((await api.call('GET', '/admin/sso')).$2['callbackUrl'], isNull);
      await api.call('PUT', '/admin/remote', {
        'publicUrl': 'https://habits.example.com',
      });
      expect(
        (await api.call('GET', '/admin/sso')).$2['callbackUrl'],
        'https://habits.example.com/auth/oidc/callback',
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
  });

  test('QR codes are drawn as SVG', () async {
    await setUpOwner();
    final response = await api.handler(
      Request(
        'GET',
        Uri.parse('http://localhost/qr.svg?data=openhabits%3A%2F%2Fpair'),
        headers: {'authorization': 'Bearer ${api.token}'},
      ),
    );
    expect(response.headers['content-type'], 'image/svg+xml');
    expect(await response.readAsString(), startsWith('<svg'));
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
