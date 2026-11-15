import 'package:core/core.dart';
import 'package:material_ui/material_ui.dart';

import '../data/repo.dart';
import 'common.dart';

/// The Progress grid: one row per habit, one column per week. Each square
/// holds the number of days you did the habit that week (or, for habits
/// you're breaking, the days you stayed clear), and is solid when you did it
/// every day it was due. Each row also says how the last four weeks went.
class GrowthView extends StatefulWidget {
  const GrowthView({super.key});

  @override
  State<GrowthView> createState() => _GrowthViewState();
}

/// How much history the grid shows.
enum _Range {
  all('Since you started', 0),
  month('1 month', 30),
  quarter('3 months', 91),
  half('6 months', 182),
  year('1 year', 365),
  custom('Custom…', 0);

  final String label;
  final int days;
  const _Range(this.label, this.days);
}

/// One habit's week: days done (or clear) out of days due.
typedef _Week = ({int done, int scheduled});

class _GrowthViewState extends State<GrowthView> {
  _Range range = _Range.all;
  DateTimeRange? custom;

  /// Habits switched off in the filter. Tracking the hidden ones (rather
  /// than the shown ones) means new habits appear without extra steps.
  final hidden = <String>{};
  bool table = false;

  @override
  Widget build(BuildContext context) => DataBuilder(
    builder: (context, repo) {
      final theme = Theme.of(context);
      final today = dateOnly(repo.clock());
      final habits = repo.habits;
      final started = habits
          .map((h) => dateOnly(h.createdAt.toLocal()))
          .fold(today, (a, b) => b.isBefore(a) ? b : a);
      final (from, to) = switch (range) {
        _Range.custom when custom != null => (custom!.start, custom!.end),
        _Range.all || _Range.custom => (started, today),
        _ => (addDays(today, -range.days), today),
      };
      final weeks = [
        for (
          var w = startOfWeek(from, repo.weekStart);
          !w.isAfter(to);
          w = addDays(w, 7)
        )
          w,
      ];
      final data = {
        for (final h in habits)
          h.id: [for (final w in weeks) repo.weekRecord(h, w)],
      };
      final shown = [
        for (final h in habits)
          if (!hidden.contains(h.id)) h,
      ];
      final muted = theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.outline,
      );

      return CenteredListView(
        maxWidth: 1100,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'How your habits are going',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (habits.isNotEmpty)
                TextButton.icon(
                  icon: Icon(
                    table ? Icons.grid_view : Icons.table_rows_outlined,
                  ),
                  label: Text(table ? 'Show as squares' : 'Show as a table'),
                  onPressed: () => setState(() => table = !table),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            "Here's how each of your habits has gone, week by week. The number in each "
            'square is how many days you did it that week. For habits you\'re trying to '
            'break, it\'s how many days you went without it. The dates along the top are '
            'when each week starts.',
            style: muted,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final r in _Range.values)
                ChoiceChip(
                  label: Text(
                    r == _Range.custom &&
                            range == _Range.custom &&
                            custom != null
                        ? '${shortDate(custom!.start)} – ${shortDate(custom!.end)}'
                        : r.label,
                  ),
                  selected: range == r,
                  onSelected: (_) => r == _Range.custom
                      ? _pickCustom(context, started, from, to, today)
                      : setState(() => range = r),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (habits.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Text(
                "Once you've started a habit, you'll see how each week went here.",
                textAlign: TextAlign.center,
                style: muted,
              ),
            )
          else ...[
            // Choose which habits to show.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final h in habits)
                  FilterChip(
                    avatar: CircleAvatar(
                      backgroundColor: Color(h.color),
                      radius: 6,
                    ),
                    label: Text(h.name),
                    selected: !hidden.contains(h.id),
                    showCheckmark: false,
                    onSelected: (on) => setState(
                      () => on ? hidden.remove(h.id) : hidden.add(h.id),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Text(
                  'Pick a habit above to see it here.',
                  textAlign: TextAlign.center,
                  style: muted,
                ),
              )
            else if (table)
              _WeekTable(habits: shown, weeks: weeks, data: data, today: today)
            else
              _WeekGrid(habits: shown, weeks: weeks, data: data, today: today),
          ],
        ],
      );
    },
  );

