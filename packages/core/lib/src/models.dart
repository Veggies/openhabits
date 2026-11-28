import 'change.dart';
import 'dates.dart';

/// Table names shared by the client and server.
abstract final class Tables {
  static const habits = 'habits';
  static const habitChecks = 'habit_checks';
  static const focusSessions = 'focus_sessions';
  static const scorecard = 'scorecard';
  static const reviews = 'reviews';

  /// Things you enjoy, each with a price in tomatoes ([Reward]).
  static const rewards = 'rewards';

  /// Tomatoes spent on a reward ([RewardSpend]).
  static const rewardSpends = 'reward_spends';

  /// One-off to-dos ([TaskItem]).
  static const tasks = 'tasks';

  /// Per-person preferences that follow you to every device. One row,
  /// [Prefs.rowId].
  static const prefs = 'prefs';
}

/// Row data as stored: field name to JSON value, including [deletedField].
typedef Fields = Map<String, Object?>;

class Prefs {
  static const rowId = 'me';

  /// [DateTime.sunday] or [DateTime.monday].
  final int weekStart;

  /// How many pomodoros (focus sessions) to aim for each day.
  final int focusGoal;

  Prefs.fromFields(Fields? f)
    : weekStart = f?['weekStart'] as int? ?? DateTime.sunday,
      focusGoal = f?['focusGoal'] as int? ?? 4;
}

bool _deleted(Fields f) => f[deletedField] == true;

DateTime? _dateTime(Object? v) => v is String ? DateTime.tryParse(v) : null;

enum HabitKind { build, quit }

/// The optional Atomic Habits fields. Every field may be empty.
class HabitPlan {
  /// "I am a person who…" — the identity each check-in is a vote for.
  final String identity;

  /// Implementation intention: when (`HH:mm`, or empty) and where.
  final String time;
  final String location;

  /// Habit stacking: "After I [stackAfter], I will [habit]."
  final String stackAfter;

  /// Today's version of the habit. It starts as the "two-minute version",
  /// something so small you can't say no, and is stepped up over time.
  final String twoMinute;

  /// No longer shown: habits don't have a finish line. Kept so older data
  /// still loads.
  final String goal;

  /// When the size was last changed or checked in on (date key), or empty.
  /// The next size check-in comes two weeks after this.
  final String steppedUpAt;

  /// The person said the current size feels right: no more suggestions to
  /// make it bigger or smaller.
  final bool sizeSettled;

  /// Every version the habit has had, oldest first, with the day it began.
  /// Empty until the size first changes.
  final List<({String text, String since})> sizeHistory;

  /// Temptation bundling: something you enjoy, paired with the habit.
  final String bundle;

  /// An immediate reward after completing it.
  final String reward;

  /// For quit habits: how to make it invisible, unattractive, difficult and
  /// unsatisfying (the inversion of the four laws), plus a habit contract.
  final String invisible;
  final String unattractive;
  final String difficult;
  final String unsatisfying;
  final String contract;

  HabitPlan.fromFields(Fields f)
    : identity = tidy('identity', _text(f['identity'])),
      time = _text(f['time']),
      location = _text(f['location']),
      stackAfter = tidy('stackAfter', _text(f['stackAfter'])),
      twoMinute = _text(f['twoMinute']),
      goal = _text(f['goal']),
      steppedUpAt = _text(f['steppedUpAt']),
      sizeSettled = f['sizeSettled'] == true,
      sizeHistory = [
        for (final v in f['sizeHistory'] as List? ?? const [])
          if (v is Map) (text: _text(v['text']), since: _text(v['since'])),
      ],
      bundle = _text(f['bundle']),
      reward = _text(f['reward']),
      invisible = _text(f['invisible']),
      unattractive = _text(f['unattractive']),
      difficult = _text(f['difficult']),
      unsatisfying = _text(f['unsatisfying']),
      contract = _text(f['contract']);

  static const fieldNames = [
    'identity',
    'time',
    'location',
    'stackAfter',
    'twoMinute',
    'goal',
    'bundle',
    'reward',
    'invisible',
    'unattractive',
    'difficult',
    'unsatisfying',
    'contract',
  ];

  /// The words the app puts in front of a field when it shows it
  /// ("After I pour my coffee"). Forms show them fixed in front of the box,
  /// so they never need typing.
  static const leads = {'stackAfter': 'After I', 'identity': 'I am'};

  /// The ways people type a field's lead words, and what's left in their
  /// place. Contractions keep their verb: "After I've eaten" becomes
  /// "have eaten", which shows as "After I have eaten".
  static const _typedLeads = {
    'stackAfter': [
      ("After I['’]ve", 'have '),
      ("After I['’]m", 'am '),
      ('After I', ''),
    ],
    'identity': [('I am', ''), ("I['’]m", '')],
  };

