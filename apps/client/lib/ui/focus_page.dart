import 'package:core/core.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../data/focus_controller.dart';
import 'common.dart';

class FocusPage extends StatelessWidget {
  const FocusPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final lengths = IconButton(
      tooltip: 'Timer lengths',
      icon: const Icon(Icons.tune),
      onPressed: () => _editDurations(context, scope.focus),
    );
    return Scaffold(
      appBar: isWide(context)
          ? null
          : AppBar(title: const Text('Focus'), actions: [lengths]),
      floatingActionButton: isWide(context) ? lengths : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endTop,
      body: _body(scope),
    );
  }

  Widget _body(AppScope scope) {
    return ListenableBuilder(
      listenable: Listenable.merge([scope.focus, scope.repo.store]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final timer = _TimerPanel(focus: scope.focus);
          const stats = _Stats();
          if (constraints.maxWidth >= 840) {
            return Row(
              children: [
                Expanded(child: Center(child: timer)),
                const VerticalDivider(width: 1),
                const SizedBox(width: 360, child: stats),
              ],
            );
          }
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 16),
            children: [
              timer,
              const SizedBox(height: 24),
              const SizedBox(height: 520, child: stats),
            ],
          );
        },
      ),
    );
  }

  Future<void> _editDurations(BuildContext context, FocusController focus) =>
      showDialog(
        context: context,
        builder: (context) => ListenableBuilder(
          listenable: focus,
          builder: (context, _) => AlertDialog(
            title: const Text('Timer lengths'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final p in FocusPhase.values)
                  Row(
                    children: [
                      Expanded(child: Text(_phaseName(p))),
                      IconButton(
                        icon: const Icon(Icons.remove),
                        onPressed: () =>
                            focus.setMinutes(p, focus.minutes[p]! - 5),
                      ),
                      SizedBox(
                        width: 56,
                        child: Text(
                          '${focus.minutes[p]} min',
                          textAlign: TextAlign.center,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add),
                        onPressed: () =>
                            focus.setMinutes(p, focus.minutes[p]! + 5),
                      ),
                    ],
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      );
}

String _phaseName(FocusPhase p) => switch (p) {
  FocusPhase.focus => 'Focus',
  FocusPhase.rest => 'Break',
};

/// Each phase has its own color so focus and breaks are easy to tell apart.
Color _phaseColor(FocusPhase p, ColorScheme scheme) => switch (p) {
  FocusPhase.focus => scheme.primary,
  FocusPhase.rest => Colors.teal,
};

String _phaseHint(FocusPhase p) => switch (p) {
  FocusPhase.focus => 'Work on one thing until the timer ends.',
  FocusPhase.rest => 'Rest before the next focus session.',
};

String _hint(FocusController focus) {
  if (focus.shown != focus.phase) {
    final doing = focus.paused ? 'paused' : 'still going';
    return focus.phase == FocusPhase.focus
        ? 'Your focus session is $doing.'
        : 'Your break is $doing.';
  }
  return _phaseHint(focus.phase);
}

class _TimerPanel extends StatelessWidget {
  final FocusController focus;
  const _TimerPanel({required this.focus});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = AppScope.of(context).repo;
    // Looking at the other phase while the timer goes on.
    final away = focus.shown != focus.phase;
    final remaining = away
        ? Duration(minutes: focus.minutes[focus.shown]!)
        : focus.remaining;
    final mm = remaining.inMinutes.toString().padLeft(2, '0');
    final ss = (remaining.inSeconds % 60).toString().padLeft(2, '0');
    final habits = repo.habits.where((h) => !h.isQuit).toList();
    final color = _phaseColor(focus.shown, theme.colorScheme);
    final active = (focus.running || focus.paused) && !away;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SegmentedButton<FocusPhase>(
          showSelectedIcon: false,
          segments: [
            for (final p in FocusPhase.values)
              ButtonSegment(value: p, label: Text(_phaseName(p))),
          ],
          selected: {focus.shown},
          onSelectionChanged: (s) => focus.show(s.first),
        ),
        const SizedBox(height: 8),
        Text(
          _hint(focus),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: 260,
          height: 260,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CircularProgressIndicator(
                value: away ? 0 : focus.progress,
                strokeWidth: 10,
                color: color,
                backgroundColor: color.withValues(alpha: 0.15),
                strokeCap: StrokeCap.round,
              ),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$mm:$ss',
                      style: theme.textTheme.displayMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      active && focus.paused
                          ? 'Paused'
                          : _phaseName(focus.shown),
                      style: theme.textTheme.titleSmall?.copyWith(color: color),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Length of this phase. Hidden (but still taking space) while the
        // timer runs, so nothing below it moves.
        Visibility(
          visible: !active,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: '5 minutes less',
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () => focus.setMinutes(
                  focus.shown,
                  focus.minutes[focus.shown]! - 5,
                ),
              ),
              _MinutesField(focus: focus),
              IconButton(
                tooltip: '5 minutes more',
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => focus.setMinutes(
                  focus.shown,
                  focus.minutes[focus.shown]! + 5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Visibility.maintain(
              visible: active,
              child: IconButton.outlined(
                tooltip: 'Reset',
                icon: const Icon(Icons.restart_alt),
                onPressed: focus.reset,
              ),
            ),
            const SizedBox(width: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: color,
                minimumSize: const Size(140, 52),
              ),
              icon: Icon(
                away
                    ? Icons.undo
                    : focus.running
                    ? Icons.pause
                    : Icons.play_arrow,
              ),
              label: Text(
                away
                    ? 'Back to Timer'
                    : focus.running
                    ? 'Pause'
                    : (focus.paused ? 'Resume' : 'Start'),
              ),
              onPressed: away
                  ? () => focus.show(focus.phase)
                  : focus.running
                  ? focus.pause
                  : focus.start,
            ),
            const SizedBox(width: 16),
            Visibility.maintain(
              visible: active,
              child: IconButton.outlined(
                tooltip: 'Skip',
                icon: const Icon(Icons.skip_next),
                onPressed: focus.skip,
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        // Same height in every phase so switching phases doesn't shift the
        // layout.
        SizedBox(
          width: 320,
          height: 64,
          child: focus.shown == FocusPhase.focus
              ? DropdownButtonFormField<String?>(
                  initialValue: habits.any((h) => h.id == focus.habitId)
                      ? focus.habitId
                      : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Focusing on',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('Nothing in particular'),
                    ),
                    for (final h in habits)
                      DropdownMenuItem(
                        value: h.id,
                        child: Text(h.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: focus.selectHabit,
                )
              : Center(
                  child: Text(
                    'Up next: Focus · ${focus.minutes[FocusPhase.focus]} min',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats();

  // Rebuilds on every data change; a const instance would otherwise
  // never refresh.
  @override
  Widget build(BuildContext context) =>
      DataBuilder(builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final theme = Theme.of(context);
    final today = dateOnly(DateTime.now());
    final sessions = repo.focusSessions;
    final todays = sessions.where((s) => dateOnly(s.start) == today).toList();
    final weekStart = addDays(today, -6);
    final week = sessions.where((s) => !s.start.isBefore(weekStart)).toList();

    String minutesLabel(int m) => m >= 60 ? '${m ~/ 60}h ${m % 60}m' : '${m}m';

    Widget stat(String label, String value) => Expanded(
      child: Column(
        children: [
          Text(value, style: theme.textTheme.headlineSmall),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const TomatoRow(),
        const SizedBox(height: 24),
        Text('Overview', style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        Row(
          children: [
            stat('Sessions today', '${todays.length}'),
            stat(
              'Today',
              minutesLabel(todays.fold(0, (a, s) => a + s.minutes)),
            ),
            stat(
              'Last 7 days',
              minutesLabel(week.fold(0, (a, s) => a + s.minutes)),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text('Recent sessions', style: theme.textTheme.titleMedium),
        if (sessions.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Your finished focus sessions will show up here.',
              style: TextStyle(color: theme.colorScheme.outline),
            ),
          ),
        for (final s in sessions.take(20))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.timer_outlined),
            title: Text(
              s.habitId == null
                  ? 'Focus'
                  : (repo.habit(s.habitId!)?.name ?? 'Focus'),
            ),
            subtitle: Text(
              '${relativeDate(s.start, DateTime.now())} · ${clockLabel(context, s.start)}',
            ),
            trailing: Text('${s.minutes} min'),
          ),
      ],
    );
  }
}

/// The current phase's length. Type a number, or use the − and + buttons
/// beside it.
class _MinutesField extends StatefulWidget {
  final FocusController focus;
  const _MinutesField({required this.focus});

  @override
  State<_MinutesField> createState() => _MinutesFieldState();
}

class _MinutesFieldState extends State<_MinutesField> {
  late final _controller = TextEditingController(text: '$_minutes');
  final _focusNode = FocusNode();

  /// The phase whose length is showing.
  late FocusPhase _phase;

  int get _minutes => widget.focus.minutes[widget.focus.shown]!;

  @override
  void initState() {
    super.initState();
    _phase = widget.focus.shown;
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_MinutesField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Follow the −/+ buttons, unless the person is typing. Another phase
    // always shows its own length.
    final switched = _phase != widget.focus.shown;
    _phase = widget.focus.shown;
    if ((switched || !_focusNode.hasFocus) && _controller.text != '$_minutes') {
      _controller.text = '$_minutes';
    }
  }

  /// Shows the length as it was understood. It's already been set, as it
  /// was typed; setting it again here could reach the other phase, if that's
  /// the one on screen by now.
  void _commit() => _controller.text = '$_minutes';

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 96,
    child: TextField(
      controller: _controller,
      focusNode: _focusNode,
      textAlign: TextAlign.center,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(3),
      ],
      style: Theme.of(context).textTheme.titleMedium,
      decoration: const InputDecoration(
        suffixText: 'min',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      // Counts straight away, since clicking Start doesn't always end editing.
      onChanged: (typed) {
        final value = int.tryParse(typed);
        if (value != null) widget.focus.setMinutes(widget.focus.shown, value);
      },
      onSubmitted: (_) => _commit(),
    ),
  );
}

/// Today's earned pomodoros against the daily goal: a tomato for each
/// focus session finished, and an empty slot for each one still to go.
class TomatoRow extends StatelessWidget {
  const TomatoRow({super.key});

  @override
  Widget build(BuildContext context) => DataBuilder(
    builder: (context, repo) {
      final theme = Theme.of(context);
      final earned = repo.pomodorosToday;
      final goal = repo.focusGoal;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  "Today's pomodoros",
                  style: theme.textTheme.titleMedium,
                ),
              ),
              PopupMenuButton<int>(
                tooltip: 'Change your daily goal',
                initialValue: goal,
                onSelected: (g) => repo.setPrefs({'focusGoal': g}),
                itemBuilder: (_) => [
                  for (var g = 1; g <= 12; g++)
                    PopupMenuItem(value: g, child: Text('$g a day')),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    earned >= goal
                        ? "You reached today's goal"
                        : '$earned of $goal',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: earned >= goal
                          ? Colors.green
                          : theme.colorScheme.outline,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < (earned > goal ? earned : goal); i++)
                i < earned
                    ? const Text('🍅', style: TextStyle(fontSize: 24))
                    : Container(
                        width: 28,
                        height: 28,
                        margin: const EdgeInsets.all(1),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant,
                            width: 1.5,
                          ),
                        ),
                      ),
            ],
          ),
        ],
      );
    },
  );
}
