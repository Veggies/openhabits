import 'package:core/core.dart';
import 'package:material_ui/material_ui.dart';

import '../data/repo.dart';
import 'common.dart';
import 'habit_detail.dart';
import 'habit_editor.dart';

/// Today's habits. On phones, opening a habit shows its page; on
/// computers it slides in over the list (see [HabitPreview]).
class HabitsPage extends StatelessWidget {
  const HabitsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    return DataBuilder(
      builder: (context, repo) {
        final Widget list = repo.habits.isEmpty
            ? const _Empty()
            : const _HabitList();
        return Scaffold(
          appBar: wide ? null : AppBar(title: const Text('Habits')),
          floatingActionButton: wide
              ? null
              : FloatingActionButton.extended(
                  // Every page lives in one IndexedStack, so FAB hero tags would clash.
                  heroTag: null,
                  icon: const Icon(Icons.add),
                  label: const Text('New habit'),
                  onPressed: () => editHabit(context),
                ),
          body: wide ? HabitPreview(child: list) : list,
        );
      },
    );
  }
}

/// Opens a habit's page: over the list on computers, as its own page on
/// phones.
void openHabit(BuildContext context, Habit habit) {
  if (isWide(context)) {
    AppScope.read(context).nav.openPreview(habit.id);
  } else {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => HabitDetailPage(habitId: habit.id)),
    );
  }
}

/// Edit, Focus on this, Archive and Delete for a habit, shown on a long
/// press or right-click.
Future<void> showHabitMenu(
  BuildContext context,
  Habit habit,
  Offset position,
) async {
  final scope = AppScope.read(context);
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(
      position & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: [
      const PopupMenuItem(value: 'edit', child: Text('Edit')),
      if (!habit.isQuit)
        const PopupMenuItem(value: 'focus', child: Text('Focus on this')),
      const PopupMenuItem(value: 'archive', child: Text('Archive')),
      const PopupMenuItem(value: 'delete', child: Text('Delete…')),
    ],
  );
  if (!context.mounted) return;
  switch (choice) {
    case 'edit':
      await editHabit(context, existing: habit);
    case 'focus':
      scope.nav.focusOn(habit, scope.focus);
    case 'archive':
      scope.repo.updateHabit(habit.id, {'archived': true});
    case 'delete':
      if (await confirmDeleteHabit(context, habit)) {
        scope.repo.deleteHabit(habit.id);
      }
  }
}

/// Asks before deleting, since it removes the habit everywhere.
Future<bool> confirmDeleteHabit(BuildContext context, Habit habit) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${habit.name}?'),
        content: const Text(
          'This removes it from all your devices.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete habit'),
          ),
        ],
      ),
    ) ??
    false;

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.local_fire_department_outlined,
            size: 56,
            color: theme.colorScheme.outlineVariant,
          ),
          const SizedBox(height: 12),
          Text('No habits yet', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Start one you want to build, or one you want to break.',
            style: TextStyle(color: theme.colorScheme.outline),
          ),
          if (isWide(context)) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('New habit'),
              onPressed: () => editHabit(context),
            ),
          ],
        ],
      ),
    );
  }
}

class _HabitList extends StatelessWidget {
  const _HabitList();