  /// [text] ready to save: trimmed, and without the field's lead words if
  /// they were typed anyway ("After I sit down" becomes "sit down").
  static String tidy(String field, String text) {
    var t = text.trim();
    final forms = _typedLeads[field];
    if (forms == null) return t;
    // Typed more than once ("After I After I sit down"), each copy comes
    // off. Every pass removes at least the two letters of "I'm".
    var removed = true;
    while (removed) {
      removed = false;
      for (final (form, keep) in forms) {
        // The lead must end at a space, punctuation or the end of the text,
        // so "After Iñaki leaves" and "I amaze people" stay. (A regex
        // word boundary in Dart treats letters like "ñ" as a break.)
        // An apostrophe isn't a separator: it starts a contraction.
        const gap = r'[\s,.…:;!?–—-]';
        final typed = RegExp(
          '^$form(?=$gap|\$)$gap*',
          caseSensitive: false,
          unicode: true,
        ).firstMatch(t);
        if (typed != null) {
          t = keep + t.substring(typed.end);
          removed = true;
          break;
        }
      }
    }
    return t.trim();
  }

  /// True when none of the Atomic Habits fields are filled in. The time
  /// doesn't count: any habit can have one.
  bool get isEmpty => fieldNames.every((n) => n == 'time' || _value(n).isEmpty);

  String _value(String name) => switch (name) {
    'identity' => identity,
    'time' => time,
    'location' => location,
    'stackAfter' => stackAfter,
    'twoMinute' => twoMinute,
    'goal' => goal,
    'bundle' => bundle,
    'reward' => reward,
    'invisible' => invisible,
    'unattractive' => unattractive,
    'difficult' => difficult,
    'unsatisfying' => unsatisfying,
    _ => contract,
  };
}

String _text(Object? v) => v is String ? v : '';

class Habit {
  final String id;
  final String name;
  final int color;

  /// Key into the app's icon set.
  final String icon;
  final HabitKind kind;

  /// Weekdays the habit is scheduled on ([DateTime.monday]..[DateTime.sunday]).
  /// Quit habits apply every day.
  final Set<int> weekdays;
  final HabitPlan plan;

  /// How long it takes, in minutes: its length on the calendar when it has
  /// a time ([HabitPlan.time]).
  final int duration;

  /// Send a reminder at the habit's time (when it has one).
  final bool remind;
  final double order;
  final DateTime createdAt;
  final bool archived;
  final bool deleted;

  Habit.fromFields(this.id, Fields f)
    : name = f['name'] as String? ?? '',
      color = f['color'] as int? ?? 0xFF4CAF50,
      icon = f['icon'] as String? ?? 'check',
      kind = f['kind'] == 'quit' ? HabitKind.quit : HabitKind.build,
      weekdays = {
        for (final d in f['weekdays'] as List? ?? const [1, 2, 3, 4, 5, 6, 7])
          d as int,
      },
      plan = HabitPlan.fromFields(f),
      duration = f['duration'] as int? ?? 15,
      remind = f['remind'] as bool? ?? true,
      order = (f['order'] as num?)?.toDouble() ?? 0,
      createdAt = _dateTime(f['createdAt']) ?? DateTime(2000),
      archived = f['archived'] == true,
      deleted = _deleted(f);

  bool get isQuit => kind == HabitKind.quit;

  bool isScheduled(DateTime day) => isQuit || weekdays.contains(day.weekday);

  /// One check-in row per habit per day, so two devices checking in on the
  /// same day write the same row instead of creating duplicates.
  static String checkId(String habitId, DateTime day) =>
      '$habitId@${dateKey(day)}';

  DateTime get _startDay => dateOnly(createdAt.toLocal());

  /// Scheduled days completed in a row, ending today. If today isn't done
  /// yet the streak still counts up to yesterday, so it doesn't reset in the
  /// morning.
  ///
  /// With [forgiving] ("never miss twice"), a single missed day doesn't end
  /// the streak; two scheduled misses in a row do. Missed days don't count.
  ///
  /// Days off ([isOff]) are passed over like days the habit isn't scheduled:
  /// they neither count nor break the streak. A day that was done counts,
  /// even if it was also marked off.
  int streak(
    bool Function(DateTime day) isDone,
    DateTime today, {
    bool forgiving = false,
    bool Function(DateTime day)? isOff,
  }) {
    var day = dateOnly(today);
    if (!isDone(day)) day = addDays(day, -1);
    final start = _startDay;
    var count = 0;
    var missedLast = false;
    for (
      var i = 0;
      i < 3660 && !day.isBefore(start);
      i++, day = addDays(day, -1)
    ) {
      if (!isScheduled(day)) continue;
      if (isDone(day)) {
        count++;
        missedLast = false;
      } else if (isOff?.call(day) ?? false) {
        continue;
      } else if (forgiving && !missedLast) {
        missedLast = true;
      } else {
        break;
      }
    }
    return count;
  }

