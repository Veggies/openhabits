import 'package:core/core.dart';
import 'package:material_ui/material_ui.dart';

import '../data/repo.dart';
import 'common.dart';

/// The Tasks tab: one-off to-dos, listed as Today (with anything overdue),
/// Upcoming, Someday and Done, or sorted into the four boxes of the
/// Eisenhower matrix. Matches the Apple app's TasksView.
class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  bool _matrix = false;

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    final theme = Theme.of(context);
    final picker = SegmentedButton<bool>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: false, label: Text('List')),
        ButtonSegment(value: true, label: Text('Matrix')),
      ],
      selected: {_matrix},
      onSelectionChanged: (s) => setState(() => _matrix = s.first),
    );
    return Scaffold(
      appBar: wide ? null : AppBar(title: const Text('Tasks')),
      floatingActionButton: wide
          ? null
          : FloatingActionButton.extended(
              heroTag: null,
              icon: const Icon(Icons.add),
              label: const Text('New task'),
              onPressed: () => editTask(context),
            ),
      body: DataBuilder(
        builder: (context, repo) => CenteredListView(
          maxWidth: _matrix ? 1000 : 760,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
          children: [
            if (wide)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Tasks',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    FilledButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('New task'),
                      onPressed: () => editTask(context),
                    ),
                  ],
                ),
              ),
            picker,
            const SizedBox(height: 12),
            if (_matrix) const _Matrix() else const _TaskList(),
          ],
        ),
      ),
    );
  }
}

/// Today, Upcoming, Someday and Done, with a box at the top to add a task
/// quickly. Done tasks stay hidden until you ask to see them.
class _TaskList extends StatefulWidget {
  const _TaskList();

  @override
  State<_TaskList> createState() => _TaskListState();
}

class _TaskListState extends State<_TaskList> {
  final _add = TextEditingController();
  bool _showDone = false;

  @override
  void dispose() {
    _add.dispose();
    super.dispose();
  }

  void _submit(String text) {
    if (text.trim().isEmpty) return;
    AppScope.read(context).repo.addTask(text);
    _add.clear();
  }

  // Rebuilds on every data change; a const instance would otherwise never
  // refresh.
  @override
  Widget build(BuildContext context) =>
      DataBuilder(builder: (context, repo) => _build(context, repo));

  Widget _build(BuildContext context, Repo repo) {
    final theme = Theme.of(context);
    final done = repo.tasksIn(TaskGroup.done);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _add,
          decoration: const InputDecoration(
            hintText: 'Add a task',
            prefixIcon: Icon(Icons.add),
            border: OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: _submit,
        ),
        if (repo.tasks.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
            child: Text(
              'Write down anything you need to do once, like renewing your '
              'passport. Tap a task to give it a due date, or to mark it as '
              'important or urgent.',
              style: TextStyle(color: theme.colorScheme.outline),
            ),
          ),
        for (final group in [
          TaskGroup.today,
          TaskGroup.upcoming,
          TaskGroup.someday,
        ])
          if (repo.tasksIn(group) case final tasks when tasks.isNotEmpty)
            TaskSection(title: group.label, tasks: tasks),
        if (done.isNotEmpty) ...[
          TaskSection(
            title: 'Done',
            tasks: _showDone ? done : const [],
            trailing: TextButton(
              onPressed: () => setState(() => _showDone = !_showDone),
              child: Text(_showDone ? 'Hide' : 'Show ${done.length}'),
            ),
          ),
          if (_showDone)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                onPressed: () async {
                  if (await _confirmClear(context, done.length)) {
                    for (final t in done) {
                      repo.deleteTask(t.id);
                    }
                  }
                },
                child: const Text('Delete finished tasks'),
              ),
            ),
        ],
      ],
    );
  }

  Future<bool> _confirmClear(BuildContext context, int count) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Delete all $count finished tasks?'),
          content: const Text('This removes them from all your devices.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete finished tasks'),
            ),
          ],
        ),
      ) ??
      false;
}

