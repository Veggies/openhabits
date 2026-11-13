import 'dart:async';

import 'package:core/core.dart';
import 'package:material_ui/material_ui.dart';

import '../data/repo.dart';
import 'common.dart';
import 'date_picker.dart';
import 'tasks_page.dart' show TaskCheckbox;

/// Edits one task. Text edits are saved after a short pause in typing so
/// each keystroke doesn't become a separate synced change.
class TaskDetail extends StatefulWidget {
  final String taskId;
  final VoidCallback? onClose;
  const TaskDetail({super.key, required this.taskId, this.onClose});

  @override
  State<TaskDetail> createState() => _TaskDetailState();
}

class _TaskDetailState extends State<TaskDetail> {
  late final TextEditingController _title;
  late final TextEditingController _notes;
  final _pending = <String, Object?>{};
  Timer? _saveTimer;
  late Repo _repo;

  @override
  void initState() {
    super.initState();
    _repo = AppScope.read(context).repo;
    final task = _repo.task(widget.taskId);
    _title = TextEditingController(text: task?.title ?? '');
    _notes = TextEditingController(text: task?.notes ?? '');
  }

  void _queue(String field, String value) {
    _pending[field] = value;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _flush);
  }

  void _flush() {
    _saveTimer?.cancel();
    if (_pending.isEmpty) return;
    _repo.updateTask(widget.taskId, Map.of(_pending));
    _pending.clear();
  }

  @override
  void dispose() {
    _flush();
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DataBuilder(
      builder: (context, repo) {
        final task = repo.task(widget.taskId);
        if (task == null) return const Center(child: Text('Task not found'));
        return _build(context, repo, task);
      },
    );
  }

  Widget _build(BuildContext context, Repo repo, Task task) {
    final theme = Theme.of(context);
    void update(Fields f) => repo.updateTask(task.id, f);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Row(
          children: [
            if (!task.deleted) TaskCheckbox(task: task),
            Expanded(
              child: TextField(
                controller: _title,
                style: theme.textTheme.titleLarge,
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Title',
                ),
                onChanged: (v) => _queue('title', v),
                onSubmitted: (_) => _flush(),
              ),
            ),
            if (widget.onClose != null)
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: widget.onClose,
              ),
          ],
        ),
        if (task.deleted)
          Card(
            color: theme.colorScheme.errorContainer,
            child: ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('This task is in the trash'),
              trailing: TextButton(
                onPressed: () => repo.restoreTask(task.id),
                child: const Text('Restore'),
              ),
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _DueChip(task: task, onChanged: update),
            if (task.dueDate != null) _TimeChip(task: task, onChanged: update),
            if (task.dueDate != null)
              _RepeatChip(task: task, onChanged: update),
            _PriorityChip(task: task, onChanged: update),
            _ListChip(task: task, repo: repo, onChanged: update),
          ],
        ),
        const SizedBox(height: 12),
        _TagEditor(task: task, onChanged: (tags) => update({'tags': tags})),
        const SizedBox(height: 12),
        TextField(
          controller: _notes,
          minLines: 3,
          maxLines: null,
          decoration: const InputDecoration(
            hintText: 'Notes',
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => _queue('notes', v),
        ),
        const SizedBox(height: 20),
        if (task.parentId == null) _Subtasks(task: task, repo: repo),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: Text(
                'Created ${shortDate(task.createdAt.toLocal())}'
                '${task.completedAt != null ? ' · Completed ${shortDate(task.completedAt!.toLocal())}' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
            if (!task.deleted)
              TextButton.icon(
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                onPressed: () {
                  repo.deleteTask(task.id);
                  if (widget.onClose != null) {
                    widget.onClose!();
                  } else {
                    Navigator.of(context).maybePop();
                  }
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _DueChip extends StatelessWidget {
  final Task task;
  final ValueChanged<Fields> onChanged;
  const _DueChip({required this.task, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return InputChip(
      avatar: const Icon(Icons.event, size: 18),
      label: Text(
        task.dueDate == null ? 'Due date' : relativeDate(task.dueDate!, now),
      ),
      onDeleted: task.dueDate == null
          ? null
          : () => onChanged({'dueDate': null, 'dueTime': null, 'repeat': null}),
      onPressed: () async {
        final picked = await pickDate(context, initial: task.dueDate ?? now);
        if (picked != null) onChanged({'dueDate': dateKey(picked)});
      },
    );
  }
}

class _TimeChip extends StatelessWidget {
  final Task task;
  final ValueChanged<Fields> onChanged;
  const _TimeChip({required this.task, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return InputChip(
      avatar: const Icon(Icons.schedule, size: 18),
      label: Text(
        task.dueTime == null
            ? 'Time'
            : '${timeLabel(context, task.dueTime!)} · ${task.duration} min',
      ),
      onDeleted: task.dueTime == null
          ? null
          : () => onChanged({'dueTime': null}),
      onPressed: () async {
        final current = task.dueTime == null ? null : parseTime(task.dueTime!);
        final picked = await showTimePicker(
          context: context,
          initialTime: current == null
              ? const TimeOfDay(hour: 9, minute: 0)
              : TimeOfDay(hour: current.hour, minute: current.minute),
        );
        if (picked == null || !context.mounted) return;
        final duration = await showDialog<int>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Duration'),
            children: [
              for (final m in [15, 30, 45, 60, 90, 120])
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, m),
                  child: Text('$m minutes'),
                ),
            ],
          ),
        );
        onChanged({
          'dueTime': formatTime(picked.hour, picked.minute),
          'duration': ?duration,
        });
      },
    );
  }
}

class _RepeatChip extends StatelessWidget {
  final Task task;
  final ValueChanged<Fields> onChanged;
  const _RepeatChip({required this.task, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final due = task.dueDate!;
    final options = <String, RepeatRule?>{
      'Does not repeat': null,
      'Daily': const RepeatRule(Freq.daily),
      'Weekdays': RepeatRule.weekdaysOnly,
      'Weekly on ${weekdayShort(due.weekday)}': RepeatRule(
        Freq.weekly,
        weekdays: {due.weekday},
      ),
      'Every 2 weeks': RepeatRule(
        Freq.weekly,
        interval: 2,
        weekdays: {due.weekday},
      ),
      'Monthly on day ${due.day}': const RepeatRule(Freq.monthly),
      'Yearly on ${shortDate(due)}': const RepeatRule(Freq.yearly),
    };
    return PopupMenuButton<RepeatRule?>(
      tooltip: 'Repeat',
      onSelected: (r) => onChanged({'repeat': r?.encode()}),
      itemBuilder: (_) => [
        for (final MapEntry(:key, :value) in options.entries)
          PopupMenuItem(value: value, child: Text(key)),
      ],
      child: Chip(
        avatar: const Icon(Icons.repeat, size: 18),
        label: Text(task.repeat?.describe() ?? 'Repeat'),
      ),
    );
  }
}

class _PriorityChip extends StatelessWidget {
  final Task task;
  final ValueChanged<Fields> onChanged;
  const _PriorityChip({required this.task, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<Priority>(
      tooltip: 'Priority',
      onSelected: (p) => onChanged({'priority': p.index}),
      itemBuilder: (_) => [
        for (final p in Priority.values.reversed)
          PopupMenuItem(
            value: p,
            child: Row(
              children: [
                Icon(Icons.flag, color: priorityColor(p, scheme)),
                const SizedBox(width: 8),
                Text(priorityLabel(p)),
              ],
            ),
          ),
      ],
      child: Chip(
        avatar: Icon(
          Icons.flag,
          size: 18,
          color: priorityColor(task.priority, scheme),
        ),
        label: Text(
          task.priority == Priority.none
              ? 'Priority'
              : priorityLabel(task.priority),
        ),
      ),
    );
  }
}

class _ListChip extends StatelessWidget {
  final Task task;
  final Repo repo;
  final ValueChanged<Fields> onChanged;
  const _ListChip({
    required this.task,
    required this.repo,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final current = repo.list(task.listId);
    return PopupMenuButton<String>(
      tooltip: 'List',
      onSelected: (id) => onChanged({'listId': id.isEmpty ? null : id}),
      itemBuilder: (_) => [
        const PopupMenuItem(value: '', child: Text('Inbox')),
        for (final l in repo.lists)
          PopupMenuItem(
            value: l.id,
            child: Row(
              children: [
                ColorDot(l.color),
                const SizedBox(width: 8),
                Text(l.name),
              ],
            ),
          ),
      ],
      child: Chip(
        avatar: current == null
            ? const Icon(Icons.inbox_outlined, size: 18)
            : ColorDot(current.color),
        label: Text(current?.name ?? 'Inbox'),
      ),
    );
  }
}

class _TagEditor extends StatelessWidget {
  final Task task;
  final ValueChanged<List<String>> onChanged;
  const _TagEditor({required this.task, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final t in task.tags)
          InputChip(
            label: Text('#$t'),
            onDeleted: () => onChanged([...task.tags]..remove(t)),
          ),
        ActionChip(
          avatar: const Icon(Icons.tag, size: 18),
          label: const Text('Add tag'),
          onPressed: () async {
            final tag = await promptText(
              context,
              title: 'Add tag',
              hint: 'e.g. errands',
              action: 'Add',
            );
            final clean = tag?.trim().replaceAll('#', '').replaceAll(' ', '-');
            if (clean != null &&
                clean.isNotEmpty &&
                !task.tags.contains(clean)) {
              onChanged([...task.tags, clean]);
            }
          },
        ),
      ],
    );
  }
}

class _Subtasks extends StatefulWidget {
  final Task task;
  final Repo repo;
  const _Subtasks({required this.task, required this.repo});

  @override
  State<_Subtasks> createState() => _SubtasksState();
}

class _SubtasksState extends State<_Subtasks> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = widget.repo;
    final subtasks = repo.subtasks(widget.task.id);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Subtasks', style: theme.textTheme.titleSmall),
        for (final s in subtasks)
          Row(
            children: [
              Checkbox(value: s.done, onChanged: (_) => repo.toggle(s)),
              Expanded(
                child: Text(
                  s.title,
                  style: TextStyle(
                    decoration: s.done ? TextDecoration.lineThrough : null,
                    color: s.done ? theme.colorScheme.outline : null,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Remove subtask',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => repo.deleteTask(s.id),
              ),
            ],
          ),
        TextField(
          controller: _controller,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.add),
            hintText: 'Add subtask',
            border: InputBorder.none,
          ),
          onSubmitted: (v) {
            if (v.trim().isEmpty) return;
            repo.createTask(
              title: v.trim(),
              parentId: widget.task.id,
              listId: widget.task.listId,
            );
            _controller.clear();
          },
        ),
      ],
    );
  }
}
