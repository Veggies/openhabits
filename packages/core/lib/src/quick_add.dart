import 'dates.dart';
import 'models.dart';
import 'recurrence.dart';

/// The result of parsing a quick-add line such as
/// `Call mom tomorrow 5pm #family !high ^Personal every week`.
class QuickAdd {
  final String title;
  final DateTime? dueDate;

  /// `HH:mm`, or null if no time was given.
  final String? dueTime;
  final List<String> tags;
  final Priority? priority;

  /// The list name after `^`, matched against existing lists by the caller.
  final String? listName;
  final RepeatRule? repeat;

  const QuickAdd({
    required this.title,
    this.dueDate,
    this.dueTime,
    this.tags = const [],
    this.priority,
    this.listName,
    this.repeat,
  });
}

typedef _Match<T> = ({T value, int consumed});

const _weekdays = {
  'mon': 1,
  'monday': 1,
  'tue': 2,
  'tues': 2,
  'tuesday': 2,
  'wed': 3,
  'wednesday': 3,
  'thu': 4,
  'thur': 4,
  'thurs': 4,
  'thursday': 4,
  'fri': 5,
  'friday': 5,
  'sat': 6,
  'saturday': 6,
  'sun': 7,
  'sunday': 7,
};

const _months = {
  'jan': 1,
  'january': 1,
  'feb': 2,
  'february': 2,
  'mar': 3,
  'march': 3,
  'apr': 4,
  'april': 4,
  'may': 5,
  'jun': 6,
  'june': 6,
  'jul': 7,
  'july': 7,
  'aug': 8,
  'august': 8,
  'sep': 9,
  'sept': 9,
  'september': 9,
  'oct': 10,
  'october': 10,
  'nov': 11,
  'november': 11,
  'dec': 12,
  'december': 12,
};

/// Parses natural-language dates, times, repeats, `#tags`, `!priority` and
/// `^list` out of [input]. Whatever isn't recognised becomes the title.
QuickAdd parseQuickAdd(String input, DateTime now) {
  final tokens = input.trim().split(RegExp(r'\s+'))
    ..removeWhere((t) => t.isEmpty);
  final titleWords = <String>[];
  final tags = <String>[];
  DateTime? date;
  ({int hour, int minute})? time;
  RepeatRule? repeat;
  Priority? priority;
  String? listName;

  var i = 0;
  while (i < tokens.length) {
    final token = tokens[i];
    if (token.length > 1 && token.startsWith('#')) {
      tags.add(token.substring(1));
      i++;
      continue;
    }
    if (token.length > 1 && token.startsWith('^')) {
      listName = token.substring(1);
      i++;
      continue;
    }
    final rest = [
      for (final t in tokens.skip(i)) t.toLowerCase().replaceAll(',', ''),
    ];
    if (_priority(rest.first) case final p?) {
      priority = p;
      i++;
      continue;
    }
    if (_repeat(rest, now) case final r?) {
      repeat = r.value.rule;
      date ??= r.value.start;
      i += r.consumed;
      continue;
    }
    if (_date(rest, now) case final d?) {
      date = d.value;
      i += d.consumed;
      continue;
    }
    if (_time(rest) case final t?) {
      time = t.value;
      i += t.consumed;
      continue;
    }
    titleWords.add(token);
    i++;
  }

  if (time != null) date ??= dateOnly(now);
  return QuickAdd(
    title: titleWords.join(' '),
    dueDate: date,
    dueTime: time == null ? null : formatTime(time.hour, time.minute),
    tags: tags,
    priority: priority,
    listName: listName,
    repeat: repeat,
  );
}

Priority? _priority(String t) => switch (t) {
  '!high' || '!h' || '!3' || '!!!' => Priority.high,
  '!medium' || '!med' || '!m' || '!2' || '!!' => Priority.medium,
  '!low' || '!l' || '!1' => Priority.low,
  _ => null,
};

