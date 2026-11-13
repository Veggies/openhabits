import 'package:core/core.dart';
import 'package:material_ui/material_ui.dart';

import 'common.dart';

/// Picks a date. Shows a month with full weekday names ("Sun", "Mon"…);
/// tapping the month title zooms out to pick any month and year.
/// Returns null if cancelled.
Future<DateTime?> pickDate(BuildContext context, {DateTime? initial}) {
  final weekStart = AppScope.of(context).repo.weekStart;
  return showDialog<DateTime>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: _DatePicker(
          initial: initial ?? DateTime.now(),
          weekStart: weekStart,
        ),
      ),
    ),
  );
}

class _DatePicker extends StatefulWidget {
  final DateTime initial;
  final int weekStart;
  const _DatePicker({required this.initial, required this.weekStart});

  @override
  State<_DatePicker> createState() => _DatePickerState();
}

class _DatePickerState extends State<_DatePicker> {
  late DateTime month = DateTime(widget.initial.year, widget.initial.month);
  late DateTime selected = dateOnly(widget.initial);
  bool pickingMonth = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = dateOnly(DateTime.now());
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (final (label, day) in [
                ('Today', today),
                ('Tomorrow', addDays(today, 1)),
                ('Next week', startOfWeek(addDays(today, 7), widget.weekStart)),
              ])
                ActionChip(
                  label: Text(label),
                  onPressed: () => Navigator.pop(context, day),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              IconButton(
                tooltip: pickingMonth ? 'Previous year' : 'Previous month',
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(
                  () => month = pickingMonth
                      ? DateTime(month.year - 1, month.month)
                      : addMonths(month, -1),
                ),
              ),
              Expanded(
                child: TextButton(
                  onPressed: () => setState(() => pickingMonth = !pickingMonth),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        pickingMonth
                            ? '${month.year}'
                            : '${monthNamesLong[month.month - 1]} ${month.year}',
                        style: theme.textTheme.titleMedium,
                      ),
                      Icon(
                        pickingMonth
                            ? Icons.arrow_drop_up
                            : Icons.arrow_drop_down,
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: pickingMonth ? 'Next year' : 'Next month',
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(
                  () => month = pickingMonth
                      ? DateTime(month.year + 1, month.month)
                      : addMonths(month, 1),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 280,
            child: pickingMonth
                ? MonthPickerGrid(
                    year: month.year,
                    selectedMonth: month.month,
                    onSelect: (m) => setState(() {
                      month = DateTime(month.year, m);
                      pickingMonth = false;
                    }),
                  )
                : MonthDayGrid(
                    month: month,
                    weekStart: widget.weekStart,
                    selected: selected,
                    onSelect: (d) => setState(() => selected = d),
                  ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.pop(context, selected),
                child: const Text('OK'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The 12 months of a year as buttons.
class MonthPickerGrid extends StatelessWidget {
  final int year;
  final int? selectedMonth;
  final ValueChanged<int> onSelect;
  const MonthPickerGrid({
    super.key,
    required this.year,
    required this.onSelect,
    this.selectedMonth,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    return ButtonGrid(
      children: [
        for (var m = 1; m <= 12; m++)
          m == selectedMonth
              ? FilledButton(
                  onPressed: () => onSelect(m),
                  child: Text(monthShort(m)),
                )
              : OutlinedButton(
                  onPressed: () => onSelect(m),
                  style: year == now.year && m == now.month
                      ? OutlinedButton.styleFrom(
                          side: BorderSide(
                            color: theme.colorScheme.primary,
                            width: 2,
                          ),
                        )
                      : null,
                  child: Text(monthShort(m)),
                ),
      ],
    );
  }
}

/// Twelve buttons in four rows of three. Plain rows rather than a GridView:
/// it takes exactly the height it needs (nothing clipped), and menus can
/// measure it before opening, which a scrolling grid can't support.
class ButtonGrid extends StatelessWidget {
  final List<Widget> children;
  const ButtonGrid({super.key, required this.children});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(4),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        for (var i = 0; i < children.length; i += 3)
          Row(
            spacing: 8,
            children: [
              for (final child in children.skip(i).take(3))
                Expanded(child: SizedBox(height: 44, child: child)),
            ],
          ),
      ],
    ),
  );
}

/// A month of days under weekday headers ("Sun", "Mon"…). [dotsFor]
/// optionally marks days that have something on them.
class MonthDayGrid extends StatelessWidget {
  final DateTime month;
  final int weekStart;
  final DateTime? selected;
  final ValueChanged<DateTime>? onSelect;
  final bool Function(DateTime day)? dotsFor;
  final bool compact;

  const MonthDayGrid({
    super.key,
    required this.month,
    required this.weekStart,
    this.selected,
    this.onSelect,
    this.dotsFor,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = dateOnly(DateTime.now());
    final first = DateTime(month.year, month.month);
    final gridStart = startOfWeek(first, weekStart);
    final weeks =
        ((daysBetween(gridStart, first) +
                    daysInMonth(month.year, month.month)) /
                7)
            .ceil();
    final labelStyle =
        (compact ? theme.textTheme.labelSmall : theme.textTheme.labelMedium)
            ?.copyWith(
              color: theme.colorScheme.outline,
              fontSize: compact ? 9 : null,
            );

    return Column(
      children: [
        Row(
          children: [
            for (final wd in weekdayOrder(weekStart))
              Expanded(
                child: Text(
                  compact ? weekdayShort(wd).substring(0, 2) : weekdayShort(wd),
                  textAlign: TextAlign.center,
                  style: labelStyle,
                ),
              ),
          ],
        ),
        SizedBox(height: compact ? 2 : 6),
        for (var w = 0; w < weeks; w++)
          Expanded(
            child: Row(
              children: [
                for (var d = 0; d < 7; d++)
                  Expanded(
                    child: _day(context, addDays(gridStart, w * 7 + d), today),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _day(BuildContext context, DateTime day, DateTime today) {
    final theme = Theme.of(context);
    if (day.month != month.month) return const SizedBox.shrink();
    final isSelected = day == selected;
    final isToday = day == today;
    final hasDot = dotsFor?.call(day) ?? false;
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: onSelect == null ? null : () => onSelect!(day),
      child: Center(
        child: Container(
          width: compact ? 18 : 36,
          height: compact ? 18 : 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isSelected
                ? theme.colorScheme.primary
                : isToday
                ? theme.colorScheme.primaryContainer
                : hasDot && compact
                ? theme.colorScheme.tertiaryContainer
                : null,
          ),
          // Scales down when the row is shorter than the circle (e.g. the
          // small months in the year view) instead of overflowing.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${day.day}',
                  style:
                      (compact
                              ? theme.textTheme.labelSmall?.copyWith(
                                  fontSize: 9,
                                )
                              : theme.textTheme.bodyMedium)
                          ?.copyWith(
                            color: isSelected
                                ? theme.colorScheme.onPrimary
                                : null,
                          ),
                ),
                if (hasDot && !compact)
                  Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isSelected
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.tertiary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
