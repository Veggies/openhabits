import 'package:core/core.dart';
import 'package:client/data/focus_controller.dart';
import 'package:client/data/local_store.dart';
import 'package:client/data/repo.dart';
import 'package:client/data/sync_engine.dart';
import 'package:client/main.dart';
import 'package:client/ui/common.dart';
import 'package:client/ui/habit_editor.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Future<Repo> pumpApp(
  WidgetTester tester,
  Size size, {
  bool onboarded = true,
  DateTime Function()? clock,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final store = LocalStore.inMemory();
  if (onboarded) store.setMeta('onboarded', '1');
  final repo = Repo(store, clock: clock);
  await tester.pumpWidget(
    App(
      repo: repo,
      sync: SyncEngine(store),
      focus: FocusController(repo, clock: tester.binding.clock.now),
    ),
  );
  return repo;
}

/// A destination in the app's navigation: the bottom bar on phones, the
/// tabs across the top on computers.
Finder nav(String label) => find.descendant(
  of: find.byWidgetPredicate(
    (w) => w is NavigationBar || w is SegmentedButton<AppTab>,
  ),
  matching: find.text(label),
);

/// Goes to a screen. On computers, Settings is a button, not a tab.
Future<void> go(WidgetTester tester, String label) async {
  final tab = nav(label);
  await tester.tap(tab.evaluate().isNotEmpty ? tab : find.byTooltip(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the habit list shows this week, from the chosen first day', (
    tester,
  ) async {
    // A Wednesday, with weeks starting on Monday.
    final now = DateTime(2026, 11, 18, 12);
    final repo = await pumpApp(tester, const Size(420, 900), clock: () => now);
    repo.setPrefs({'weekStart': DateTime.monday});
    final id = repo.createHabit({'name': 'Read'});
    await tester.pumpAndSettle();

    // Monday to Sunday, in order, under the circles.
    final names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final xs = [for (final n in names) tester.getCenter(find.text(n)).dx];
    expect(xs, orderedEquals([...xs]..sort()));

    // Earlier this week can be ticked; later this week can't, yet.
    await tester.tap(find.text('Mon'));
    await tester.tap(find.text('Fri'));
    await tester.pumpAndSettle();
    expect(repo.isHabitDone(id, DateTime(2026, 11, 16)), isTrue);
    expect(repo.isHabitDone(id, DateTime(2026, 11, 20)), isFalse);
    // Tapping a later day does nothing at all (it doesn't open the habit).
    expect(find.text('Your plan'), findsNothing);

    // With weeks starting on Sunday, the row starts on Sunday instead.
    repo.setPrefs({'weekStart': DateTime.sunday});
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.text('Sun')).dx,
      lessThan(tester.getCenter(find.text('Mon')).dx),
    );
  });

  for (final (name, size) in [
    ('desktop', const Size(1400, 900)),
    ('phone', const Size(400, 860)),
  ]) {
    testWidgets('$name: visit every screen', (tester) async {
      final repo = await pumpApp(tester, size);
      repo.createHabit({'name': 'Read'});
      expect(find.text('Tasks'), findsNothing);
      expect(find.text('Calendar'), findsNothing);
      final first = name == 'phone' ? 'Habits' : 'Today';
      for (final tab in ['Progress', 'Reflect', 'Focus', 'Settings', first]) {
        await go(tester, tab);
        expect(tester.takeException(), isNull, reason: tab);
      }
      expect(find.text('Read'), findsWidgets);
    });
  }

  testWidgets('the habit editor scrolls from anywhere in the window', (
    tester,
  ) async {
    await pumpApp(tester, const Size(1400, 500));
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
    testWidgets('$name: Reflect has the weekly review and the scorecard', (
      tester,
    ) async {
      final repo = await pumpApp(tester, size);
      repo.createHabit({'name': 'Read'});
      await tester.pumpAndSettle();

      // With few habits, the list suggests the scorecard, in Reflect.
      await tester.tap(find.text('Not sure what to work on?'));
      await tester.pumpAndSettle();
      expect(find.text('Scorecard'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Check phone in bed');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(repo.scorecard.single.text, 'Check phone in bed');
      // Rated with coloured pills.
      await tester.tap(find.byTooltip('Hurts'));
      await tester.pumpAndSettle();
      expect(repo.scorecard.single.rating, '-');

      await tester.tap(find.text('Weekly review'));
      await tester.pumpAndSettle();
      expect(find.text('How the week went'), findsOneWidget);
    });
  }

  testWidgets('size check-in: grow it, and see it on the Progress tab', (
    tester,
  ) async {
    final repo = await pumpApp(tester, const Size(1400, 900));
    final today = dateOnly(DateTime.now());
    final id = repo.createHabit({
      'name': 'Read',
      'color': 0xFF3F51B5,
      'weekdays': [1, 2, 3, 4, 5, 6, 7],
      'twoMinute': 'Read one page',
    });
    final walk = repo.createHabit({'name': 'Walk', 'color': 0xFF009688});
    for (final h in [id, walk]) {
      repo.updateHabit(h, {
        'createdAt': addDays(today, -40).toUtc().toIso8601String(),
      });
    }
    for (var d = 0; d < 14; d++) {
      if (d != 3) repo.setHabitDone(id, addDays(today, -d), true);
    }
    await tester.pumpAndSettle();

    expect(find.text('Read one page'), findsOneWidget);
    await tester.tap(find.text('Time for a check-in'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('you did this on 13 of the 14 days it was scheduled'),
      findsOneWidget,
    );
    expect(find.text('Is it starting to feel too easy?'), findsOneWidget);
    expect(find.text('Keep it as it is'), findsOneWidget);
    expect(find.text('This feels right, stop asking'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Your new version'),
      'Read five pages',
    );
    await tester.tap(find.text('Make it bigger'));
    await tester.pumpAndSettle();
    expect(repo.habit(id)!.plan.twoMinute, 'Read five pages');
    expect(
      find.byTooltip('Grown from: Read one page  →  Read five pages'),
      findsOneWidget,
    );
    expect(find.text('Time for a check-in'), findsNothing);

    final scroll = repo.createHabit({
      'name': 'Scrolling in bed',
      'kind': 'quit',
    });
    repo.updateHabit(scroll, {
      'createdAt': addDays(today, -40).toUtc().toIso8601String(),
    });
    // Stayed clear every day of the last four weeks but one.
    for (var d = 0; d < 28; d++) {
      if (d != 2) repo.setHabitDone(scroll, addDays(today, -d), true);
    }
    await tester.tap(find.text('Progress'));
    await tester.pumpAndSettle();
    // One button for the period, which opens a menu of them all, and one
    // for which habits to show.
    expect(find.text('All habits'), findsOneWidget);
    await tester.tap(find.text('Since you started'));
    await tester.pumpAndSettle();
    for (final range in ['1 month', '3 months', '6 months', '1 year']) {
      expect(find.widgetWithText(MenuItemButton, range), findsOneWidget);
    }
    await tester.tap(find.widgetWithText(MenuItemButton, '3 months'));
    await tester.pumpAndSettle();
    expect(find.text('3 months'), findsOneWidget); // now the button's label

    // Each habit says how the last four weeks went, in words.
    expect(find.text('BUILDING'), findsOneWidget);
    expect(find.text('BREAKING'), findsOneWidget);
    // The period is part of each line, so nothing needs a heading.
    expect(find.text('Last 4 weeks'), findsNothing);
    expect(find.text('27 of the last 28 days clear'), findsOneWidget);
    final read = repo.record(repo.habit(id)!, repo.clock(), 28);
    expect(
      find.text('${read.done} of the last ${read.scheduled} days'),
      findsOneWidget,
    );

    // Hovering or tapping a square says how that week went, and what the
    // version changed from and to.
    final week = repo.weekRecord(
      repo.habit(id)!,
      startOfWeek(today, repo.weekStart),
    );
    final messages = [
      for (final t in tester.widgetList<Tooltip>(find.byType(Tooltip)))
        t.message ?? '',
    ];
    expect(
      messages,
      contains(
        'Read\nThis week: ${week.done} of ${week.scheduled} '
        'day${week.scheduled == 1 ? '' : 's'} so far\n\n'
        'You changed your version on ${fullDate(today)}\n'
        'From: Read one page\nTo: Read five pages',
      ),
    );

    // Switching a habit off in the filter menu hides its row, and the
    // button says how many are showing.
    await tester.tap(find.text('All habits'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxMenuButton, 'Walk'));
    await tester.pumpAndSettle();
    await tester.tapAt(Offset.zero); // close the menu
    await tester.pumpAndSettle();
    expect(find.text('2 of 3 habits'), findsOneWidget);
    expect(find.byKey(const ValueKey('progress-grid')), findsOneWidget);
    expect(find.text('Walk'), findsNothing);
    expect(find.text('Read'), findsWidgets);
  });

  testWidgets('habits can be created and checked in', (tester) async {
    final repo = await pumpApp(tester, const Size(1400, 900));
    await tester.tap(find.text('New habit'));
    await tester.pumpAndSettle();
    // Days are one row, starting on Sunday.
    final sun = tester.getCenter(find.text('Sun'));
    final sat = tester.getCenter(find.text('Sat'));
    expect(sun.dy, sat.dy);
    expect(sun.dx, lessThan(sat.dx));
    await tester.enterText(find.byType(TextField).first, 'Meditate');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Meditate'), findsWidgets); // card and overview

    await tester.tap(find.byTooltip('Done today'));
    await tester.pumpAndSettle();
    expect(repo.streak(repo.habits.single), 1);
    expect(find.byTooltip('A streak of 1 day'), findsOneWidget);
  });

  testWidgets('the tour can be taken again from Settings', (tester) async {
    await pumpApp(tester, const Size(1400, 900));
    await go(tester, 'Settings');
    await tester.scrollUntilVisible(
      find.text('Show the tour again'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(find.text('Show the tour again'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show the tour again'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    // Straight to the tour: no need to connect again.
    expect(find.text('Check in each day'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Miss once, but never twice'), findsOneWidget);
    await tester.tap(find.text('Skip tour'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("I'll do it later"));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start using OpenHabits'));
    await tester.pumpAndSettle();
    expect(
      find.text('Show the tour again'),
      findsOneWidget,
    ); // back in Settings
  });

  testWidgets('setup wizard: skip the server, take the tour, build a habit', (
    tester,
  ) async {
    final repo = await pumpApp(tester, const Size(500, 900), onboarded: false);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    expect(find.text('Connect to your server'), findsOneWidget);
    await tester.tap(find.text('Skip — use on this device only'));
    await tester.pumpAndSettle();

    // The tour, one page at a time.
    for (final title in [
      'Check in each day',
      'Miss once, but never twice',
      'Start small, then grow it',
      'Break bad habits too',
      'Give each habit a plan',
      "See how it's going",
      'Look back each week',
      'Focus, and earn your tomatoes',
      'On all your devices',
    ]) {
      expect(find.text(title), findsOneWidget);
      await tester.ensureVisible(
        find.text('Next').evaluate().isEmpty
            ? find.text('Continue')
            : find.text('Next'),
      );
      await tester.tap(
        find.text('Next').evaluate().isEmpty
            ? find.text('Continue')
            : find.text('Next'),
      );
      await tester.pumpAndSettle();
    }
    expect(find.text('Build your first habit?'), findsOneWidget);
    await tester.tap(find.text("Let's build one"));
    await tester.pumpAndSettle();

    Future<void> fill(String label, String text) async {
      await tester.enterText(find.widgetWithText(TextField, label), text);
      await tester.pump();
    }

    Future<void> next() async {
      await tester.ensureVisible(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }

    await fill('Who you want to become', 'a reader');
    await next();
    await fill('Habit', 'Read');
    // Starting small is optional: the boxes appear once it's switched on.
    expect(find.text('Your version for now'), findsNothing);
    await tester.tap(find.text('Start small and grow it'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('For a daily habit, "most days" means 12 out of 14.'),
      findsOneWidget,
    );
    await fill('Your version for now', 'Read one page');
    await next();
    // Clicking the "When" box itself opens the time picker.
    await tester.tap(find.widgetWithText(TextField, 'When'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('07:00'), findsOneWidget);
    // "After I" is shown in front of the box; typing it too doesn't double it.
    await fill(
      'Right after something you already do',
      'After I pour my morning coffee',
    );
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
    await tester.tap(find.text('Start using OpenHabits'));
    await tester.pumpAndSettle();

    final habit = repo.habits.single;
    expect(habit.name, 'Read');
    expect(habit.plan.identity, 'a reader');
    expect(habit.plan.reward, 'A square of chocolate');
    expect(find.text('Read'), findsWidgets); // now in the app, in the list
  });

  testWidgets("saving the editor doesn't undo another device's edit", (
    tester,
  ) async {
    final repo = await pumpApp(tester, const Size(1400, 2400));
    final id = repo.createHabit({'name': 'Read', 'color': listColors[0]});
    await tester.pumpAndSettle();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => HabitEditor(existing: repo.habit(id)),
          ),
        );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Read'),
      'Read before bed',
    );
    // While the editor is open, a sync brings a new colour from the laptop.
    repo.updateHabit(id, {'color': listColors[5]});
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(repo.habit(id)!.name, 'Read before bed');
    expect(repo.habit(id)!.color, listColors[5]);
  });

  testWidgets('the editor shows the four laws', (tester) async {
    // Tall enough that the whole editor is laid out without scrolling.
    await pumpApp(tester, const Size(1400, 2400));
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

  testWidgets(
    "focus: lengths are adjustable and switching phases doesn't move the timer",
    (tester) async {
      await pumpApp(tester, const Size(1400, 900));
      await go(tester, 'Focus');
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

  testWidgets('focus: a typed length counts when you go straight to Start', (
    tester,
  ) async {
    await pumpApp(tester, const Size(1400, 900));
    await go(tester, 'Focus');
    await tester.enterText(find.widgetWithText(TextField, '25'), '40');
    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(find.text('40:00'), findsOneWidget);
    await tester.tap(find.byTooltip('Reset'));
    await tester.pump();
  });

  testWidgets('focus: looking at Break leaves the session running', (
    tester,
  ) async {
    await pumpApp(tester, const Size(1400, 900));
    await go(tester, 'Focus');
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.tap(find.text('Break').first);
    await tester.pump();
    expect(find.text('05:00'), findsOneWidget);
    expect(find.text('Your focus session is still going.'), findsOneWidget);
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          )
          .value,
      0,
    );
    // A length typed here is the break's, not the running session's.
    await tester.enterText(find.widgetWithText(TextField, '5'), '10');
    await tester.pump();
    expect(find.text('10:00'), findsOneWidget);
    await tester.pump(const Duration(minutes: 1));
    await tester.tap(find.text('Back to Timer'));
    await tester.pump();
    expect(find.text('24:00'), findsOneWidget);
    await tester.pump();
    await tester.tap(find.byTooltip('Reset'));
    await tester.pump();
    // And it doesn't follow you back to Focus.
    expect(find.text('25:00'), findsOneWidget);
    expect(find.widgetWithText(TextField, '25'), findsOneWidget);
  });

  testWidgets('focus: the end is a quiet note that goes away by itself', (
    tester,
  ) async {
    final sounds = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemSound.play') sounds.add(call.arguments);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final repo = await pumpApp(tester, const Size(1400, 900));
    await go(tester, 'Focus');

    Future<void> runOut(int minutes) async {
      await tester.tap(find.text('Start'));
      await go(tester, 'Today');
      sounds.clear();
      await tester.pump(Duration(minutes: minutes, seconds: 1));
      await tester.pump();
    }

    await runOut(25);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text("Time's up"), findsOneWidget);
    expect(sounds, ['SystemSoundType.alert']);
    expect(repo.focusSessions, hasLength(1));
    await tester.pump(const Duration(minutes: 1, seconds: 1));
    expect(find.text("Time's up"), findsNothing);

    // With the sound off, there's only the note.
    await go(tester, 'Focus');
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await runOut(5);
    expect(find.text("Break's over"), findsOneWidget);
    expect(sounds, isEmpty);

    // It can be dismissed early.
    await go(tester, 'Focus');
    await tester.tap(find.byTooltip('Dismiss'));
    await go(tester, 'Today');
    expect(find.text("Break's over"), findsNothing);
  });

  testWidgets('a day off keeps the streak and the nudge away', (tester) async {
    // A Wednesday, with weeks starting on Monday.
    final now = DateTime(2026, 11, 18, 12);
    final repo = await pumpApp(tester, const Size(420, 900), clock: () => now);
    repo.setPrefs({'weekStart': DateTime.monday});
    final id = repo.createHabit({'name': 'Inbox zero'});
    repo.updateHabit(id, {
      'createdAt': DateTime(2026, 11, 10).toUtc().toIso8601String(),
    });
    for (final d in [12, 13, 14, 15, 16]) {
      repo.setHabitDone(id, DateTime(2026, 11, d), true);
    }
    await tester.pumpAndSettle();
    // Tuesday was missed.
    expect(repo.missedLastTime(repo.habit(id)!), isTrue);
    expect(repo.streak(repo.habit(id)!), 5);

    await tester.longPress(find.text('Tue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Take the day off'));
    await tester.pumpAndSettle();
    final tuesday = DateTime(2026, 11, 17);
    expect(repo.isHabitOff(id, tuesday), isTrue);
    expect(repo.missedLastTime(repo.habit(id)!), isFalse);
    expect(repo.streak(repo.habit(id)!), 5);
    expect(find.byType(DashedCircle), findsOneWidget);

    // Ticking it anyway ends the day off and counts.
    await tester.tap(find.text('Tue'));
    await tester.pumpAndSettle();
    expect(repo.isHabitOff(id, tuesday), isFalse);
    expect(repo.streak(repo.habit(id)!), 6);

    // Days ahead can be given the day off too, but done days can't.
    await tester.longPress(find.text('Fri'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Take the day off'));
    await tester.pumpAndSettle();
    expect(repo.isHabitOff(id, DateTime(2026, 11, 20)), isTrue);
    await tester.longPress(find.text('Tue'));
    await tester.pumpAndSettle();
    expect(find.text('Take the day off'), findsNothing);

    // Taking a day off never writes done, so it can't undo a check-in
    // from another device; and unticking doesn't bring a day off back.
    final wednesday = DateTime(2026, 11, 19);
    repo.setHabitOff(id, wednesday, true);
    final row = repo.store.row(
      Tables.habitChecks,
      Habit.checkId(id, wednesday),
    );
    expect(row?.containsKey('done'), isFalse);
    repo.store.write(Tables.habitChecks, Habit.checkId(id, wednesday), {
      'done': true,
    });
    repo.setHabitOff(id, wednesday, true);
    expect(repo.isHabitDone(id, wednesday), isTrue);
    repo.setHabitDone(id, wednesday, false);
    expect(repo.isHabitOff(id, wednesday), isFalse);
  });

  testWidgets('rewards spend only the tomatoes earned today', (tester) async {
    final now = DateTime(2026, 11, 27, 15);
    final repo = await pumpApp(
      tester,
      const Size(1400, 1000),
      clock: () => now,
    );
    repo.createHabit({'name': 'Read'});
    await go(tester, 'Focus');
    expect(find.text('🍅 0 to spend today'), findsOneWidget);

    await tester.tap(find.text('Add a reward'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          )
          .first,
      'An episode of a show',
    );
    // Tap a tomato to set the price, or type it.
    await tester.tap(find.bySemanticsLabel('6 tomatoes'));
    await tester.pump();
    expect(find.widgetWithText(TextField, '6'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '6'), '2');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('2 more to go'), findsOneWidget);

    // Yesterday's tomatoes don't count today.
    repo.recordFocus(start: DateTime(2026, 11, 26, 9), minutes: 25);
    repo.recordFocus(start: DateTime(2026, 11, 27, 9), minutes: 25);
    await tester.pumpAndSettle();
    expect(find.text('1 more to go'), findsOneWidget);
    repo.recordFocus(start: DateTime(2026, 11, 27, 10), minutes: 25);
    await tester.pumpAndSettle();
    // Today says so, and takes you to it.
    await go(tester, 'Today');
    expect(find.text("You've earned a reward"), findsOneWidget);
    expect(
      find.text(
        'You can enjoy An episode of a show. You have 2 tomatoes to spend today.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text("You've earned a reward"));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enjoy'));
    await tester.pumpAndSettle();
    expect(find.text('🍅 0 to spend today'), findsOneWidget);
    expect(find.text('Enjoyed today'), findsOneWidget);
    expect(repo.rewardSpends.single.name, 'An episode of a show');
    // Nothing left to afford: Today stays quiet.
    await go(tester, 'Today');
    expect(find.text("You've earned a reward"), findsNothing);
    await go(tester, 'Focus');

    await tester.tap(find.text('Take back'));
    await tester.pumpAndSettle();
    expect(find.text('🍅 2 to spend today'), findsOneWidget);
  });

  testWidgets('phone: a habit opens as its own page', (tester) async {
    final repo = await pumpApp(tester, const Size(400, 860));
    final id = repo.createHabit({'name': 'Read', 'twoMinute': 'Read one page'});
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Your plan'), findsOneWidget);
    // Archive is in the ⋯ menu, and takes you back to the list.
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(repo.habit(id)!.archived, isTrue);
    expect(find.text('Your plan'), findsNothing);
  });

  testWidgets('desktop: a habit slides in over the list, Esc closes it', (
    tester,
  ) async {
    final repo = await pumpApp(tester, const Size(1400, 900));
    repo.createHabit({'name': 'Read'});
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);
    expect(find.byTooltip('Close (Esc)'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close (Esc)'), findsNothing);
  });

  testWidgets('finished focus sessions earn tomatoes toward the goal', (
    tester,
  ) async {
    final repo = await pumpApp(tester, const Size(1400, 900));
    await go(tester, 'Focus');
    expect(find.text('0 of 4'), findsOneWidget);
    repo.recordFocus(start: DateTime.now(), minutes: 25);
    await tester.pumpAndSettle();
    expect(find.text('1 of 4'), findsOneWidget);
    expect(find.text('🍅'), findsOneWidget);
  });

  test('emoji habit icons are recognised', () {
    for (final e in ['📚', '✍️', '☀️', '👩‍💻', '🇯🇵', '👍🏽']) {
      expect(isEmojiIcon(e), isTrue, reason: e);
    }
    for (final t in ['book', 'check', 'a', '1', '', 'ab']) {
      expect(isEmojiIcon(t), isFalse, reason: t);
    }
  });

  testWidgets('the icon picker offers every emoji, not just the grid', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                pickHabitIcon(context, selected: 'check', color: 0xFF4CAF50),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    // No box to type into, but a way to reach any emoji.
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('More emoji'));
    await tester.pumpAndSettle();
    expect(find.byType(EmojiPicker), findsOneWidget);
    // The full list loads in the background; once it's there, the picker
    // shows it (on smileys) without throwing.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('😀'), findsOneWidget);
  });
}