/// The next [weekday] on or after [from].
DateTime _upcoming(int weekday, DateTime from, {bool includeToday = true}) {
  final today = dateOnly(from);
  var diff = (weekday - today.weekday) % 7;
  if (diff == 0 && !includeToday) diff = 7;
  return addDays(today, diff);
}

_Match<DateTime>? _date(List<String> t, DateTime now) {
  final today = dateOnly(now);
  final first = t[0];
  final second = t.length > 1 ? t[1] : null;

  if (first == 'on' && t.length > 1) {
    final inner = _date(t.sublist(1), now);
    if (inner != null) {
      return (value: inner.value, consumed: inner.consumed + 1);
    }
  }
  switch (first) {
    case 'today' || 'tod':
      return (value: today, consumed: 1);
    case 'tomorrow' || 'tmr' || 'tmrw':
      return (value: addDays(today, 1), consumed: 1);
  }
  if (first == 'next' && second != null) {
    if (second == 'week') {
      return (value: _upcoming(1, now, includeToday: false), consumed: 2);
    }
    if (second == 'month') {
      return (value: DateTime(today.year, today.month + 1), consumed: 2);
    }
    if (_weekdays[second] case final wd?) {
      return (value: _upcoming(wd, now, includeToday: false), consumed: 2);
    }
  }
  if (first == 'in' && t.length > 2) {
    final n = int.tryParse(t[1]);
    if (n != null) {
      final unit = t[2].endsWith('s')
          ? t[2].substring(0, t[2].length - 1)
          : t[2];
      final value = switch (unit) {
        'day' => addDays(today, n),
        'week' => addDays(today, 7 * n),
        'month' => addMonths(today, n),
        _ => null,
      };
      if (value != null) return (value: value, consumed: 3);
    }
  }
  if (_weekdays[first] case final wd?) {
    return (value: _upcoming(wd, now), consumed: 1);
  }

  // "nov 20", "november 20th", "20 nov"
  if (second != null) {
    final month = _months[first];
    final day = _dayNumber(second);
    if (month != null && day != null) {
      return (value: _nextDate(month, day, today), consumed: 2);
    }
    final day2 = _dayNumber(first);
    final month2 = _months[second];
    if (day2 != null && month2 != null) {
      return (value: _nextDate(month2, day2, today), consumed: 2);
    }
  }
  // 2026-11-20
  final iso = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(first);
  if (iso != null) {
    return (
      value: DateTime(
        int.parse(iso[1]!),
        int.parse(iso[2]!),
        int.parse(iso[3]!),
      ),
      consumed: 1,
    );
  }
  // 11/20 or 11/20/2026
  final slash = RegExp(r'^(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?$')
      .firstMatch(first);
  if (slash != null) {
    final month = int.parse(slash[1]!);
    final day = int.parse(slash[2]!);
    if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
      final year = slash[3];
      if (year == null) {
        return (value: _nextDate(month, day, today), consumed: 1);
      }
      final y = int.parse(year);
      return (value: DateTime(y < 100 ? 2000 + y : y, month, day), consumed: 1);
    }
  }
  return null;
}

int? _dayNumber(String t) {
  final m = RegExp(r'^(\d{1,2})(st|nd|rd|th)?$').firstMatch(t);
  if (m == null) return null;
  final n = int.parse(m[1]!);
  return n >= 1 && n <= 31 ? n : null;
}

/// [month]/[day] this year, or next year if that date has already passed.
DateTime _nextDate(int month, int day, DateTime today) {
  final thisYear = DateTime(today.year, month, day);
  return thisYear.isBefore(today)
      ? DateTime(today.year + 1, month, day)
      : thisYear;
}

