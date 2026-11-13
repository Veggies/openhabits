import 'dart:convert';
import 'dart:io';

import 'package:core/core.dart';
import 'package:http/http.dart' as http;

import '../sync_store.dart';
import 'caldav.dart';
import 'ics.dart';

/// An external calendar to import, from the server's calendars.json.
///
/// ```json
/// [
///   {"name": "Work", "type": "ics", "url": "https://calendar.google.com/calendar/ical/.../basic.ics"},
///   {"name": "iCloud", "type": "caldav", "url": "https://caldav.icloud.com",
///    "username": "me@icloud.com", "password": "app-specific-password"}
/// ]
/// ```
class CalendarSource {
  final String name;
  final String type;
  final Uri url;
  final String? username;
  final String? password;

  /// Whose calendar this is (an account username). Defaults to the owner.
  final String? user;

  CalendarSource.fromJson(Map<String, Object?> json)
    : name = json['name'] as String,
      type = json['type'] as String,
      url = Uri.parse(
        (json['url'] as String).replaceFirst(RegExp('^webcal:'), 'https:'),
      ),
      username = json['username'] as String?,
      password = json['password'] as String?,
      user = json['user'] as String?;

  static List<CalendarSource> load(String path) {
    final file = File(path);
    if (!file.existsSync()) return const [];
    final json = jsonDecode(file.readAsStringSync());
    final list = json is Map ? json['calendars'] : json;
    return [
      for (final e in list as List)
        CalendarSource.fromJson(e as Map<String, Object?>),
    ];
  }
}

/// Fetched events for one source, grouped by calendar name.
typedef CalendarFetch =
    Future<List<({String calendar, List<IcsEvent> events})>> Function(
      CalendarSource source,
      DateTime from,
      DateTime to,
    );

/// Imports external calendar events into the events table, so they reach
/// every device through normal sync. Events are read-only on devices.
class CalendarSync {
  final SyncStore store;

  /// Replaced when the owner edits calendars on the setup page.
  List<CalendarSource> sources;
  final CalendarFetch _fetch;

  /// Resolves a source's account to a user id, or null if it doesn't exist.
  final String? Function(CalendarSource source) userIdFor;

  /// How far back and ahead to import.
  static const past = Duration(days: 60);
  static const future = Duration(days: 365);

  CalendarSync(
    this.store,
    this.sources, {
    required this.userIdFor,
    CalendarFetch? fetch,
    http.Client? client,
  }) : _fetch = fetch ?? _defaultFetch(client ?? http.Client());

  /// Refreshes every source. Returns per-source errors; a failing source
  /// keeps its previously imported events rather than having them deleted.
  Future<Map<String, String>> run({DateTime? now}) async {
    final at = (now ?? DateTime.now()).toUtc();
    final errors = <String, String>{};
    for (final source in sources) {
      final userId = userIdFor(source);
      if (userId == null) {
        errors[source.name] =
            'No account "${source.user ?? 'owner'}" to import into yet.';
        continue;
      }
      try {
        final calendars = await _fetch(
          source,
          at.subtract(past),
          at.add(future),
        );
        _store(userId, source, calendars, at);
      } catch (e) {
        errors[source.name] = '$e';
        stderr.writeln('Calendar "${source.name}" failed: $e');
      }
    }
    return errors;
  }

  void _store(
    String userId,
    CalendarSource source,
    List<({String calendar, List<IcsEvent> events})> calendars,
    DateTime now,
  ) {
    final wanted = <String, Map<String, Object?>>{};
    for (final cal in calendars) {
      for (final o in expandEvents(
        cal.events,
        now.subtract(past),
        now.add(future),
      )) {
        final start = o.start.encode();
        wanted['${source.name}|${cal.calendar}|${o.uid}|$start'] = {
          'source': source.name,
          'calendar': cal.calendar,
          'title': o.title,
          'allDay': o.start.allDay,
          'start': start,
          'end': o.end.encode(),
          deletedField: false,
        };
      }
    }

    final existing = {
      for (final MapEntry(:key, :value)
          in store.rows(userId, Tables.events).entries)
        if (value['source'] == source.name) key: value,
    };
    final changes = <Change>[];
    void set(String id, String field, Object? value) => changes.add(
      Change(
        table: Tables.events,
        rowId: id,
        field: field,
        value: value,
        hlc: store.stamp(),
      ),
    );

    for (final MapEntry(key: id, value: fields) in wanted.entries) {
      final old = existing[id] ?? const {};
      for (final MapEntry(key: field, :value) in fields.entries) {
        if (!old.containsKey(field) || old[field] != value) {
          set(id, field, value);
        }
      }
    }
    for (final MapEntry(key: id, value: fields) in existing.entries) {
      if (!wanted.containsKey(id) && fields[deletedField] != true) {
        set(id, deletedField, true);
      }
    }
    store.apply(userId, changes);
  }
}

CalendarFetch _defaultFetch(http.Client client) => (source, from, to) async {
  switch (source.type) {
    case 'ics':
      final response = await client.get(source.url);
      if (response.statusCode != 200) {
        throw HttpException(
          'HTTP ${response.statusCode} fetching ${source.url}',
        );
      }
      return [
        (
          calendar: source.name,
          events: parseIcs(utf8.decode(response.bodyBytes)),
        ),
      ];
    case 'caldav':
      final caldav = CalDavClient(
        client,
        source.url,
        source.username ?? '',
        source.password ?? '',
      );
      return [
        for (final cal in await caldav.fetchEvents(from, to))
          (
            calendar: cal.name,
            events: [for (final doc in cal.ics) ...parseIcs(doc)],
          ),
      ];
    default:
      throw ArgumentError(
        'Unknown calendar type "${source.type}" (use "ics" or "caldav")',
      );
  }
};
