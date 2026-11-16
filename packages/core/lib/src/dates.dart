/// Date-only values are stored as `yyyy-MM-dd` strings so they mean the same
/// calendar day on every device, whatever its time zone.
String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime parseDateKey(String key) {
  final parts = key.split('-');
  return DateTime(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
}

/// Like [parseDateKey], but null for anything that isn't a date key.
DateTime? tryParseDateKey(String key) {
  if (key.isEmpty) return null;
  try {
    return parseDateKey(key);
  } on FormatException {
    return null;
  } on RangeError {
    return null;
  }
}

/// Midnight at the start of [d]'s day, in [d]'s time zone.
DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Adds whole calendar days. Unlike `d.add(Duration(days: n))`, this is safe
/// across daylight-saving changes.
DateTime addDays(DateTime d, int days) =>
    DateTime(d.year, d.month, d.day + days);

/// The first day of [d]'s week, for weeks starting on [firstDay]
/// ([DateTime.sunday] or [DateTime.monday]).
DateTime startOfWeek(DateTime d, [int firstDay = DateTime.sunday]) =>
    addDays(dateOnly(d), -((d.weekday - firstDay) % 7));

/// Whole calendar days from [a] to [b], unaffected by daylight-saving shifts.
int daysBetween(DateTime a, DateTime b) => DateTime.utc(
  b.year,
  b.month,
  b.day,
).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

int daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

/// The same day-of-month [months] later, clamped to the end of shorter
/// months (Jan 31 + 1 month = Feb 28).
DateTime addMonths(DateTime d, int months) {
  final first = DateTime(d.year, d.month + months);
  final day = d.day.clamp(1, daysInMonth(first.year, first.month));
  return DateTime(first.year, first.month, day);
}

/// Parses `HH:mm`.
({int hour, int minute}) parseTime(String hhmm) {
  final parts = hhmm.split(':');
  return (hour: int.parse(parts[0]), minute: int.parse(parts[1]));
}

String formatTime(int hour, int minute) =>
    '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
