import 'package:core/core.dart';

import 'local_store.dart';

/// Built-in task views.
enum SmartList { inbox, today, next7, all, completed, trash }

/// What the task list is currently showing.
sealed class TaskFilter {
  const TaskFilter();
}

class SmartFilter extends TaskFilter {
  final SmartList list;
  const SmartFilter(this.list);

  @override
  bool operator ==(Object other) => other is SmartFilter && other.list == list;

  @override
  int get hashCode => list.hashCode;
}

class ListFilter extends TaskFilter {
  final String listId;
  const ListFilter(this.listId);

  @override
  bool operator ==(Object other) =>
      other is ListFilter && other.listId == listId;

  @override
  int get hashCode => listId.hashCode;
}

class TagFilter extends TaskFilter {
  final String tag;
  const TagFilter(this.tag);

  @override
  bool operator ==(Object other) => other is TagFilter && other.tag == tag;

  @override
  int get hashCode => tag.hashCode;
}

/// Typed reads and writes over the [LocalStore].
/// What a size check-in offers: [grow] asks whether a habit that's sticking
/// feels too easy (and could be a little bigger); [shrink] offers to make a
/// habit that's often missed a little smaller for a while.
enum SizeSuggestion { grow, shrink }

class Repo {
  final LocalStore store;
  final DateTime Function() clock;

