import 'package:client/data/local_store.dart';
import 'package:client/data/repo.dart';
import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'app_test.dart' show go, pumpApp;

void main() {
  // Matches `addingTickingOffAndDeleting` in HabitsCoreTests/CoreTests.swift.
  test('adding, ticking off and deleting tasks', () {
    var now = DateTime(2026, 11, 28, 9);
    final r = Repo(LocalStore.inMemory(), clock: () => now);
    final today = r.today;
    final rent = r.addTask(
      ' Pay the rent ',
      due: today,
      important: true,
      urgent: true,
    );
    final juggle = r.addTask('Learn to juggle');
    final dentist = r.addTask('Call the dentist', due: addDays(today, 1));
    final late = r.addTask('Return the library book', due: addDays(today, -3));
    ids(List<TaskItem> l) => [for (final t in l) t.id];

    expect(r.tasks.firstWhere((t) => t.id == rent).title, 'Pay the rent');
    expect(ids(r.tasksIn(TaskGroup.today)), [rent, late]);
    expect(ids(r.tasksIn(TaskGroup.upcoming)), [dentist]);
    expect(ids(r.tasksIn(TaskGroup.someday)), [juggle]);
    expect(ids(r.tasksInBox(TaskQuadrant.doNow)), [rent]);
    expect(ids(r.tasksForToday), [rent, late]);

    r.setTaskDone(rent, true);
    expect(ids(r.tasksIn(TaskGroup.done)), [rent]);
    expect(r.tasksInBox(TaskQuadrant.doNow), isEmpty);
    expect(ids(r.tasksForToday), [late, rent]);
    r.setTaskDone(rent, false);
    expect(r.tasks.firstWhere((t) => t.id == rent).doneAt, isNull);

    // Taking the date away moves it to someday.
    r.updateTask(
      dentist,
      title: 'Call the dentist',
      due: null,
      important: false,
      urgent: true,
    );
    expect(ids(r.tasksIn(TaskGroup.someday)), [dentist, juggle]);
    expect(ids(r.tasksInBox(TaskQuadrant.keepQuick)), [dentist]);

    r.deleteTask(juggle);
    expect(r.tasks.any((t) => t.id == juggle), isFalse);

    // The next day, yesterday's finished task drops off Today.
    r.setTaskDone(late, true);
    now = DateTime(2026, 11, 29, 9);
    expect(ids(r.tasksForToday), [rent]);
  });

  for (final (name, size) in [
    ('desktop', const Size(1400, 900)),
    ('phone', const Size(400, 860)),
  ]) {
    testWidgets('$name: add a task, see it today, and sort it in the matrix', (
      tester,
    ) async {
      final repo = await pumpApp(tester, size);
      repo.createHabit({'name': 'Read'});
      await go(tester, 'Tasks');

      // Added quickly, it has no date or marks.
      await tester.enterText(
        find.widgetWithText(TextField, 'New task'),
        'Learn to juggle',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(repo.tasks.map((t) => t.title), ['Learn to juggle']);
      expect(find.text('SOMEDAY'), findsOneWidget);

      // Give it today's date and mark it important and urgent.
      await tester.tap(find.text('Learn to juggle'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Important'));
      await tester.tap(find.text('Urgent'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('This one goes in “Do it now.”'),
        findsOneWidget,
      );
      await tester.tap(find.text('Due date'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('TODAY'), findsOneWidget);

      await tester.tap(find.text('Matrix'));
      await tester.pumpAndSettle();
      expect(
        repo.tasksInBox(TaskQuadrant.doNow).single.title,
        'Learn to juggle',
      );
      expect(find.text('Learn to juggle'), findsOneWidget);

      // It shows with today's habits, and can be ticked off there.
      await go(tester, name == 'phone' ? 'Habits' : 'Today');
      expect(find.text('Learn to juggle'), findsOneWidget);
      await tester.tap(find.byTooltip('Mark Learn to juggle as done'));
      await tester.pumpAndSettle();
      expect(repo.tasks.single.done, isTrue);
      expect(find.text('Learn to juggle'), findsOneWidget); // stays for today
      expect(tester.takeException(), isNull);
    });
  }

  for (final (name, size) in [
    ('desktop', const Size(1400, 900)),
    ('phone', const Size(400, 860)),
  ]) {
    testWidgets("$name: today's tasks show on Habits with no habits yet", (
      tester,
    ) async {
      final repo = await pumpApp(tester, size);
      repo.addTask('Pay the rent', due: repo.today);
      await tester.pumpAndSettle();
      expect(find.text('Pay the rent'), findsOneWidget);
    });
  }

  testWidgets('Settings from the gear keeps a way back when widened', (
    tester,
  ) async {
    await pumpApp(tester, const Size(400, 860));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1400, 900);
    await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Show the tour again'), findsNothing);
  });
}