_Match<({int hour, int minute})>? _time(List<String> t) {
  if (t[0] == 'at' && t.length > 1) {
    final inner = _time(t.sublist(1));
    if (inner != null) {
      return (value: inner.value, consumed: inner.consumed + 1);
    }
    return null;
  }
  if (t[0] == 'noon') return (value: (hour: 12, minute: 0), consumed: 1);

  // "5pm", "5:30pm", or "5 pm"
  var text = t[0];
  var consumed = 1;
  if (t.length > 1 &&
      (t[1] == 'am' || t[1] == 'pm') &&
      RegExp(r'^\d{1,2}(:\d{2})?$').hasMatch(text)) {
    text += t[1];
    consumed = 2;
  }
  final ampm = RegExp(r'^(\d{1,2})(?::(\d{2}))?(am|pm|a|p)$').firstMatch(text);
  if (ampm != null) {
    var hour = int.parse(ampm[1]!);
    final minute = int.parse(ampm[2] ?? '0');
    if (hour < 1 || hour > 12 || minute > 59) return null;
    final pm = ampm[3]!.startsWith('p');
    if (hour == 12) hour = 0;
    if (pm) hour += 12;
    return (value: (hour: hour, minute: minute), consumed: consumed);
  }
  final h24 = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(t[0]);
  if (h24 != null) {
    final hour = int.parse(h24[1]!);
    final minute = int.parse(h24[2]!);
    if (hour > 23 || minute > 59) return null;
    return (value: (hour: hour, minute: minute), consumed: 1);
  }
  return null;
}

_Match<({RepeatRule rule, DateTime start})>? _repeat(
  List<String> t,
  DateTime now,
) {
  final today = dateOnly(now);
  switch (t[0]) {
    case 'daily':
      return (
        value: (rule: const RepeatRule(Freq.daily), start: today),
        consumed: 1,
      );
    case 'weekly':
      return (
        value: (rule: const RepeatRule(Freq.weekly), start: today),
        consumed: 1,
      );
    case 'monthly':
      return (
        value: (rule: const RepeatRule(Freq.monthly), start: today),
        consumed: 1,
      );
    case 'yearly' || 'annually':
      return (
        value: (rule: const RepeatRule(Freq.yearly), start: today),
        consumed: 1,
      );
  }
  if (t[0] != 'every' || t.length < 2) return null;

  Freq? unitFreq(String u) =>
      switch (u.endsWith('s') ? u.substring(0, u.length - 1) : u) {
        'day' => Freq.daily,
        'week' => Freq.weekly,
        'month' => Freq.monthly,
        'year' => Freq.yearly,
        _ => null,
      };

  if (t[1] == 'weekday') {
    return (
      value: (
        rule: RepeatRule.weekdaysOnly,
        start: _firstOf(RepeatRule.weekdaysOnly.weekdays, now),
      ),
      consumed: 2,
    );
  }
  if (unitFreq(t[1]) case final freq?) {
    return (value: (rule: RepeatRule(freq), start: today), consumed: 2);
  }
  // "every 2 weeks"
  final n = int.tryParse(t[1]);
  if (n != null && n > 0 && t.length > 2) {
    if (unitFreq(t[2]) case final freq?) {
      return (
        value: (rule: RepeatRule(freq, interval: n), start: today),
        consumed: 3,
      );
    }
  }
  // "every mon wed fri" or "every mon and thu"
  final days = <int>{};
  var i = 1;
  while (i < t.length) {
    if (t[i] == 'and' &&
        days.isNotEmpty &&
        i + 1 < t.length &&
        _weekdays.containsKey(t[i + 1])) {
      i++;
      continue;
    }
    final wd = _weekdays[t[i]];
    if (wd == null) break;
    days.add(wd);
    i++;
  }
  if (days.isEmpty) return null;
  final rule = RepeatRule(Freq.weekly, weekdays: days);
  return (value: (rule: rule, start: _firstOf(days, now)), consumed: i);
}

DateTime _firstOf(Set<int> weekdays, DateTime now) => weekdays
    .map((wd) => _upcoming(wd, now))
    .reduce((a, b) => a.isBefore(b) ? a : b);
