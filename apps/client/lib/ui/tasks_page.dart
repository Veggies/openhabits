import 'package:core/core.dart';
import 'package:material_ui/material_ui.dart';

import '../data/repo.dart';
import 'common.dart';

/// The Tasks tab: one-off to-dos, listed as Today (with anything overdue),
/// Upcoming and Someday, or sorted into the four boxes of the Eisenhower
/// matrix. Matches the Apple app's TasksView.
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
      appBar: wide
          ? null
          : AppBar(
              title: picker,
              centerTitle: true,
              actions: [
                IconButton(
                  tooltip: 'New task',
                  icon: const Icon(Icons.add),
                  onPressed: () => editTask(context),
                ),
              ],
            ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (wide)
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: _matrix ? 1100 : 760),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
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
                      picker,
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('New task'),
                        onPressed: () => editTask(context),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(child: _matrix ? const _Matrix() : const _TaskList()),
        ],
      ),
    );
  }
}

/// Today, Upcoming and Someday, like a list in a reminders app: a row to
/// add a task straight away, and finished tasks out of sight until you ask.
class _TaskList extends StatefulWidget {
  const _TaskList();

  @override
  State<_TaskList> createState() => _TaskListState();
}

class _TaskListState extends State<_TaskList> {
  final _add = TextEditingController();
  final _addFocus = FocusNode();
  bool _showDone = false;

  @override
  void dispose() {
    _add.dispose();
    _addFocus.dispose();
    super.dispose();
  }

  void _submit(String text) {
    if (text.trim().isEmpty) return;
    AppScope.read(context).repo.addTask(text);
    _add.clear();
    _addFocus.requestFocus(); // ready for the next one
  }

  // Rebuilds on every data change; a const instance would otherwise never
  // refresh.
  @override
  Widget build(BuildContext context) =>
      DataBuilder(builder: (context, repo) => _build(context, repo));

