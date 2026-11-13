import 'package:core/core.dart';
import 'package:material_ui/material_ui.dart';

import '../data/repo.dart';
import 'atomic_pages.dart';
import 'common.dart';
import 'habit_editor.dart';

class HabitsPage extends StatefulWidget {
  const HabitsPage({super.key});

  @override
  State<HabitsPage> createState() => _HabitsPageState();
}

/// The Habits page's tabs. Scorecard and Weekly review only exist with the
/// Atomic Habits framework on.
enum HabitsTab { habits, scorecard, review }

class _HabitsPageState extends State<HabitsPage>
    with SingleTickerProviderStateMixin {
  /// On phones the overview is a second view instead of a side pane.
  bool showOverview = false;

  /// The week the Weekly review tab opens on (null = this week).
  DateTime? reviewDay;

  late final _tabs = TabController(length: HabitsTab.values.length, vsync: this)
    ..addListener(() => setState(() {}));

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _open(HabitsTab tab, {DateTime? day}) {
    if (tab == HabitsTab.review) reviewDay = day;
    _tabs.animateTo(tab.index);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    return DataBuilder(
      builder: (context, repo) {
        final framework = repo.atomicHabits;
        final tab = framework
            ? HabitsTab.values[_tabs.index]
            : HabitsTab.habits;
        final overviewToggle =
            !wide && tab == HabitsTab.habits && repo.habits.isNotEmpty;

        Widget habitsBody() => repo.habits.isEmpty
            ? const _Empty()
            : wide
            ? Row(
                children: [
                  Expanded(child: _HabitList(onOpen: _open)),
                  const VerticalDivider(width: 1),
                  const SizedBox(width: 420, child: HabitOverview()),
                ],
              )
            : showOverview
            ? const HabitOverview()
            : _HabitList(onOpen: _open);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Habits'),
            bottom: !framework && !overviewToggle
                ? null
                : PreferredSize(
                    preferredSize: Size.fromHeight(
                      (framework ? 48 : 0) + (overviewToggle ? 52 : 0),
                    ),
                    child: Column(
                      children: [
                        if (framework)
                          TabBar(
                            controller: _tabs,
                            // Centered on wide screens; on phones the three
                            // share the width so none scroll out of view.
                            isScrollable: wide,
                            tabAlignment: wide
                                ? TabAlignment.center
                                : TabAlignment.fill,
                            tabs: const [
                              Tab(text: 'My habits'),
                              Tab(text: 'Scorecard'),
                              Tab(text: 'Weekly review'),
                            ],
                          ),
                        if (overviewToggle)
                          Padding(
                            padding: const EdgeInsets.only(top: 4, bottom: 8),
                            child: SegmentedButton<bool>(
                              segments: const [
                                ButtonSegment(
                                  value: false,
                                  label: Text('Today'),
                                ),
                                ButtonSegment(
                                  value: true,
                                  label: Text('Overview'),
                                ),
                              ],
                              selected: {showOverview},
                              onSelectionChanged: (s) =>
                                  setState(() => showOverview = s.first),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
          floatingActionButton: tab == HabitsTab.habits
              ? FloatingActionButton.extended(
                  // Every page lives in one IndexedStack, so FAB hero tags would clash.
                  heroTag: null,
                  icon: const Icon(Icons.add),
                  label: const Text('New habit'),
                  onPressed: () => editHabit(context),
                )
              : null,
          body: switch (tab) {
            HabitsTab.habits => habitsBody(),
            HabitsTab.scorecard => const ScorecardView(),
            HabitsTab.review => WeeklyReviewView(
              key: ValueKey(reviewDay),
              day: reviewDay,
            ),
          },
        );
      },
    );
  }
}

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
            'Tap "New habit" to build one up, or break one down.',
            style: TextStyle(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }
}

class _HabitList extends StatelessWidget {
  /// Switches the Habits page to another tab.
  final void Function(HabitsTab tab, {DateTime? day}) onOpen;
  const _HabitList({required this.onOpen});

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

    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
    );

    return CenteredListView(
      maxWidth: 760,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      children: [
        if (repo.lastWeekReviewDue)
          Card(
            color: theme.colorScheme.tertiaryContainer,
            child: ListTile(
              leading: const Icon(Icons.rate_review_outlined),
              title: const Text('Time for your weekly review'),
              subtitle: const Text(
                'Reflect on last week to keep your habits on track.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  onOpen(HabitsTab.review, day: addDays(repo.clock(), -7)),
            ),
          ),
        if (build.isNotEmpty && quit.isNotEmpty) header('BUILDING'),
        for (final h in build) _HabitCard(habit: h),
        if (quit.isNotEmpty) header('BREAKING'),
        for (final h in quit) _HabitCard(habit: h),
        // A nudge toward the scorecard while there's little to track yet.
        if (repo.atomicHabits &&
            habits.length < 3 &&
            repo.scorecard.isEmpty) ...[
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.fact_check_outlined),
            title: const Text('Not sure what to work on?'),
            subtitle: const Text(
              'Rate your daily routine in the Scorecard to see which habits help and which hurt.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onOpen(HabitsTab.scorecard),
          ),
        ],
      ],
    );
  }
}

class _HabitCard extends StatelessWidget {
  final Habit habit;
  const _HabitCard({required this.habit});

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final theme = Theme.of(context);
    final today = dateOnly(repo.clock());
    final color = Color(habit.color);
    final days = [for (var i = 6; i >= 0; i--) addDays(today, -i)];
    final checkedToday = repo.isHabitDone(habit.id, today);
    final plan = habit.plan;
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.outline,
    );

    // The cue line: "After I pour coffee · 7:00 AM · Kitchen".
    final cue = [
      if (plan.stackAfter.isNotEmpty) 'After I ${plan.stackAfter}',
      if (plan.time.isNotEmpty) timeLabel(context, plan.time),
      if (plan.location.isNotEmpty) plan.location,
    ].join(' · ');

    final Widget stat;
    if (habit.isQuit) {
      final clean = repo.daysClean(habit);
      stat = _Stat(
        icon: Icons.shield_outlined,
        color: Colors.green,
        text: '$clean day${clean == 1 ? '' : 's'} clean',
      );
    } else {
      final streak = repo.streak(habit);
      stat = _Stat(
        icon: Icons.local_fire_department,
        color: streak > 0 ? Colors.deepOrange : theme.colorScheme.outline,
        text: '$streak day${streak == 1 ? '' : 's'}',
      );
    }

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => editHabit(context, existing: habit),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  HabitAvatar(icon: habit.icon, color: habit.color),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(habit.name, style: theme.textTheme.titleMedium),
                        if (plan.identity.isNotEmpty)
                          Text(
                            plan.identity,
                            style: small?.copyWith(fontStyle: FontStyle.italic),
                          ),
                        if (cue.isNotEmpty) Text(cue, style: small),
                        if (plan.twoMinute.isNotEmpty && !habit.isQuit)
                          Text(
                            plan.goal.isEmpty
                                ? 'Now: ${plan.twoMinute}'
                                : 'Now: ${plan.twoMinute}  →  Goal: ${plan.goal}',
                            style: small,
                          ),
                      ],
                    ),
                  ),
                  stat,
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'edit') editHabit(context, existing: habit);
                      if (v == 'archive') {
                        repo.updateHabit(habit.id, {'archived': true});
                      }
                      if (v == 'delete') repo.deleteHabit(habit.id);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(value: 'archive', child: Text('Archive')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ],
              ),
              if (!habit.isQuit &&
                  repo.atomicHabits &&
                  repo.missedLastTime(habit))
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 10),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Missed last time. Never miss twice: '
                      '${plan.twoMinute.isNotEmpty ? plan.twoMinute.toLowerCase() : 'even a tiny version counts'}.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
              if (repo.readyToStepUp(habit))
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 10),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer.withValues(
                        alpha: 0.6,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.trending_up, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            "You've been showing up consistently. Ready to make it a little bigger?",
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        TextButton(
                          onPressed: () => _stepUp(context, habit),
                          child: const Text('Step up'),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              Row(
                children: [
                  for (final day in days)
                    Expanded(
                      child: Column(
                        children: [
                          Text(
                            day == today ? 'Today' : weekdayShort(day.weekday),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                          const SizedBox(height: 4),
                          _DayToggle(
                            checked: repo.isHabitDone(habit.id, day),
                            quit: habit.isQuit,
                            scheduled: habit.isScheduled(day),
                            color: color,
                            onTap: () => repo.setHabitDone(
                              habit.id,
                              day,
                              !repo.isHabitDone(habit.id, day),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 10),
                child: Row(
                  children: [
                    if (repo.atomicHabits &&
                        !habit.isQuit &&
                        plan.identity.isNotEmpty)
                      Expanded(
                        child: Text(
                          '${repo.votes(habit.id)} votes for who you are becoming',
                          style: small,
                        ),
                      )
                    else
                      const Spacer(),
                    if (habit.isScheduled(today) && !checkedToday)
                      habit.isQuit
                          ? TextButton.icon(
                              icon: const Icon(Icons.undo),
                              label: const Text('I slipped today'),
                              style: TextButton.styleFrom(
                                foregroundColor: theme.colorScheme.error,
                              ),
                              onPressed: () =>
                                  repo.setHabitDone(habit.id, today, true),
                            )
                          : FilledButton.tonalIcon(
                              icon: const Icon(Icons.check),
                              label: const Text('Done today'),
                              onPressed: () =>
                                  repo.setHabitDone(habit.id, today, true),
                            ),
                    if (!habit.isQuit && checkedToday && plan.reward.isNotEmpty)
                      Text(
                        'Reward: ${plan.reward}',
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
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
  const _Stat({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 2),
      Text(text, style: Theme.of(context).textTheme.labelLarge),
    ],
  );
}

class _DayToggle extends StatelessWidget {
  final bool checked;
  final bool quit;
  final bool scheduled;
  final Color color;
  final VoidCallback onTap;
  const _DayToggle({
    required this.checked,
    required this.quit,
    required this.scheduled,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outline = theme.colorScheme.outlineVariant;
    // For quit habits a check-in is a slip, shown in red.
    final fill = quit ? theme.colorScheme.error : color;
    return InkResponse(
      onTap: onTap,
      radius: 22,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: checked ? fill : null,
          border: Border.all(
            color: checked
                ? fill
                : (scheduled ? outline : outline.withValues(alpha: 0.3)),
            width: 2,
          ),
        ),
        child: checked
            ? Icon(
                quit ? Icons.close : Icons.check,
                size: 18,
                color: Colors.white,
              )
            : null,
      ),
    );
  }
}

/// Every habit at a glance for a week or a month.
class HabitOverview extends StatefulWidget {
  const HabitOverview({super.key});

  @override
  State<HabitOverview> createState() => _HabitOverviewState();
}

class _HabitOverviewState extends State<HabitOverview> {
  bool month = false;
  DateTime anchor = DateTime.now();

  // Rebuilds on every data change; a const instance would otherwise
  // never refresh.
  @override
  Widget build(BuildContext context) =>
      DataBuilder(builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final theme = Theme.of(context);
    final habits = repo.habits;
    final today = dateOnly(repo.clock());

    final List<DateTime> days;
    final String title;
    if (month) {
      final first = DateTime(anchor.year, anchor.month);
      days = [
        for (var d = 0; d < daysInMonth(first.year, first.month); d++)
          addDays(first, d),
      ];
      title = '${monthNamesLong[first.month - 1]} ${first.year}';
    } else {
      final start = startOfWeek(anchor, repo.weekStart);
      days = [for (var d = 0; d < 7; d++) addDays(start, d)];
      title = '${shortDate(days.first)} – ${shortDate(days.last)}';
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
            IconButton(
              tooltip: 'Previous',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => setState(
                () => anchor = month
                    ? addMonths(anchor, -1)
                    : addDays(anchor, -7),
              ),
            ),
            IconButton(
              tooltip: 'Next',
              icon: const Icon(Icons.chevron_right),
              onPressed: () => setState(
                () =>
                    anchor = month ? addMonths(anchor, 1) : addDays(anchor, 7),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Week')),
            ButtonSegment(value: true, label: Text('Month')),
          ],
          selected: {month},
          onSelectionChanged: (s) => setState(() => month = s.first),
        ),
        const SizedBox(height: 16),
        if (!month)
          Row(
            children: [
              const SizedBox(width: 120),
              for (final d in days)
                Expanded(
                  child: Text(
                    weekdayShort(d.weekday),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: d == today
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline,
                      fontWeight: d == today ? FontWeight.bold : null,
                    ),
                  ),
                ),
            ],
          ),
        for (final h in habits)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: month
                ? _monthRow(context, repo, h, days, today)
                : _weekRow(context, repo, h, days, today),
          ),
      ],
    );
  }

  Widget _cell(
    BuildContext context,
    Repo repo,
    Habit h,
    DateTime day,
    DateTime today,
    double size,
  ) {
    final theme = Theme.of(context);
    final future = day.isAfter(today);
    final before = day.isBefore(dateOnly(h.createdAt.toLocal()));
    final hit = repo.isHabitDone(h.id, day);
    final scheduled = h.isScheduled(day);
    final Color? fill;
    if (future || before || !scheduled) {
      fill = null;
    } else if (h.isQuit) {
      fill = hit
          ? theme.colorScheme.error
          : Colors.green.withValues(alpha: 0.55);
    } else {
      fill = hit ? Color(h.color) : null;
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(size / 4),
        border: fill == null
            ? Border.all(
                color: theme.colorScheme.outlineVariant.withValues(
                  alpha: scheduled && !future ? 1 : 0.3,
                ),
              )
            : null,
      ),
    );
  }

  Widget _weekRow(
    BuildContext context,
    Repo repo,
    Habit h,
    List<DateTime> days,
    DateTime today,
  ) => Row(
    children: [
      SizedBox(
        width: 120,
        child: Row(
          children: [
            Icon(habitIcon(h.icon), size: 18, color: Color(h.color)),
            const SizedBox(width: 6),
            Expanded(child: Text(h.name, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
      for (final d in days)
        Expanded(child: Center(child: _cell(context, repo, h, d, today, 20))),
    ],
  );

  Widget _monthRow(
    BuildContext context,
    Repo repo,
    Habit h,
    List<DateTime> days,
    DateTime today,
  ) {
    final theme = Theme.of(context);
    final end = days.last.isAfter(today) ? today : days.last;
    final rate = end.isBefore(days.first)
        ? 0.0
        : repo.completionRate(h, end, daysBetween(days.first, end) + 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(habitIcon(h.icon), size: 18, color: Color(h.color)),
            const SizedBox(width: 6),
            Expanded(child: Text(h.name)),
            Text(
              '${(rate * 100).round()}% ${h.isQuit ? 'clean' : 'done'}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 3,
          runSpacing: 3,
          children: [
            for (final d in days) _cell(context, repo, h, d, today, 11),
          ],
        ),
      ],
    );
  }
}

/// Asks for the habit's next, slightly bigger version.
Future<void> _stepUp(BuildContext context, Habit habit) async {
  final repo = AppScope.of(context).repo;
  final controller = TextEditingController(text: habit.plan.twoMinute);
  final next = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Step it up'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Now: ${habit.plan.twoMinute}'),
          if (habit.plan.goal.isNotEmpty) Text('Goal: ${habit.plan.goal}'),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Next small step',
              helperText: 'Grow it a little, e.g. one page becomes five.',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Not yet'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Step up'),
        ),
      ],
    ),
  );
  final value = next?.trim() ?? '';
  if (value.isNotEmpty && value != habit.plan.twoMinute) {
    repo.stepUp(habit, value);
  } else {
    // "Not yet": ask again in two weeks.
    repo.stepUp(habit, habit.plan.twoMinute);
  }
}
