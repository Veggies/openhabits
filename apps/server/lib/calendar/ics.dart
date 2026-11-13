import 'package:core/core.dart' show dateKey;
import 'package:timezone/timezone.dart' as tz;

/// A DTSTART/DTEND-style value.
///
/// [wall] holds the wall-clock reading as a UTC [DateTime], used purely as a
/// container so date arithmetic never shifts across daylight-saving changes.
/// [location] says how to turn that reading into an instant.
class IcsTime {
  final DateTime wall;
  final bool allDay;

  /// True for values ending in `Z`.
  final bool utc;

  /// Null for UTC, all-day, and floating (zone-less) values, or when the
  /// TZID isn't a recognised IANA zone.
  final tz.Location? location;

  const IcsTime(
    this.wall, {
    this.allDay = false,
    this.utc = false,
    this.location,
  });

  IcsTime withWall(DateTime wall) =>
      IcsTime(wall, allDay: allDay, utc: utc, location: location);

  /// The real instant. Floating times are treated as UTC, which is only used
  /// to compare against the sync window, so being a few hours off is harmless.
  DateTime toUtc() {
    final loc = location;
    if (loc == null) return wall;
    return tz.TZDateTime(
      loc,
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
      wall.second,
    ).toUtc();
  }

  /// How the value is stored for clients: a date key for all-day values, an
  /// ISO instant ending in `Z` when the zone is known, otherwise floating
  /// local time (no `Z`), which each device reads in its own zone.
  String encode() {
    if (allDay) return dateKey(wall);
    if (utc || location != null) return toUtc().toIso8601String();
    return wall.toIso8601String().replaceAll('Z', '');
  }
}

class IcsEvent {
  final String uid;
  final String summary;
  final IcsTime start;
  final IcsTime end;
  final Map<String, String>? rrule;
  final List<IcsTime> exdates;
  final IcsTime? recurrenceId;
  final bool cancelled;

  IcsEvent({
    required this.uid,
    required this.summary,
    required this.start,
    required this.end,
    this.rrule,
    this.exdates = const [],
    this.recurrenceId,
    this.cancelled = false,
  });
}

/// One concrete occurrence, ready to store.
class Occurrence {
  final String uid;
  final String title;
  final IcsTime start;
  final IcsTime end;

  Occurrence(this.uid, this.title, this.start, this.end);
}

typedef _Prop = ({String name, Map<String, String> params, String value});

/// Parses every VEVENT in an iCalendar document. Malformed events are skipped.
List<IcsEvent> parseIcs(String text) {
  final events = <IcsEvent>[];
  List<_Prop>? current;
  var depth = 0; // nesting inside the VEVENT (e.g. VALARM)
  for (final line in _unfold(text)) {
    final prop = _parseLine(line);
    if (prop == null) continue;
    if (prop.name == 'BEGIN' && prop.value.toUpperCase() == 'VEVENT') {
      current = [];
      depth = 0;
    } else if (current != null && prop.name == 'BEGIN') {
      depth++;
    } else if (current != null && prop.name == 'END') {
      if (prop.value.toUpperCase() == 'VEVENT' && depth == 0) {
        final event = _buildEvent(current);
        if (event != null) events.add(event);
        current = null;
      } else {
        depth--;
      }
    } else if (current != null && depth == 0) {
      current.add(prop);
    }
  }
  return events;
}

Iterable<String> _unfold(String text) sync* {
  final lines = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  var buffer = StringBuffer();
  for (final line in lines) {
    if ((line.startsWith(' ') || line.startsWith('\t')) && buffer.isNotEmpty) {
      buffer.write(line.substring(1));
    } else {
      if (buffer.isNotEmpty) yield buffer.toString();
      buffer = StringBuffer(line);
    }
  }
  if (buffer.isNotEmpty) yield buffer.toString();
}

_Prop? _parseLine(String line) {
  // The value starts at the first colon outside a quoted parameter.
  var inQuotes = false;
  var colon = -1;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') inQuotes = !inQuotes;
    if (c == ':' && !inQuotes) {
      colon = i;
      break;
    }
  }
  if (colon < 0) return null;
  final head = line.substring(0, colon).split(';');
  final params = <String, String>{};
  for (final p in head.skip(1)) {
    final eq = p.indexOf('=');
    if (eq > 0) {
      params[p.substring(0, eq).toUpperCase()] = p
          .substring(eq + 1)
          .replaceAll('"', '');
    }
  }
  return (
    name: head.first.toUpperCase(),
    params: params,
    value: line.substring(colon + 1),
  );
}