  Widget _build(BuildContext context, Repo repo) {
    final theme = Theme.of(context);
    final done = repo.tasksIn(TaskGroup.done);
    return CenteredListView(
      maxWidth: 760,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 48),
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 48,
                  child: Icon(
                    Icons.add_circle,
                    color: theme.colorScheme.primary,
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _add,
                    focusNode: _addFocus,
                    decoration: const InputDecoration(
                      hintText: 'New task',
                      border: InputBorder.none,
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: _submit,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (repo.tasks.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Text(
              'Add anything you need to do once, like renewing your '
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
            TaskSection(
              title: group.label,
              tasks: tasks,
              inToday: group == TaskGroup.today,
            ),
        if (done.isNotEmpty) ...[
          const SizedBox(height: 16),
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_showDone)
                  for (final t in done) ...[
                    TaskTile(task: t),
                    const Divider(height: 1, indent: 56),
                  ],
                ListTile(
                  title: Text(
                    _showDone
                        ? 'Hide finished tasks'
                        : 'Show finished tasks (${done.length})',
                    style: TextStyle(color: theme.colorScheme.primary),
                  ),
                  onTap: () => setState(() => _showDone = !_showDone),
                ),
                if (_showDone)
                  ListTile(
                    title: Text(
                      'Delete finished tasks',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                    onTap: () async {
                      if (await _confirmClear(context, done.length)) {
                        for (final t in done) {
                          repo.deleteTask(t.id);
                        }
                      }
                    },
                  ),
              ],
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

  /// A list of today's tasks, so "Today" goes without saying on each one.
  final bool inToday;
  const TaskSection({
    super.key,
    required this.title,
    required this.tasks,
    this.inToday = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 16, 0, 6),
          child: Text(
            title.toUpperCase(),
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ),
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final (i, t) in tasks.indexed) ...[
                if (i > 0) const Divider(height: 1, indent: 56),
                TaskTile(task: t, inToday: inToday),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// The Eisenhower matrix as a 2×2 grid that fills the page: urgent on the
/// left, important on top, so "Do it now" is the top-left box.
class _Matrix extends StatelessWidget {
  const _Matrix();

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox.square(dimension: 10);
    Widget row(String label, TaskQuadrant a, TaskQuadrant b) => Expanded(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 20,
            child: Center(
              child: RotatedBox(quarterTurns: 3, child: _AxisLabel(label)),
            ),
          ),
          Expanded(child: _Box(box: a)),
          gap,
          Expanded(child: _Box(box: b)),
        ],
      ),
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 12, 12),
          child: DataBuilder(
            builder: (context, _) => Column(
              children: [
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      SizedBox(width: 20),
                      Expanded(child: Center(child: _AxisLabel('Urgent'))),
                      gap,
                      Expanded(child: Center(child: _AxisLabel('Not urgent'))),
                    ],
                  ),
                ),
                row('Important', TaskQuadrant.doNow, TaskQuadrant.plan),
                gap,
                row(
                  'Not important',
                  TaskQuadrant.keepQuick,
                  TaskQuadrant.letGo,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AxisLabel extends StatelessWidget {
  final String text;
  const _AxisLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text.toUpperCase(),
      maxLines: 1,
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.outline,
        letterSpacing: 0.6,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

extension TaskQuadrantLook on TaskQuadrant {
  Color get color => switch (this) {
    TaskQuadrant.doNow => Colors.red,
    TaskQuadrant.plan => Colors.blue,
    TaskQuadrant.keepQuick => Colors.orange,
    TaskQuadrant.letGo => Colors.grey,
  };

  IconData get icon => switch (this) {
    TaskQuadrant.doNow => Icons.local_fire_department,
    TaskQuadrant.plan => Icons.calendar_today,
    TaskQuadrant.keepQuick => Icons.bolt,
    TaskQuadrant.letGo => Icons.eco,
  };
}

class _Box extends StatelessWidget {
  final TaskQuadrant box;
  const _Box({required this.box});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tasks = AppScope.of(context).repo.tasksInBox(box);
    final color = box.color;
    // A Material, so the task rows' ink shows on the tinted box.
    return Material(
      color: Color.alphaBlend(
        color.withValues(alpha: 0.08),
        theme.colorScheme.surface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: color.withValues(alpha: 0.2)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 0, 0),
            child: Row(
              children: [
                Icon(box.icon, color: color, size: 18),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    box.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (tasks.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(
                    '${tasks.length}',
                    style: TextStyle(color: color.withValues(alpha: 0.7)),
                  ),
                ],
                const Spacer(),
                IconButton(
                  tooltip: 'New task in ${box.label}',
                  color: color,
                  icon: const Icon(Icons.add, size: 20),
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
          ),
          Expanded(
            child: tasks.isEmpty
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Text(
                      box.hint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 8),
                    children: [
                      for (final t in tasks) TaskTile(task: t, dense: true),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// "Overdue", "Today", "Tomorrow", or the date ("Fri, Dec 4"), and whether
/// it's overdue. Null if the task has no date or is done, or (with
/// [hidingToday]) if it's due today, where that goes without saying.
({String text, bool overdue})? dueText(
  TaskItem t,
  DateTime today, {
  bool hidingToday = false,
}) {
  final days = t.daysUntilDue(today);
  if (t.done || days == null) return null;
  if (days == 0 && hidingToday) return null;
  final label = dueLabel(t, today);
  if (label != null) return (text: label, overdue: days < 0);
  final d = tryParseDateKey(t.due!)!;
  return (text: '${weekdayShort(d.weekday)}, ${shortDate(d)}', overdue: false);
}

/// A task with a circle to tick it off, colored by its box in the matrix
/// so you can tell what matters at a glance. Tapping the rest opens it to
/// edit; a long press or right-click marks it important or urgent, or
/// deletes it.
class TaskTile extends StatelessWidget {
  final TaskItem task;
  final bool dense;
  final bool inToday;
  const TaskTile({
    super.key,
    required this.task,
    this.dense = false,
    this.inToday = false,
  });

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final theme = Theme.of(context);
    final due = dueText(task, repo.today, hidingToday: inToday);
    return GestureDetector(
      onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
      onLongPressStart: (d) => _menu(context, d.globalPosition),
      child: ListTile(
        dense: dense,
        visualDensity: dense ? VisualDensity.compact : null,
        contentPadding: EdgeInsets.only(left: dense ? 0 : 4, right: 12),
        horizontalTitleGap: dense ? 0 : 4,
        leading: IconButton(
          tooltip: task.done
              ? 'Mark ${task.title} as not done'
              : 'Mark ${task.title} as done',
          iconSize: dense ? 20 : 24,
          icon: Icon(
            task.done ? Icons.check_circle : Icons.circle_outlined,
            color: task.done
                ? theme.colorScheme.outline
                : taskQuadrant(task).color,
          ),
          onPressed: () => repo.setTaskDone(task.id, !task.done),
        ),
        title: Text(
          task.title,
          maxLines: dense ? 2 : null,
          overflow: dense ? TextOverflow.ellipsis : null,
          style: task.done
              ? TextStyle(
                  decoration: TextDecoration.lineThrough,
                  color: theme.colorScheme.outline,
                )
              : null,
        ),
        subtitle: due == null
            ? null
            : Text(
                due.text,
                style: TextStyle(
                  color: due.overdue
                      ? theme.colorScheme.error
                      : theme.colorScheme.outline,
                ),
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
        CheckedPopupMenuItem(
          value: 'important',
          checked: task.important,
          child: const Text('Important'),
        ),
        CheckedPopupMenuItem(
          value: 'urgent',
          checked: task.urgent,
          child: const Text('Urgent'),
        ),
        const PopupMenuDivider(),
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