  Future<void> _pickCustom(
    BuildContext context,
    DateTime started,
    DateTime from,
    DateTime to,
    DateTime today,
  ) async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: started.isBefore(addDays(today, -365))
          ? started
          : addDays(today, -365),
      lastDate: today,
      initialDateRange: DateTimeRange(start: from, end: to),
      helpText: 'Choose the dates to show',
    );
    if (picked == null) return;
    setState(() {
      range = _Range.custom;
      custom = picked;
    });
  }
}

/// The version a habit changed to during the week starting [week], if any.
String? _changeIn(Habit h, DateTime week) {
  for (final v in h.plan.sizeHistory.skip(1)) {
    final since = parseDateKey(v.since);
    if (!since.isBefore(week) && since.isBefore(addDays(week, 7))) {
      return v.text;
    }
  }
  return null;
}

bool _isThisWeek(DateTime week, DateTime today) =>
    !today.isBefore(week) && today.isBefore(addDays(week, 7));

/// "Week of Nov 3", or "This week" for the current one.
String _weekName(DateTime week, DateTime today) =>
    _isThisWeek(week, today) ? 'This week' : 'Week of ${shortDate(week)}';

/// "5 of 7 days", or "5 of 7 days clear" for a habit being broken.
String _days(Habit h, int done, int due) =>
    '$done of $due day${due == 1 ? '' : 's'}${h.isQuit ? ' clear' : ''}';

/// What a square says on hover: "Read — Week of Nov 3: 5 of 7 days".
String _describe(Habit h, DateTime week, _Week w, DateTime today) {
  final name = _weekName(week, today);
  final days = w.scheduled == 0
      ? 'not due'
      : '${_days(h, w.done, w.scheduled)}'
            '${_isThisWeek(week, today) ? ' so far' : ''}';
  final change = _changeIn(h, week);
  return '${h.name}\n$name: $days'
      '${change == null ? '' : '\nYou changed your version to "$change"'}';
}

/// How well a habit is going over the last four weeks.
enum StrengthLevel {
  justStarted('Just started'),
  strong('Going strong'),
  gettingThere('Getting there'),
  struggling('Struggling');

  final String label;
  const StrengthLevel(this.label);

  Color color(ThemeData theme) => switch (this) {
    strong => Colors.green.shade700,
    struggling => theme.colorScheme.error,
    _ => theme.colorScheme.outline,
  };
}

/// Days done (or clear) out of days due over the last four weeks, and what
/// that means. The thresholds match the size check-ins (80% is "most days").
/// A habit less than a week old has "just started": too soon to judge.
({int done, int scheduled, StrengthLevel level}) habitStrength(
  Repo repo,
  Habit h,
) {
  final today = dateOnly(repo.clock());
  final (:done, :scheduled) = repo.record(h, today, 28);
  final level =
      scheduled == 0 || daysBetween(dateOnly(h.createdAt.toLocal()), today) < 7
      ? StrengthLevel.justStarted
      : done >= Repo.growDaysNeeded(scheduled)
      ? StrengthLevel.strong
      : done * 2 >= scheduled
      ? StrengthLevel.gettingThere
      : StrengthLevel.struggling;
  return (done: done, scheduled: scheduled, level: level);
}

/// "26 of 28 days", or "" when it's too soon to say.
String _strengthCount(
  Habit h,
  ({int done, int scheduled, StrengthLevel level}) s,
) => s.level == StrengthLevel.justStarted ? '' : _days(h, s.done, s.scheduled);

class _WeekGrid extends StatefulWidget {
  final List<Habit> habits;
  final List<DateTime> weeks;
  final Map<String, List<_Week>> data;
  final DateTime today;
  const _WeekGrid({
    required this.habits,
    required this.weeks,
    required this.data,
    required this.today,
  });

