import 'package:core/core.dart';
import 'package:material_ui/material_ui.dart';

import '../data/repo.dart';
import 'common.dart';
import 'task_detail.dart';

class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  TaskFilter filter = const SmartFilter(SmartList.today);
  String? selectedId;

  void _select(TaskFilter f) => setState(() {
    filter = f;
    selectedId = null;
  });

  void _open(BuildContext context, String id) {
    if (isWide(context)) {
      setState(() => selectedId = id);
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

  @override
  Widget build(BuildContext context) {
    return DataBuilder(
      builder: (context, repo) {
        final title = filterTitle(repo, filter);
        final sidebar = _Sidebar(
          selected: filter,
          onSelect: (f) {
            _select(f);
            if (!isWide(context)) Navigator.of(context).maybePop();
          },
        );
        final list = _TaskListView(
          filter: filter,
          selectedId: selectedId,
          onOpen: (id) => _open(context, id),
        );

        if (!isWide(context)) {
          return Scaffold(
            appBar: AppBar(title: Text(title)),
            drawer: Drawer(child: SafeArea(child: sidebar)),
            body: list,
          );
        }
        return Scaffold(
          body: Row(
            children: [
              SizedBox(width: 240, child: sidebar),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    Expanded(child: list),
                  ],
                ),
              ),
              if (selectedId != null && repo.task(selectedId!) != null) ...[
                const VerticalDivider(width: 1),
                SizedBox(
                  width: 380,
                  child: TaskDetail(
                    key: ValueKey(selectedId),
                    taskId: selectedId!,
                    onClose: () => setState(() => selectedId = null),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

String filterTitle(Repo repo, TaskFilter f) => switch (f) {
  SmartFilter(list: SmartList.inbox) => 'Inbox',
  SmartFilter(list: SmartList.today) => 'Today',
  SmartFilter(list: SmartList.next7) => 'Next 7 Days',
  SmartFilter(list: SmartList.all) => 'All',
  SmartFilter(list: SmartList.completed) => 'Completed',
  SmartFilter(list: SmartList.trash) => 'Trash',
  ListFilter(:final listId) => repo.list(listId)?.name ?? 'List',
  TagFilter(:final tag) => '#$tag',
};

class _Sidebar extends StatelessWidget {
  final TaskFilter selected;
  final ValueChanged<TaskFilter> onSelect;
  const _Sidebar({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final theme = Theme.of(context);

    Widget item(
      TaskFilter f,
      IconData icon,
      String label, {
      Widget? leading,
      int? count,
      VoidCallback? onLongPress,
    }) {
      return ListTile(
        dense: true,
        selected: f == selected,
        selectedTileColor: theme.colorScheme.secondaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        leading: leading ?? Icon(icon, size: 20),
        title: Text(label, overflow: TextOverflow.ellipsis),
        trailing: count == null || count == 0
            ? null
            : Text('$count', style: theme.textTheme.bodySmall),
        onTap: () => onSelect(f),
        onLongPress: onLongPress,
      );
    }

    int count(TaskFilter f) => repo.tasksFor(f).length;

    Widget header(String text, {Widget? action}) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          ?action,
        ],
      ),
    );

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      children: [
        item(
          const SmartFilter(SmartList.today),
          Icons.today_outlined,
          'Today',
          count: count(const SmartFilter(SmartList.today)),
        ),
        item(
          const SmartFilter(SmartList.next7),
          Icons.date_range_outlined,
          'Next 7 Days',
          count: count(const SmartFilter(SmartList.next7)),
        ),
        item(
          const SmartFilter(SmartList.inbox),
          Icons.inbox_outlined,
          'Inbox',
          count: count(const SmartFilter(SmartList.inbox)),
        ),
        item(const SmartFilter(SmartList.all), Icons.all_inbox_outlined, 'All'),
        header(
          'LISTS',
          action: IconButton(
            tooltip: 'New list',
            icon: const Icon(Icons.add, size: 18),
            onPressed: () => _editList(context, null),
          ),
        ),
        for (final l in repo.lists)
          item(
            ListFilter(l.id),
            Icons.list,
            l.name,
            leading: Padding(
              padding: const EdgeInsets.all(5),
              child: ColorDot(l.color),
            ),
            count: count(ListFilter(l.id)),
            onLongPress: () => _editList(context, l),
          ),
        if (repo.tags.isNotEmpty) header('TAGS'),
        for (final t in repo.tags) item(TagFilter(t), Icons.tag, t),
        const Divider(),
        item(
          const SmartFilter(SmartList.completed),
          Icons.check_circle_outline,
          'Completed',
        ),
        item(const SmartFilter(SmartList.trash), Icons.delete_outline, 'Trash'),
      ],
    );
  }

  Future<void> _editList(BuildContext context, TaskList? existing) async {
    final repo = AppScope.of(context).repo;
    final controller = TextEditingController(text: existing?.name ?? '');
    var color = existing?.color ?? listColors.first;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(existing == null ? 'New list' : 'Edit list'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
                onSubmitted: (_) => Navigator.pop(context, 'save'),
              ),
              const SizedBox(height: 16),
              ColorPicker(
                selected: color,
                onChanged: (c) => setState(() => color = c),
              ),
            ],
          ),
          actions: [
            if (existing != null)
              TextButton(
                onPressed: () => Navigator.pop(context, 'delete'),
                child: const Text('Delete'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'save'),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    final name = controller.text.trim();
    if (result == 'delete' && existing != null) {
      repo.deleteList(existing.id);
      if (selected == ListFilter(existing.id)) {
        onSelect(const SmartFilter(SmartList.inbox));
      }
    } else if (result == 'save' && name.isNotEmpty) {
      if (existing == null) {
        onSelect(ListFilter(repo.createList(name, color)));
      } else {
        repo.updateList(existing.id, {'name': name, 'color': color});
      }
    }
  }
}

class _TaskListView extends StatelessWidget {
  final TaskFilter filter;
  final String? selectedId;
  final ValueChanged<String> onOpen;
  const _TaskListView({
    required this.filter,
    required this.selectedId,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final tasks = repo.tasksFor(filter);
    final readOnly =
        filter == const SmartFilter(SmartList.trash) ||
        filter == const SmartFilter(SmartList.completed);
    final now = repo.clock();

    // Group dated views into Overdue / day sections, like TickTick.
    final grouped =
        filter == const SmartFilter(SmartList.next7) ||
        filter == const SmartFilter(SmartList.today);
    final children = <Widget>[];
    String? lastGroup;
    for (final t in tasks) {
      if (grouped) {
        final group = t.isOverdue(now) && t.dueDate!.isBefore(dateOnly(now))
            ? 'Overdue'
            : relativeDate(t.dueDate!, now);
        if (group != lastGroup) {
          children.add(_SectionHeader(group, warning: group == 'Overdue'));
          lastGroup = group;
        }
      }
      children.add(
        TaskTile(
          task: t,
          selected: t.id == selectedId,
          onTap: () => onOpen(t.id),
        ),
      );
    }

    return Column(
      children: [
        if (!readOnly) QuickAddField(filter: filter),
        Expanded(
          child: tasks.isEmpty
              ? _EmptyState(filter: filter)
              : ListView(
                  padding: const EdgeInsets.only(bottom: 80),
                  children: children,
                ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  final bool warning;
  const _SectionHeader(this.text, {this.warning = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: warning ? theme.colorScheme.error : theme.colorScheme.outline,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final TaskFilter filter;
  const _EmptyState({required this.filter});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = switch (filter) {
      SmartFilter(list: SmartList.trash) => 'Trash is empty',
      SmartFilter(list: SmartList.completed) => 'No completed tasks yet',
      SmartFilter(list: SmartList.today) => 'Nothing due today',
      _ => 'No tasks',
    };
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 56,
            color: theme.colorScheme.outlineVariant,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

/// The add-task field. Understands dates, times, repeats, #tags, !priority
/// and ^list, and previews what it parsed as you type.
class QuickAddField extends StatefulWidget {
  final TaskFilter? filter;
  final DateTime? defaultDate;
  final VoidCallback? onAdded;
  const QuickAddField({super.key, this.filter, this.defaultDate, this.onAdded});

  @override
  State<QuickAddField> createState() => _QuickAddFieldState();
}

class _QuickAddFieldState extends State<QuickAddField> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final repo = AppScope.of(context).repo;
    final id = repo.quickAdd(
      _controller.text,
      context: widget.filter,
      defaultDate: widget.defaultDate,
    );
    if (id != null) {
      _controller.clear();
      widget.onAdded?.call();
    }
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            focusNode: _focus,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.add),
              hintText: 'Add task, e.g. "Call mom tomorrow 5pm #family !high"',
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.5,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              isDense: true,
            ),
          ),
          if (_controller.text.trim().isNotEmpty)
            _Preview(parseQuickAdd(_controller.text, DateTime.now())),
        ],
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  final QuickAdd q;
  const _Preview(this.q);

  @override
  Widget build(BuildContext context) {
    final chips = <String>[
      if (q.dueDate != null) relativeDate(q.dueDate!, DateTime.now()),
      if (q.dueTime != null) timeLabel(context, q.dueTime!),
      if (q.repeat != null) q.repeat!.describe(),
      if (q.priority != null) '${priorityLabel(q.priority!)} priority',
      if (q.listName != null) 'List: ${q.listName}',
      for (final t in q.tags) '#$t',
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final c in chips)
            Chip(
              label: Text(c),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
        ],
      ),
    );
  }
}

class TaskTile extends StatelessWidget {
  final Task task;
  final bool selected;
  final VoidCallback onTap;
  const TaskTile({
    super.key,
    required this.task,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final repo = scope.repo;
    final theme = Theme.of(context);
    final now = repo.clock();
    final subtasks = repo.subtasks(task.id);
    final list = repo.list(task.listId);
    final meta = <Widget>[];
    final small = theme.textTheme.bodySmall!;

    if (task.dueDate != null) {
      meta.add(
        Text(
          dueLabel(context, task, now),
          style: small.copyWith(
            color: task.isOverdue(now)
                ? theme.colorScheme.error
                : theme.colorScheme.primary,
          ),
        ),
      );
    }
    if (task.repeat != null) {
      meta.add(Icon(Icons.repeat, size: 14, color: theme.colorScheme.outline));
    }
    if (subtasks.isNotEmpty) {
      meta.add(
        Text(
          '${subtasks.where((s) => s.done).length}/${subtasks.length}',
          style: small,
        ),
      );
    }
    if (task.notes.isNotEmpty) {
      meta.add(Icon(Icons.notes, size: 14, color: theme.colorScheme.outline));
    }
    for (final t in task.tags) {
      meta.add(
        Text('#$t', style: small.copyWith(color: theme.colorScheme.tertiary)),
      );
    }
    if (list != null) {
      meta.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ColorDot(list.color, size: 7),
            const SizedBox(width: 4),
            Text(list.name, style: small),
          ],
        ),
      );
    }

    return Material(
      color: selected
          ? theme.colorScheme.secondaryContainer.withValues(alpha: 0.6)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              if (task.deleted)
                IconButton(
                  tooltip: 'Restore',
                  icon: const Icon(Icons.restore_from_trash),
                  onPressed: () => repo.restoreTask(task.id),
                )
              else
                TaskCheckbox(task: task),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title.isEmpty ? 'Untitled' : task.title,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          decoration: task.done
                              ? TextDecoration.lineThrough
                              : null,
                          color: task.done ? theme.colorScheme.outline : null,
                        ),
                      ),
                      if (meta.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Wrap(
                            spacing: 10,
                            runSpacing: 2,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: meta,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A checkbox tinted by priority. Completing a repeating task shows where
/// it moved to.
class TaskCheckbox extends StatelessWidget {
  final Task task;
  const TaskCheckbox({super.key, required this.task});

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final color = priorityColor(task.priority, Theme.of(context).colorScheme);
    return Checkbox(
      value: task.done,
      activeColor: color,
      side: BorderSide(color: color, width: 2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      onChanged: (_) {
        if (task.done) {
          repo.uncomplete(task);
          return;
        }
        final next = repo.complete(task);
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            // Snack bars with an action stay up until dismissed by default;
            // this one should fade on its own like any other.
            persist: false,
            duration: const Duration(seconds: 4),
            content: Text(
              next == null
                  ? 'Completed "${task.title}"'
                  : 'Next: ${relativeDate(next, DateTime.now())}',
            ),
            action: next == null
                ? SnackBarAction(
                    label: 'Undo',
                    onPressed: () => repo.uncomplete(task),
                  )
                : null,
          ),
        );
      },
    );
  }
}
