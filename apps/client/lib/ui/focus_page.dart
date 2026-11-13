import 'package:core/core.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../data/focus_controller.dart';
import '../data/repo.dart';
import 'common.dart';

class FocusPage extends StatelessWidget {
  const FocusPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Focus'),
        actions: [
          IconButton(
            tooltip: 'Timer lengths',
            icon: const Icon(Icons.tune),
            onPressed: () => _editDurations(context, scope.focus),
          ),
        ],
      ),
      body: ListenableBuilder(
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
                const SizedBox(height: 420, child: stats),
              ],
            );
          },
        ),
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

class _TimerPanel extends StatelessWidget {
  final FocusController focus;
  const _TimerPanel({required this.focus});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = AppScope.of(context).repo;
    final remaining = focus.remaining;
    final mm = remaining.inMinutes.toString().padLeft(2, '0');
    final ss = (remaining.inSeconds % 60).toString().padLeft(2, '0');
    final openTasks = repo.tasksFor(const SmartFilter(SmartList.all));
    final selectedTask = focus.taskId == null ? null : repo.task(focus.taskId!);
    final color = _phaseColor(focus.phase, theme.colorScheme);
    final active = focus.running || focus.paused;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SegmentedButton<FocusPhase>(
          showSelectedIcon: false,
          segments: [
            for (final p in FocusPhase.values)
              ButtonSegment(value: p, label: Text(_phaseName(p))),
          ],
          selected: {focus.phase},
          onSelectionChanged: (s) => focus.selectPhase(s.first),
        ),
        const SizedBox(height: 8),
        Text(
          _phaseHint(focus.phase),
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
                value: focus.progress,
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
                      focus.paused ? 'Paused' : _phaseName(focus.phase),
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
                  focus.phase,
                  focus.minutes[focus.phase]! - 5,
                ),
              ),
              _MinutesField(focus: focus),
              IconButton(
                tooltip: '5 minutes more',
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => focus.setMinutes(
                  focus.phase,
                  focus.minutes[focus.phase]! + 5,
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
              icon: Icon(focus.running ? Icons.pause : Icons.play_arrow),
              label: Text(
                focus.running ? 'Pause' : (focus.paused ? 'Resume' : 'Start'),
              ),
              onPressed: focus.running ? focus.pause : focus.start,
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
          child: focus.phase == FocusPhase.focus
              ? DropdownButtonFormField<String?>(
                  initialValue:
                      selectedTask == null ||
                          selectedTask.done ||
                          selectedTask.deleted
                      ? null
                      : focus.taskId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Focusing on',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('No task')),
                    for (final t in openTasks)
                      DropdownMenuItem(
                        value: t.id,
                        child: Text(t.title, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: focus.selectTask,
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
        Text('Overview', style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        Row(
          children: [
            stat("Today's pomos", '${todays.length}'),
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
              'Completed focus sessions appear here.',
              style: TextStyle(color: theme.colorScheme.outline),
            ),
          ),
        for (final s in sessions.take(20))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.timer_outlined),
            title: Text(
              s.taskId == null
                  ? 'Focus'
                  : (repo.task(s.taskId!)?.title ?? 'Focus'),
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

  int get _minutes => widget.focus.minutes[widget.focus.phase]!;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_MinutesField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Follow the −/+ buttons and phase changes, unless the person is typing.
    if (!_focusNode.hasFocus && _controller.text != '$_minutes') {
      _controller.text = '$_minutes';
    }
  }

  void _commit() {
    final value = int.tryParse(_controller.text.trim());
    if (value != null) widget.focus.setMinutes(widget.focus.phase, value);
    _controller.text = '$_minutes';
  }

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
      onSubmitted: (_) => _commit(),
    ),
  );
}
