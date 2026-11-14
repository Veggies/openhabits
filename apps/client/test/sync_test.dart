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
import 'package:server/remote/remote_access.dart';
import 'package:server/remote/upnp.dart';
import 'package:server/settings_store.dart';
import 'package:server/sync_store.dart';
import 'package:shelf/shelf.dart' as shelf;

const server = 'http://server';

/// A device: its own local database, repo and sync engine, talking to the
/// real server handler in memory.
class Device {
  final LocalStore store = LocalStore.inMemory();
  late final Repo repo = Repo(store);
  late final SyncEngine sync;

  /// Hosts this device can't reach right now (e.g. home, while away).
  final unreachable = <String>{};
  final hostsUsed = <String>[];

  Device(shelf.Handler handler) {
    sync = SyncEngine(
      store,
      deviceName: 'Test',
      client: MockClient((request) async {
        if (unreachable.contains(request.url.host)) {
          throw const SocketException('No route to host');
        }
        hostsUsed.add(request.url.host);
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
    handler = buildHandler(serverStore, auth);
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

  test('a task created on one device appears on the other', () async {
    phone.repo.createTask(title: 'Buy milk');
    await phone.sync.syncNow();
    await laptop.sync.syncNow();
    expect(
      laptop.repo
          .tasksFor(const SmartFilter(SmartList.inbox))
          .map((t) => t.title),
      ['Buy milk'],
    );
    expect(phone.store.pendingCount, 0);
  });

  test('concurrent edits to different fields both survive', () async {
    final id = phone.repo.createTask(title: 'Buy milk');
    await phone.sync.syncNow();
    await laptop.sync.syncNow();

    // Both devices edit while "offline".
    laptop.repo.updateTask(id, {'title': 'Buy oat milk'});
    phone.repo.complete(phone.repo.task(id)!);

    await laptop.sync.syncNow();
    await phone.sync.syncNow();
    await laptop.sync.syncNow();

    for (final device in [phone, laptop]) {
      final task = device.repo.task(id)!;
      expect((task.title, task.done), ('Buy oat milk', true));
    }
  });

  test('delete on one device, restore on another', () async {
    final id = phone.repo.createTask(title: 'Call mom');
    await phone.sync.syncNow();
    await laptop.sync.syncNow();

    phone.repo.deleteTask(id);
    await phone.sync.syncNow();
    await laptop.sync.syncNow();
    expect(laptop.repo.task(id)!.deleted, isTrue);

    laptop.repo.restoreTask(id);
    await laptop.sync.syncNow();
    await phone.sync.syncNow();
    expect(phone.repo.task(id)!.deleted, isFalse);
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
      phone.repo.createTask(title: 'x');
      await phone.sync.syncNow();
      expect(phone.sync.status, SyncStatus.signedOut);
      expect(phone.sync.isConfigured, isFalse);
      expect(phone.store.pendingCount, greaterThan(0)); // nothing lost
    });

    test("a different person on the same device doesn't see the last person's data", () async {
      phone.repo.createTask(title: "Ryan's secret");
      await phone.sync.syncNow();
      await phone.sync.signOut();

      await phone.signIn('sam', 'sam password');
      expect(phone.repo.allTasks, isEmpty);

      await phone.signIn('ryan', 'correct horse');
      expect(phone.repo.allTasks.map((t) => t.title), ["Ryan's secret"]);
    });

    test('tasks made offline before the first sign-in are uploaded', () async {
      final device = Device(handler);
      device.repo.createTask(title: 'Made offline');
      await device.signIn();
      await laptop.sync.syncNow();
      expect(
        laptop.repo.allTasks.map((t) => t.title),
        contains('Made offline'),
      );
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
      phone.repo.createTask(title: 'Added on the train');
      await phone.sync.syncNow();
      expect(phone.sync.status, SyncStatus.idle);
      expect(phone.hostsUsed, everyElement('203.0.113.7'));
      expect(phone.store.pendingCount, 0);

      await owner.sync.syncNow();
      expect(
        owner.repo.allTasks.map((t) => t.title),
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

  test('local data and queued changes survive an app restart', () {
    final dir = Directory.systemTemp.createTempSync('client_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/data.sqlite';

    final first = LocalStore.open(path);
    final id = Repo(first).createTask(title: 'Persist me');
    final pending = first.pendingCount;
    final nodeId = first.nodeId;
    first.dispose();

    final reopened = LocalStore.open(path);
    addTearDown(reopened.dispose);
    expect(Repo(reopened).task(id)!.title, 'Persist me');
    expect(reopened.pendingCount, pending);
    expect(reopened.nodeId, nodeId);

    // New edits must still win over ones made before the restart.
    Repo(reopened).updateTask(id, {'title': 'Edited'});
    expect(Repo(reopened).task(id)!.title, 'Edited');
  });

  group('Repo', () {
    late Repo repo;
    setUp(
      () => repo = Repo(
        LocalStore.inMemory(),
        clock: () => DateTime(2026, 11, 13, 10),
      ),
    );

    test('quick add creates the named list and applies everything parsed', () {
      final id = repo.quickAdd(
        'Call mom tomorrow 5pm #family !high ^Personal',
      )!;
      final task = repo.task(id)!;
      expect(repo.list(task.listId)!.name, 'Personal');
      expect(task.dueAt, DateTime(2026, 11, 14, 17));
      expect(task.priority, Priority.high);
      expect(task.tags, ['family']);
      expect(repo.tasksFor(const SmartFilter(SmartList.next7)).single.id, id);
    });

    test('quick add in Today defaults to today', () {
      final id = repo.quickAdd(
        'Water plants',
        context: const SmartFilter(SmartList.today),
      )!;
      expect(repo.task(id)!.dueDate, DateTime(2026, 11, 13));
    });

    test('completing a repeating task moves it to the next occurrence', () {
      final id = repo.quickAdd('Gym every mon wed fri')!;
      final next = repo.complete(repo.task(id)!);
      expect(next, DateTime(2026, 11, 16));
      expect(repo.task(id)!.done, isFalse);
      expect(repo.task(id)!.dueDate, DateTime(2026, 11, 16));
    });

    test('deleting a list moves its tasks to the Inbox', () {
      final listId = repo.createList('Errands', 0xFF000000);
      final id = repo.createTask(title: 'Post office', listId: listId);
      repo.deleteList(listId);
      expect(repo.task(id)!.listId, isNull);
      expect(repo.tasksFor(const SmartFilter(SmartList.inbox)).single.id, id);
    });

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

    test('streaks are strict unless Atomic Habits is on', () {
      final id = habit();
      for (final d in [10, 12, 13]) {
        repo.setHabitDone(id, DateTime(2026, 11, d), true);
      }
      expect(repo.streak(repo.habit(id)!), 2);
      repo.setPrefs({'atomicHabits': true});
      expect(repo.streak(repo.habit(id)!), 3); // one miss forgiven
      expect(repo.votes(id), 3);
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
  Future<String> externalAddress(UpnpGateway gw) async => '203.0.113.7';

  @override
  Future<void> deletePortMapping(UpnpGateway gw, int externalPort) async {}
}
