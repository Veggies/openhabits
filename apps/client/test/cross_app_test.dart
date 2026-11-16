/// The Flutter half of the Apple ↔ Android check in `tool/cross_app_check.sh`.
/// Skipped unless the script sets HABITS_TEST_SERVER and HABITS_CROSS_NAME.
library;

import 'dart:io';

import 'package:client/data/local_store.dart';
import 'package:client/data/repo.dart';
import 'package:client/data/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final env = Platform.environment;
  final url = env['HABITS_TEST_SERVER'];
  final name = env['HABITS_CROSS_NAME'];

  test(
    'the Flutter app reads and edits a habit made by the Apple app',
    () async {
      final store = LocalStore.inMemory();
      final repo = Repo(store);
      final sync = SyncEngine(store, deviceName: 'Cross-app Android');
      addTearDown(sync.dispose);

      await sync.signIn(
        url!,
        env['HABITS_TEST_USER'] ?? 'tester',
        env['HABITS_TEST_PASSWORD'] ?? 'testpass123',
      );
      await sync.syncNow();
      expect(sync.lastError, isNull);

      final habit = repo.habits.where((h) => h.name == name).firstOrNull;
      expect(habit, isNotNull, reason: "The Apple app's habit didn't arrive");
      expect(habit!.weekdays, {2, 4});
      expect(habit.duration, 15);
      expect(repo.isHabitDone(habit.id, DateTime.now()), isTrue);

      repo.updateHabit(habit.id, {
        'name': '$name (from Android)',
        'duration': 25,
      });
      repo.setHabitDone(habit.id, DateTime.now(), false);
      await sync.syncNow();
      expect(store.pendingCount, 0);
    },
    skip: url == null || name == null
        ? 'Run through tool/cross_app_check.sh'
        : false,
  );
}
