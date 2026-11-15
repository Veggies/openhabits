import 'dart:convert';
import 'dart:io';

import 'package:core/core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:server/api.dart';
import 'package:server/auth/auth_store.dart';
import 'package:server/auth/oidc.dart';
import 'package:server/sync_store.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Change set(String field, Object? value, int millis, String node) => Change(
  table: 'tasks',
  rowId: 't1',
  field: field,
  value: value,
  hlc: Hlc(millis, 0, node),
);

/// A test client for the handler.
class Api {
  final Handler handler;
  Api(this.handler);

  Future<(int, Map<String, Object?>)> call(
    String method,
    String path, {
    Object? body,
    String? token,
  }) async {
    final response = await handler(
      Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: {'authorization': ?(token == null ? null : 'Bearer $token')},
        body: body == null ? null : jsonEncode(body),
      ),
    );
    final text = await response.readAsString();
    final decoded = text.startsWith('{')
        ? jsonDecode(text) as Map<String, Object?>
        : {'body': text};
    return (response.statusCode, decoded);
  }

  Future<String> login(String username, String password) async {
    final (status, b) = await call(
      'POST',
      '/auth/login',
      body: {'username': username, 'password': password, 'device': 'test'},
    );
    expect(status, 200, reason: '$b');
    return b['token'] as String;
  }

  Future<Map<String, Object?>> sync(
    String token,
    int since,
    List<Change> changes,
  ) async {
    final (status, b) = await call(
      'POST',
      '/sync',
      token: token,
      body: {
        'since': since,
        'changes': [for (final c in changes) c.toJson()],
      },
    );
    expect(status, 200, reason: '$b');
    return b;
  }
}