/// A heading and a card of tasks. Also used for today's tasks on the
/// Habits tab.
class TaskSection extends StatelessWidget {
  final String title;
  final List<TaskItem> tasks;
  final Widget? trailing;
  const TaskSection({
    super.key,
    required this.title,
    required this.tasks,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 16, 0, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
        if (tasks.isNotEmpty)
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final (i, t) in tasks.indexed) ...[
                  if (i > 0) const Divider(height: 1, indent: 56),
                  TaskTile(task: t),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// The four boxes of the matrix, two across when there's room. Each box's
/// plus button adds a task already marked to go in it.
class _Matrix extends StatelessWidget {
  const _Matrix();

  @override
  Widget build(BuildContext context) =>
      DataBuilder(builder: (context, _) => LayoutBuilder(builder: _layout));

  Widget _layout(BuildContext context, BoxConstraints c) {
    final boxes = [for (final b in TaskQuadrant.values) _Box(box: b)];
    if (c.maxWidth < 640) {
      return Column(
        children: [
          for (final b in boxes)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: b),
        ],
      );
    }
    return Column(
      children: [
        for (var i = 0; i < boxes.length; i += 2)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: boxes[i]),
                  const SizedBox(width: 12),
                  Expanded(child: boxes[i + 1]),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

extension on TaskQuadrant {
  Color get color => switch (this) {
    TaskQuadrant.doNow => Colors.red,
    TaskQuadrant.plan => Colors.blue,
    TaskQuadrant.keepQuick => Colors.orange,
    TaskQuadrant.letGo => Colors.blueGrey,
  };

  IconData get icon => switch (this) {
    TaskQuadrant.doNow => Icons.local_fire_department_outlined,
    TaskQuadrant.plan => Icons.calendar_today_outlined,
    TaskQuadrant.keepQuick => Icons.bolt_outlined,
    TaskQuadrant.letGo => Icons.eco_outlined,
  };
}

class _Box extends StatelessWidget {
  final TaskQuadrant box;
  const _Box({required this.box});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tasks = AppScope.of(context).repo.tasksInBox(box);
    // A Material, so the task rows' ink shows on the tinted box.
    return Material(
      color: Color.alphaBlend(
        box.color.withValues(alpha: 0.08),
        theme.colorScheme.surface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: box.color.withValues(alpha: 0.25)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(box.icon, color: box.color, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(box.label, style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  tooltip: 'New task in ${box.label}',
                  icon: const Icon(Icons.add),
                  onPressed: () => editTask(
                    context,
                    important:
                        box == TaskQuadrant.doNow || box == TaskQuadrant.plan,
                    urgent:
                        box == TaskQuadrant.doNow ||
                        box == TaskQuadrant.keepQuick,
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                box.hint,
                style: TextStyle(color: theme.colorScheme.outline),
              ),
            ),
            const SizedBox(height: 4),
            if (tasks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Nothing here right now.',
                  style: TextStyle(
                    color: theme.colorScheme.outline.withValues(alpha: 0.7),
                  ),
                ),
              )
            else
              for (final t in tasks) TaskTile(task: t, dense: true),
          ],
        ),
      ),
    );
  }
}

/// A task with a circle to tick it off. Tapping the rest opens it to edit;
/// a long press or right-click marks it important or urgent, or deletes it.
class TaskTile extends StatelessWidget {
  final TaskItem task;
  final bool dense;
  const TaskTile({super.key, required this.task, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final theme = Theme.of(context);
    final due = dueLabel(task, repo.today);
    final overdue = (task.daysUntilDue(repo.today) ?? 0) < 0;
    return GestureDetector(
      onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
      onLongPressStart: (d) => _menu(context, d.globalPosition),
      child: ListTile(
        dense: dense,
        contentPadding: dense
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(horizontal: 8),
        leading: IconButton(
          tooltip: task.done
              ? 'Mark ${task.title} as not done'
              : 'Mark ${task.title} as done',
          icon: Icon(
            task.done ? Icons.check_circle : Icons.circle_outlined,
            color: task.done
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
          ),
          onPressed: () => repo.setTaskDone(task.id, !task.done),
        ),
        title: Text(
          task.title,
          style: task.done
              ? TextStyle(
                  decoration: TextDecoration.lineThrough,
                  color: theme.colorScheme.outline,
                )
              : null,
        ),
        subtitle: due == null && !task.important && !task.urgent
            ? null
            : Wrap(
                spacing: 6,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (due != null)
                    Text(
                      due,
                      style: TextStyle(
                        color: overdue
                            ? theme.colorScheme.error
                            : theme.colorScheme.outline,
                      ),
                    ),
                  if (task.important) const _Tag('Important', Colors.blue),
                  if (task.urgent) const _Tag('Urgent', Colors.orange),
                ],
              ),
        onTap: () => editTask(context, existing: task),
      ),
    );
  }

  Future<void> _menu(BuildContext context, Offset position) async {
    final repo = AppScope.read(context).repo;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: 'important',
          child: Text(task.important ? 'Not important' : 'Important'),
        ),
        PopupMenuItem(
          value: 'urgent',
          child: Text(task.urgent ? 'Not urgent' : 'Urgent'),
        ),
        const PopupMenuItem(value: 'edit', child: Text('Edit')),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
    if (!context.mounted) return;
    final due = task.due == null ? null : tryParseDateKey(task.due!);
    switch (choice) {
      case 'important' || 'urgent':
        repo.updateTask(
          task.id,
          title: task.title,
          due: due,
          important: choice == 'important' ? !task.important : task.important,
          urgent: choice == 'urgent' ? !task.urgent : task.urgent,
        );
      case 'edit':
        await editTask(context, existing: task);
      case 'delete':
        repo.deleteTask(task.id);
    }
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color color;
  const _Tag(this.text, this.color);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(text, style: TextStyle(color: color, fontSize: 12)),
  );
}

/// Adds a task, or edits [existing]. [important] and [urgent] set the marks
/// for a new one, as when it's added from a box of the matrix.
Future<void> editTask(
  BuildContext context, {
  TaskItem? existing,
  bool important = false,
  bool urgent = false,
}) => showDialog(
  context: context,
  builder: (_) =>
      _TaskDialog(existing: existing, important: important, urgent: urgent),
);

class _TaskDialog extends StatefulWidget {
  final TaskItem? existing;
  final bool important;
  final bool urgent;
  const _TaskDialog({
    this.existing,
    this.important = false,
    this.urgent = false,
  });