  // Rebuilds on every data change; a const instance would otherwise
  // never refresh.
  @override
  Widget build(BuildContext context) =>
      DataBuilder(builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final habits = repo.habits;
    final build = habits.where((h) => !h.isQuit).toList();
    final quit = habits.where((h) => h.isQuit).toList();
    final theme = Theme.of(context);
    final both = build.isNotEmpty && quit.isNotEmpty;
    final due = [
      for (final h in habits)
        if (repo.sizeSuggestion(h) != null) h,
    ];

    return CenteredListView(
      maxWidth: 760,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      children: [
        // On computers there's no title bar, so the page names itself and
        // holds the New habit button.
        if (isWide(context))
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Today',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        fullDate(repo.clock()),
                        style: TextStyle(color: theme.colorScheme.outline),
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('New habit'),
                  onPressed: () => editHabit(context),
                ),
              ],
            ),
          ),
        if (repo.lastWeekReviewDue)
          Card(
            color: theme.colorScheme.tertiaryContainer,
            child: ListTile(
              leading: const Icon(Icons.rate_review_outlined),
              title: const Text('Time for your weekly review'),
              subtitle: const Text(
                'Take a minute to look back on last week and see how your habits went.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                AppScope.read(context).nav
                  ..showScorecard(false)
                  ..go(AppTab.reflect);
              },
            ),
          ),
        if (due.isNotEmpty)
          Card(
            color: theme.colorScheme.primaryContainer,
            child: ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('Time for a check-in'),
              subtitle: Text(
                due.length == 1
                    ? 'See whether ${due.single.name} still feels like the right size.'
                    : 'See whether ${_names(due)} still feel like the right size.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                // One check-in after another, skipping any that no
                // longer need one.
                // Closing one without choosing stops there.
                for (final (i, h) in due.indexed) {
                  if (!context.mounted) return;
                  final current = repo.habit(h.id);
                  final s = current == null
                      ? null
                      : repo.sizeSuggestion(current);
                  if (s == null) continue;
                  final answered = await sizeCheckIn(
                    context,
                    current!,
                    s,
                    step: (i + 1, due.length),
                  );
                  if (!answered) return;
                }
              },
            ),
          ),
        if (build.isNotEmpty)
          _Section(title: both ? 'BUILDING' : null, habits: build),
        if (quit.isNotEmpty)
          _Section(
            title: both || build.isEmpty ? 'BREAKING' : null,
            habits: quit,
          ),
        // A nudge toward the scorecard while there's little to track yet.
        if (habits.length < 3 &&
            repo.scorecard.isEmpty) ...[
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.fact_check_outlined),
            title: const Text('Not sure what to work on?'),
            subtitle: const Text(
              'Try the Scorecard. You list what you already do each day and see which habits help you and which hold you back.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              AppScope.read(context).nav
                ..showScorecard(true)
                ..go(AppTab.reflect);
            },
          ),
        ],
      ],
    );
  }
}