  Repo(this.store, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;

  // ---- Lists ----

  List<TaskList> get lists =>
      [
        for (final MapEntry(:key, :value) in store.table(Tables.lists).entries)
          TaskList.fromFields(key, value),
      ].where((l) => !l.deleted).toList()..sort(
        (a, b) => a.order.compareTo(b.order),
      );

  TaskList? list(String? id) => id == null
      ? null
      : switch (store.row(Tables.lists, id)) {
          final f? when f[deletedField] != true => TaskList.fromFields(id, f),
          _ => null,
        };

  String createList(String name, int color) {
    final id = store.newId();
    store.write(Tables.lists, id, {
      'name': name,
      'color': color,
      'order': clock().millisecondsSinceEpoch.toDouble(),
    });
    return id;
  }

  void updateList(String id, Fields fields) =>
      store.write(Tables.lists, id, fields);

  /// Deletes a list; its tasks move to the Inbox.
  void deleteList(String id) {
    for (final t in allTasks.where((t) => t.listId == id)) {
      store.write(Tables.tasks, t.id, {'listId': null});
    }
    store.write(Tables.lists, id, {deletedField: true});
  }

  // ---- Tasks ----

  Iterable<Task> get allTasks => [
    for (final MapEntry(:key, :value) in store.table(Tables.tasks).entries)
      Task.fromFields(key, value),
  ];

  Task? task(String id) => switch (store.row(Tables.tasks, id)) {
    final f? => Task.fromFields(id, f),
    null => null,
  };

  List<String> get tags {
    final all = <String>{
      for (final t in allTasks)
        if (!t.deleted) ...t.tags,
    };
    return all.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  List<Task> subtasks(String parentId) =>
      allTasks.where((t) => t.parentId == parentId && !t.deleted).toList()
        ..sort((a, b) => a.order.compareTo(b.order));

  /// Top-level tasks for [filter], sorted for display.
  List<Task> tasksFor(TaskFilter filter) {
    final today = dateOnly(clock());
    final live = allTasks.where((t) => !t.deleted && t.parentId == null);
    final validLists = {for (final l in lists) l.id};
    bool inInbox(Task t) => t.listId == null || !validLists.contains(t.listId);

    final Iterable<Task> result = switch (filter) {
      SmartFilter(list: SmartList.inbox) => live.where(
        (t) => !t.done && inInbox(t),
      ),
      SmartFilter(list: SmartList.today) => live.where(
        (t) => !t.done && t.dueDate != null && !t.dueDate!.isAfter(today),
      ),
      SmartFilter(list: SmartList.next7) => live.where(
        (t) =>
            !t.done &&
            t.dueDate != null &&
            t.dueDate!.isBefore(addDays(today, 7)),
      ),
      SmartFilter(list: SmartList.all) => live.where((t) => !t.done),
      SmartFilter(list: SmartList.completed) => live.where((t) => t.done),
      SmartFilter(list: SmartList.trash) => allTasks.where(
        (t) => t.deleted && t.parentId == null,
      ),
      ListFilter(:final listId) => live.where(
        (t) => !t.done && t.listId == listId,
      ),
      TagFilter(:final tag) => live.where(
        (t) => !t.done && t.tags.contains(tag),
      ),
    };

    final list = result.toList();
    if (filter == const SmartFilter(SmartList.completed)) {
      list.sort(
        (a, b) => (b.completedAt ?? b.createdAt).compareTo(
          a.completedAt ?? a.createdAt,
        ),
      );
    } else {
      list.sort(compareTasks);
    }
    return list;
  }

  /// Dated tasks first by due time, then by priority, then newest first.
  static int compareTasks(Task a, Task b) {
    final ad = a.dueAt, bd = b.dueAt;
    if (ad != null && bd != null && ad != bd) return ad.compareTo(bd);
    if (ad != null && bd == null) return -1;
    if (ad == null && bd != null) return 1;
    if (a.priority != b.priority) {
      return b.priority.index.compareTo(a.priority.index);
    }
    return b.createdAt.compareTo(a.createdAt);
  }

  /// Tasks due on [day] (not deleted), for the calendar.
  List<Task> tasksOn(DateTime day) {
    final d = dateOnly(day);
    return allTasks.where((t) => !t.deleted && t.dueDate == d).toList()
      ..sort(compareTasks);
  }

  /// Creates a task from quick-add text, defaulting to [defaults] for
  /// anything the text doesn't specify. Returns the new id, or null if the
  /// title is empty.
  String? quickAdd(String text, {TaskFilter? context, DateTime? defaultDate}) {
    final parsed = parseQuickAdd(text, clock());
    if (parsed.title.trim().isEmpty) return null;
    String? listId;
    if (parsed.listName != null) {
      final name = parsed.listName!.toLowerCase();
      listId = lists.where((l) => l.name.toLowerCase() == name).firstOrNull?.id;
      listId ??= createList(parsed.listName!, 0xFF4772FA);
    } else if (context is ListFilter) {
      listId = context.listId;
    }
    var dueDate = parsed.dueDate ?? defaultDate;
    if (dueDate == null &&
        (context == const SmartFilter(SmartList.today) ||
            context == const SmartFilter(SmartList.next7))) {
      dueDate = dateOnly(clock());
    }
    return createTask(
      title: parsed.title,
      listId: listId,
      dueDate: dueDate,
      dueTime: parsed.dueTime,
      priority: parsed.priority ?? Priority.none,
      tags: {...parsed.tags, if (context is TagFilter) context.tag}.toList(),
      repeat: parsed.repeat,
    );
  }

  String createTask({
    required String title,
    String? listId,
    String? parentId,
    DateTime? dueDate,
    String? dueTime,
    Priority priority = Priority.none,
    List<String> tags = const [],
    RepeatRule? repeat,
  }) {
    final id = store.newId();
    final now = clock();
    store.write(Tables.tasks, id, {
      'title': title,
      'listId': listId,
      'parentId': ?parentId,
      'dueDate': dueDate == null ? null : dateKey(dueDate),
      'dueTime': dueTime,
      'priority': priority.index,
      'tags': tags,
      'repeat': repeat?.encode(),
      'done': false,
      'order': now.millisecondsSinceEpoch.toDouble(),
      'createdAt': now.toUtc().toIso8601String(),
    });
    return id;
  }

  void updateTask(String id, Fields fields) =>
      store.write(Tables.tasks, id, fields);

  /// Completes a task. A repeating task moves to its next occurrence instead
  /// and its subtasks reset. Returns the next due date for repeating tasks.
  DateTime? complete(Task task) {
    final now = clock();
    final repeat = task.repeat;
    if (repeat != null && task.dueDate != null) {
      final next = repeat.next(task.dueDate!);
      store.write(Tables.tasks, task.id, {
        'dueDate': dateKey(next),
        'lastCompletedAt': now.toUtc().toIso8601String(),
      });
      for (final s in subtasks(task.id).where((s) => s.done)) {
        store.write(Tables.tasks, s.id, {'done': false, 'completedAt': null});
      }
      return next;
    }
    store.write(Tables.tasks, task.id, {
      'done': true,
      'completedAt': now.toUtc().toIso8601String(),
    });
    return null;
  }

  void uncomplete(Task task) =>
      store.write(Tables.tasks, task.id, {'done': false, 'completedAt': null});

  void toggle(Task task) => task.done ? uncomplete(task) : complete(task);

  void deleteTask(String id) =>
      store.write(Tables.tasks, id, {deletedField: true});

  void restoreTask(String id) =>
      store.write(Tables.tasks, id, {deletedField: false});

  // ---- Habits ----

  List<Habit> get habits =>
      [
        for (final MapEntry(:key, :value) in store.table(Tables.habits).entries)
          Habit.fromFields(key, value),
      ].where((h) => !h.deleted && !h.archived).toList()..sort(
        (a, b) => a.order.compareTo(b.order),
      );

  /// Creates a habit from [fields] (name, color, icon, kind, weekdays and any
  /// Atomic Habits plan fields).
  String createHabit(Fields fields) {
    final id = store.newId();
    final now = clock();
    store.write(Tables.habits, id, {
      ...fields,
      'order': now.millisecondsSinceEpoch.toDouble(),
      'createdAt': now.toUtc().toIso8601String(),
    });
    return id;
  }

  /// Habits to show on the calendar on [day]: ones with a time that are
  /// scheduled that day, from the day they were created.
  List<Habit> timedHabitsOn(DateTime day) {
    final d = dateOnly(day);
    return [
      for (final h in habits)
        if (!h.isQuit &&
            h.plan.time.isNotEmpty &&
            h.isScheduled(d) &&
            !dateOnly(h.createdAt.toLocal()).isAfter(d))
          h,
    ]..sort((a, b) => a.plan.time.compareTo(b.plan.time));
  }

  Habit? habit(String id) => switch (store.row(Tables.habits, id)) {
    final f? => Habit.fromFields(id, f),
    null => null,
  };

  // ---- Preferences ----

  Prefs get prefs => Prefs.fromFields(store.row(Tables.prefs, Prefs.rowId));

  void setPrefs(Fields fields) =>
      store.write(Tables.prefs, Prefs.rowId, fields);

  bool get atomicHabits => prefs.atomicHabits ?? false;

  /// First day of the week for calendars and habit grids.
  int get weekStart => prefs.weekStart;

  // ---- Atomic Habits: scorecard and weekly review ----

  List<ScorecardItem> get scorecard =>
      [
          for (final MapEntry(:key, :value)
              in store.table(Tables.scorecard).entries)
            ScorecardItem.fromFields(key, value),
        ].where((s) => !s.deleted).toList()
        ..sort((a, b) => a.order.compareTo(b.order));

  void addScorecardItem(String text) =>
      store.write(Tables.scorecard, store.newId(), {
        'text': text,
        'rating': '=',
        'order': clock().millisecondsSinceEpoch.toDouble(),
      });

  void updateScorecardItem(String id, Fields fields) =>
      store.write(Tables.scorecard, id, fields);

  void deleteScorecardItem(String id) =>
      store.write(Tables.scorecard, id, {deletedField: true});

  /// The review for the week containing [day].
  WeeklyReview review(DateTime day) {
    final id = dateKey(startOfWeek(day, weekStart));
    return WeeklyReview.fromFields(
      id,
      store.row(Tables.reviews, id) ?? const {},
    );
  }

  void saveReview(DateTime day, String prompt, String answer) => store.write(
    Tables.reviews,
    dateKey(startOfWeek(day, weekStart)),
    {prompt: answer},
  );

  /// Last week's review, if it hasn't been written yet: prompts the review
  /// banner from the start of the new week.
  bool get lastWeekReviewDue {
    if (!atomicHabits || habits.isEmpty) return false;
    final thisWeek = startOfWeek(clock(), weekStart);
    final hadHabitsLastWeek = habits.any(
      (h) => h.createdAt.toLocal().isBefore(thisWeek),
    );
    return hadHabitsLastWeek && review(addDays(thisWeek, -7)).answers.isEmpty;
  }

  void updateHabit(String id, Fields fields) =>
      store.write(Tables.habits, id, fields);

  void deleteHabit(String id) =>
      store.write(Tables.habits, id, {deletedField: true});

  bool isHabitDone(String habitId, DateTime day) =>
      store.row(Tables.habitChecks, Habit.checkId(habitId, day))?['done'] ==
      true;

  /// Checks a habit in for [day]. For a habit being broken, a check-in
  /// means "I stayed clear today".
  void setHabitDone(String habitId, DateTime day, bool done) => store.write(
    Tables.habitChecks,
    Habit.checkId(habitId, day),
    {'habitId': habitId, 'date': dateKey(day), 'done': done},
  );

  /// For build habits: scheduled days done in a row. With the Atomic Habits
  /// framework on, a single miss is forgiven ("never miss twice").
  int streak(Habit habit) => habit.streak(
    (d) => isHabitDone(habit.id, d),
    clock(),
    forgiving: atomicHabits,
  );

  /// The Goldilocks rule: keep each habit at a size that's a little
  /// challenging but still easy to keep doing. Consistency can't tell how
  /// hard a habit feels, so: done on most scheduled days (80%) over two
  /// weeks means it's sticking, and the person is *asked* whether it's
  /// starting to feel too easy ([SizeSuggestion.grow]); done on under half
  /// suggests making it smaller. Otherwise, or if the person said the size
  /// feels right, nothing is suggested.
  SizeSuggestion? sizeSuggestion(Habit habit) {
    final plan = habit.plan;
    if (!atomicHabits || habit.isQuit || plan.twoMinute.isEmpty) return null;
    if (plan.sizeSettled) return null;
    final today = dateOnly(clock());
    final since = plan.steppedUpAt.isNotEmpty
        ? parseDateKey(plan.steppedUpAt)
        : dateOnly(habit.createdAt.toLocal());
    if (daysBetween(since, today) < 14) return null;
    final (:done, :scheduled) = record(habit, today, 14);
    if (scheduled == 0) return null;
    if (done >= growDaysNeeded(scheduled)) return SizeSuggestion.grow;
    if (done * 2 < scheduled) return SizeSuggestion.shrink;
    return null;
  }

  /// How many of [scheduled] days need doing before growing is suggested:
  /// 80%, rounded up (12 of 14, 8 of 10, 5 of 6). Whole-number maths, so
  /// 80% of 10 is exactly 8.
  static int growDaysNeeded(int scheduled) => (scheduled * 4 + 4) ~/ 5;

  /// Makes [next] the habit's current version, remembering the old one.
  void resize(Habit habit, String next) =>
      updateHabit(habit.id, resizeFields(habit, next));

  /// The fields that change [habit]'s version to [next] (and start a new
  /// two-week check-in period). Nothing changes if [next] is the same.
  Fields resizeFields(Habit habit, String next) {
    final plan = habit.plan;
    next = next.trim();
    if (next.isEmpty || next == plan.twoMinute) return const {};
    final today = dateKey(clock());
    return {
      'twoMinute': next,
      'steppedUpAt': today,
      'sizeHistory': [
        // The first change also records where it started.
        if (plan.sizeHistory.isEmpty && plan.twoMinute.isNotEmpty)
          {'text': plan.twoMinute, 'since': dateKey(habit.createdAt.toLocal())},
        for (final v in plan.sizeHistory) {'text': v.text, 'since': v.since},
        {'text': next, 'since': today},
      ],
    };
  }

  /// "Keep it as it is": check in again in two weeks.
  void keepSize(Habit habit) =>
      updateHabit(habit.id, {'steppedUpAt': dateKey(clock())});

  /// "This feels right, stop asking" (or, with [settled] false, start
  /// checking in again from today).
  void settleSize(Habit habit, {bool settled = true}) => updateHabit(habit.id, {
    'sizeSettled': settled,
    'steppedUpAt': dateKey(clock()),
  });

  /// For the Progress grid: the days [habit] was done, out of the days it
  /// was due, in the week starting [weekStart]. Only counts days from when
  /// the habit was created up to today, so this week means "so far".
  ({int done, int scheduled}) weekRecord(Habit habit, DateTime weekStart) {
    final today = dateOnly(clock());
    final weekEnd = addDays(dateOnly(weekStart), 6);
    final end = weekEnd.isAfter(today) ? today : weekEnd;
    if (end.isBefore(weekStart)) return (done: 0, scheduled: 0);
    return record(habit, end, daysBetween(weekStart, end) + 1);
  }

  /// Total check-ins: each one is a vote for the habit's identity.
  int votes(String habitId) => store
      .table(Tables.habitChecks)
      .values
      .where((c) => c['habitId'] == habitId && c['done'] == true)
      .length;

  bool missedLastTime(Habit habit) =>
      habit.missedLastTime((d) => isHabitDone(habit.id, d), clock());

  /// For quit habits, a check-in records a slip.
  int daysClean(Habit habit) =>
      habit.daysClean((d) => isHabitDone(habit.id, d), clock());

  /// Fraction of scheduled days done in the [days] before and including
  /// [end], counting only days since the habit started.
  double completionRate(Habit habit, DateTime end, int days) {
    final (:done, :scheduled) = record(habit, end, days);
    return scheduled == 0 ? 0 : done / scheduled;
  }

  /// Scheduled days done, out of scheduled days, in the [days] before and
  /// including [end] (only counting days since the habit started).
  ({int done, int scheduled}) record(Habit habit, DateTime end, int days) {
    var scheduled = 0;
    var done = 0;
    final start = dateOnly(habit.createdAt.toLocal());
    for (var i = 0; i < days; i++) {
      final day = addDays(dateOnly(end), -i);
      if (day.isBefore(start) || !habit.isScheduled(day)) continue;
      scheduled++;
      final hit = isHabitDone(habit.id, day);
      if (hit) done++;
    }
    return (done: done, scheduled: scheduled);
  }

  // ---- Focus ----

  List<FocusSession> get focusSessions =>
      [
          for (final MapEntry(:key, :value)
              in store.table(Tables.focusSessions).entries)
            FocusSession.fromFields(key, value),
        ].where((s) => !s.deleted).toList()
        ..sort((a, b) => b.start.compareTo(a.start));

  void recordFocus({
    required DateTime start,
    required int minutes,
    String? taskId,
  }) => store.write(Tables.focusSessions, store.newId(), {
    'start': start.toUtc().toIso8601String(),
    'minutes': minutes,
    'taskId': taskId,
  });

  // ---- External calendar events ----

  List<CalendarEvent> eventsOn(DateTime day) =>
      [
        for (final MapEntry(:key, :value) in store.table(Tables.events).entries)
          CalendarEvent.fromFields(key, value),
      ].where((e) => !e.deleted && e.occursOn(day)).toList()..sort(
        (a, b) => a.start.compareTo(b.start),
      );
}
