import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:core/core.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../data/repo.dart';
import 'common.dart';
import 'growth_chart.dart';
import 'habit_editor.dart';
import 'habits_page.dart';

/// One habit: how it's going, a month of check-ins you can change, and its
/// plan. A full page on phones; on computers it's shown by [HabitPreview],
/// with [onClose].
class HabitDetailPage extends StatefulWidget {
  final String habitId;
  final VoidCallback? onClose;
  const HabitDetailPage({super.key, required this.habitId, this.onClose});

  @override
  State<HabitDetailPage> createState() => _HabitDetailPageState();
}

class _HabitDetailPageState extends State<HabitDetailPage> {
  late DateTime month = DateTime(DateTime.now().year, DateTime.now().month);

  void _leave() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _menu(Habit habit, String choice) async {
    final repo = AppScope.read(context).repo;
    if (choice == 'archive') {
      repo.updateHabit(habit.id, {'archived': true});
      _leave();
    } else if (choice == 'delete' && await confirmDeleteHabit(context, habit)) {
      repo.deleteHabit(habit.id);
      _leave();
    }
  }

  Widget _moreMenu(Habit habit) => PopupMenuButton<String>(
    tooltip: 'More',
    icon: const Icon(Icons.more_horiz),
    onSelected: (v) => _menu(habit, v),
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'archive', child: Text('Archive')),
      PopupMenuItem(value: 'delete', child: Text('Delete…')),
    ],
  );

  @override
  Widget build(BuildContext context) => DataBuilder(
    builder: (context, repo) {
      final habit = repo.habit(widget.habitId);
      if (habit == null || habit.deleted) {
        return const Scaffold(
          body: Center(child: Text('This habit was deleted.')),
        );
      }
      final inPanel = widget.onClose != null;
      final theme = Theme.of(context);
      final suggestion = repo.sizeSuggestion(habit);

      final content = ListView(
        padding: EdgeInsets.fromLTRB(20, inPanel ? 24 : 8, 20, 40),
        children: [
          _Header(habit: habit, showName: inPanel),
          if (suggestion != null) ...[
            const SizedBox(height: 16),
            Card(
              color: theme.colorScheme.primaryContainer,
              child: ListTile(
                leading: Icon(
                  suggestion == SizeSuggestion.grow
                      ? Icons.trending_up
                      : Icons.trending_down,
                ),
                title: Text(
                  suggestion == SizeSuggestion.grow
                      ? 'Is it starting to feel too easy?'
                      : 'Make it a little smaller?',
                ),
                subtitle: Text(
                  suggestion == SizeSuggestion.grow
                      ? "You've done it on most days lately. Have a quick look at its size."
                      : "It's been hard to fit in lately. A smaller version might help.",
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => sizeCheckIn(context, habit, suggestion),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _MonthCalendar(
                habit: habit,
                month: month,
                onMonth: (m) => setState(() => month = m),
              ),
            ),
          ),
          _Plan(habit: habit),
        ],
      );

      if (!inPanel) {
        return Scaffold(
          appBar: AppBar(
            title: Text(habit.name),
            actions: [
              _moreMenu(habit),
              TextButton(
                onPressed: () => editHabit(context, existing: habit),
                child: const Text('Edit'),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: content,
        );
      }
      // In the panel, the actions sit on the page itself.
      return Material(
        color: theme.colorScheme.surface,
        child: Stack(
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: content,
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: Row(
                children: [
                  _moreMenu(habit),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: () => editHabit(context, existing: habit),
                    child: const Text('Edit'),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Close (Esc)',
                    icon: const Icon(Icons.close),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _Header extends StatelessWidget {
  final Habit habit;
  final bool showName;
  const _Header({required this.habit, required this.showName});

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final theme = Theme.of(context);
    final strength = habitStrength(repo, habit);
    final count = habit.isQuit ? repo.daysClean(habit) : repo.streak(habit);
    final identity = habit.plan.identity;
    return Column(
      children: [
        HabitAvatar(icon: habit.icon, color: habit.color, size: 72),
        if (showName) ...[
          const SizedBox(height: 10),
          Text(
            habit.name,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
        if (identity.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            'I am $identity',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontStyle: FontStyle.italic,
              color: theme.colorScheme.outline,
            ),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            _Stat(
              icon: habit.isQuit ? Icons.shield : Icons.local_fire_department,
              color: habit.isQuit ? Colors.green : Colors.deepOrange,
              value: '$count',
              label: habit.isQuit
                  ? (count == 1 ? 'day clean' : 'days clean')
                  : 'day streak',
            ),
            const SizedBox(width: 10),
            _Stat(
              icon: Icons.show_chart,
              color: strength.level.color(theme),
              value: strength.level.label,
              label: strength.level == StrengthLevel.justStarted
                  ? 'too soon to say'
                  : '${strength.done} of ${strength.scheduled} days${habit.isQuit ? ' clear' : ''}',
            ),
            const SizedBox(width: 10),
            _Stat(
              icon: Icons.check,
              color: Color(habit.color),
              value: '${repo.votes(habit.id)}',
              label: identity.isEmpty
                  ? 'check-ins'
                  : "votes for who you're becoming",
            ),
          ],
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String value;
  final String label;
  const _Stat({
    required this.icon,
    required this.color,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.5,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 4),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              label,
              maxLines: 2,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A month of check-ins. Tap any day up to today to change it.
class _MonthCalendar extends StatelessWidget {
  final Habit habit;
  final DateTime month;
  final ValueChanged<DateTime> onMonth;
  const _MonthCalendar({
    required this.habit,
    required this.month,
    required this.onMonth,
  });

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final theme = Theme.of(context);
    final today = dateOnly(repo.clock());
    final first = DateTime(month.year, month.month);
    final order = weekdayOrder(repo.weekStart);
    final lead = order.indexOf(first.weekday);
    final cells = <DateTime?>[
      for (var i = 0; i < lead; i++) null,
      for (var d = 0; d < daysInMonth(first.year, first.month); d++)
        addDays(first, d),
    ];
    final color = Color(habit.color);
    final start = dateOnly(habit.createdAt.toLocal());

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${monthNamesLong[first.month - 1]} ${first.year}',
                style: theme.textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: 'Previous month',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => onMonth(addMonths(first, -1)),
            ),
            IconButton(
              tooltip: 'Next month',
              icon: const Icon(Icons.chevron_right),
              // Months ahead are there for planning time off.
              onPressed: addMonths(first, 1).isAfter(addMonths(today, 12))
                  ? null
                  : () => onMonth(addMonths(first, 1)),
            ),
          ],
        ),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.15,
          children: [
            for (final d in order)
              Center(
                child: Text(
                  weekdayShort(d).substring(0, 1),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            for (final day in cells)
              if (day == null)
                const SizedBox.shrink()
              else
                Builder(
                  builder: (context) {
                    final done = repo.isHabitDone(habit.id, day);
                    final off = repo.isHabitOff(habit.id, day);
                    final open = !day.isAfter(today) && !day.isBefore(start);
                    final scheduled = habit.isScheduled(day);
                    return Center(
                      child: Semantics(
                        // A day that can't be ticked isn't a button.
                        button: open && (scheduled || done),
                        label: MaterialLocalizations.of(context)
                            .formatFullDate(day),
                        value: off
                            ? 'Day off'
                            : done
                            ? (habit.isQuit ? 'Stayed clear' : 'Done')
                            : scheduled
                            ? 'Not done'
                            : 'Not scheduled',
                        excludeSemantics: true,
                        child: GestureDetector(
                          // Any day ahead can be given the day off too.
                          onLongPressStart: (d) => showDayOffMenu(
                            context,
                            habit,
                            day,
                            d.globalPosition,
                          ),
                          onSecondaryTapDown: (d) => showDayOffMenu(
                            context,
                            habit,
                            day,
                            d.globalPosition,
                          ),
                          child: InkResponse(
                            radius: 20,
                            // Days the habit isn't scheduled on can't be
                            // ticked, but a tick already there can be undone.
                            onTap: open && (scheduled || done)
                                ? () => repo.setHabitDone(habit.id, day, !done)
                                : null,
                            child: Container(
                              width: 36,
                              height: 36,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: done ? color : null,
                                border: day == today && !done && !off
                                    ? Border.all(color: color, width: 2)
                                    : null,
                              ),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  if (off)
                                    DashedCircle(
                                      size: 36,
                                      color: color.withValues(alpha: 0.7),
                                    ),
                                  Text(
                                    '${day.day}',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: day == today
                                          ? FontWeight.bold
                                          : null,
                                      color: done
                                          ? Colors.white
                                          : open && scheduled
                                          ? null
                                          : theme.colorScheme.outline
                                                .withValues(alpha: 0.5),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
          ],
        ),
      ],
    );
  }
}

class _Plan extends StatelessWidget {
  final Habit habit;
  const _Plan({required this.habit});

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final theme = Theme.of(context);
    final plan = habit.plan;
    final history = versionLine(plan);
    final rows = habit.isQuit
        ? [
            ('Remove the cue', plan.invisible),
            ('Reframe it', plan.unattractive),
            ('Add friction', plan.difficult),
            ('Accountability', plan.unsatisfying),
            ('Habit contract', plan.contract),
          ]
        : [
            ('Your version for now', plan.twoMinute),
            (
              'Grown from',
              history.startsWith('Grown from: ')
                  ? history.substring('Grown from: '.length)
                  : '',
            ),
            ('After I…', plan.stackAfter),
            (
              'When',
              plan.time.isEmpty
                  ? ''
                  : '${timeLabel(context, plan.time)}, for ${durationLabel(habit.duration)}',
            ),
            ('Where', plan.location),
            ('Pair it with', plan.bundle),
            ('Reward', plan.reward),
            (
              'Days',
              habit.weekdays.length == 7
                  ? 'Every day'
                  : [
                      for (final d in weekdayOrder(repo.weekStart))
                        if (habit.weekdays.contains(d)) weekdayShort(d),
                    ].join(', '),
            ),
          ];
    final filled = [
      for (final r in rows)
        if (r.$2.isNotEmpty) r,
    ];
    if (filled.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(
                  habit.isQuit ? 'Your plan to break it' : 'Your plan',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              for (final (label, value) in filled)
                ListTile(
                  dense: true,
                  title: Text(label),
                  trailing: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Text(
                      value,
                      textAlign: TextAlign.end,
                      style: TextStyle(color: theme.colorScheme.outline),
                    ),
                  ),
                ),
              if (plan.sizeSettled && plan.twoMinute.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: TextButton(
                    onPressed: () => repo.settleSize(habit, settled: false),
                    child: const Text('Start checking in on the size again'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// On computers: a habit's page slides in from the right over most of the
/// window, and the list stays visible, blurred, on the left. Click the list
/// or press Esc to slide it away again.
class HabitPreview extends StatefulWidget {
  final Widget child;
  const HabitPreview({super.key, required this.child});

  @override
  State<HabitPreview> createState() => _HabitPreviewState();
}

class _HabitPreviewState extends State<HabitPreview>
    with SingleTickerProviderStateMixin {
  late final _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  late final _curve = CurvedAnimation(
    parent: _slide,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  /// The habit on show. Kept while the page slides away after closing.
  String? _shown;
  AppNav? _nav;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nav = AppScope.of(context).nav;
    if (nav != _nav) {
      _nav?.removeListener(_follow);
      _nav = nav..addListener(_follow);
      _follow();
    }
  }

  void _follow() {
    final id = _nav?.preview;
    if (id != null) {
      setState(() => _shown = id);
      _slide.forward();
    } else if (_shown != null) {
      _slide.reverse().whenComplete(() {
        if (mounted && _nav?.preview == null) setState(() => _shown = null);
      });
    }
  }

  @override
  void dispose() {
    _nav?.removeListener(_follow);
    _slide.dispose();
    super.dispose();
  }

  void _close() => _nav?.openPreview(null);

  @override
  Widget build(BuildContext context) {
    // A habit that's archived or deleted (here or elsewhere) closes.
    final repo = AppScope.of(context).repo;
    return ListenableBuilder(
      listenable: repo.store,
      builder: (context, _) {
        if (_nav?.preview case final id?
            when repo.habit(id)?.archived != false ||
                repo.habit(id)?.deleted == true) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _close());
        }
        return LayoutBuilder(
          builder: (context, size) {
            // Briefly narrower than 680 while the window is resized, the
            // smallest size gives way rather than crash.
            final most = max(0.0, size.maxWidth - 120);
            final width = (size.maxWidth * 0.75)
                .clamp(min(560.0, most), most)
                .toDouble();
            return AnimatedBuilder(
              animation: _curve,
              builder: (context, _) {
                final t = _curve.value;
                return Stack(
                  children: [
                    ImageFiltered(
                      enabled: t > 0,
                      imageFilter: ImageFilter.blur(
                        sigmaX: 10 * t,
                        sigmaY: 10 * t,
                      ),
                      child: IgnorePointer(
                        ignoring: _shown != null,
                        child: widget.child,
                      ),
                    ),
                    if (_shown != null) ...[
                      Positioned.fill(
                        child: GestureDetector(
                          onTap: _close,
                          child: ColoredBox(
                            color: Colors.black.withValues(alpha: 0.2 * t),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: -width * (1 - t),
                        width: width,
                        child: CallbackShortcuts(
                          bindings: {
                            const SingleActivator(LogicalKeyboardKey.escape):
                                _close,
                          },
                          child: Focus(
                            autofocus: true,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(
                                      alpha: 0.25 * t,
                                    ),
                                    blurRadius: 30,
                                    offset: const Offset(-6, 0),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: const BorderRadius.horizontal(
                                  left: Radius.circular(18),
                                ),
                                child: HabitDetailPage(
                                  key: ValueKey(_shown),
                                  habitId: _shown!,
                                  onClose: _close,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}
