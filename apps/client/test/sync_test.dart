import 'dart:convert';
import 'dart:io';

import 'package:client/data/local_store.dart';
import 'package:client/data/repo.dart';
import 'package:client/data/sync_engine.dart';
import 'package:client/ui/connect.dart';
import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:server/api.dart';
import 'package:server/auth/auth_store.dart';
import 'package:server/remote/directory.dart';
import 'package:server/remote/remote_access.dart';
import 'package:server/remote/upnp.dart';
import 'package:server/settings_store.dart';
import 'package:server/sync_store.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:sqlite3/sqlite3.dart';

const server = 'http://server';

/// A device: its own local database, repo and sync engine, talking to the
/// real server handler in memory.
class Device {
  final LocalStore store;
  late final Repo repo = Repo(store);
  late final SyncEngine sync;

  /// The server this device reaches; swapped to simulate a reinstall.
  shelf.Handler handler;

  /// Hosts this device can't reach right now (e.g. home, while away).
  final unreachable = <String>{};
  final hostsUsed = <String>[];

  /// Something other than the server answering at a host, e.g. a hotel's
  /// sign-in page, or another device that happens to have the home
  /// server's address on someone else's network.
  final impostors = <String, http.Response>{};

  /// Every sign-in token sent to each host.
  final tokensSentTo = <String>[];

  /// The directory's entries (server ID → what the server published, as
  /// the real directory hands it back), shared by everyone.
  static final directory = <String, Map<String, Object?>>{};

  Device(this.handler, {LocalStore? store})
    : store = store ?? LocalStore.inMemory() {
    sync = SyncEngine(
      this.store,
      deviceName: 'Test',
      client: MockClient((request) async {
        if (unreachable.contains(request.url.host)) {
          throw const SocketException('No route to host');
        }
        hostsUsed.add(request.url.host);
        if (request.headers['authorization'] case final auth?
            when auth != 'Bearer null') {
          tokensSentTo.add(request.url.host);
        }
        if (impostors[request.url.host] case final response?) return response;
        if (request.url.host == 'directory.example') {
          final entry = directory[request.url.pathSegments.last];
          return entry == null
              ? http.Response('{"error":"No server with that ID."}', 404)
              : http.Response(jsonEncode(entry), 200);
        }
        // The current server, which a test may swap out.
        final response = await handler(
          shelf.Request(
            request.method,
            request.url,
            headers: request.headers,
            body: request.body,
          ),
        );
        return http.Response(
          await response.readAsString(),
          response.statusCode,
          headers: response.headers,
        );
      }),
    );
  }

  Future<Account> signIn([
    String user = 'ryan',
    String password = 'correct horse',
  ]) async {
    final account = await sync.signIn(server, user, password);
    await sync.syncNow();
    return account;
  }
}