void main() {
  late SyncStore store;
  late AuthStore auth;
  late Api api;
  late String ownerToken;

  setUp(() async {
    store = SyncStore.inMemory();
    // Fewer PBKDF2 rounds would be nicer for speed, but tests use the real
    // setting to catch regressions in the hash format.
    auth = AuthStore(store);
    auth.createUser(
      'ryan',
      password: 'correct horse',
      email: 'ryan@example.com',
    );
    api = Api(buildHandler(store, auth));
    ownerToken = await api.login('ryan', 'correct horse');
  });

  tearDown(() => store.close());

  group('auth', () {
    test('sync requires a session', () async {
      expect((await api.call('POST', '/sync', body: {})).$1, 401);
      expect(
        (await api.call('POST', '/sync', body: {}, token: 'nope')).$1,
        401,
      );
    });

    test('public routes work without signing in', () async {
      expect((await api.call('GET', '/health')).$1, 200);
      final (status, info) = await api.call('GET', '/auth/info');
      expect(status, 200);
      expect(info['hasUsers'], isTrue);
      expect(info['oidc'], isNull);
      expect((await api.call('GET', '/')).$2['body'], contains('OpenHabits Server'));
    });

    test('wrong passwords are rejected, then rate limited', () async {
      for (var i = 0; i < 5; i++) {
        final (status, b) = await api.call(
          'POST',
          '/auth/login',
          body: {'username': 'ryan', 'password': 'wrong'},
        );
        expect(status, 400);
        expect(b['error'], "That username or password isn't right.");
      }
      final (_, b) = await api.call(
        'POST',
        '/auth/login',
        body: {'username': 'ryan', 'password': 'correct horse'},
      );
      expect(b['error'], startsWith("That's too many tries"));
    });

    test('logging out ends the session', () async {
      expect(
        (await api.call('POST', '/auth/logout', token: ownerToken)).$1,
        200,
      );
      expect((await api.call('GET', '/auth/me', token: ownerToken)).$1, 401);
    });

    test('a pairing code signs in a new device once', () async {
      final (_, pairing) = await api.call(
        'POST',
        '/auth/pairing-code',
        token: ownerToken,
      );
      final code = pairing['code'] as String;
      expect(code, matches(RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}$')));

      // Typed in lowercase without the dash still works.
      final (status, b) = await api.call(
        'POST',
        '/auth/redeem',
        body: {
          'code': code.toLowerCase().replaceAll('-', ''),
          'device': 'Phone',
        },
      );
      expect(status, 200);
      expect((b['user'] as Map)['username'], 'ryan');
      expect(
        (await api.call('POST', '/auth/redeem', body: {'code': code})).$1,
        400,
      );
    });

    test('changing your password needs the current one', () async {
      final (bad, _) = await api.call(
        'POST',
        '/auth/password',
        token: ownerToken,
        body: {'current': 'nope', 'new': 'new password!'},
      );
      expect(bad, 400);
      final (ok, _) = await api.call(
        'POST',
        '/auth/password',
        token: ownerToken,
        body: {'current': 'correct horse', 'new': 'new password!'},
      );
      expect(ok, 200);
      await api.login('ryan', 'new password!');
    });
  });

  group('people', () {
    test('the owner adds people; their data is separate', () async {
      final (status, _) = await api.call(
        'POST',
        '/users',
        token: ownerToken,
        body: {'username': 'sam', 'password': 'sam password'},
      );
      expect(status, 200);
      final samToken = await api.login('sam', 'sam password');

      await api.sync(ownerToken, 0, [set('title', "Ryan's task", 1, 'a')]);
      await api.sync(samToken, 0, [set('title', "Sam's task", 1, 'b')]);

      final ryanView = await api.sync(ownerToken, 0, []);
      final samView = await api.sync(samToken, 0, []);
      expect((ryanView['changes'] as List).map((c) => (c as Map)['value']), [
        "Ryan's task",
      ]);
      expect((samView['changes'] as List).map((c) => (c as Map)['value']), [
        "Sam's task",
      ]);
    });

    test('only the owner can manage people', () async {
      await api.call(
        'POST',
        '/users',
        token: ownerToken,
        body: {'username': 'sam', 'password': 'sam password'},
      );
      final samToken = await api.login('sam', 'sam password');
      expect((await api.call('GET', '/users', token: samToken)).$1, 403);
      expect(
        (await api.call(
          'POST',
          '/users',
          token: samToken,
          body: {'username': 'x', 'password': 'xxxxxxxx'},
        )).$1,
        403,
      );
    });

    test('removing a person signs them out and deletes their data', () async {
      final (_, created) = await api.call(
        'POST',
        '/users',
        token: ownerToken,
        body: {'username': 'sam', 'password': 'sam password'},
      );
      final samId = (created['user'] as Map)['id'] as String;
      final samToken = await api.login('sam', 'sam password');
      await api.sync(samToken, 0, [set('title', 'x', 1, 'b')]);

      expect(
        (await api.call('DELETE', '/users/$samId', token: ownerToken)).$1,
        200,
      );
      expect((await api.call('GET', '/auth/me', token: samToken)).$1, 401);
      expect(store.changesSince(samId, 0), isEmpty);
    });

    test(
      'bad usernames and short passwords are refused with a message',
      () async {
        final (s1, b1) = await api.call(
          'POST',
          '/users',
          token: ownerToken,
          body: {'username': 'a b', 'password': 'longenough'},
        );
        expect(s1, 400);
        expect(b1['error'], contains('Usernames'));
        final (s2, b2) = await api.call(
          'POST',
          '/users',
          token: ownerToken,
          body: {'username': 'sam', 'password': 'short'},
        );
        expect(s2, 400);
        expect(b2['error'], contains('8 characters'));
      },
    );
  });

  group('sync', () {
    test('a change pushed by one device reaches another', () async {
      final laptopToken = await api.login('ryan', 'correct horse');
      await api.sync(ownerToken, 0, [set('title', 'Milk', 1, 'phone')]);
      final laptop = await api.sync(laptopToken, 0, []);
      expect((laptop['changes'] as List).single['value'], 'Milk');
    });

    test('pulling from the latest cursor returns nothing new', () async {
      final first = await api.sync(ownerToken, 0, [
        set('title', 'Milk', 1, 'phone'),
      ]);
      final again = await api.sync(ownerToken, first['cursor'] as int, []);
      expect(again['changes'], isEmpty);
    });

    test('a stale edit does not overwrite a newer one', () async {
      await api.sync(ownerToken, 0, [set('title', 'Oat milk', 5, 'laptop')]);
      await api.sync(ownerToken, 0, [set('title', 'Milk', 1, 'phone')]);
      final result = await api.sync(ownerToken, 0, []);
      expect((result['changes'] as List).single['value'], 'Oat milk');
    });
  });

  group('calendar link', () {
    /// Uploads a habit's fields the way the app does.
    Future<void> habit(String id, Map<String, Object?> fields) =>
        api.sync(ownerToken, 0, [
          for (final (i, e) in fields.entries.indexed)
            Change(
              table: Tables.habits,
              rowId: id,
              field: e.key,
              value: e.value,
              hlc: Hlc(1000 + i, 0, 'phone'),
            ),
        ]);

    test('habits with a time become repeating calendar events', () async {
      await habit('read', {
        'name': 'Read',
        'time': '21:00',
        'duration': 30,
        'weekdays': [1, 3, 5],
        'twoMinute': 'Read 5 pages',
        'stackAfter': 'get into bed',
        'createdAt': '2026-11-01T10:00:00.000Z',
      });
      await habit('meditate', {
        'name': 'Meditate',
        'time': '07:00',
        'duration': 10,
        'createdAt': '2026-11-01T10:00:00.000Z',
      });
      await habit('water', {'name': 'Drink water'}); // no time
      await habit('old', {
        'name': 'Old habit',
        'time': '08:00',
        'archived': true,
      });
      await habit('scroll', {
        'name': 'Scrolling in bed',
        'kind': 'quit',
        'time': '22:00',
      });

      final (status, link) = await api.call(
        'GET',
        '/calendar-link',
        token: ownerToken,
      );
      expect(status, 200);
      final url = Uri.parse(link['url'] as String);
      expect(url.path, matches(RegExp(r'^/calendar/[\w-]{40,}\.ics$')));
      expect(link['anywhere'], isFalse); // no public address set up

      // Calendar apps fetch it without signing in.
      final (feedStatus, feed) = await api.call('GET', url.path);
      expect(feedStatus, 200);
      final ics = feed['body'] as String;
      expect(ics, startsWith('BEGIN:VCALENDAR\r\n'));
      expect(ics, contains('SUMMARY:Read\r\n'));
      expect(ics, contains('DTSTART:20261101T210000\r\n'));
      expect(ics, contains('DURATION:PT30M\r\n'));
      expect(ics, contains('RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR\r\n'));
      expect(
        ics,
        contains(
          r'DESCRIPTION:Your version for now: Read 5 pages\nAfter I get into bed',
        ),
      );
      expect(ics, contains('SUMMARY:Meditate\r\n'));
      expect(ics, contains('RRULE:FREQ=DAILY\r\n'));
      for (final hidden in ['Drink water', 'Old habit', 'Scrolling in bed']) {
        expect(ics, isNot(contains(hidden)));
      }
    });

    test('the link stays the same until it is replaced', () async {
      Future<String> link() async =>
          (await api.call('GET', '/calendar-link', token: ownerToken)).$2['url']
              as String;
      final first = await link();
      expect(await link(), first);

      final (_, replaced) = await api.call(
        'POST',
        '/calendar-link/reset',
        token: ownerToken,
      );
      final second = replaced['url'] as String;
      expect(second, isNot(first));
      expect((await api.call('GET', Uri.parse(first).path)).$1, 404);
      expect((await api.call('GET', Uri.parse(second).path)).$1, 200);
      expect((await api.call('GET', '/calendar/guess.ics')).$1, 404);
    });

    test('getting the link needs a signed-in person', () async {
      expect((await api.call('GET', '/calendar-link')).$1, 401);
    });
  });

  test('state survives a restart, and pre-account data goes to the owner', () {
    final dir = Directory.systemTemp.createTempSync('sync_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/data.sqlite';

    // A database from before accounts existed.
    sqlite3.open(path)
      ..execute(
        '''CREATE TABLE fields (tbl TEXT NOT NULL, row_id TEXT NOT NULL, field TEXT NOT NULL,
          value TEXT, hlc TEXT NOT NULL, seq INTEGER NOT NULL, PRIMARY KEY (tbl, row_id, field))''',
      )
      ..execute(
        "INSERT INTO fields VALUES ('tasks', 't1', 'title', '\"Milk\"', '${const Hlc(1, 0, 'a').pack()}', 1)",
      )
      ..close();

    final upgraded = SyncStore.open(path);
    final owner = AuthStore(upgraded)
        .createUser('ryan', password: 'correct horse');
    expect(upgraded.changesSince(owner.id, 0).single.value, 'Milk');
    upgraded.close();

    final reopened = SyncStore.open(path);
    addTearDown(reopened.close);
    expect(reopened.cursor, 1);
    reopened.apply(owner.id, [set('title', 'Oat milk', 2, 'phone')]);
    expect(reopened.cursor, 2); // keeps counting, never reuses a sequence
    expect(AuthStore(reopened).signIn('ryan', 'correct horse').id, owner.id);
  });

  group('OIDC', () {
    late Api oidcApi;
    final issuer = 'https://accounts.example.com';
    String? nonce;

    String jwt(Map<String, Object?> claims) =>
        '${base64Url.encode(utf8.encode('{"alg":"none"}'))}.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.sig';

    setUp(() {
      final provider = MockClient((request) async {
        if (request.url.path.endsWith('openid-configuration')) {
          return http.Response(
            jsonEncode({
              'issuer': issuer,
              'authorization_endpoint': '$issuer/auth',
              'token_endpoint': '$issuer/token',
            }),
            200,
          );
        }
        if (request.url.toString() == '$issuer/token') {
          expect(request.bodyFields['code_verifier'], isNotEmpty);
          expect(
            request.bodyFields['redirect_uri'],
            'https://tasks.example.com/auth/oidc/callback',
          );
          return http.Response(
            jsonEncode({
              'id_token': jwt({
                'iss': issuer,
                'aud': 'client-1',
                'exp':
                    DateTime.now()
                        .add(const Duration(minutes: 5))
                        .millisecondsSinceEpoch ~/
                    1000,
                'nonce': nonce,
                'email': request.bodyFields['code'] == 'stranger'
                    ? 'who@example.com'
                    : 'ryan@example.com',
                'email_verified': true,
              }),
            }),
            200,
          );
        }
        return http.Response('unexpected', 500);
      });
      final oidc = OidcProvider(
        OidcConfig(
          issuer: Uri.parse(issuer),
          clientId: 'client-1',
          clientSecret: 'secret',
          label: 'Google',
          publicUrl: Uri.parse('https://tasks.example.com'),
        ),
        client: provider,
      );
      oidcApi = Api(buildHandler(store, auth, oidc: oidc));
    });

    Future<String> startFlow() async {
      final response = await oidcApi.handler(
        Request(
          'GET',
          Uri.parse(
            'http://localhost/auth/oidc/start?redirect_uri=tasks://auth',
          ),
        ),
      );
      expect(response.statusCode, 302);
      final location = Uri.parse(response.headers['location']!);
      expect(location.queryParameters['code_challenge_method'], 'S256');
      nonce = location.queryParameters['nonce'];
      return location.queryParameters['state']!;
    }

    test(
      'sign in with the provider, then redeem the code in the app',
      () async {
        expect((await oidcApi.call('GET', '/auth/info')).$2['oidc'], {
          'label': 'Google',
        });
        final state = await startFlow();
        final callback = await oidcApi.handler(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/auth/oidc/callback?state=$state&code=abc',
            ),
          ),
        );
        expect(callback.statusCode, 302);
        final back = Uri.parse(callback.headers['location']!);
        expect(back.scheme, 'tasks');
        final (status, b) = await oidcApi.call(
          'POST',
          '/auth/redeem',
          body: {'code': back.queryParameters['code']},
        );
        expect(status, 200);
        expect((b['user'] as Map)['username'], 'ryan');
      },
    );

    test('an email with no account is told to ask the owner', () async {
      final state = await startFlow();
      final callback = await oidcApi.handler(
        Request(
          'GET',
          Uri.parse(
            'http://localhost/auth/oidc/callback?state=$state&code=stranger',
          ),
        ),
      );
      expect(callback.statusCode, 400);
      expect(
        await callback.readAsString(),
        contains('no account here for who@example.com'),
      );
    });

    test(
      'state can only be used once, and redirects must go to the app',
      () async {
        final state = await startFlow();
        await oidcApi.handler(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/auth/oidc/callback?state=$state&code=abc',
            ),
          ),
        );
        final replay = await oidcApi.handler(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/auth/oidc/callback?state=$state&code=abc',
            ),
          ),
        );
        expect(replay.statusCode, 400);

        final evil = await oidcApi.handler(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/auth/oidc/start?redirect_uri=https://evil.example/steal',
            ),
          ),
        );
        expect(evil.statusCode, 400);
      },
    );
  });
}