/// "Read, Walk and Journal".
String _names(List<Habit> habits) {
  final names = [for (final h in habits) h.name];
  return names.length == 1
      ? names.single
      : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

/// Room for each day's circle, so the day labels line up above them.
const double _daySlot = 38;

/// Width of the name column on wide screens. A fixed width keeps every
/// habit's circles in the same place, right beside its name.
const double _nameWidth = 260;

/// The avatar plus the gap after it.
const double _avatarSlot = 12 + 32 + 10;

/// A group of habits (building or breaking) in one card, with the days
/// labelled once along the top.
class _Section extends StatelessWidget {
  final String? title;
  final List<Habit> habits;
  const _Section({required this.title, required this.habits});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = AppScope.of(context).repo;
    final today = dateOnly(repo.clock());
    // This calendar week, starting on the day chosen in Settings. Days
    // still to come show faintly until they arrive.
    final weekStart = startOfWeek(today, repo.weekStart);
    final days = [for (var i = 0; i < 7; i++) addDays(weekStart, i)];
    final heading = Text(
      title ?? '',
      style: theme.textTheme.labelLarge?.copyWith(
        color: theme.colorScheme.outline,
      ),
    );

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 700;
        final labels = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final day in days)
              SizedBox(
                width: _daySlot,
                child: Text(
                  day == today ? 'Today' : weekdayShort(day.weekday),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: day == today
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                    fontWeight: day == today ? FontWeight.w700 : null,
                  ),
                ),
              ),
          ],
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 16, 0, 6),
              child: wide
                  ? Row(
                      children: [
                        SizedBox(
                          width: _avatarSlot + _nameWidth,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: heading,
                          ),
                        ),
                        labels,
                      ],
                    )
                  // Narrow: each row labels its own days, so the header is
                  // just the group's name.
                  : Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: heading,
                    ),
            ),
            Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (final (i, h) in habits.indexed)
                    _HabitRow(
                      habit: h,
                      days: days,
                      wide: wide,
                      shaded: i.isOdd,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _HabitRow extends StatelessWidget {
  final Habit habit;
  final List<DateTime> days;
  final bool wide;
  final bool shaded;
  const _HabitRow({
    required this.habit,
    required this.days,
    required this.wide,
    required this.shaded,
  });

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final theme = Theme.of(context);
    final today = dateOnly(repo.clock());
    final color = Color(habit.color);
    final checkedToday = repo.isHabitDone(habit.id, today);
    final plan = habit.plan;
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.outline,
    );

    // One short line under the name: the version for now and the cue
    // ("Read one page · After I pour coffee · 7:00 AM"). Once today is
    // checked off, the reward takes its place.
    final details = !habit.isQuit && checkedToday && plan.reward.isNotEmpty
        ? 'Reward: ${plan.reward}'
        : [
            if (plan.twoMinute.isNotEmpty && !habit.isQuit) plan.twoMinute,
            if (plan.stackAfter.isNotEmpty) 'After I ${plan.stackAfter}',
            if (plan.time.isNotEmpty && wide) timeLabel(context, plan.time),
            if (plan.location.isNotEmpty) plan.location,
          ].join(' · ');

    final Widget stat;
    if (habit.isQuit) {
      final clean = repo.daysClean(habit);
      stat = _Stat(
        icon: Icons.shield_outlined,
        color: clean > 0 ? Colors.green : theme.colorScheme.outline,
        text: '$clean',
        tooltip: '$clean day${clean == 1 ? '' : 's'} clean',
      );
    } else {
      final streak = repo.streak(habit);
      stat = _Stat(
        icon: Icons.local_fire_department,
        color: streak > 0 ? Colors.deepOrange : theme.colorScheme.outline,
        text: '$streak',
        tooltip: 'A streak of $streak day${streak == 1 ? '' : 's'}',
      );
    }

    // If you missed it last time, the second line says so instead, in
    // amber. Hovering shows the full "never miss twice" message.
    final missed = !checkedToday && repo.missedLastTime(habit);
    final String line;
    final String hover;
    if (missed) {
      line = habit.isQuit
          ? "Yesterday wasn't a clear day"
          : 'You missed this last time';
      hover = habit.isQuit
          ? "Yesterday wasn't marked as a clear day. Try to stay clear today, so it doesn't happen two days in a row."
          : plan.twoMinute.isNotEmpty
          ? 'You missed this last time, so try not to miss it two days in a row. Even the small version counts: "${plan.twoMinute}".'
          : 'You missed this last time, so try not to miss it two days in a row. Even doing a tiny bit counts.';
    } else {
      line = details;
      hover = plan.sizeHistory.length > 1 ? versionLine(plan) : details;
    }

    final nameColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                habit.name,
                style: theme.textTheme.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!wide && plan.time.isNotEmpty) ...[
              const SizedBox(width: 8),
              Icon(Icons.schedule, size: 13, color: theme.colorScheme.outline),
              const SizedBox(width: 3),
              Text(timeLabel(context, plan.time), style: small),
            ],
          ],
        ),
        if (line.isNotEmpty)
          Tooltip(
            message: hover,
            child: Text(
              line,
              style: missed
                  ? small?.copyWith(color: Colors.amber.shade800)
                  : small,
              maxLines: wide ? 1 : 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );

    Widget weekRow({required bool spread}) => Row(
      mainAxisSize: spread ? MainAxisSize.max : MainAxisSize.min,
      children: [
        for (final day in days)
          _spreadIf(
            spread,
            _DayToggle(
              key: day == today ? ValueKey('today-${habit.id}') : null,
              tooltip: day == today
                  ? (habit.isQuit ? 'Stayed clear today' : 'Done today')
                  : weekdayShort(day.weekday),
              dayName: day == today ? 'Today' : weekdayShort(day.weekday),
              shortName: weekdayShort(day.weekday),
              doneWord: habit.isQuit ? 'Stayed clear' : 'Done',
              labelled: !wide,
              isToday: day == today,
              checked: repo.isHabitDone(habit.id, day),
              scheduled: habit.isScheduled(day),
              upcoming: day.isAfter(today),
              color: color,
              onTap: () => repo.setHabitDone(
                habit.id,
                day,
                !repo.isHabitDone(habit.id, day),
              ),
            ),
          ),
      ],
    );
    final week = weekRow(spread: false);

    final avatar = Padding(
      padding: const EdgeInsets.only(left: 12, right: 10),
      child: HabitAvatar(icon: habit.icon, color: habit.color, size: 32),
    );

    return Material(
      // Every other row is shaded a little, so your eye can follow a
      // habit across to its days.
      color: shaded
          ? theme.colorScheme.onSurface.withValues(alpha: 0.035)
          : Colors.transparent,
      child: InkWell(
        onTap: () => openHabit(context, habit),
        onLongPress: () {
          final box = context.findRenderObject() as RenderBox;
          showHabitMenu(
            context,
            habit,
            box.localToGlobal(box.size.center(Offset.zero)),
          );
        },
        onSecondaryTapDown: (d) =>
            showHabitMenu(context, habit, d.globalPosition),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: wide
              ? Row(
                  children: [
                    avatar,
                    SizedBox(width: _nameWidth, child: nameColumn),
                    week,
                    const SizedBox(width: 12),
                    stat,
                    const Spacer(),
                  ],
                )
              : Column(
                  children: [
                    Row(
                      children: [
                        avatar,
                        Expanded(child: nameColumn),
                        stat,
                        const SizedBox(width: 12),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: weekRow(spread: true),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  final String tooltip;
  const _Stat({
    required this.icon,
    required this.color,
    required this.text,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 44),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 2),
          Text(text, style: Theme.of(context).textTheme.labelLarge),
        ],
      ),
    ),
  );
}

/// In a spread-out week each day takes an equal share of the row.
Widget _spreadIf(bool spread, Widget child) =>
    spread ? Expanded(child: Center(child: child)) : child;

class _DayToggle extends StatelessWidget {
  final String tooltip;

  /// For screen readers: "Today" or "Mon", and what a check-in means.
  final String dayName;
  final String doneWord;

  /// Shown under the circle when [labelled]: "Mon", today in bold.
  final String shortName;

  /// Shows the day's name under the circle (narrow screens).
  final bool labelled;
  final bool isToday;
  final bool checked;
  final bool scheduled;

  /// Later this week: shown faintly, and can't be ticked yet.
  final bool upcoming;
  final Color color;
  final VoidCallback onTap;
  const _DayToggle({
    super.key,
    required this.tooltip,
    required this.dayName,
    required this.doneWord,
    required this.shortName,
    this.labelled = false,
    required this.isToday,
    required this.checked,
    required this.scheduled,
    this.upcoming = false,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outlineVariant;
    // A check-in is always good news: done, or for a habit being broken,
    // a day you stayed clear. Today's circle is a little bigger and ringed
    // in the habit's colour, so it's easy to find down the list.
    final size = isToday ? 32.0 : 26.0;
    final theme = Theme.of(context);
    final circle = SizedBox(
      width: _daySlot,
      height: 38,
      child: Center(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: checked ? color : null,
            border: Border.all(
              color: checked || isToday
                  ? color
                  : (scheduled && !upcoming
                        ? outline
                        : outline.withValues(alpha: 0.3)),
              width: 2,
            ),
          ),
          child: checked
              ? Icon(Icons.check, size: isToday ? 20 : 16, color: Colors.white)
              : null,
        ),
      ),
    );
    return Semantics(
      button: true,
      label: dayName,
      value: upcoming
          ? 'Upcoming'
          : checked
          ? doneWord
          : 'Not done',
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip,
        child: InkResponse(
          // A later day takes the tap without doing anything, so it
          // doesn't fall through and open the habit.
          onTap: upcoming ? () {} : onTap,
          splashColor: upcoming ? Colors.transparent : null,
          highlightColor: upcoming ? Colors.transparent : null,
          enableFeedback: !upcoming,
          radius: 20,
          child: labelled
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    circle,
                    Text(
                      shortName,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: isToday
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outline.withValues(
                                alpha: upcoming ? 0.5 : 1,
                              ),
                        fontWeight: isToday ? FontWeight.w700 : null,
                      ),
                    ),
                  ],
                )
              : circle,
        ),
      ),
    );
  }
}

