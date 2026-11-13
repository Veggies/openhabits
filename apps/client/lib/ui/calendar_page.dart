import 'dart:math';

import 'package:core/core.dart';
import 'package:material_ui/material_ui.dart';

import '../data/repo.dart';
import 'common.dart';
import 'habit_editor.dart';
import 'date_picker.dart';
import 'task_detail.dart';
import 'tasks_page.dart' show QuickAddField, TaskCheckbox;

enum CalendarView { day, week, month, year }

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  CalendarView view = CalendarView.month;
  DateTime selected = dateOnly(DateTime.now());

  void _move(int direction) => setState(() {
    selected = switch (view) {
      CalendarView.month => addMonths(
        DateTime(selected.year, selected.month),
        direction,
      ),
      CalendarView.week => addDays(selected, 7 * direction),
      CalendarView.day => addDays(selected, direction),
      CalendarView.year => DateTime(
        selected.year + direction,
        selected.month,
        1,
      ),
    };
  });

  String _title(int weekStart) => switch (view) {
    CalendarView.month =>
      '${monthNamesLong[selected.month - 1]} ${selected.year}',
    CalendarView.week => () {
      final start = _weekStart(selected, weekStart);
      final end = addDays(start, 6);
      return '${shortDate(start)} – ${shortDate(end)}, ${end.year}';
    }(),
    CalendarView.year => '${selected.year}',
    CalendarView.day =>
      '${weekdayShort(selected.weekday)}, ${shortDate(selected)} ${selected.year}',
  };

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    final weekStart = AppScope.of(context).repo.weekStart;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        // ‹ November 2026 › : the arrows step through whatever the title
        // shows; tapping the title jumps anywhere.
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Previous',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => _move(-1),
            ),
            Flexible(
              child: _TitleButton(
                label: _title(weekStart),
                view: view,
                selected: selected,
                weekStart: weekStart,
                onJump: (day) => setState(() => selected = day),
              ),
            ),
            IconButton(
              tooltip: 'Next',
              icon: const Icon(Icons.chevron_right),
              onPressed: () => _move(1),
            ),
          ],
        ),
        actions: [
          if (wide)
            OutlinedButton(
              onPressed: () =>
                  setState(() => selected = dateOnly(DateTime.now())),
              child: const Text('Today'),
            )
          else
            IconButton(
              tooltip: 'Today',
              icon: const Icon(Icons.today),
              onPressed: () =>
                  setState(() => selected = dateOnly(DateTime.now())),
            ),
          const SizedBox(width: 8),
          if (wide) ...[
            SegmentedButton<CalendarView>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: CalendarView.day, label: Text('Day')),
                ButtonSegment(value: CalendarView.week, label: Text('Week')),
                ButtonSegment(value: CalendarView.month, label: Text('Month')),
                ButtonSegment(value: CalendarView.year, label: Text('Year')),
              ],
              selected: {view},
              onSelectionChanged: (s) => setState(() => view = s.first),
            ),
            const SizedBox(width: 12),
          ] else
            PopupMenuButton<CalendarView>(
              tooltip: 'View',
              icon: const Icon(Icons.view_agenda_outlined),
              initialValue: view,
              onSelected: (v) => setState(() => view = v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: CalendarView.day, child: Text('Day')),
                PopupMenuItem(value: CalendarView.week, child: Text('Week')),
                PopupMenuItem(value: CalendarView.month, child: Text('Month')),
                PopupMenuItem(value: CalendarView.year, child: Text('Year')),
              ],
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        // Every page lives in one IndexedStack, so FAB hero tags would clash.
        heroTag: null,
        tooltip: 'Add task on this day',
        onPressed: () => _addTask(context),
        child: const Icon(Icons.add),
      ),
      body: DataBuilder(
        builder: (context, repo) => switch (view) {
          CalendarView.month =>
            wide
                ? Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: _MonthGrid(
                          month: selected,
                          selected: selected,
                          onSelect: _onSelect,
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      SizedBox(width: 340, child: _Agenda(day: selected)),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(
                        flex: 3,
                        child: _MonthGrid(
                          month: selected,
                          selected: selected,
                          onSelect: _onSelect,
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(flex: 2, child: _Agenda(day: selected)),
                    ],
                  ),
          CalendarView.week => _Timeline(
            days: [
              for (var i = 0; i < 7; i++)
                addDays(_weekStart(selected, weekStart), i),
            ],
            onSelectDay: (d) => setState(() {
              selected = d;
              view = CalendarView.day;
            }),
          ),
          CalendarView.day => _Timeline(days: [selected]),
          CalendarView.year => _YearView(
            year: selected.year,
            weekStart: weekStart,
            onSelectMonth: (m) => setState(() {
              selected = DateTime(selected.year, m, 1);
              view = CalendarView.month;
            }),
          ),
        },
      ),
    );
  }

  void _onSelect(DateTime d) => setState(() => selected = d);

  Future<void> _addTask(BuildContext context) => showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Text(
              'New task · ${relativeDate(selected, DateTime.now())}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          QuickAddField(
            defaultDate: selected,
            onAdded: () => Navigator.pop(context),
          ),
        ],
      ),
    ),
  );
}

