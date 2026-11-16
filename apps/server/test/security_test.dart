// Sign-in limits, sessions and first-run setup: the parts of the server
// that face people who aren't signed in.
import 'dart:convert';
import 'dart:io';

import 'package:server/api.dart';
import 'package:server/auth/auth_store.dart';
import 'package:server/settings_store.dart';
import 'package:server/sync_store.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// What shelf's server puts in a request's context: who connected.
class FakeConnection implements HttpConnectionInfo {
  @override
  final InternetAddress remoteAddress;
  FakeConnection(String ip) : remoteAddress = InternetAddress(ip);
  @override
  int get localPort => 8080;
  @override
  int get remotePort => 50000;
}

/// Calls the handler as a given address would.
class Client {
  final Handler handler;
  final String ip;
  final Map<String, String> headers;
  String? token;
  Client(this.handler, {this.ip = '192.168.1.50', this.headers = const {}});

  Future<(int, Map<String, Object?>)> call(
    String method,
    String path, [
    Object? body,
    String contentType = 'application/json',
  ]) async {
    final response = await handler(
      Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: {
          ...headers,
          'authorization': ?(token == null ? null : 'Bearer $token'),
          if (body != null) 'content-type': contentType,
        },
        body: body == null ? null : (body is String ? body : jsonEncode(body)),
        context: {'shelf.io.connection_info': FakeConnection(ip)},
      ),
    );
    final text = await response.readAsString();
    return (
      response.statusCode,
      text.startsWith('{')
          ? jsonDecode(text) as Map<String, Object?>
          : <String, Object?>{'body': text},
    );
  }

  Future<(int, Map<String, Object?>)> login(String user, String password) =>
      call('POST', '/auth/login', {'username': user, 'password': password});
}

