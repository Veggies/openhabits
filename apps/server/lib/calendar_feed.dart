import 'package:core/core.dart';

/// Turns a person's habits into an iCalendar file that calendar apps
/// (Apple, Google, Outlook) can subscribe to. Each habit with a time becomes
/// a repeating event on the days it's scheduled, lasting as long as the
/// habit takes.
///
/// Times are "floating" (no time zone): 9:00 PM shows at 9:00 PM wherever
/// the calendar is, the same way the habit works in the app.
String habitsCalendar(
  Map<String, Map<String, Object?>> habitRows, {
  String name = 'Habits',
  DateTime? now,
}) {
  final stamp = _utcStamp((now ?? DateTime.now()).toUtc());
  final lines = <String>[
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//OpenHabits//Habits//EN',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    'X-WR-CALNAME:${_escape(name)}',
    // Asks calendar apps to check for changes every hour.
    'REFRESH-INTERVAL;VALUE=DURATION:PT1H',
    'X-PUBLISHED-TTL:PT1H',
  ];

  final habits = [
    for (final MapEntry(:key, :value) in habitRows.entries)
      Habit.fromFields(key, value),
  ]..sort((a, b) => a.plan.time.compareTo(b.plan.time));

  for (final h in habits) {
    if (h.deleted || h.archived || h.isQuit || h.plan.time.isEmpty) continue;
    if (h.weekdays.isEmpty) continue;
    final t = parseTime(h.plan.time);
    final start = h.createdAt.toUtc();
    final date =
        '${start.year.toString().padLeft(4, '0')}'
        '${_two(start.month)}${_two(start.day)}';
    final days = (h.weekdays.toList()..sort());
    final rule = days.length == 7
        ? 'FREQ=DAILY'
        : 'FREQ=WEEKLY;BYDAY=${days.map((d) => _dayCodes[d - 1]).join(',')}';
    final notes = [
      if (h.plan.twoMinute.isNotEmpty)
        'Your version for now: ${h.plan.twoMinute}',
      if (h.plan.stackAfter.isNotEmpty) 'After I ${h.plan.stackAfter}',
      if (h.plan.identity.isNotEmpty) 'I am ${h.plan.identity}',
    ];
    lines.addAll([
      'BEGIN:VEVENT',
      'UID:${h.id}@habits',
      'DTSTAMP:$stamp',
      'DTSTART:${date}T${_two(t.hour)}${_two(t.minute)}00',
      'DURATION:PT${h.duration}M',
      'RRULE:$rule',
      'SUMMARY:${_escape(h.name)}',
      if (notes.isNotEmpty) 'DESCRIPTION:${_escape(notes.join('\n'))}',
      if (h.plan.location.isNotEmpty) 'LOCATION:${_escape(h.plan.location)}',
      'TRANSP:TRANSPARENT', // a habit doesn't make you look busy
      'END:VEVENT',
    ]);
  }
  lines.add('END:VCALENDAR');
  return '${lines.map(_fold).join('\r\n')}\r\n';
}

const _dayCodes = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

String _two(int n) => n.toString().padLeft(2, '0');

String _utcStamp(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}${_two(d.month)}${_two(d.day)}'
    'T${_two(d.hour)}${_two(d.minute)}${_two(d.second)}Z';

/// Text values escape backslashes, commas, semicolons and newlines.
String _escape(String s) => s
    .replaceAll(r'\', r'\\')
    .replaceAll(',', r'\,')
    .replaceAll(';', r'\;')
    .replaceAll('\n', r'\n');

/// Lines longer than 75 bytes continue on the next line after a space.
String _fold(String line) {
  if (line.length <= 73) return line;
  final out = StringBuffer();
  var count = 0;
  for (final rune in line.runes) {
    final ch = String.fromCharCode(rune);
    final size = ch.codeUnits.length == 1 && rune < 0x80
        ? 1
        : rune < 0x800
        ? 2
        : rune < 0x10000
        ? 3
        : 4;
    if (count + size > 74) {
      out.write('\r\n ');
      count = 1;
    }
    out.write(ch);
    count += size;
  }
  return out.toString();
}
