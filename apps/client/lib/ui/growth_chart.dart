import 'package:core/core.dart';
import 'package:material_ui/material_ui.dart';

import '../data/repo.dart';
import 'common.dart';
import 'habit_editor.dart';

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
  custom('Custom dates', 0);

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

      // Nothing yet: centred in the whole page, with a way to get started.
      if (habits.isEmpty) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _Nothing(
                icon: Icons.grid_view,
                title: 'Nothing to show yet',
                text: "Once you've started a habit, you'll see how each week went here.",
              ),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('New habit'),
                onPressed: () => editHabit(context),
              ),
            ],
          ),
        );
      }

      return CenteredListView(
        maxWidth: 1100,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              _rangeMenu(context, started, from, to, today),
              if (habits.length > 1) _habitFilter(habits),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            "Here's how each habit has gone, week by week. The number in each square is "
            "how many days you did it that week. For habits you're trying to break, it's "
            'how many days you went without it.',
            style: muted,
          ),
          const SizedBox(height: 16),
          if (shown.isEmpty)
            const _Nothing(
              icon: Icons.filter_list,
              title: 'No habits chosen',
              text: 'Choose which habits to show with the filter button.',
            )
          else
            _WeekGrid(habits: shown, weeks: weeks, data: data, today: today),
        ],
      );
    },
  );

  /// Which weeks to show, as one menu button.
  Widget _rangeMenu(
    BuildContext context,
    DateTime started,
    DateTime from,
    DateTime to,
    DateTime today,
  ) {
    final title = range == _Range.custom && custom != null
        ? '${shortDate(custom!.start)} – ${shortDate(custom!.end)}'
        : range.label;
    return MenuAnchor(
      menuChildren: [
        for (final r in _Range.values)
          MenuItemButton(
            leadingIcon: Icon(range == r ? Icons.check : null, size: 18),
            onPressed: () => r == _Range.custom
                ? _pickCustom(context, started, from, to, today)
                : setState(() => range = r),
            child: Text(r.label),
          ),
      ],
      builder: (context, menu, _) => _MenuButton(
        icon: Icons.calendar_today_outlined,
        label: title,
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
      ),
    );
  }

  /// Which habits to show: one button, a tick for each habit. The menu
  /// stays open so several can be switched in one go.
  Widget _habitFilter(List<Habit> habits) => MenuAnchor(
    menuChildren: [
      for (final h in habits)
        CheckboxMenuButton(
          value: !hidden.contains(h.id),
          closeOnActivate: false,
          onChanged: (on) => setState(
            () => on == true ? hidden.remove(h.id) : hidden.add(h.id),
          ),
          child: Text(h.name),
        ),
    ],
    builder: (context, menu, _) => _MenuButton(
      icon: hidden.isEmpty ? Icons.filter_list : Icons.filter_alt,
      label: hidden.isEmpty
          ? 'All habits'
          : '${habits.length - hidden.length} of ${habits.length} habits',
      onPressed: () => menu.isOpen ? menu.close() : menu.open(),
    ),
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
String? _changeIn(Habit h, DateTime week) => _changeDetails(h, week)?.to;

/// How a habit's version changed during the week starting [week], if it
/// did: from what, to what, and on which day.
({String from, String to, DateTime on})? _changeDetails(
  Habit h,
  DateTime week,
) {
  final history = h.plan.sizeHistory;
  for (var i = 1; i < history.length; i++) {
    final since = parseDateKey(history[i].since);
    if (!since.isBefore(week) && since.isBefore(addDays(week, 7))) {
      return (from: history[i - 1].text, to: history[i].text, on: since);
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
  final change = _changeDetails(h, week);
  return '${h.name}\n$name: $days'
      '${change == null ? '' : '\n\nYou changed your version on ${fullDate(change.on)}\n'
                'From: ${change.from}\nTo: ${change.to}'}';
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
    final names = narrow ? 150.0 : 260.0;
    final row = narrow ? 76.0 : 60.0;
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
        const SizedBox(height: header),
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
      // you changed your version of the habit. The inner square's corners
      // follow the ring's (10 minus the 4 inset), so the gap is even.
      final changed = _changeIn(h, weeks[i]) != null;
      // Hover with a mouse, or tap, to see the week's details.
      return Tooltip(
        message: _describe(h, weeks[i], w, today),
        waitDuration: const Duration(milliseconds: 150),
        triggerMode: TooltipTriggerMode.tap,
        showDuration: const Duration(seconds: 6),
        child: Container(
          width: cell,
          height: cell,
          margin: const EdgeInsets.only(right: gap),
          // The ring sits outside the square, in the space between squares,
          // so a changed week's square and number stay the same size.
          child: Stack(
            clipBehavior: Clip.none,
            fit: StackFit.expand,
            children: [
              Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: w.scheduled == 0 || w.done == 0
                      ? null
                      : perfect
                      ? color
                      : color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
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
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: perfect
                              ? onColor
                              : w.done == 0
                              ? theme.colorScheme.outline
                              : null,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
              if (changed)
                Positioned(
                  left: -3,
                  top: -3,
                  right: -3,
                  bottom: -3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(
                        color: theme.colorScheme.onSurface,
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
            ],
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
        Stack(
          clipBehavior: Clip.none,
          children: [
            // Every other row gets a faint band, so each habit's name is
            // easy to follow across to its weeks. One layer behind both
            // columns, so a band runs the full width while the weeks scroll.
            Positioned(
              left: -8,
              right: -8,
              top: 0,
              child: Column(
                children: [
                  const SizedBox(height: header),
                  for (final (_, list) in sections) ...[
                    const SizedBox(height: section),
                    for (var i = 0; i < list.length; i++)
                      Container(
                        height: row,
                        decoration: BoxDecoration(
                          color: i.isEven
                              ? theme.colorScheme.onSurface.withValues(
                                  alpha: 0.05,
                                )
                              : null,
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                  ],
                ],
              ),
            ),
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
        ),
      ],
    );
  }

  /// The habit's icon and name, how it's going, and over what period:
  /// "Going strong", then "27 of the last 28 days".
  Widget _nameCell(BuildContext context, Repo repo, Habit h, bool narrow) {
    final theme = Theme.of(context);
    final strength = habitStrength(repo, h);
    final recent = recentLabel(h, strength);
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 24,
            child: HabitGlyph(icon: h.icon, color: h.color, size: 17),
          ),
          const SizedBox(width: 8),
          Expanded(
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
                Text(
                  strength.level.label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: strength.level.color(theme),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (recent.isNotEmpty)
                  Text(
                    recent,
                    maxLines: narrow ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "27 of the last 28 days" for a daily habit; "10 of 12 days in the last 4
/// weeks" for one that isn't every day ("clear" for habits being broken).
/// Empty while it's too soon to say.
String recentLabel(
  Habit h,
  ({int done, int scheduled, StrengthLevel level}) s,
) {
  if (s.level == StrengthLevel.justStarted) return '';
  final clear = h.isQuit ? ' clear' : '';
  return s.scheduled == 28
      ? '${s.done} of the last 28 days$clear'
      : '${s.done} of ${s.scheduled} days$clear in the last 4 weeks';
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
        // Wraps on narrow screens instead of running off the edge.
        Flexible(child: Text(text, style: label)),
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

/// A rounded button that opens a menu: icon, label and a small arrow.
class _MenuButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  const _MenuButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 14),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Text(label),
        const SizedBox(width: 4),
        const Icon(Icons.expand_more, size: 18),
      ],
    ),
  );
}

/// An empty state: an icon, a short title and a line of help.
class _Nothing extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;
  const _Nothing({required this.icon, required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(icon, size: 40, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