  /// True when the most recent scheduled day before today was missed and
  /// today isn't done yet: the moment "never miss twice" is about. Days off
  /// are passed over, and there's nothing to say on a day off.
  bool missedLastTime(
    bool Function(DateTime day) isDone,
    DateTime today, {
    bool Function(DateTime day)? isOff,
  }) {
    final t = dateOnly(today);
    if (isDone(t) || (isOff?.call(t) ?? false)) return false;
    for (
      var day = addDays(t, -1);
      !day.isBefore(_startDay);
      day = addDays(day, -1)
    ) {
      if (!isScheduled(day)) continue;
      if (isDone(day)) return false;
      if (isOff?.call(day) ?? false) continue;
      return true;
    }
    return false;
  }

  /// Scheduled days done, out of scheduled days, in the [days] up to and
  /// including [end], counting only days since the habit started. Days off
  /// don't count either way, unless they were done anyway.
  ({int done, int scheduled}) record(
    bool Function(DateTime day) isDone,
    DateTime end,
    int days, {
    bool Function(DateTime day)? isOff,
  }) {
    var scheduled = 0;
    var done = 0;
    for (var i = 0; i < days; i++) {
      final day = addDays(dateOnly(end), -i);
      if (day.isBefore(_startDay) || !isScheduled(day)) continue;
      if (isDone(day)) {
        done++;
        scheduled++;
      } else if (!(isOff?.call(day) ?? false)) {
        scheduled++;
      }
    }
    return (done: done, scheduled: scheduled);
  }

  /// For habits being broken, a check-in means "I stayed clear today", so
  /// days clean is the run of marked days, like a strict streak.
  int daysClean(bool Function(DateTime day) stayedClear, DateTime today) =>
      streak(stayedClear, today);

  /// The `habit_checks` field that marks a day off: the habit gets the day
  /// off, so it isn't missed. Older apps ignore it and see a missed day.
  static const offField = 'off';
}

/// A line on the Atomic Habits "habits scorecard": an existing habit rated
/// good (+), bad (−) or neutral (=), to build awareness.
class ScorecardItem {
  final String id;
  final String text;

  /// '+', '-' or '='.
  final String rating;
  final double order;
  final bool deleted;

  ScorecardItem.fromFields(this.id, Fields f)
    : text = _text(f['text']),
      rating = f['rating'] as String? ?? '=',
      order = (f['order'] as num?)?.toDouble() ?? 0,
      deleted = _deleted(f);
}

/// A weekly reflection. The row id is the date key of the week's first day.
class WeeklyReview {
  final String id;
  final Map<String, String> answers;
  final bool deleted;

  WeeklyReview.fromFields(this.id, Fields f)
    : answers = {
        for (final MapEntry(:key, :value) in f.entries)
          if (value is String && key != deletedField) key: value,
      },
      deleted = _deleted(f);

  static const prompts = {
    'wentWell': 'What went well this week?',
    'didntGoWell': "What didn't go so well?",
    'improve': 'What will you change next week?',
    'identity':
        'What did you do this week that fits the person you want to be?',
  };
}

class FocusSession {
  final String id;

  /// The habit the session was spent on, if one was picked.
  final String? habitId;
  final DateTime start;
  final int minutes;
  final bool deleted;

  FocusSession.fromFields(this.id, Fields f)
    : habitId = f['habitId'] as String?,
      start = _dateTime(f['start'])?.toLocal() ?? DateTime(2000),
      minutes = f['minutes'] as int? ?? 0,
      deleted = _deleted(f);
}

/// Something you enjoy, bought with the day's tomatoes: "An episode of a
/// show" for 4.
class Reward {
  final String id;
  final String name;

  /// The price in tomatoes, at least 1.
  final int cost;
  final double order;
  final bool deleted;

  Reward.fromFields(this.id, Fields f)
    : name = _text(f['name']),
      cost = _cost(f['cost']),
      order = (f['order'] as num?)?.toDouble() ?? 0,
      deleted = _deleted(f);

  /// The most a reward can cost: more than a long day's worth of sessions.
  static const maxCost = 20;
}

int _cost(Object? v) =>
    v is num && v.isFinite ? v.clamp(1, Reward.maxCost).round() : 1;