void main() {
  late SyncStore serverStore;
  late AuthStore auth;
  late shelf.Handler handler;
  late Device phone;
  late Device laptop;

  setUp(() async {
    serverStore = SyncStore.inMemory();
    auth = AuthStore(serverStore);
    auth.createUser('ryan', password: 'correct horse');
    auth.createUser('sam', password: 'sam password');
    handler = buildHandler(serverStore, auth, serverId: 'home-server');
    phone = Device(handler);
    laptop = Device(handler);
    await phone.signIn();
    await laptop.signIn();
  });

  tearDown(() {
    phone.sync.dispose();
    laptop.sync.dispose();
    serverStore.close();
  });

  test('a habit created on one device appears on the other', () async {
    phone.repo.createHabit({'name': 'Read'});
    await phone.sync.syncNow();
    await laptop.sync.syncNow();
    expect(laptop.repo.habits.map((h) => h.name), ['Read']);
    expect(phone.store.pendingCount, 0);
  });

  test('a field written by a device with its date set ahead can still be '
      'changed', () async {
    final id = phone.repo.createHabit({'name': 'Read'});
    await phone.sync.syncNow();
    // A third device, its date set three days ahead, renames it.
    final owner = auth.userByName('ryan')!.id;
    serverStore.apply(owner, [
      Change(
        table: Tables.habits,
        rowId: id,
        field: 'name',
        value: 'From the future',
        hlc: Hlc(
          DateTime.now().add(const Duration(days: 3)).millisecondsSinceEpoch,
          0,
          'wrong-date',
        ),
      ),
    ]);
    await phone.sync.syncNow();
    expect(phone.repo.habit(id)!.name, 'From the future');

    phone.repo.updateHabit(id, {'name': 'Read before bed'});
    expect(phone.repo.habit(id)!.name, 'Read before bed');
    await phone.sync.syncNow();
    await laptop.sync.syncNow();
    expect(laptop.repo.habit(id)!.name, 'Read before bed');
  });

  test('concurrent edits to different fields both survive', () async {
    final id = phone.repo.createHabit({'name': 'Read'});
    await phone.sync.syncNow();
    await laptop.sync.syncNow();

    // Both devices edit while "offline".
    laptop.repo.updateHabit(id, {'name': 'Read before bed'});
    phone.repo.updateHabit(id, {'color': 0xFF009688});

    await laptop.sync.syncNow();
    await phone.sync.syncNow();
    await laptop.sync.syncNow();

    for (final device in [phone, laptop]) {
      final habit = device.repo.habit(id)!;
      expect((habit.name, habit.color), ('Read before bed', 0xFF009688));
    }
  });

  test('delete on one device, restore on another', () async {
    final id = phone.repo.createHabit({'name': 'Stretch'});
    await phone.sync.syncNow();
    await laptop.sync.syncNow();

    phone.repo.deleteHabit(id);
    await phone.sync.syncNow();
    await laptop.sync.syncNow();
    expect(laptop.repo.habit(id)!.deleted, isTrue);

    laptop.repo.updateHabit(id, {deletedField: false});
    await laptop.sync.syncNow();
    await phone.sync.syncNow();
    expect(phone.repo.habit(id)!.deleted, isFalse);
  });

  test('habits with a time can be shown in a calendar app', () async {
    phone.repo.createHabit({
      'name': 'Read',
      'time': '21:00',
      'duration': 30,
      'weekdays': [1, 2, 3, 4, 5, 6, 7],
    });
    await phone.sync.syncNow();

    final link = await laptop.sync.calendarLink();
    expect(link.url, startsWith('$server/calendar/'));
    expect(link.anywhere, isFalse); // the server has no public address

    // A calendar app fetches the link without signing in.
    final response = await handler(shelf.Request('GET', Uri.parse(link.url)));
    final ics = await response.readAsString();
    expect(response.statusCode, 200);
    expect(ics, contains('SUMMARY:Read'));
    expect(ics, contains('RRULE:FREQ=DAILY'));

    // Both devices see the same link; a new one replaces it.
    expect((await phone.sync.calendarLink()).url, link.url);
    final replaced = await phone.sync.calendarLink(replace: true);
    expect(replaced.url, isNot(link.url));
  });

  test('preferences such as the Atomic Habits choice follow you', () async {
    phone.repo.setPrefs({'atomicHabits': true});
    await phone.sync.syncNow();
    await laptop.sync.syncNow();
    expect(laptop.repo.atomicHabits, isTrue);
  });

  group('signing in', () {
    test(
      'wrong passwords explain themselves and leave the device signed out',
      () async {
        final device = Device(handler);
        await expectLater(
          device.sync.signIn(server, 'ryan', 'nope'),
          throwsA(
            isA<SyncException>().having(
              (e) => e.message,
              'message',
              "That username or password isn't right.",
            ),
          ),
        );
        expect(device.sync.isConfigured, isFalse);
        device.sync.dispose();
      },
    );

    test('a pairing code from the phone signs in a new laptop', () async {
      final pairing = await phone.sync.pairingCode();
      expect(pairing.url, server);
      final payload = parsePairingPayload(
        pairingPayload(pairing.url, pairing.code),
      )!;

      final newLaptop = Device(handler);
      final account = await newLaptop.sync.redeemCode(
        payload.server,
        payload.code,
      );
      expect(account.username, 'ryan');
      newLaptop.sync.dispose();
    });

    test('a revoked session marks the device signed out', () async {
      await laptop.sync.signOut(); // ends the laptop's session on the server
      await phone.sync.syncNow();
      expect(phone.sync.status, SyncStatus.idle); // other sessions unaffected

      final id = auth.userByName('ryan')!.id;
      for (final s in serverStore.db.select(
        'SELECT token_hash FROM sessions WHERE user_id = ?',
        [id],
      )) {
        serverStore.db.execute('DELETE FROM sessions WHERE token_hash = ?', [
          s['token_hash'],
        ]);
      }
      phone.repo.createHabit({'name': 'x'});
      await phone.sync.syncNow();
      expect(phone.sync.status, SyncStatus.signedOut);
      expect(phone.sync.isConfigured, isFalse);
      expect(phone.store.pendingCount, greaterThan(0)); // nothing lost
    });

    test("a different person on the same device doesn't see the last person's data", () async {
      phone.repo.createHabit({'name': "Ryan's secret habit"});
      await phone.sync.syncNow();
      await phone.sync.signOut();

      await phone.signIn('sam', 'sam password');
      expect(phone.repo.habits, isEmpty);

      await phone.signIn('ryan', 'correct horse');
      expect(phone.repo.habits.map((h) => h.name), ["Ryan's secret habit"]);
    });

    test('habits made offline before the first sign-in are uploaded', () async {
      final device = Device(handler);
      device.repo.createHabit({'name': 'Made offline'});
      await device.signIn();
      await laptop.sync.syncNow();
      expect(laptop.repo.habits.map((h) => h.name), contains('Made offline'));
      device.sync.dispose();
    });

    test('addresses are normalized', () {
      expect(
        SyncEngine.normalizeUrl('tasks.example.com/'),
        'https://tasks.example.com',
      );
      expect(
        SyncEngine.normalizeUrl('192.168.1.10:8080'),
        'http://192.168.1.10:8080',
      );
      expect(
        SyncEngine.normalizeUrl('nas.local:8080'),
        'http://nas.local:8080',
      );
      expect(SyncEngine.normalizeUrl('https://x.dev'), 'https://x.dev');
    });
  });

  group('away from home', () {
    late RemoteAccess remote;
    late shelf.Handler remoteHandler;
    const remoteUrl = 'https://203.0.113.7:8443';

    setUp(() async {
      final settings = SettingsStore(serverStore.db);
      remote = RemoteAccess(
        settings,
        httpsPort: 8443,
        upnp: _Router(),
        publicIp: () async => '203.0.113.7',
      );
      await remote.enable();
      remoteHandler = buildHandler(
        serverStore,
        auth,
        settings: settings,
        remote: remote,
        fingerprint: 'AA:BB',
        serverId: 'home-server',
      );
    });

    test('a phone paired by QR at home keeps working away from home', () async {
      final owner = Device(remoteHandler);
      await owner.signIn();
      final pairing = await owner.sync.pairingCode();
      final scanned = parsePairingPayload(
        pairingPayload(
          pairing.url,
          pairing.code,
          remoteUrl: pairing.remoteUrl,
          fingerprint: pairing.fingerprint,
        ),
      )!;
      expect((scanned.remote, scanned.fingerprint), (remoteUrl, 'AA:BB'));

      final phone = Device(remoteHandler);
      await phone.sync.redeemCode(
        scanned.server,
        scanned.code,
        remoteUrl: scanned.remote,
        fingerprint: scanned.fingerprint,
      );
      await phone.sync.syncNow();
      expect(phone.store.meta('fingerprint'), 'AA:BB');
      expect(phone.sync.remoteUrl, remoteUrl);

      // Leave home: the home address stops answering.
      phone.unreachable.add('server');
      phone.hostsUsed.clear();
      phone.repo.createHabit({'name': 'Added on the train'});
      await phone.sync.syncNow();
      expect(phone.sync.status, SyncStatus.idle);
      expect(phone.hostsUsed, everyElement('203.0.113.7'));
      expect(phone.store.pendingCount, 0);

      await owner.sync.syncNow();
      expect(
        owner.repo.habits.map((h) => h.name),
        contains('Added on the train'),
      );
      owner.sync.dispose();
      phone.sync.dispose();
    });

    test("a temporary problem on the server doesn't make devices forget the address", () async {
      final device = Device(remoteHandler);
      await device.signIn();
      remote.status = RemoteStatus(RemoteState.error, 'Router not answering');
      await device.sync.syncNow();
      expect(device.sync.remoteUrl, remoteUrl);
      device.sync.dispose();
    });

    test(
      'when the home address changes while away, the directory finds it',
      () async {
        final router = _Router();
        final settings = SettingsStore(serverStore.db);
        final identity = DirectoryIdentity.loadOrCreate(
          Directory.systemTemp.createTempSync('directory'),
        );
        final remote = RemoteAccess(
          settings,
          httpsPort: 8443,
          upnp: router,
          publicIp: () async => router.ip,
          // The real client, signing real updates, into the shared entries.
          directory: DirectoryClient(
            Uri.parse('https://directory.example'),
            identity,
            client: MockClient((request) async {
              final body = jsonDecode(request.body) as Map<String, Object?>;
              final payload = jsonDecode(body['payload'] as String) as Map;
              Device.directory[identity.id] = {
                'urls': payload['urls'],
                'payload': body['payload'],
                'sig': body['sig'],
              };
              return http.Response('{"ok":true}', 200);
            }),
          ),
        );
        await remote.enable();
        final handler = buildHandler(
          serverStore,
          auth,
          settings: settings,
          remote: remote,
          fingerprint: 'AA:BB',
          serverId: identity.id,
          serverKey: identity.publicKeyBase64Url,
        );

        final phone = Device(handler);
        await phone.signIn();
        expect(phone.sync.remoteUrl, 'https://203.0.113.7:8443');

        // Away from home, the provider hands the house a new address. The
        // phone only knows the old one.
        phone.unreachable.addAll({'server', '203.0.113.7'});
        router.ip = '198.51.100.30';
        await remote.refresh();

        phone.repo.createHabit({'name': 'Added after the address changed'});
        phone.hostsUsed.clear();
        await phone.sync.syncNow();
        expect(phone.sync.status, SyncStatus.idle);
        expect(phone.store.pendingCount, 0);
        expect(phone.hostsUsed, contains('directory.example'));
        expect(phone.sync.remoteUrl, 'https://198.51.100.30:8443');

        // From now on it goes straight to the new address.
        phone.hostsUsed.clear();
        await phone.sync.syncNow();
        expect(phone.hostsUsed, everyElement('198.51.100.30'));

        // A directory that's been tampered with points somewhere else. The
        // address isn't signed by the server, so the phone ignores it.
        final forger = DirectoryIdentity.loadOrCreate(
          Directory.systemTemp.createTempSync('forger'),
        );
        final forged = jsonEncode({
          'id': identity.id,
          'urls': ['https://evil.example'],
          'ts': DateTime.now().millisecondsSinceEpoch,
        });
        Device.directory[identity.id] = {
          'urls': ['https://evil.example'],
          'payload': forged,
          'sig': base64Url
              .encode(forger.sign(utf8.encode(forged)))
              .replaceAll('=', ''),
        };
        phone.unreachable.add('198.51.100.30');
        phone.repo.createHabit({'name': 'Kept safe'});
        await phone.sync.syncNow();
        expect(phone.hostsUsed, isNot(contains('evil.example')));
        expect(phone.sync.status, SyncStatus.error);
        expect(phone.store.pendingCount, greaterThan(0));
        phone.sync.dispose();
      },
    );

    test(
      "something else at an already trusted remote address can't sign the "
      'phone out',
      () async {
        final device = Device(remoteHandler);
        await device.signIn();
        device.unreachable.add('server');
        await device.sync.syncNow(); // the remote address checks out
        expect(device.sync.status, SyncStatus.idle);

        device.impostors['203.0.113.7'] = http.Response(
          '{"error":"Please sign in again."}',
          401,
        );
        device.repo.createHabit({'name': 'Kept'});
        await device.sync.syncNow();
        expect(device.sync.status, isNot(SyncStatus.signedOut));
        expect(device.store.pendingCount, greaterThan(0));
        device.sync.dispose();
      },
    );

    test(
      "away from home, another device at the home address doesn't get the "
      "token and can't sign the phone out",
      () async {
        final device = Device(remoteHandler);
        await device.signIn();
        // On someone else's network, something else has the same address as
        // the home server and refuses everything.
        device.impostors['server'] = http.Response(
          '{"error":"Please sign in again."}',
          401,
        );
        device.tokensSentTo.clear();
        device.repo.createHabit({'name': 'At a friend\'s house'});
        await device.sync.syncNow();
        expect(device.sync.status, SyncStatus.idle);
        expect(device.tokensSentTo, isNot(contains('server')));
        expect(device.store.pendingCount, 0); // went via the remote address
        device.sync.dispose();
      },
    );

    test(
      'devices follow the remote address, and forget it when turned off',
      () async {
        final device = Device(remoteHandler);
        await device.signIn();
        expect(device.sync.remoteUrl, remoteUrl);
        await remote.disable();
        await device.sync.syncNow();
        expect(device.sync.remoteUrl, isNull);
        device.sync.dispose();
      },
    );
  });

  group('things that answer but are not the server', () {
    test("a hotel's sign-in page doesn't swallow queued changes", () async {
      phone.impostors['server'] = http.Response(
        '<html>Welcome! Accept the terms to get online.</html>',
        200,
        headers: {'content-type': 'text/html'},
      );
      phone.repo.createHabit({'name': 'Made at the hotel'});
      await phone.sync.syncNow();
      expect(phone.sync.status, SyncStatus.error);
      expect(phone.store.pendingCount, greaterThan(0));

      // Back online properly: everything arrives.
      phone.impostors.clear();
      await phone.sync.syncNow();
      await laptop.sync.syncNow();
      expect(
        laptop.repo.habits.map((h) => h.name),
        contains('Made at the hotel'),
      );
    });

    test('a 200 that isn\'t a sync answer keeps the queue too', () async {
      // Even from a device signed in before servers had ids, so the address
      // isn't checked first.
      phone.store.setMeta('serverId', null);
      phone.impostors['server'] = http.Response('{"ok":true}', 200);
      phone.repo.createHabit({'name': 'Still queued'});
      await phone.sync.syncNow();
      expect(phone.store.pendingCount, greaterThan(0));
    });
  });

  group('when the server loses data', () {
    test('after a reinstall, signing in again uploads this device\'s habits '
        'instead of deleting them', () async {
      phone.repo.createHabit({'name': 'Only copy is on the phone'});
      await phone.sync.syncNow();

      // The server is wiped and set up again, same address, same name.
      final fresh = SyncStore.inMemory();
      addTearDown(fresh.close);
      final freshAuth = AuthStore(fresh)
        ..createUser('ryan', password: 'correct horse');
      phone.handler = buildHandler(fresh, freshAuth, serverId: 'reinstalled');

      await phone.sync.syncNow();
      expect(phone.sync.status, SyncStatus.error);
      expect(phone.sync.lastError, contains('sign in again'));

      await phone.signIn();
      expect(
        phone.repo.habits.map((h) => h.name),
        contains('Only copy is on the phone'),
      );
      final owner = freshAuth.userByName('ryan')!.id;
      expect(
        fresh.rows(owner, Tables.habits).values.map((h) => h['name']),
        contains('Only copy is on the phone'),
      );
    });

    test('a reinstall at a new address also keeps and uploads the habits',
        () async {
      phone.repo.createHabit({'name': 'Only copy is on the phone'});
      await phone.sync.syncNow();
      final fresh = SyncStore.inMemory();
      addTearDown(fresh.close);
      final freshAuth = AuthStore(fresh)
        ..createUser('ryan', password: 'correct horse');
      phone.handler = buildHandler(fresh, freshAuth, serverId: 'new-box');

      await phone.sync.signIn('http://new-box', 'ryan', 'correct horse');
      await phone.sync.syncNow();
      final owner = freshAuth.userByName('ryan')!.id;
      expect(
        fresh.rows(owner, Tables.habits).values.map((h) => h['name']),
        contains('Only copy is on the phone'),
      );
    });

    test("signing in doesn't fall back to the previous server's directory",
        () async {
      phone.store.setMeta(
        'directoryLookup',
        'https://directory.example/v1/servers/old',
      );
      phone.unreachable.add('new-box');
      phone.hostsUsed.clear();
      await expectLater(
        phone.sync.signIn('http://new-box', 'ryan', 'correct horse'),
        throwsA(isA<SyncException>()),
      );
      expect(phone.hostsUsed, isNot(contains('directory.example')));
    });

    test('after a restore from backup, devices send what it lost', () async {
      final dir = Directory.systemTemp.createTempSync('restore');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/data.sqlite';
      final live = SyncStore.open(path);
      final liveAuth = AuthStore(live)
        ..createUser('ryan', password: 'correct horse');
      final device = Device(buildHandler(live, liveAuth, serverId: 'home'));
      await device.signIn();
      device.repo.createHabit({'name': 'Before the backup'});
      await device.sync.syncNow();

      File(path).copySync('${dir.path}/backup.sqlite');
      device.repo.createHabit({'name': 'After the backup'});
      device.repo.createHabit({'name': 'Also after'});
      await device.sync.syncNow();
      live.close();

      // The disk fails; the owner restores last night's backup.
      final restored = SyncStore.open('${dir.path}/backup.sqlite');
      addTearDown(restored.close);
      device.handler = buildHandler(restored, AuthStore(restored),
          serverId: 'home');
      await device.sync.syncNow();
      await device.sync.syncNow();
      expect(device.sync.status, SyncStatus.idle);
      final owner = AuthStore(restored).userByName('ryan')!.id;
      expect(
        restored.rows(owner, Tables.habits).values.map((h) => h['name']),
        containsAll(['Before the backup', 'After the backup', 'Also after']),
      );
      device.sync.dispose();
    });
  });

  test('a pairing code for another server says what switching costs', () {
    expect(phone.sync.replacementWarning(server), isNull); // same server
    phone.repo.createHabit({'name': 'Not sent yet'});
    final warning = phone.sync.replacementWarning('https://elsewhere.example');
    expect(warning, contains(server));
    expect(warning, contains('as ryan'));
    expect(warning, contains("haven't been sent yet"));
    expect(Device(handler).sync.replacementWarning('https://x.example'), isNull);
  });

  test('a queued change that can\'t be read doesn\'t block the rest', () async {
    final db = sqlite3.openInMemory();
    final store = LocalStore(db);
    final device = Device(handler, store: store);
    await device.signIn();
    db.execute("INSERT INTO outbox (change) VALUES ('not json')");
    device.repo.createHabit({'name': 'After the bad one'});
    await device.sync.syncNow();
    expect(device.sync.status, SyncStatus.idle);
    expect(store.pendingCount, 0);
    await laptop.sync.syncNow();
    expect(
      laptop.repo.habits.map((h) => h.name),
      contains('After the bad one'),
    );
    device.sync.dispose();
  });

  test('local data and queued changes survive an app restart', () {
    final dir = Directory.systemTemp.createTempSync('client_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/data.sqlite';

    final first = LocalStore.open(path);
    final id = Repo(first).createHabit({'name': 'Persist me'});
    final pending = first.pendingCount;
    final nodeId = first.nodeId;
    first.dispose();

    final reopened = LocalStore.open(path);
    addTearDown(reopened.dispose);
    expect(Repo(reopened).habit(id)!.name, 'Persist me');
    expect(reopened.pendingCount, pending);
    expect(reopened.nodeId, nodeId);

    // New edits must still win over ones made before the restart.
    Repo(reopened).updateHabit(id, {'name': 'Edited'});
    expect(Repo(reopened).habit(id)!.name, 'Edited');
  });

  group('Repo', () {
    late Repo repo;
    setUp(
      () => repo = Repo(
        LocalStore.inMemory(),
        clock: () => DateTime(2026, 11, 13, 10),
      ),
    );

    String habit({String kind = 'build'}) {
      final id = repo.createHabit({
        'name': 'Read',
        'kind': kind,
        'weekdays': [1, 2, 3, 4, 5, 6, 7],
      });
      // Pretend it was created a week ago.
      repo.updateHabit(id, {
        'createdAt': DateTime(2026, 11, 6).toUtc().toIso8601String(),
      });
      return id;
    }

    test('one missed day is forgiven, two in a row are not', () {
      final id = habit();
      for (final d in [10, 12, 13]) {
        repo.setHabitDone(id, DateTime(2026, 11, d), true);
      }
      expect(repo.streak(repo.habit(id)!), 3); // one miss forgiven
      expect(repo.votes(id), 3);
      repo.setHabitDone(id, DateTime(2026, 11, 12), false);
      expect(repo.streak(repo.habit(id)!), 1); // the 11th and 12th: two misses
    });

    test('size check-ins: grow, keep, shrink, and "feels right"', () {
      repo.setPrefs({'atomicHabits': true});
      final id = repo.createHabit({
        'name': 'Read',
        'weekdays': [1, 2, 3, 4, 5, 6, 7],
        'twoMinute': 'Read one page',
      });
      repo.updateHabit(id, {
        'createdAt': DateTime(2026, 10, 20).toUtc().toIso8601String(),
      });
      Habit habit() => repo.habit(id)!;

      // Missing most days: offer to make it smaller.
      expect(repo.sizeSuggestion(habit()), SizeSuggestion.shrink);

      for (var d = 0; d < 14; d++) {
        if (d != 3) {
          repo.setHabitDone(id, addDays(DateTime(2026, 11, 13), -d), true);
        }
      }
      expect(repo.record(habit(), repo.clock(), 14), (done: 13, scheduled: 14));
      expect(repo.sizeSuggestion(habit()), SizeSuggestion.grow);

      // "Most days" is 80%, rounded up.
      expect(Repo.growDaysNeeded(14), 12); // every day
      expect(Repo.growDaysNeeded(10), 8); // weekdays
      expect(Repo.growDaysNeeded(6), 5); // three days a week
      expect(Repo.growDaysNeeded(2), 2); // once a week

      // Growing it remembers where it started.
      repo.resize(habit(), 'Read five pages');
      expect(habit().plan.twoMinute, 'Read five pages');
      expect(
        [for (final v in habit().plan.sizeHistory) v.text],
        ['Read one page', 'Read five pages'],
      );
      expect(repo.sizeSuggestion(habit()), isNull); // next check in two weeks

      // "Keep it as it is" also waits two weeks, without a new version.
      repo.updateHabit(id, {'steppedUpAt': '2026-10-25'});
      expect(repo.sizeSuggestion(habit()), SizeSuggestion.grow);
      repo.keepSize(habit());
      expect(repo.sizeSuggestion(habit()), isNull);
      expect(habit().plan.sizeHistory, hasLength(2));

      // "This feels right": no more suggestions, until undone.
      repo.updateHabit(id, {'steppedUpAt': '2026-10-25'});
      repo.settleSize(habit());
      repo.updateHabit(id, {'steppedUpAt': '2026-10-25'});
      expect(repo.sizeSuggestion(habit()), isNull);
      repo.settleSize(habit(), settled: false);
      repo.updateHabit(id, {'steppedUpAt': '2026-10-25'});
      expect(repo.sizeSuggestion(habit()), SizeSuggestion.grow);

      // The Progress grid's weeks (weeks start on Sunday by default).
      // Today is Friday Nov 13; Tuesday Nov 10 was missed.
      expect(repo.weekRecord(habit(), DateTime(2026, 11, 8)), (
        done: 5,
        scheduled: 6, // this week so far
      ));
      expect(repo.weekRecord(habit(), DateTime(2026, 11, 1)), (
        done: 7,
        scheduled: 7,
      ));
      expect(repo.weekRecord(habit(), DateTime(2026, 11, 15)), (
        done: 0,
        scheduled: 0, // next week hasn't started
      ));
    });

    test('breaking a habit: a check-in means "I stayed clear"', () {
      final id = habit(kind: 'quit'); // started Nov 6; today is Nov 13
      expect(repo.daysClean(repo.habit(id)!), 0); // nothing marked yet
      for (var d = 6; d <= 13; d++) {
        if (d != 10) repo.setHabitDone(id, DateTime(2026, 11, d), true);
      }
      expect(repo.daysClean(repo.habit(id)!), 3); // Nov 11, 12, 13
      expect(repo.record(repo.habit(id)!, repo.clock(), 7), (
        done: 6,
        scheduled: 7,
      ));
    });

    test('scorecard and weekly review', () {
      repo.addScorecardItem('Check phone in bed');
      repo.updateScorecardItem(repo.scorecard.single.id, {'rating': '-'});
      expect(repo.scorecard.single.rating, '-');

      repo.setPrefs({'atomicHabits': true});
      habit();
      expect(repo.lastWeekReviewDue, isTrue);
      repo.saveReview(DateTime(2026, 11, 5), 'wentWell', 'Read every day');
      expect(repo.lastWeekReviewDue, isFalse);
      expect(
        repo.review(DateTime(2026, 11, 2)).answers['wentWell'],
        'Read every day',
      );
    });
  });
}

/// A home router that does whatever remote access asks.
class _Router extends UpnpClient {
  /// The home's internet address, as the provider has assigned it today.
  String ip = '203.0.113.7';

  @override
  Future<UpnpGateway?> discover({
    Duration timeout = const Duration(seconds: 3),
  }) async => UpnpGateway(
    Uri.parse('http://192.168.1.1/ctl'),
    'WANIPConnection:1',
    '192.168.1.20',
  );

  @override
  Future<void> addPortMapping(
    UpnpGateway gw, {
    required int externalPort,
    required int internalPort,
    String description = '',
    int leaseSeconds = 3600,
  }) async {}

  @override
  Future<String> externalAddress(UpnpGateway gw) async => ip;

  @override
  Future<void> deletePortMapping(UpnpGateway gw, int externalPort) async {}
}