  @override
  State<_WeekGrid> createState() => _WeekGridState();
}

class _WeekGridState extends State<_WeekGrid> {
  final _scroll = ScrollController();

  static const cell = 34.0, gap = 6.0, header = 40.0, section = 36.0;

  @override
  void initState() {
    super.initState();
    _showLatest();
  }

  @override
  void didUpdateWidget(_WeekGrid old) {
    super.didUpdateWidget(old);
    if (old.weeks.length != widget.weeks.length) _showLatest();
  }

  /// Opens on the most recent weeks; older ones are a swipe to the left.
  void _showLatest() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  });

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = AppScope.of(context).repo;
    final weeks = widget.weeks;
    final today = widget.today;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final names = narrow ? 128.0 : 240.0;
    final row = narrow ? 64.0 : 50.0;
    final small = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.outline,
    );
    final building = [
      for (final h in widget.habits)
        if (!h.isQuit) h,
    ];
    final breaking = [
      for (final h in widget.habits)
        if (h.isQuit) h,
    ];
    final sections = [
      if (building.isNotEmpty) ('BUILDING', building),
      if (breaking.isNotEmpty) ('BREAKING', breaking),
    ];

    // Left: names and how each habit is going. Stays put.
    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: header,
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Text('Last 4 weeks', style: small),
          ),
        ),
        for (final (title, list) in sections) ...[
          SizedBox(
            height: section,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Text(
                title,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          ),
          for (final h in list)
            SizedBox(
              height: row,
              width: names,
              child: _nameCell(context, repo, h, narrow),
            ),
        ],
      ],
    );

    // Right: the weeks. Scrolls sideways when they don't all fit.
    Widget square(Habit h, int i) {
      final w = widget.data[h.id]![i];
      final color = Color(h.color);
      final perfect = w.scheduled > 0 && w.done == w.scheduled;
      final onColor = color.computeLuminance() > 0.5
          ? Colors.black87
          : Colors.white;
      // A dark ring, with a gap so it shows on any color, marks the week
      // you changed your version of the habit.
      final changed = _changeIn(h, weeks[i]) != null;
      return Tooltip(
        message: _describe(h, weeks[i], w, today),
        waitDuration: const Duration(milliseconds: 150),
        child: Container(
          width: cell,
          height: cell,
          margin: const EdgeInsets.only(right: gap),
          padding: EdgeInsets.all(changed ? 3 : 0),
          decoration: changed
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: theme.colorScheme.onSurface,
                    width: 2,
                  ),
                )
              : null,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: w.scheduled == 0 || w.done == 0
                  ? null
                  : perfect
                  ? color
                  : color.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(changed ? 5 : 8),
              border: w.scheduled == 0 || w.done == 0
                  ? Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: w.scheduled == 0 ? 0.4 : 1,
                      ),
                    )
                  : null,
            ),
            child: w.scheduled == 0
                ? null
                : Text(
                    '${w.done}',
                    style:
                        (changed
                                ? theme.textTheme.labelMedium
                                : theme.textTheme.labelLarge)
                            ?.copyWith(
                              color: perfect
                                  ? onColor
                                  : w.done == 0
                                  ? theme.colorScheme.outline
                                  : null,
                              fontWeight: FontWeight.w600,
                            ),
                  ),
          ),
        ),
      );
    }

    final right = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Month names, then the date each week starts.
        SizedBox(
          height: header,
          child: Row(
            children: [
              for (var i = 0; i < weeks.length; i++)
                SizedBox(
                  width: cell + gap,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 16,
                        child: i == 0 || weeks[i - 1].month != weeks[i].month
                            ? OverflowBox(
                                alignment: Alignment.centerLeft,
                                maxWidth: 80,
                                child: Text(
                                  monthNamesLong[weeks[i].month - 1].substring(
                                    0,
                                    3,
                                  ),
                                  style: small?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              )
                            : null,
                      ),
                      SizedBox(
                        width: cell,
                        child: Text(
                          '${weeks[i].day}',
                          textAlign: TextAlign.center,
                          style: _isThisWeek(weeks[i], today)
                              ? small?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w700,
                                )
                              : small,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        for (final (_, list) in sections) ...[
          const SizedBox(height: section),
          for (final h in list)
            SizedBox(
              height: row,
              child: Row(
                children: [for (var i = 0; i < weeks.length; i++) square(h, i)],
              ),
            ),
        ],
      ],
    );

    return Column(
      key: const ValueKey('progress-grid'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The key sits above the habits, so it's in view however many there are.
        _Legend(color: theme.colorScheme.primary),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: names, child: left),
            Expanded(
              child: SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                child: right,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _nameCell(BuildContext context, Repo repo, Habit h, bool narrow) {
    final theme = Theme.of(context);
    final strength = habitStrength(repo, h);
    final count = _strengthCount(h, strength);
    final verdict = strength.level.label;
    final verdictStyle = theme.textTheme.bodySmall?.copyWith(
      color: strength.level.color(theme),
      fontWeight: FontWeight.w600,
    );
    final countStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.outline,
    );
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            h.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
          if (narrow) ...[
            if (count.isNotEmpty) Text(count, style: countStyle),
            Text(verdict, style: verdictStyle),
          ] else
            Text.rich(
              TextSpan(
                children: [
                  if (count.isNotEmpty)
                    TextSpan(text: '$count · ', style: countStyle),
                  TextSpan(text: verdict, style: verdictStyle),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}

/// A key to the squares: plain samples (the numbers live in the grid).
class _Legend extends StatelessWidget {
  final Color color;
  const _Legend({required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.outline,
    );
    Widget box({Color? fill, Border? border}) => Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(4),
        border:
            border ??
            (fill == null
                ? Border.all(color: theme.colorScheme.outlineVariant)
                : null),
      ),
    );
    Widget item(Widget sample, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        sample,
        const SizedBox(width: 6),
        Text(text, style: label),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Each square shows:',
              style: label?.copyWith(fontWeight: FontWeight.w600),
            ),
            item(box(fill: color), 'Done every scheduled day'),
            item(box(fill: color.withValues(alpha: 0.18)), 'Some days'),
            item(box(), 'No days'),
          ],
        ),
        const SizedBox(height: 8),
        item(
          Container(
            width: 20,
            height: 20,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: theme.colorScheme.onSurface, width: 2),
            ),
            child: box(fill: color),
          ),
          'A ring means you changed your version of the habit that week',
        ),
      ],
    );
  }
}

