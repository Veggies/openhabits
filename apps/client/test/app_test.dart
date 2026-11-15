import 'package:core/core.dart';
import 'package:client/data/focus_controller.dart';
import 'package:client/data/local_store.dart';
import 'package:client/data/repo.dart';
import 'package:client/data/sync_engine.dart';
import 'package:client/main.dart';
import 'package:client/ui/common.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
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
    final repo = await pumpApp(tester, const Size(1400, 500));
    repo.setPrefs({'atomicHabits': true}); // a long form
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
    repo.setPrefs({'atomicHabits': true});
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
    expect(find.text('How your habits are going'), findsOneWidget);
    for (final range in ['1 month', '3 months', '6 months', '1 year']) {
      expect(find.widgetWithText(ChoiceChip, range), findsOneWidget);
    }

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
    expect(find.widgetWithText(FilterChip, 'Read'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'Walk'), findsOneWidget);

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

    // The same numbers as a table.
    await tester.tap(find.text('Show as a table'));
    await tester.pumpAndSettle();
    expect(
      find.text('${week.done} of ${week.scheduled} · changed version'),
      findsOneWidget,
    );

    // Switching a habit off hides its row.
    await tester.tap(find.widgetWithText(FilterChip, 'Walk'));
    await tester.pumpAndSettle();
    expect(find.text('Walk'), findsOneWidget); // only its chip is left
    await tester.tap(find.text('Show as squares'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('progress-grid')), findsOneWidget);
    expect(find.text('Walk'), findsOneWidget);
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

    await fill('I am…', 'a reader');
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
    await tester.tap(find.text('Start using OpenHabits'));
    await tester.pumpAndSettle();

    final habit = repo.habits.single;
    expect(habit.name, 'Read');
    expect(habit.plan.identity, 'a reader');
    expect(habit.plan.reward, 'A square of chocolate');
    expect(find.text('Today'), findsWidgets); // now in the app
  });

  testWidgets('the editor shows the four laws', (tester) async {
    // Tall enough that the whole editor is laid out without scrolling.
    final repo = await pumpApp(tester, const Size(1400, 2400));
    repo.setPrefs({'atomicHabits': true});
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

  test('any single emoji can be a habit icon', () {
    for (final e in ['📚', '✍️', '☀️', '👩‍💻', '🇯🇵', '👍🏽']) {
      expect(isEmojiIcon(e), isTrue, reason: e);
    }
    for (final t in ['book', 'check', 'a', '1', '', 'ab']) {
      expect(isEmojiIcon(t), isFalse, reason: t);
    }
    expect(lastEmoji('hello 🎸'), '🎸');
    expect(lastEmoji('abc'), isNull);
  });
}