void main() {
  late SyncStore store;
  late AuthStore auth;
  late DateTime now;

  setUp(() {
    store = SyncStore.inMemory();
    now = DateTime.utc(2026, 11, 16, 9);
    auth = AuthStore(store, clock: () => now);
  });
  tearDown(() => store.close());

  Handler handler({ProxyTrust trust = ProxyTrust.none}) =>
      buildHandler(store, auth, trustProxy: trust, serverId: 'server-1');

  group('first-run setup', () {
    test("another web page can't submit the setup form", () async {
      // A cross-site <form enctype="text/plain"> can carry JSON-looking text
      // but can't say it's JSON.
      final (status, _) = await Client(handler()).call(
        'POST',
        '/setup',
        '{"username":"mallory","password":"hunter222","x":"="}',
        'text/plain',
      );
      expect(status, 415);
      expect(auth.hasUsers, isFalse);
    });

    test('two setups at once: exactly one becomes the owner', () async {
      final api = Client(handler());
      final results = await Future.wait([
        api.call('POST', '/setup', {'username': 'ryan', 'password': '12345678'}),
        api.call('POST', '/setup', {'username': 'eve', 'password': '12345678'}),
      ]);
      expect(results.map((r) => r.$1).toList()..sort(), [200, 409]);
      expect(auth.users, hasLength(1));
      expect(auth.users.single.isOwner, isTrue);
    });
  });

  group('sign-in limits', () {
    setUp(() {
      auth.createUser('ryan', password: 'correct horse');
      auth.createUser('sam', password: 'sam password');
    });

    test("one person's wrong guesses don't lock out someone else", () async {
      final api = Client(handler());
      for (var i = 0; i < 5; i++) {
        await api.login('ryan', 'wrong');
      }
      expect((await api.login('ryan', 'correct horse')).$2['error'],
          startsWith("That's too many tries"));
      // Same address (e.g. the same proxy), different person: fine.
      expect((await api.login('sam', 'sam password')).$1, 200);
    });

    test('the wait grows, then failures are forgotten', () async {
      final api = Client(handler());
      for (var i = 0; i < 5; i++) {
        await api.login('ryan', 'wrong');
      }
      now = now.add(const Duration(seconds: 31));
      await api.login('ryan', 'wrong'); // 6th: now 60 seconds
      now = now.add(const Duration(seconds: 31));
      expect((await api.login('ryan', 'correct horse')).$2['error'],
          startsWith("That's too many tries"));
      now = now.add(const Duration(hours: 2));
      expect((await api.login('ryan', 'correct horse')).$1, 200);
    });

    test('trying many usernames from one address is limited too', () async {
      final api = Client(handler());
      for (var i = 0; i < 20; i++) {
        await api.login('nobody$i', 'guess');
      }
      expect((await api.login('ryan', 'correct horse')).$2['error'],
          startsWith("That's too many tries"));
      // Another address isn't affected.
      expect((await Client(handler(), ip: '192.168.1.51')
              .login('ryan', 'correct horse')).$1, 200);
    });

    test('forwarded addresses are only believed from a local proxy', () async {
      // Straight from the internet (e.g. the forwarded HTTPS port), a made-up
      // header changes nothing: every guess counts against the real address.
      for (var i = 0; i < 6; i++) {
        await Client(handler(trust: ProxyTrust.forwardedFor),
            ip: '198.51.100.9',
            headers: {'x-forwarded-for': '10.9.9.$i'}).login('ryan', 'wrong');
      }
      expect((await Client(handler(trust: ProxyTrust.forwardedFor),
                  ip: '198.51.100.9')
              .login('ryan', 'correct horse')).$2['error'],
          startsWith("That's too many tries"));
    });

    test('behind a proxy, the address the proxy added is used', () {
      expect(
        clientFromHeaders({'x-forwarded-for': 'spoofed, 203.0.113.5'},
            ProxyTrust.forwardedFor),
        '203.0.113.5',
      );
      expect(
        clientFromHeaders({'cf-connecting-ip': '203.0.113.5'},
            ProxyTrust.forwardedFor),
        isNull,
      );
      expect(
        clientFromHeaders({'cf-connecting-ip': '203.0.113.5'},
            ProxyTrust.cloudflare),
        '203.0.113.5',
      );
      expect(ProxyTrust.parse('true'), ProxyTrust.forwardedFor);
      expect(ProxyTrust.parse(null), ProxyTrust.none);
    });

    test('password checks run side by side without mixing up results',
        () async {
      final api = Client(handler());
      final results = await Future.wait([
        api.login('ryan', 'correct horse'),
        api.login('sam', 'sam password'),
        Client(handler(), ip: '192.168.1.60').login('sam', 'wrong'),
      ]);
      expect(results.map((r) => r.$1), [200, 200, 400]);
    });
  });

  group('one-time codes', () {
    late String owner;
    setUp(() => owner = auth.createUser('ryan', password: 'correct horse').id);

    test('expire after ten minutes', () {
      final code = auth.createCode(owner);
      now = now.add(AuthStore.codeLifetime + const Duration(seconds: 1));
      expect(() => auth.redeemCode(code), throwsA(isA<AuthException>()));
    });

    test('work once, within the time', () {
      final code = auth.createCode(owner);
      now = now.add(const Duration(minutes: 9));
      expect(auth.redeemCode(code).id, owner);
      expect(() => auth.redeemCode(code), throwsA(isA<AuthException>()));
    });

    test('guessing is limited', () {
      for (var i = 0; i < 10; i++) {
        expect(() => auth.redeemCode('AAAA-AAA$i', client: 'x'),
            throwsA(isA<AuthException>()));
      }
      final code = auth.createCode(owner);
      expect(
        () => auth.redeemCode(code, client: 'x'),
        throwsA(predicate((e) => '$e'.startsWith("That's too many tries"))),
      );
      expect(auth.redeemCode(code, client: 'y').id, owner);
    });
  });

  group('sessions', () {
    late Client phone, laptop;
    setUp(() async {
      auth.createUser('ryan', password: 'correct horse');
      auth.createUser('sam', password: 'sam password');
      phone = Client(handler());
      laptop = Client(handler());
      phone.token = (await phone.login('ryan', 'correct horse')).$2['token']
          as String;
      laptop.token = (await laptop.login('ryan', 'correct horse')).$2['token']
          as String;
    });

    test('expire after three months unused', () async {
      now = now.add(const Duration(days: 89));
      expect((await phone.call('GET', '/auth/me')).$1, 200);
      now = now.add(const Duration(days: 89)); // phone was used; laptop wasn't
      expect((await phone.call('GET', '/auth/me')).$1, 200);
      expect((await laptop.call('GET', '/auth/me')).$1, 401);
    });

    test('a lost device can be signed out from another', () async {
      final sessions =
          (await phone.call('GET', '/auth/me')).$2['sessions'] as List;
      expect(sessions.where((s) => s['current'] == true), hasLength(1));
      final other = sessions.firstWhere((s) => s['current'] == false);
      expect((await phone.call('DELETE', '/auth/sessions/${other['id']}')).$1,
          200);
      expect((await laptop.call('GET', '/auth/me')).$1, 401);
      expect((await phone.call('GET', '/auth/me')).$1, 200);
    });

    test("you can't sign out someone else's device", () async {
      final sam = Client(handler());
      sam.token = (await sam.login('sam', 'sam password')).$2['token'] as String;
      final ids = [
        for (final s in (await phone.call('GET', '/auth/me')).$2['sessions']
            as List)
          s['id'],
      ];
      expect((await sam.call('DELETE', '/auth/sessions/${ids.first}')).$1, 404);
      expect((await phone.call('GET', '/auth/me')).$1, 200);
    });

    test('changing your password signs out your other devices', () async {
      final (status, _) = await phone.call('POST', '/auth/password', {
        'current': 'correct horse',
        'new': 'battery staple',
      });
      expect(status, 200);
      expect((await phone.call('GET', '/auth/me')).$1, 200);
      expect((await laptop.call('GET', '/auth/me')).$1, 401);
    });

    test('the owner can sign someone out without deleting their data',
        () async {
      final sam = Client(handler());
      sam.token = (await sam.login('sam', 'sam password')).$2['token'] as String;
      final samId = auth.userByName('sam')!.id;
      expect((await sam.call('POST', '/users/$samId/sign-out')).$1, 403);
      expect((await phone.call('POST', '/users/$samId/sign-out')).$1, 200);
      expect((await sam.call('GET', '/auth/me')).$1, 401);
      expect(auth.userById(samId), isNotNull);
    });
  });

  test('sign-in answers say which server this is', () async {
    auth.createUser('ryan', password: 'correct horse');
    final api = Client(handler());
    expect((await api.call('GET', '/auth/info')).$2['id'], 'server-1');
    expect(((await api.login('ryan', 'correct horse')).$2['server'] as Map)['id'],
        'server-1');
  });

  group('limits on what anyone can send', () {
    test('a huge request is refused before it is read', () async {
      final big = '{"username":"${'x' * (maxBodyBytes + 10)}"}';
      final (status, _) = await Client(handler()).call('POST', '/auth/login', big);
      expect(status, 413);
    });

    test('logs leave out calendar links and pairing codes', () {
      expect(
        redactLogLine('GET [200] /calendar/abcDEF_123-xyz.ics 2ms'),
        'GET [200] /calendar/… 2ms',
      );
      expect(
        redactLogLine('GET [200] /qr.svg?data=openhabits%3A%2F%2Fpair%3Fcode%3DK7QM-3XPT 1ms'),
        'GET [200] /qr.svg?… 1ms',
      );
    });
  });

  group('PUBLIC_URL from the environment', () {
    test("is applied once, so the owner's later choices stick", () {
      final settings = SettingsStore(store.db);
      settings.applyEnvPublicUrl('https://habits.example.com');
      expect(settings.publicUrl, 'https://habits.example.com');
      expect(settings.remoteEnabled, isTrue);

      // The owner turns remote access off; the server restarts.
      settings.remoteEnabled = false;
      settings.applyEnvPublicUrl('https://habits.example.com');
      expect(settings.remoteEnabled, isFalse);

      // A new address in the environment is applied again.
      settings.applyEnvPublicUrl('https://new.example.com');
      expect(settings.publicUrl, 'https://new.example.com');
      expect(settings.remoteEnabled, isTrue);
    });
  });
}