String _unescape(String v) => v
    .replaceAll(r'\n', '\n')
    .replaceAll(r'\N', '\n')
    .replaceAll(r'\,', ',')
    .replaceAll(r'\;', ';')
    .replaceAll(r'\\', r'\');

IcsEvent? _buildEvent(List<_Prop> props) {
  _Prop? find(String name) {
    for (final p in props) {
      if (p.name == name) return p;
    }
    return null;
  }

  final uid = find('UID')?.value;
  final dtstart = find('DTSTART');
  if (uid == null || dtstart == null) return null;
  final start = parseIcsTime(dtstart.value, dtstart.params);
  if (start == null) return null;

  final dtend = find('DTEND');
  final durationProp = find('DURATION');
  final explicitEnd = dtend == null
      ? null
      : parseIcsTime(dtend.value, dtend.params);
  final duration = durationProp == null
      ? null
      : parseDuration(durationProp.value);
  final end =
      explicitEnd ??
      start.withWall(
        start.wall.add(
          duration ?? (start.allDay ? const Duration(days: 1) : Duration.zero),
        ),
      );

  final rruleProp = find('RRULE');
  final recurrence = find('RECURRENCE-ID');
  return IcsEvent(
    uid: uid,
    summary: _unescape(find('SUMMARY')?.value ?? ''),
    start: start,
    end: end,
    rrule: rruleProp == null ? null : _parseRrule(rruleProp.value),
    exdates: [
      for (final p in props.where((p) => p.name == 'EXDATE'))
        for (final v in p.value.split(',')) ?parseIcsTime(v, p.params),
    ],
    recurrenceId: recurrence == null
        ? null
        : parseIcsTime(recurrence.value, recurrence.params),
    cancelled: find('STATUS')?.value.toUpperCase() == 'CANCELLED',
  );
}

Map<String, String> _parseRrule(String v) => {
  for (final part in v.split(';'))
    if (part.contains('='))
      part.split('=')[0].toUpperCase(): part.split('=')[1],
};

IcsTime? parseIcsTime(String value, Map<String, String> params) {
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$')
      .firstMatch(value.trim());
  if (m == null) return null;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  if (m[4] == null) return IcsTime(DateTime.utc(y, mo, d), allDay: true);
  final wall = DateTime.utc(
    y,
    mo,
    d,
    int.parse(m[4]!),
    int.parse(m[5]!),
    int.parse(m[6]!),
  );
  if (m[7] != null) return IcsTime(wall, utc: true);
  return IcsTime(wall, location: _location(params['TZID']));
}

tz.Location? _location(String? tzid) {
  if (tzid == null) return null;
  // Some producers prefix the IANA name, e.g. "/mozilla.org/.../Europe/London".
  final segments = tzid.split('/').where((s) => s.isNotEmpty).toList();
  for (var i = 0; i < segments.length; i++) {
    try {
      return tz.getLocation(segments.sublist(i).join('/'));
    } catch (_) {}
  }
  return null;
}

Duration? parseDuration(String v) {
  final m = RegExp(
    r'^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$',
  ).firstMatch(v.trim());
  if (m == null) return null;
  int n(int i) => int.tryParse(m[i] ?? '') ?? 0;
  final d = Duration(
    days: n(2) * 7 + n(3),
    hours: n(4),
    minutes: n(5),
    seconds: n(6),
  );
  return m[1] == '-' ? -d : d;
}

const _byDayNames = {
  'MO': 1,
  'TU': 2,
  'WE': 3,
  'TH': 4,
  'FR': 5,
  'SA': 6,
  'SU': 7,
};

/// Expands [events] (masters plus overrides from the same feed) into
/// occurrences overlapping [from]..[to].
List<Occurrence> expandEvents(
  List<IcsEvent> events,
  DateTime from,
  DateTime to,
) {
  final overrides = <String, Map<DateTime, IcsEvent>>{};
  for (final e in events.where((e) => e.recurrenceId != null)) {
    overrides.putIfAbsent(e.uid, () => {})[e.recurrenceId!.toUtc()] = e;
  }

  bool overlaps(IcsTime start, IcsTime end) =>
      end.toUtc().isAfter(from) && start.toUtc().isBefore(to) ||
      (start.toUtc() == end.toUtc() &&
          !start.toUtc().isBefore(from) &&
          start.toUtc().isBefore(to));

  final result = <Occurrence>[];
  for (final e in events) {
    if (e.recurrenceId != null) {
      if (!e.cancelled && overlaps(e.start, e.end)) {
        result.add(Occurrence(e.uid, e.summary, e.start, e.end));
      }
      continue;
    }
    if (e.cancelled) continue;
    final length = e.end.wall.difference(e.start.wall);
    final excluded = {for (final x in e.exdates) x.toUtc()};
    final moved = overrides[e.uid] ?? const {};
    for (final wall in _occurrenceWalls(e, to)) {
      final start = e.start.withWall(wall);
      final instant = start.toUtc();
      if (excluded.contains(instant) || moved.containsKey(instant)) continue;
      final end = e.end.withWall(wall.add(length));
      if (overlaps(start, end)) {
        result.add(Occurrence(e.uid, e.summary, start, end));
      }
    }
  }
  return result;
}

/// Wall-clock start times for [e], stopping once past [to]. Handles the
/// RRULE parts calendars commonly produce: FREQ, INTERVAL, COUNT, UNTIL,
/// BYDAY (with ordinals for monthly rules), BYMONTHDAY and BYMONTH.
Iterable<DateTime> _occurrenceWalls(IcsEvent e, DateTime to) sync* {
  final rule = e.rrule;
  final dtstart = e.start.wall;
  if (rule == null) {
    yield dtstart;
    return;
  }
  final interval = int.tryParse(rule['INTERVAL'] ?? '') ?? 1;
  final count = int.tryParse(rule['COUNT'] ?? '');
  final untilTime = rule['UNTIL'] == null
      ? null
      : parseIcsTime(rule['UNTIL']!, const {});
  final until = untilTime == null
      ? null
      : (untilTime.allDay
            ? untilTime.wall.add(const Duration(days: 1))
            : untilTime.wall);
  final byDay = [
    for (final d in (rule['BYDAY'] ?? '').split(',').where((d) => d.isNotEmpty))
      if (RegExp(r'^([+-]?\d+)?([A-Z]{2})$').firstMatch(d.toUpperCase())
          case final m? when _byDayNames.containsKey(m[2]))
        (ordinal: int.tryParse(m[1] ?? ''), weekday: _byDayNames[m[2]]!),
  ];
  final byMonthDay = [
    for (final d in (rule['BYMONTHDAY'] ?? '').split(',')) ?int.tryParse(d),
  ];
  final byMonth = [
    for (final m in (rule['BYMONTH'] ?? '').split(',')) ?int.tryParse(m),
  ];

  DateTime at(int y, int m, int d) =>
      DateTime.utc(y, m, d, dtstart.hour, dtstart.minute, dtstart.second);

  List<DateTime> candidates(int period) {
    switch (rule['FREQ']?.toUpperCase()) {
      case 'DAILY':
        final day = DateTime.utc(
          dtstart.year,
          dtstart.month,
          dtstart.day + period * interval,
        );
        final ok = byDay.isEmpty || byDay.any((b) => b.weekday == day.weekday);
        return ok ? [at(day.year, day.month, day.day)] : [];
      case 'WEEKLY':
        final weekStart = DateTime.utc(
          dtstart.year,
          dtstart.month,
          dtstart.day - (dtstart.weekday - 1) + period * interval * 7,
        );
        final days = byDay.isEmpty
            ? [dtstart.weekday]
            : byDay.map((b) => b.weekday);
        return [
          for (final wd in days.toSet().toList()..sort())
            at(weekStart.year, weekStart.month, weekStart.day + wd - 1),
        ];
      case 'MONTHLY':
        final first = DateTime.utc(
          dtstart.year,
          dtstart.month + period * interval,
        );
        return _monthDays(
          first.year,
          first.month,
          byDay,
          byMonthDay,
          dtstart.day,
        ).map((d) => at(first.year, first.month, d)).toList();
      case 'YEARLY':
        final year = dtstart.year + period * interval;
        final months = byMonth.isEmpty ? [dtstart.month] : byMonth;
        return [
          for (final m in months..sort())
            for (final d in _monthDays(year, m, byDay, byMonthDay, dtstart.day))
              at(year, m, d),
        ];
      default:
        return period == 0 ? [dtstart] : [];
    }
  }

  var emitted = 0;
  for (var period = 0; period < 10000; period++) {
    final list = candidates(period)..sort();
    for (final c in list) {
      if (c.isBefore(dtstart)) continue;
      if (until != null && c.isAfter(until)) return;
      if (count != null && emitted >= count) return;
      emitted++;
      if (e.start.withWall(c).toUtc().isAfter(to)) return;
      yield c;
    }
  }
}

/// Days of [month] matching BYDAY/BYMONTHDAY, defaulting to [defaultDay].
/// Invalid days (Feb 30) are skipped, as RFC 5545 requires.
List<int> _monthDays(
  int year,
  int month,
  List<({int? ordinal, int weekday})> byDay,
  List<int> byMonthDay,
  int defaultDay,
) {
  final length = DateTime.utc(year, month + 1, 0).day;
  final days = <int>{};
  if (byMonthDay.isNotEmpty) {
    for (final d in byMonthDay) {
      final day = d > 0 ? d : length + d + 1;
      if (day >= 1 && day <= length) days.add(day);
    }
  } else if (byDay.isNotEmpty) {
    for (final b in byDay) {
      final matching = [
        for (var d = 1; d <= length; d++)
          if (DateTime.utc(year, month, d).weekday == b.weekday) d,
      ];
      final ordinal = b.ordinal;
      if (ordinal == null) {
        days.addAll(matching);
      } else {
        final index = ordinal > 0 ? ordinal - 1 : matching.length + ordinal;
        if (index >= 0 && index < matching.length) days.add(matching[index]);
      }
    }
  } else if (defaultDay <= length) {
    days.add(defaultDay);
  }
  return days.toList()..sort();
}