/// Tomatoes spent on a reward. The reward's name and price are kept as they
/// were, so renaming or deleting the reward later doesn't change the past.
/// Taking it back deletes the row.
class RewardSpend {
  final String id;
  final String? rewardId;
  final String name;
  final int cost;

  /// The day the tomatoes were spent ([dateKey]).
  final String day;
  final DateTime at;
  final bool deleted;

  RewardSpend.fromFields(this.id, Fields f)
    : rewardId = f['rewardId'] as String?,
      name = _text(f['name']),
      cost = _cost(f['cost']),
      day = _text(f['day']),
      at = _dateTime(f['at'])?.toLocal() ?? DateTime(2000),
      deleted = _deleted(f);
}

/// The tomatoes left to spend today: those [earnedToday] (focus sessions
/// finished today), less what was spent today. Tomatoes only count on the
/// day they're earned, so whatever isn't spent resets at midnight. Never
/// below zero, even if two devices spent the same tomatoes before syncing.
int tomatoesToSpend(
  int earnedToday,
  Iterable<RewardSpend> spends,
  String todayKey,
) {
  var spent = 0;
  for (final s in spends) {
    if (!s.deleted && s.day == todayKey) spent += s.cost;
  }
  return earnedToday - spent < 0 ? 0 : earnedToday - spent;
}

/// A one-off to-do: "Renew the passport", due Friday. Ticking it off sets
/// [done]; deleting it sets the usual [deletedField].
class TaskItem {
  final String id;
  final String title;

  /// The day it's due ([dateKey]), or null if it has no date.
  final String? due;

  /// Both marked by you, to place the task in the matrix.
  final bool important;
  final bool urgent;
  final bool done;

  /// When it was ticked off, for the Done list.
  final DateTime? doneAt;
  final DateTime created;
  final bool deleted;

  TaskItem.fromFields(this.id, Fields f)
    : title = _text(f['title']),
      due = _dueKey(f['due']),
      important = f['important'] == true,
      urgent = f['urgent'] == true,
      done = f['done'] == true,
      doneAt = _dateTime(f['doneAt'])?.toLocal(),
      created = _dateTime(f['created'])?.toLocal() ?? DateTime(2000),
      deleted = _deleted(f);

  /// Whole days from [today] until it's due: 0 today, 1 tomorrow, below 0
  /// if it's overdue. Null if it has no date.
  int? daysUntilDue(DateTime today) {
    final d = due == null ? null : tryParseDateKey(due!);
    return d == null ? null : daysBetween(today, d);
  }
}

/// A due day only counts if it reads back as the same text, so a day that
/// doesn't exist (like 2026-02-31) reads as no date.
String? _dueKey(Object? v) {
  if (v is! String) return null;
  final d = tryParseDateKey(v);
  return d != null && dateKey(d) == v ? v : null;
}

/// Where a task sits in the Tasks list.
enum TaskGroup {
  /// Due today, or overdue.
  today('Today'),
  upcoming('Upcoming'),

  /// No due date.
  someday('Someday'),
  done('Done');

  final String label;
  const TaskGroup(this.label);
}

TaskGroup taskGroup(TaskItem t, DateTime today) {
  if (t.done) return TaskGroup.done;
  final days = t.daysUntilDue(today);
  if (days == null) return TaskGroup.someday;
  return days <= 0 ? TaskGroup.today : TaskGroup.upcoming;
}

/// How a task's due date reads in a list: "Overdue", "Due today", "Due
/// tomorrow", "Due in 3 days". Null if it has no date or is done.
String? dueLabel(TaskItem t, DateTime today) {
  final days = t.daysUntilDue(today);
  if (t.done || days == null) return null;
  if (days < 0) return 'Overdue';
  if (days == 0) return 'Due today';
  if (days == 1) return 'Due tomorrow';
  return 'Due in $days days';
}

/// The four boxes of the Eisenhower matrix: important or not, urgent or
/// not, as you marked the task.
enum TaskQuadrant {
  doNow('Do it now', "These matter and can't wait."),
  plan(
    'Plan a time for it',
    "These matter, but they can wait. Pick a day for them so they don't "
        'sneak up on you.',
  ),
  keepQuick(
    'Get it done quickly',
    "These can't wait but don't matter much, so don't let them take over "
        'your day.',
  ),
  letGo(
    'Maybe let it go',
    "These aren't urgent or important. You might not need to do them at all.",
  );

  final String label;

  /// What the box means, in a sentence.
  final String hint;
  const TaskQuadrant(this.label, this.hint);
}

TaskQuadrant taskQuadrant(TaskItem t) => t.important
    ? (t.urgent ? TaskQuadrant.doNow : TaskQuadrant.plan)
    : (t.urgent ? TaskQuadrant.keepQuick : TaskQuadrant.letGo);