DateTime _weekStart(DateTime d, int first) => startOfWeek(d, first);

void openTask(BuildContext context, String id) {
  if (isWide(context)) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        child: SizedBox(
          width: 440,
          height: 600,
          child: TaskDetail(taskId: id, onClose: () => Navigator.pop(context)),
        ),
      ),
    );
  } else {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(),
          body: TaskDetail(taskId: id),
        ),
      ),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  final DateTime month;
  final DateTime selected;
  final ValueChanged<DateTime> onSelect;
  const _MonthGrid({
    required this.month,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final theme = Theme.of(context);
    final first = DateTime(month.year, month.month);
    final gridStart = _weekStart(first, repo.weekStart);
    final today = dateOnly(DateTime.now());

    return Column(
      children: [
        Row(
          children: [
            for (final d in weekdayOrder(repo.weekStart))
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    weekdayShort(d),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              ),
          ],
        ),
        Expanded(
          child: Column(
            children: [
              for (var w = 0; w < 6; w++)
                Expanded(
                  child: Row(
                    children: [
                      for (var d = 0; d < 7; d++)
                        Expanded(
                          child: _dayCell(
                            context,
                            repo,
                            addDays(gridStart, w * 7 + d),
                            today,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dayCell(
    BuildContext context,
    Repo repo,
    DateTime day,
    DateTime today,
  ) {
    final theme = Theme.of(context);
    final inMonth = day.month == month.month;
    final isSelected = day == selected;
    final isToday = day == today;
    final items = <(String, Color, bool)>[
      for (final e in repo.eventsOn(day))
        (e.title, theme.colorScheme.tertiary, false),
      for (final t in repo.tasksOn(day))
        (t.title, priorityColor(t.priority, theme.colorScheme), t.done),
      for (final h in repo.timedHabitsOn(day))
        (h.name, Color(h.color), repo.isHabitDone(h.id, day)),
    ];

    return InkWell(
      onTap: () => onSelect(day),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            width: 0.5,
          ),
          color: isSelected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
              : null,
        ),
        padding: const EdgeInsets.all(3),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxItems = max(
              0,
              ((constraints.maxHeight - 24) / 16).floor(),
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: isToday
                      ? BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(10),
                        )
                      : null,
                  child: Text(
                    '${day.day}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: isToday
                          ? theme.colorScheme.onPrimary
                          : inMonth
                          ? null
                          : theme.colorScheme.outline.withValues(alpha: 0.6),
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                for (final (title, color, done) in items.take(
                  items.length > maxItems ? max(0, maxItems - 1) : maxItems,
                ))
                  Container(
                    height: 15,
                    margin: const EdgeInsets.only(bottom: 1),
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    alignment: Alignment.centerLeft,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        decoration: done ? TextDecoration.lineThrough : null,
                      ),
                    ),
                  ),
                if (items.length > maxItems && maxItems > 0)
                  Text(
                    '+${items.length - maxItems + 1}',
                    style: theme.textTheme.labelSmall?.copyWith(fontSize: 10),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Agenda extends StatelessWidget {
  final DateTime day;
  const _Agenda({required this.day});

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final theme = Theme.of(context);
    final events = repo.eventsOn(day);
    final tasks = repo.tasksOn(day);
    final habits = repo.timedHabitsOn(day);
    final canCheckIn = !day.isAfter(dateOnly(DateTime.now()));

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            relativeDate(day, DateTime.now()),
            style: theme.textTheme.titleMedium,
          ),
        ),
        if (events.isEmpty && tasks.isEmpty && habits.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Nothing scheduled',
              style: TextStyle(color: theme.colorScheme.outline),
            ),
          ),
        for (final e in events)
          ListTile(
            dense: true,
            leading: Icon(Icons.event, color: theme.colorScheme.tertiary),
            title: Text(e.title),
            subtitle: Text(
              [
                e.allDay
                    ? 'All day'
                    : '${clockLabel(context, e.start)} – ${clockLabel(context, e.end)}',
                e.calendar,
              ].join(' · '),
            ),
          ),
        for (final t in tasks)
          ListTile(
            dense: true,
            leading: TaskCheckbox(task: t),
            title: Text(
              t.title,
              style: TextStyle(
                decoration: t.done ? TextDecoration.lineThrough : null,
              ),
            ),
            subtitle: t.dueTime == null
                ? null
                : Text(timeLabel(context, t.dueTime!)),
            onTap: () => openTask(context, t.id),
          ),
        for (final h in habits)
          ListTile(
            dense: true,
            leading: Checkbox(
              value: repo.isHabitDone(h.id, day),
              activeColor: Color(h.color),
              side: BorderSide(color: Color(h.color), width: 2),
              shape: const CircleBorder(),
              // Habits can't be checked in ahead of time.
              onChanged: canCheckIn
                  ? (v) => repo.setHabitDone(h.id, day, v ?? false)
                  : null,
            ),
            title: Text(
              h.name,
              style: TextStyle(
                decoration: repo.isHabitDone(h.id, day)
                    ? TextDecoration.lineThrough
                    : null,
              ),
            ),
            subtitle: Text(
              '${timeLabel(context, h.plan.time)} · ${durationLabel(h.duration)} · Habit',
            ),
          ),
      ],
    );
  }
}

/// "21:00" → 1260. Taken from the clock time itself, so a habit stays at
/// 9 PM even on the days clocks change.
int _minuteOfDay(String hhmm) {
  final t = parseTime(hhmm);
  return t.hour * 60 + t.minute;
}

/// An item on the timeline: start/end minutes from midnight.
class _Block {
  final String title;
  final int start;
  final int end;
  final Color color;
  final bool done;
  final VoidCallback? onTap;
  int lane = 0;
  int lanes = 1;
  _Block(
    this.title,
    this.start,
    this.end,
    this.color, {
    this.done = false,
    this.onTap,
  });
}

/// Day and week views: an hour grid with timed tasks and events as blocks,
/// and all-day items in a strip above.
class _Timeline extends StatefulWidget {
  final List<DateTime> days;
  final ValueChanged<DateTime>? onSelectDay;
  const _Timeline({required this.days, this.onSelectDay});

  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  static const hourHeight = 56.0;
  final _scroll = ScrollController(initialScrollOffset: hourHeight * 7.5);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final theme = Theme.of(context);
    final today = dateOnly(DateTime.now());

    return Column(
      children: [
        // Day headers and all-day items.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(width: 52),
            for (final day in widget.days)
              Expanded(
                child: InkWell(
                  onTap: widget.onSelectDay == null
                      ? null
                      : () => widget.onSelectDay!(day),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '${weekdayShort(day.weekday)} ${day.day}',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: day == today
                                ? theme.colorScheme.primary
                                : null,
                            fontWeight: day == today ? FontWeight.bold : null,
                          ),
                        ),
                        for (final e
                            in repo.eventsOn(day).where((e) => e.allDay))
                          _chip(context, e.title, theme.colorScheme.tertiary),
                        for (final t
                            in repo
                                .tasksOn(day)
                                .where((t) => t.dueTime == null))
                          _chip(
                            context,
                            t.title,
                            priorityColor(t.priority, theme.colorScheme),
                            done: t.done,
                            onTap: () => openTask(context, t.id),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            controller: _scroll,
            child: SizedBox(
              height: hourHeight * 24,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 52,
                    child: Stack(
                      children: [
                        for (var h = 1; h < 24; h++)
                          Positioned(
                            top: h * hourHeight - 7,
                            right: 6,
                            child: Text(
                              TimeOfDay(hour: h, minute: 0).format(context),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  for (final day in widget.days)
                    Expanded(child: _dayColumn(context, repo, day, today)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _chip(
    BuildContext context,
    String title,
    Color color, {
    bool done = false,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(top: 2),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(decoration: done ? TextDecoration.lineThrough : null),
        ),
      ),
    );
  }

  Widget _dayColumn(
    BuildContext context,
    Repo repo,
    DateTime day,
    DateTime today,
  ) {
    final theme = Theme.of(context);
    final dayStart = dateOnly(day);
    int minutesInto(DateTime t) =>
        t.difference(dayStart).inMinutes.clamp(0, 24 * 60);

    final blocks = <_Block>[
      for (final e in repo.eventsOn(day).where((e) => !e.allDay))
        _Block(
          e.title,
          minutesInto(e.start),
          max(minutesInto(e.end), minutesInto(e.start) + 15),
          theme.colorScheme.tertiary,
        ),
      for (final t in repo.tasksOn(day).where((t) => t.dueTime != null))
        _Block(
          t.title,
          minutesInto(t.dueAt!),
          min(24 * 60, minutesInto(t.dueAt!) + max(15, t.duration)),
          priorityColor(t.priority, theme.colorScheme) ==
                  theme.colorScheme.outline
              ? theme.colorScheme.primary
              : priorityColor(t.priority, theme.colorScheme),
          done: t.done,
          onTap: () => openTask(context, t.id),
        ),
      for (final h in repo.timedHabitsOn(day))
        _Block(
          h.name,
          _minuteOfDay(h.plan.time),
          min(24 * 60, _minuteOfDay(h.plan.time) + max(15, h.duration)),
          Color(h.color),
          done: repo.isHabitDone(h.id, day),
          // Clicking checks it off (not ahead of time).
          onTap: day.isAfter(today)
              ? null
              : () =>
                    repo.setHabitDone(h.id, day, !repo.isHabitDone(h.id, day)),
        ),
    ];
    _assignLanes(blocks);
    final now = DateTime.now();

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Stack(
          children: [
            for (var h = 0; h < 24; h++)
              Positioned(
                top: h * hourHeight,
                left: 0,
                right: 0,
                child: Container(
                  height: hourHeight,
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: theme.colorScheme.outlineVariant.withValues(
                          alpha: 0.5,
                        ),
                        width: 0.5,
                      ),
                      left: BorderSide(
                        color: theme.colorScheme.outlineVariant.withValues(
                          alpha: 0.5,
                        ),
                        width: 0.5,
                      ),
                    ),
                  ),
                ),
              ),
            for (final b in blocks)
              Positioned(
                top: b.start / 60 * hourHeight,
                height: max(18, (b.end - b.start) / 60 * hourHeight - 2),
                left: width / b.lanes * b.lane + 2,
                width: width / b.lanes - 4,
                child: GestureDetector(
                  onTap: b.onTap,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: b.color.withValues(alpha: 0.22),
                      border: Border(
                        left: BorderSide(color: b.color, width: 3),
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      b.title,
                      overflow: TextOverflow.fade,
                      style: theme.textTheme.labelSmall?.copyWith(
                        decoration: b.done ? TextDecoration.lineThrough : null,
                      ),
                    ),
                  ),
                ),
              ),
            if (day == today)
              Positioned(
                top: minutesInto(now) / 60 * hourHeight,
                left: 0,
                right: 0,
                child: Container(height: 2, color: theme.colorScheme.error),
              ),
          ],
        );
      },
    );
  }

  /// Places overlapping blocks side by side: each cluster of mutually
  /// overlapping blocks shares its width equally.
  static void _assignLanes(List<_Block> blocks) {
    blocks.sort(
      (a, b) => a.start != b.start
          ? a.start.compareTo(b.start)
          : b.end.compareTo(a.end),
    );
    var cluster = <_Block>[];
    var clusterEnd = -1;
    void close() {
      final lanes = cluster.isEmpty
          ? 1
          : cluster.map((b) => b.lane).reduce(max) + 1;
      for (final b in cluster) {
        b.lanes = lanes;
      }
      cluster = [];
    }

    for (final b in blocks) {
      if (b.start >= clusterEnd) {
        close();
        clusterEnd = b.end;
      }
      final used = {
        for (final o in cluster)
          if (o.end > b.start) o.lane,
      };
      var lane = 0;
      while (used.contains(lane)) {
        lane++;
      }
      b.lane = lane;
      cluster.add(b);
      clusterEnd = max(clusterEnd, b.end);
    }
    close();
  }
}

/// Twelve small months. Tap one to open it; days with tasks are marked.
class _YearView extends StatelessWidget {
  final int year;
  final int weekStart;
  final ValueChanged<int> onSelectMonth;
  const _YearView({
    required this.year,
    required this.weekStart,
    required this.onSelectMonth,
  });

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final theme = Theme.of(context);
    final now = DateTime.now();
    final busy = <DateTime>{
      for (final t in repo.allTasks)
        if (!t.deleted && t.dueDate != null && t.dueDate!.year == year)
          t.dueDate!,
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1000
            ? 4
            : constraints.maxWidth >= 600
            ? 3
            : 2;
        return GridView.count(
          padding: const EdgeInsets.all(12),
          crossAxisCount: columns,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.95,
          children: [
            for (var m = 1; m <= 12; m++)
              Card(
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onSelectMonth(m),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          monthNamesLong[m - 1],
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: year == now.year && m == now.month
                                ? theme.colorScheme.primary
                                : null,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Expanded(
                          child: IgnorePointer(
                            child: MonthDayGrid(
                              month: DateTime(year, m),
                              weekStart: weekStart,
                              compact: true,
                              dotsFor: busy.contains,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The title, which opens a quick picker: months (and the year) in month
/// view, years in year view, and the date picker in day and week views.
class _TitleButton extends StatefulWidget {
  final String label;
  final CalendarView view;
  final DateTime selected;
  final int weekStart;
  final ValueChanged<DateTime> onJump;

  const _TitleButton({
    required this.label,
    required this.view,
    required this.selected,
    required this.weekStart,
    required this.onJump,
  });

  @override
  State<_TitleButton> createState() => _TitleButtonState();
}

class _TitleButtonState extends State<_TitleButton> {
  final _menu = MenuController();

  void _jump(DateTime day) {
    _menu.close();
    widget.onJump(day);
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleLarge;
    final dropdown =
        widget.view == CalendarView.month || widget.view == CalendarView.year;
    return MenuAnchor(
      controller: _menu,
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        if (dropdown)
          SizedBox(
            width: 300,
            child: widget.view == CalendarView.month
                ? _MonthJump(selected: widget.selected, onPick: _jump)
                : _YearJump(selected: widget.selected, onPick: _jump),
          ),
      ],
      builder: (context, menu, _) => TextButton(
        style: TextButton.styleFrom(
          foregroundColor: style?.color,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        onPressed: () async {
          if (dropdown) {
            menu.isOpen ? menu.close() : menu.open();
            return;
          }
          final day = await pickDate(context, initial: widget.selected);
          if (day != null) widget.onJump(day);
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                widget.label,
                style: style,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}

/// All twelve months, with the year changeable above them.
class _MonthJump extends StatefulWidget {
  final DateTime selected;
  final ValueChanged<DateTime> onPick;
  const _MonthJump({required this.selected, required this.onPick});

  @override
  State<_MonthJump> createState() => _MonthJumpState();
}

class _MonthJumpState extends State<_MonthJump> {
  late int year = widget.selected.year;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Previous year',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => setState(() => year--),
            ),
            Expanded(
              child: Text(
                '$year',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: 'Next year',
              icon: const Icon(Icons.chevron_right),
              onPressed: () => setState(() => year++),
            ),
          ],
        ),
        MonthPickerGrid(
          year: year,
          selectedMonth: year == widget.selected.year
              ? widget.selected.month
              : null,
          onSelect: (m) => widget.onPick(DateTime(year, m)),
        ),
      ],
    ),
  );
}

/// Twelve years at a time, pageable.
class _YearJump extends StatefulWidget {
  final DateTime selected;
  final ValueChanged<DateTime> onPick;
  const _YearJump({required this.selected, required this.onPick});

  @override
  State<_YearJump> createState() => _YearJumpState();
}

class _YearJumpState extends State<_YearJump> {
  late int first = widget.selected.year - 5;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().year;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Earlier years',
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(() => first -= 12),
              ),
              Expanded(
                child: Text(
                  '$first – ${first + 11}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Later years',
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(() => first += 12),
              ),
            ],
          ),
          ButtonGrid(
            children: [
              for (var y = first; y < first + 12; y++)
                y == widget.selected.year
                    ? FilledButton(
                        onPressed: () =>
                            widget.onPick(DateTime(y, widget.selected.month)),
                        child: Text('$y'),
                      )
                    : OutlinedButton(
                        onPressed: () =>
                            widget.onPick(DateTime(y, widget.selected.month)),
                        style: y == now
                            ? OutlinedButton.styleFrom(
                                side: BorderSide(
                                  color: Theme.of(context).colorScheme.primary,
                                  width: 2,
                                ),
                              )
                            : null,
                        child: Text('$y'),
                      ),
            ],
          ),
        ],
      ),
    );
  }
}
