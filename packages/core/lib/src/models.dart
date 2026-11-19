import 'change.dart';
import 'dates.dart';

/// Table names shared by the client and server.
abstract final class Tables {
  static const habits = 'habits';
  static const habitChecks = 'habit_checks';
  static const focusSessions = 'focus_sessions';
  static const scorecard = 'scorecard';
  static const reviews = 'reviews';

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

  /// [text] ready to save: trimmed, and without the field's lead words if
  /// they were typed anyway ("After I sit down" becomes "sit down").
  static String tidy(String field, String text) {
    final t = text.trim();
    final lead = leads[field];
    if (lead == null) return t;
    final typed = RegExp(
      '^${RegExp.escape(lead)}\\b[\\s,.…]*',
      caseSensitive: false,
    );
    return t.replaceFirst(typed, '');
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
  int streak(
    bool Function(DateTime day) isDone,
    DateTime today, {
    bool forgiving = false,
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
      } else if (forgiving && !missedLast) {
        missedLast = true;
      } else {
        break;
      }
    }
    return count;
  }

  /// True when the most recent scheduled day before today was missed and
  /// today isn't done yet: the moment "never miss twice" is about.
  bool missedLastTime(bool Function(DateTime day) isDone, DateTime today) {
    final t = dateOnly(today);
    if (isDone(t)) return false;
    for (
      var day = addDays(t, -1);
      !day.isBefore(_startDay);
      day = addDays(day, -1)
    ) {
      if (isScheduled(day)) return !isDone(day);
    }
    return false;
  }

  /// For habits being broken, a check-in means "I stayed clear today", so
  /// days clean is the run of marked days, like a strict streak.
  int daysClean(bool Function(DateTime day) stayedClear, DateTime today) =>
      streak(stayedClear, today);
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