/// The same numbers as a table, for anyone who'd rather read than look.
class _WeekTable extends StatelessWidget {
  final List<Habit> habits;
  final List<DateTime> weeks;
  final Map<String, List<_Week>> data;
  final DateTime today;
  const _WeekTable({
    required this.habits,
    required this.weeks,
    required this.data,
    required this.today,
  });

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      primary: false,
      child: DataTable(
        columns: [
          const DataColumn(label: Text('Week')),
          for (final h in habits) DataColumn(label: Text(h.name)),
        ],
        rows: [
          DataRow(
            cells: [
              const DataCell(Text('Last 4 weeks')),
              for (final h in habits)
                DataCell(
                  Text(switch (habitStrength(repo, h)) {
                    final s when _strengthCount(h, s).isEmpty => s.level.label,
                    final s => '${_strengthCount(h, s)} · ${s.level.label}',
                  }),
                ),
            ],
          ),
          for (var i = weeks.length - 1; i >= 0; i--)
            DataRow(
              cells: [
                DataCell(Text(_weekName(weeks[i], today))),
                for (final h in habits)
                  DataCell(
                    Text(switch (data[h.id]![i]) {
                      (scheduled: 0, done: _) => '–',
                      final w =>
                        '${w.done} of ${w.scheduled}'
                            '${_changeIn(h, weeks[i]) == null ? '' : ' · changed version'}',
                    }),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
