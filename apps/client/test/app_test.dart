import 'package:client/data/focus_controller.dart';
import 'package:client/data/local_store.dart';
import 'package:client/data/repo.dart';
import 'package:client/data/sync_engine.dart';
import 'package:client/main.dart';
import 'package:client/ui/common.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Future<Repo> pumpApp(
  WidgetTester tester,
  Size size, {
  bool onboarded = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final store = LocalStore.inMemory();
  if (onboarded) store.setMeta('onboarded', '1');
  final repo = Repo(store);
  await tester.pumpWidget(
    App(repo: repo, sync: SyncEngine(store), focus: FocusController(repo)),
  );
  return repo;
}

void main() {
  for (final (name, size) in [
    ('desktop', const Size(1400, 900)),
    ('phone', const Size(400, 860)),
  ]) {
    testWidgets('$name: quick add, then visit every screen', (tester) async {
      final repo = await pumpApp(tester, size);

      await tester.enterText(
        find.byType(TextField).first,
        'Pay rent today 9am !high #home',
      );
      await tester.pump();
      expect(find.text('High priority'), findsOneWidget); // live parse preview
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(find.text('Pay rent'), findsOneWidget);
      expect(repo.tasksFor(const SmartFilter(SmartList.today)).single.tags, [
        'home',
      ]);

      // Open the task detail.
      await tester.tap(find.text('Pay rent'));
      await tester.pumpAndSettle();
      expect(find.text('Subtasks'), findsOneWidget);
      if (size.width < 840) {
        await tester.pageBack();
        await tester.pumpAndSettle();
      }

      for (final tab in ['Calendar', 'Habits', 'Focus', 'Settings', 'Tasks']) {
        await tester.tap(find.text(tab).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: tab);
      }
    });
  }

  testWidgets('calendar shows tasks in month, week and day views', (
    tester,
  ) async {
    final repo = await pumpApp(tester, const Size(1400, 900));
    repo.quickAdd('Dentist today 3pm');
    repo.quickAdd('Taxes today');
    await tester.tap(find.text('Calendar'));
    await tester.pumpAndSettle();
    expect(find.text('Dentist'), findsWidgets);

    for (final view in ['Week', 'Day', 'Month']) {
      await tester.tap(find.text(view));
      await tester.pumpAndSettle();
      expect(find.text('Dentist'), findsWidgets, reason: view);
      expect(find.text('Taxes'), findsWidgets, reason: view);
    }

    // Weeks start on Sunday, with full day names.
    expect(find.text('Sun'), findsWidgets);
    expect(find.text('S'), findsNothing);

    // In month view, the title opens a dropdown of months with the year
    // changeable above them.
    final now = DateTime.now();
    await tester.tap(find.text('${monthNamesLong[now.month - 1]} ${now.year}'));
    await tester.pumpAndSettle();
    expect(find.text('Jan'), findsOneWidget);
    expect(find.text('Dec'), findsOneWidget);
    // The last row isn't clipped by the dropdown.
    expect(find.text('Dec').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('Next year'));
    await tester.pumpAndSettle();
    expect(find.text('${now.year + 1}'), findsOneWidget);
    await tester.tap(find.text('Jul'));
    await tester.pumpAndSettle();
    expect(find.text('July ${now.year + 1}'), findsOneWidget);
    expect(find.text('Jan'), findsNothing); // the dropdown closed

    // The arrows beside the title step one month.
    await tester.tap(find.byTooltip('Next'));
    await tester.pumpAndSettle();
    expect(find.text('August ${now.year + 1}'), findsOneWidget);

    // In year view, the title opens a list of years.
    await tester.tap(find.text('Year'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('${now.year + 1}'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('${now.year - 2}'));
    await tester.pumpAndSettle();
    expect(find.text('${now.year - 2}'), findsOneWidget);
    expect(find.text('January'), findsOneWidget); // still the year view

    // Today comes back from anywhere.
    await tester.tap(find.text('Today'));
    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    expect(
      find.text('${monthNamesLong[now.month - 1]} ${now.year}'),
      findsOneWidget,
    );
  });

  testWidgets('habits with a time show on the calendar', (tester) async {
    final repo = await pumpApp(tester, const Size(1400, 900));
    final today = DateTime.now();
    final id = repo.createHabit({
      'name': 'Read a book',
      'time': '21:00',
      'duration': 30,
      'weekdays': [1, 2, 3, 4, 5, 6, 7],
    });
    repo.createHabit({'name': 'Drink water'}); // no time: not on the calendar
    expect(
      repo.habit(id)!.plan.isEmpty,
      isTrue,
    ); // a time alone isn't the framework

    await tester.tap(find.text('Calendar'));
    await tester.pumpAndSettle();
    expect(find.text('Read a book'), findsWidgets); // month grid and day list
    expect(find.text('Drink water'), findsNothing);
    expect(find.textContaining('30 min · Habit'), findsOneWidget);

    await tester.tap(find.text('Day'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Read a book'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Read a book'));
    await tester.pumpAndSettle();
    expect(repo.isHabitDone(id, today), isTrue);

    // The editor offers time and length without Atomic Habits.
    await tester.tap(find.text('Habits'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drink water').first);
    await tester.pumpAndSettle();
    expect(find.text('Time (optional)'), findsOneWidget);
    expect(find.text('How long'), findsNothing); // only once there's a time
  });

  testWidgets('the habit editor scrolls from anywhere in the window', (
    tester,
  ) async {
    final repo = await pumpApp(tester, const Size(1400, 500));
    repo.setPrefs({'atomicHabits': true}); // a long form
    await tester.tap(find.text('Habits'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New habit'));
    await tester.pumpAndSettle();

    final before = tester.getTopLeft(find.text('Repeat on')).dy;
    // Mouse wheel near the window's left edge, far outside the form.
    tester.binding.handlePointerEvent(
      const PointerScrollEvent(
        position: Offset(30, 300),
        scrollDelta: Offset(0, 200),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Repeat on')).dy, lessThan(before));
  });

  for (final (name, size) in [
    ('desktop', const Size(1400, 900)),
    ('phone', const Size(400, 860)),
  ]) {
    testWidgets('$name: scorecard and weekly review are tabs on Habits', (
      tester,
    ) async {
      final repo = await pumpApp(tester, size);
      repo.createHabit({'name': 'Read'});
      await tester.tap(find.text('Habits').last);
      await tester.pumpAndSettle();
      expect(find.text('Scorecard'), findsNothing); // framework off: no tabs

      repo.setPrefs({'atomicHabits': true});
      await tester.pumpAndSettle();
      expect(find.text('My habits'), findsOneWidget);
      expect(find.text('Weekly review'), findsOneWidget);

      // With few habits, the list suggests the scorecard.
      await tester.tap(find.text('Not sure what to work on?'));
      await tester.pumpAndSettle();
      expect(find.byType(FloatingActionButton), findsNothing);
      await tester.enterText(find.byType(TextField), 'Check phone in bed');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(repo.scorecard.single.text, 'Check phone in bed');

      await tester.tap(find.text('Weekly review'));
      await tester.pumpAndSettle();
      expect(find.text('How the week went'), findsOneWidget);

      await tester.tap(find.text('My habits'));
      await tester.pumpAndSettle();
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(find.text('Not sure what to work on?'), findsNothing);
    });
  }

  testWidgets('habits can be created and checked in', (tester) async {
    final repo = await pumpApp(tester, const Size(1400, 900));
    await tester.tap(find.text('Habits'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New habit'));
    await tester.pumpAndSettle();
    // The framework is off, so only the basics are shown.
    expect(find.text('Atomic Habits'), findsNothing);
    // Days are one row, starting on Sunday.
    final sun = tester.getCenter(find.text('Sun'));
    final sat = tester.getCenter(find.text('Sat'));
    expect(sun.dy, sat.dy);
    expect(sun.dx, lessThan(sat.dx));
    await tester.enterText(find.byType(TextField).first, 'Meditate');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Meditate'), findsWidgets); // card and overview

    await tester.tap(find.text('Done today'));
    await tester.pumpAndSettle();
    expect(repo.streak(repo.habits.single), 1);
    expect(find.text('1 day'), findsOneWidget);
  });

  testWidgets('the "Completed" message goes away on its own', (tester) async {
    final repo = await pumpApp(tester, const Size(1400, 900));
    repo.quickAdd('Water plants today');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.text('Completed "Water plants"'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Completed "Water plants"'), findsNothing);
  });

  testWidgets('setup wizard can be run again from Settings', (tester) async {
    final repo = await pumpApp(tester, const Size(1400, 900));
    repo.setPrefs({'atomicHabits': false});
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Run setup again'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Run setup again'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip — use on this device only'));
    await tester.pumpAndSettle();
    // Asked again, even though it was answered before.
    expect(find.text('Build habits with Atomic Habits?'), findsOneWidget);
    await tester.tap(find.text('Yes, walk me through my first habit'));
    await tester.pumpAndSettle();
    expect(repo.atomicHabits, isTrue);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start using Tasks'));
    await tester.pumpAndSettle();
    expect(find.text('Run setup again'), findsOneWidget); // back in Settings
  });

  testWidgets(
    'setup wizard: skip the server, build a habit with Atomic Habits',
    (tester) async {
      final repo = await pumpApp(
        tester,
        const Size(500, 900),
        onboarded: false,
      );
      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();
      expect(find.text('Connect to your server'), findsOneWidget);
      await tester.tap(find.text('Skip — use on this device only'));
      await tester.pumpAndSettle();

      expect(find.text('Build habits with Atomic Habits?'), findsOneWidget);
      await tester.tap(find.text('Yes, walk me through my first habit'));
      await tester.pumpAndSettle();
      expect(repo.atomicHabits, isTrue);

      Future<void> fill(String label, String text) async {
        await tester.enterText(find.widgetWithText(TextField, label), text);
        await tester.pump();
      }

      Future<void> next() async {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
      }

      await fill('I am…', 'a reader');
      await next();
      await fill('Habit', 'Read');
      await fill('Start with', 'Read one page');
      await fill('Build up to (optional)', 'Read 20 pages a day');
      await next();
      // Clicking the "When" box itself opens the time picker.
      await tester.tap(find.widgetWithText(TextField, 'When'));
      await tester.pumpAndSettle();
      expect(find.byType(TimePickerDialog), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('07:00'), findsOneWidget);
      await fill('After I…', 'pour my morning coffee');
      await fill('Where', 'on the couch');
      await next();
      await fill('Reward', 'A square of chocolate');
      await next();
      expect(
        find.textContaining(
          'After I pour my morning coffee, I will read one page at 7:00 AM on the couch.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Create habit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start using Tasks'));
      await tester.pumpAndSettle();

      final habit = repo.habits.single;
      expect(habit.name, 'Read');
      expect(habit.plan.identity, 'a reader');
      expect(habit.plan.reward, 'A square of chocolate');
      expect(find.text('Today'), findsWidgets); // now in the app
    },
  );

  testWidgets('with Atomic Habits on, the editor shows the four laws', (
    tester,
  ) async {
    // Tall enough that the whole editor is laid out without scrolling.
    final repo = await pumpApp(tester, const Size(1400, 2400));
    repo.setPrefs({'atomicHabits': true});
    await tester.tap(find.text('Habits'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New habit'));
    await tester.pumpAndSettle();
    for (final law in [
      'Make it obvious',
      'Make it attractive',
      'Make it easy',
      'Make it satisfying',
    ]) {
      expect(find.text(law), findsOneWidget);
    }
    await tester.tap(find.text('Break a habit'));
    await tester.pumpAndSettle();
    for (final law in [
      'Make it invisible',
      'Make it unattractive',
      'Make it difficult',
      'Make it unsatisfying',
    ]) {
      expect(find.text(law), findsOneWidget);
    }
  });

  testWidgets('date picker uses day names and can jump to any month', (
    tester,
  ) async {
    final repo = await pumpApp(tester, const Size(1400, 900));
    repo.quickAdd('Book flights');
    await tester.tap(find.text('Inbox'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Book flights'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Due date'));
    await tester.pumpAndSettle();

    expect(find.text('Sun'), findsOneWidget);
    expect(find.text('Wed'), findsOneWidget);
    final now = DateTime.now();
    await tester.tap(find.text('${monthNamesLong[now.month - 1]} ${now.year}'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jul'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(repo.allTasks.single.dueDate, DateTime(now.year, 7, 15));
  });

  testWidgets(
    "focus: lengths are adjustable and switching phases doesn't move the timer",
    (tester) async {
      await pumpApp(tester, const Size(1400, 900));
      await tester.tap(find.text('Focus'));
      await tester.pumpAndSettle();
      expect(find.text('25:00'), findsOneWidget);
      await tester.tap(find.byTooltip('5 minutes more'));
      await tester.pump();
      expect(find.text('30:00'), findsOneWidget);

      // The minutes can be typed too.
      await tester.enterText(find.widgetWithText(TextField, '30'), '45');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('45:00'), findsOneWidget);

      // Just two phases: Focus and Break.
      expect(find.text('Long break'), findsNothing);
      final startButton = tester.getCenter(find.text('Start'));
      await tester.tap(find.text('Break').first);
      await tester.pumpAndSettle();
      expect(find.text('05:00'), findsOneWidget);
      expect(tester.getCenter(find.text('Start')), startButton);
    },
  );
}