/// "Read one page → Read 5 pages → Read 10 pages": how the habit has grown,
/// ending with the version for now (the last three, to keep it short).
String versionLine(HabitPlan plan) {
  final versions = [for (final v in plan.sizeHistory) v.text];
  if (versions.length < 2) return 'Your version for now: ${plan.twoMinute}';
  final shown = versions.length > 3
      ? ['…', ...versions.sublist(versions.length - 3)]
      : versions;
  return 'Grown from: ${shown.join('  →  ')}';
}

/// The two-weekly size check-in (the Goldilocks rule): grow it, shrink it,
/// keep it as it is, or say the size feels right and stop asking.
/// Returns false if it was closed without choosing, so a run of check-ins
/// can stop there. [step] is "1 of 2" style progress through that run.
Future<bool> sizeCheckIn(
  BuildContext context,
  Habit habit,
  SizeSuggestion suggestion, {
  (int, int)? step,
}) async {
  final repo = AppScope.of(context).repo;
  final plan = habit.plan;
  final (:done, :scheduled) = repo.record(habit, repo.clock(), 14);
  final grow = suggestion == SizeSuggestion.grow;
  final controller = TextEditingController(text: plan.twoMinute);
  final choice = await showDialog<_SizeChoice>(
    context: context,
    builder: (context) => AlertDialog(
      // The habit comes first, big and with its icon, so it's clear
      // straight away which one this is about.
      title: Row(
        children: [
          HabitAvatar(icon: habit.icon, color: habit.color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(habit.name),
                Text(
                  grow
                      ? 'Is it starting to feel too easy?'
                      : 'Make it a little smaller?',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (step case (final n, final total) when total > 1)
            Text(
              '$n of $total',
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              grow
                  ? "Over the last two weeks, you did this on $done of the $scheduled days it was scheduled, "
                        "so it's sticking. Nice going.\n\n"
                        "If it's starting to feel too easy, you could make it a little bigger. "
                        'If it still takes some effort, keeping it as it is works just as well.'
                  : "Over the last two weeks, you did this on $done of the $scheduled days it was scheduled. "
                        "That's completely normal. A smaller version that you actually do beats a bigger one you skip.",
            ),
            const SizedBox(height: 12),
            Text('Your version for now: ${plan.twoMinute}'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Your new version',
                helperText: grow
                    ? 'Just a little bigger. For example, one page could become five.'
                    : 'Something easy enough to do even on a busy day.',
                helperMaxLines: 2,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => Navigator.pop(context, _SizeChoice.change),
            ),
            const SizedBox(height: 12),
            Text(
              "If you keep it as it is, we'll check in again in two weeks.",
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _SizeChoice.settle),
          child: const Text('This feels right, stop asking'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _SizeChoice.keep),
          child: const Text('Keep it as it is'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _SizeChoice.change),
          child: Text(grow ? 'Make it bigger' : 'Make it smaller'),
        ),
      ],
    ),
  );
  switch (choice) {
    case _SizeChoice.change
        when controller.text.trim().isNotEmpty &&
            controller.text.trim() != plan.twoMinute:
      repo.resize(habit, controller.text);
    case _SizeChoice.settle:
      repo.settleSize(habit);
    case _SizeChoice.keep || _SizeChoice.change:
      repo.keepSize(habit);
    case null:
      return false; // closed without choosing: ask again next time
  }
  return true;
}

enum _SizeChoice { change, keep, settle }