  @override
  State<_TaskDialog> createState() => _TaskDialogState();
}

class _TaskDialogState extends State<_TaskDialog> {
  late final _title = TextEditingController(text: widget.existing?.title);
  late DateTime? _due = widget.existing?.due == null
      ? null
      : tryParseDateKey(widget.existing!.due!);
  late bool _important = widget.existing?.important ?? widget.important;
  late bool _urgent = widget.existing?.urgent ?? widget.urgent;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _save() {
    final repo = AppScope.read(context).repo;
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final existing = widget.existing;
    if (existing == null) {
      repo.addTask(title, due: _due, important: _important, urgent: _urgent);
    } else {
      repo.updateTask(
        existing.id,
        title: title,
        due: _due,
        important: _important,
        urgent: _urgent,
      );
    }
    Navigator.pop(context);
  }

  Future<void> _pickDue() async {
    final today = AppScope.read(context).repo.today;
    final picked = await showDatePicker(
      context: context,
      initialDate: _due ?? today,
      firstDate: DateTime(today.year - 5),
      lastDate: DateTime(today.year + 10),
    );
    if (picked != null) setState(() => _due = picked);
  }

  Future<void> _delete() async {
    final existing = widget.existing!;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${existing.title}?'),
        content: const Text('This removes it from all your devices.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete task'),
          ),
        ],
      ),
    );
    if (sure == true && mounted) {
      AppScope.read(context).repo.deleteTask(existing.id);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final box = taskQuadrant(
      TaskItem.fromFields('', {'important': _important, 'urgent': _urgent}),
    );
    return AlertDialog(
      scrollable: true,
      title: Text(widget.existing == null ? 'New task' : 'Edit task'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _title,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Task',
                hintText: 'Renew the passport',
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Due date'),
              subtitle: _due == null ? null : Text(fullDate(_due!)),
              value: _due != null,
              onChanged: (on) {
                if (on) {
                  _pickDue();
                } else {
                  setState(() => _due = null);
                }
              },
            ),
            if (_due != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _pickDue,
                  child: const Text('Change date'),
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Important'),
              value: _important,
              onChanged: (v) => setState(() => _important = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Urgent'),
              value: _urgent,
              onChanged: (v) => setState(() => _urgent = v),
            ),
            Text(
              "Important means it matters to you. Urgent means it can't "
              'wait. Together they decide which box the task goes in on the '
              'matrix. This one goes in “${box.label}.”',
              style: TextStyle(color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.existing != null)
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            onPressed: _delete,
            child: const Text('Delete'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _title.text.trim().isEmpty ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
