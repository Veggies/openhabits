import 'package:core/core.dart';
import 'package:material_ui/material_ui.dart';

import '../data/repo.dart';
import 'atomic_pages.dart';
import 'common.dart';
import 'growth_chart.dart';
import 'habit_editor.dart';

class HabitsPage extends StatefulWidget {
  const HabitsPage({super.key});

  @override
  State<HabitsPage> createState() => _HabitsPageState();
}

/// The Habits page's tabs. My habits and Progress are always there; Scorecard
/// and Weekly review only exist with the
/// Atomic Habits framework on.
enum HabitsTab { habits, growth, scorecard, review }

class _HabitsPageState extends State<HabitsPage> with TickerProviderStateMixin {
  /// On phones the overview is a second view instead of a side pane.
  bool showOverview = false;

  /// The week the Weekly review tab opens on (null = this week).
  DateTime? reviewDay;

  /// One controller with every tab, one with just the two that are always
  /// there; which one is in use follows the Atomic Habits setting.
  late final _all = TabController(length: HabitsTab.values.length, vsync: this)
    ..addListener(() => setState(() {}));
  late final _basic = TabController(length: 2, vsync: this)
    ..addListener(() => setState(() {}));

  List<HabitsTab> _visible(bool framework) =>
      framework ? HabitsTab.values : const [HabitsTab.habits, HabitsTab.growth];

  TabController _tabs(bool framework) => framework ? _all : _basic;

  @override
  void dispose() {
    _all.dispose();
    _basic.dispose();
    super.dispose();
  }

  void _open(HabitsTab tab, {DateTime? day}) {
    if (tab == HabitsTab.review) reviewDay = day;
    final framework = AppScope.read(context).repo.atomicHabits;
    final i = _visible(framework).indexOf(tab);
    if (i >= 0) _tabs(framework).animateTo(i);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    return DataBuilder(
      builder: (context, repo) {
        final framework = repo.atomicHabits;
        final visible = _visible(framework);
        final tab = visible[_tabs(framework).index];
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
            bottom: PreferredSize(
              preferredSize: Size.fromHeight(48 + (overviewToggle ? 52 : 0)),
              child: Column(
                children: [
                  TabBar(
                    controller: _tabs(framework),
                    // Centered on wide screens; on phones the three
                    // share the width so none scroll out of view.
                    isScrollable: wide,
                    tabAlignment: wide
                        ? TabAlignment.center
                        : TabAlignment.fill,
                    tabs: [
                      for (final t in visible)
                        Tab(
                          text: switch (t) {
                            HabitsTab.habits => 'My habits',
                            HabitsTab.growth => 'Progress',
                            HabitsTab.scorecard => 'Scorecard',
                            // Four tabs share a phone's width: keep it short.
                            HabitsTab.review =>
                              wide ? 'Weekly review' : 'Review',
                          },
                        ),
                    ],
                  ),
                  if (overviewToggle)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: false, label: Text('Today')),
                          ButtonSegment(value: true, label: Text('Overview')),
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
            HabitsTab.growth => const GrowthView(),
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
            'Click "New habit" to start one you want to build, or one you want to break.',
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
    final both = build.isNotEmpty && quit.isNotEmpty;
    final due = [
      for (final h in habits)
        if (repo.sizeSuggestion(h) != null) h,
    ];

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
                'Take a minute to look back on last week and see how your habits went.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  onOpen(HabitsTab.review, day: addDays(repo.clock(), -7)),
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
                  final answered = await _sizeCheckIn(
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
        if (repo.atomicHabits &&
            habits.length < 3 &&
            repo.scorecard.isEmpty) ...[
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.fact_check_outlined),
            title: const Text('Not sure what to work on?'),
            subtitle: const Text(
              'Try the Scorecard. You list what you already do each day and see which habits help you and which hold you back.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onOpen(HabitsTab.scorecard),
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
    final today = dateOnly(AppScope.of(context).repo.clock());
    final days = [for (var i = 6; i >= 0; i--) addDays(today, -i)];
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
                  day == today
                      ? 'Today'
                      : wide
                      ? weekdayShort(day.weekday)
                      : weekdayShort(day.weekday).substring(0, 1),
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
                  : Row(
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: heading,
                          ),
                        ),
                        labels,
                        const SizedBox(width: 8),
                      ],
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
    final today = days.last;
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
            if (plan.time.isNotEmpty) timeLabel(context, plan.time),
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
    final missed =
        repo.atomicHabits && !checkedToday && repo.missedLastTime(habit);
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
      hover = plan.sizeHistory.length > 1 ? _versionLine(plan) : details;
    }

    final nameColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          habit.name,
          style: theme.textTheme.titleSmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (line.isNotEmpty)
          Tooltip(
            message: hover,
            child: Text(
              line,
              style: missed
                  ? small?.copyWith(color: Colors.amber.shade800)
                  : small,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );

    final week = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final day in days)
          _DayToggle(
            key: day == today ? ValueKey('today-${habit.id}') : null,
            tooltip: day == today
                ? (habit.isQuit ? 'Stayed clear today' : 'Done today')
                : weekdayShort(day.weekday),
            isToday: day == today,
            checked: repo.isHabitDone(habit.id, day),
            scheduled: habit.isScheduled(day),
            color: color,
            onTap: () => repo.setHabitDone(
              habit.id,
              day,
              !repo.isHabitDone(habit.id, day),
            ),
          ),
      ],
    );

    final menu = PopupMenuButton<String>(
      tooltip: 'More',
      onSelected: (v) {
        if (v == 'edit') editHabit(context, existing: habit);
        if (v == 'archive') repo.updateHabit(habit.id, {'archived': true});
        if (v == 'delete') repo.deleteHabit(habit.id);
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'edit', child: Text('Edit')),
        PopupMenuItem(value: 'archive', child: Text('Archive')),
        PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );

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
        onTap: () => editHabit(context, existing: habit),
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
                    menu,
                  ],
                )
              : Column(
                  children: [
                    Row(
                      children: [
                        avatar,
                        Expanded(child: nameColumn),
                        stat,
                        menu,
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: week,
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

class _DayToggle extends StatelessWidget {
  final String tooltip;
  final bool isToday;
  final bool checked;
  final bool scheduled;
  final Color color;
  final VoidCallback onTap;
  const _DayToggle({
    super.key,
    required this.tooltip,
    required this.isToday,
    required this.checked,
    required this.scheduled,
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
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 20,
        child: SizedBox(
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
                      : (scheduled ? outline : outline.withValues(alpha: 0.3)),
                  width: 2,
                ),
              ),
              child: checked
                  ? Icon(
                      Icons.check,
                      size: isToday ? 20 : 16,
                      color: Colors.white,
                    )
                  : null,
            ),
          ),
        ),
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

/// "Read one page → Read 5 pages → Read 10 pages": how the habit has grown,
/// ending with the version for now (the last three, to keep it short).
String _versionLine(HabitPlan plan) {
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
Future<bool> _sizeCheckIn(
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
