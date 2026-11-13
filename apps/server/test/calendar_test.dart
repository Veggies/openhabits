import 'package:core/core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:server/calendar/caldav.dart';
import 'package:server/calendar/calendar_sync.dart';
import 'package:server/calendar/ics.dart';
import 'package:server/sync_store.dart';
import 'package:test/test.dart';
import 'package:timezone/data/latest.dart' as tz;

String calendar(String events) =>
    'BEGIN:VCALENDAR\r\nVERSION:2.0\r\n$events\r\nEND:VCALENDAR\r\n';

final windowStart = DateTime.utc(2026, 11, 1);
final windowEnd = DateTime.utc(2027, 1, 1);

List<Occurrence> expand(String ics) =>
    expandEvents(parseIcs(calendar(ics)), windowStart, windowEnd)
      ..sort((a, b) => a.start.toUtc().compareTo(b.start.toUtc()));

void main() {
  setUpAll(tz.initializeTimeZones);

  group('parsing', () {
    test('folded lines, escapes and nested alarms', () {
      final events = parseIcs(
        calendar('''
BEGIN:VEVENT
UID:1
DTSTART:20261113T150000Z
DTEND:20261113T160000Z
SUMMARY:Dentist\\, then gro
 ceries
BEGIN:VALARM
TRIGGER:-PT15M
SUMMARY:Alarm summary should be ignored
END:VALARM
END:VEVENT'''),
      );
      expect(events.single.summary, 'Dentist, then groceries');
    });

    test('TZID times convert to UTC, respecting daylight saving', () {
      final o = expand('''
BEGIN:VEVENT
UID:2
DTSTART;TZID=America/New_York:20261113T090000
DURATION:PT1H30M
SUMMARY:Standup
END:VEVENT''').single;
      expect(o.start.encode(), '2026-11-13T14:00:00.000Z'); // EST = UTC-5
      expect(o.end.encode(), '2026-11-13T15:30:00.000Z');
    });

    test('all-day events store date keys', () {
      final o = expand('''
BEGIN:VEVENT
UID:3
DTSTART;VALUE=DATE:20261120
DTEND;VALUE=DATE:20261122
SUMMARY:Trip
END:VEVENT''').single;
      expect(
        (o.start.encode(), o.end.encode(), o.start.allDay),
        ('2026-11-20', '2026-11-22', true),
      );
    });
  });

  group('recurrence', () {
    test('weekly BYDAY with COUNT, EXDATE and a moved occurrence', () {
      final list = expand('''
BEGIN:VEVENT
UID:gym
DTSTART;TZID=Europe/London:20261102T070000
DTEND;TZID=Europe/London:20261102T080000
RRULE:FREQ=WEEKLY;BYDAY=MO,TH;COUNT=6
EXDATE;TZID=Europe/London:20261105T070000
SUMMARY:Gym
END:VEVENT
BEGIN:VEVENT
UID:gym
RECURRENCE-ID;TZID=Europe/London:20261109T070000
DTSTART;TZID=Europe/London:20261109T180000
DTEND;TZID=Europe/London:20261109T190000
SUMMARY:Gym (evening)
END:VEVENT''');
      expect(
        list.map((o) => '${o.start.encode().substring(0, 16)} ${o.title}'),
        [
          '2026-11-02T07:00 Gym',
          // 5 Nov excluded
          '2026-11-09T18:00 Gym (evening)', // moved
          '2026-11-12T07:00 Gym',
          '2026-11-16T07:00 Gym',
          '2026-11-19T07:00 Gym',
        ],
      );
    });

    test('monthly on the second Tuesday, until a date', () {
      final list = expand('''
BEGIN:VEVENT
UID:board
DTSTART:20261013T170000Z
DTEND:20261013T180000Z
RRULE:FREQ=MONTHLY;BYDAY=2TU;UNTIL=20261231T000000Z
SUMMARY:Board meeting
END:VEVENT''');
      expect(list.map((o) => o.start.encode().substring(0, 10)), [
        '2026-11-10',
        '2026-12-08',
      ]);
    });

    test('a recurring event spanning the window start is included', () {
      final list = expand('''
BEGIN:VEVENT
UID:daily
DTSTART:20250101T120000Z
DTEND:20250101T121500Z
RRULE:FREQ=DAILY;INTERVAL=10
SUMMARY:Water plants
END:VEVENT''');
      expect(list.first.start.toUtc().isAfter(windowStart), isTrue);
      expect(list.length, 6); // every 10 days across November and December
    });

    test('cancelled events are dropped', () {
      expect(
        expand('''
BEGIN:VEVENT
UID:x
DTSTART:20261113T150000Z
STATUS:CANCELLED
SUMMARY:Cancelled
END:VEVENT'''),
        isEmpty,
      );
    });
  });

  group('CalendarSync', () {
    late SyncStore store;
    late List<IcsEvent> feed;
    var failing = false;

    setUp(() {
      store = SyncStore.inMemory();
      failing = false;
      feed = parseIcs(
        calendar('''
BEGIN:VEVENT
UID:a
DTSTART:20261113T150000Z
DTEND:20261113T160000Z
SUMMARY:Lunch
END:VEVENT
BEGIN:VEVENT
UID:b
DTSTART:20261114T150000Z
DTEND:20261114T160000Z
SUMMARY:Coffee
END:VEVENT'''),
      );
    });

    CalendarSync sync() => CalendarSync(
      store,
      userIdFor: (_) => 'u1',
      [
        CalendarSource.fromJson({
          'name': 'Work',
          'type': 'ics',
          'url': 'webcal://example.com/cal.ics',
        }),
      ],
      fetch: (source, from, to) async {
        if (failing) throw Exception('offline');
        return [(calendar: 'Work', events: feed)];
      },
    );

    Map<String, Map<String, Object?>> live() => {
      for (final MapEntry(:key, :value)
          in store.rows('u1', Tables.events).entries)
        if (value[deletedField] != true) key: value,
    };

    test('imports events as synced rows', () async {
      await sync().run(now: DateTime.utc(2026, 11, 13));
      expect(
        live().values.map((e) => e['title']),
        unorderedEquals(['Lunch', 'Coffee']),
      );
      expect(store.changesSince('u1', 0), isNotEmpty);
    });

    test('a second run with no changes writes nothing', () async {
      await sync().run(now: DateTime.utc(2026, 11, 13));
      final cursor = store.cursor;
      await sync().run(now: DateTime.utc(2026, 11, 13));
      expect(store.cursor, cursor);
    });

    test('events removed upstream are deleted; failures keep events', () async {
      await sync().run(now: DateTime.utc(2026, 11, 13));
      failing = true;
      final errors = await sync().run(now: DateTime.utc(2026, 11, 13));
      expect(errors.keys, ['Work']);
      expect(live(), hasLength(2));

      failing = false;
      feed = feed.where((e) => e.uid == 'a').toList();
      await sync().run(now: DateTime.utc(2026, 11, 13));
      expect(live().values.single['title'], 'Lunch');
    });

    test('server stamps order after client edits it has seen', () {
      store.apply('u1', [
        Change(
          table: 'tasks',
          rowId: 't',
          field: 'title',
          value: 'x',
          hlc: Hlc(DateTime.utc(2099).millisecondsSinceEpoch, 0, 'phone'),
        ),
      ]);
      expect(
        store.stamp() >
            Hlc(DateTime.utc(2099).millisecondsSinceEpoch, 0, 'phone'),
        isTrue,
      );
    });
  });

  test(
    'CalDAV discovery follows redirects and finds event calendars',
    () async {
      final requests = <String>[];
      final client = MockClient((request) async {
        requests.add('${request.method} ${request.url}');
        expect(request.headers['Authorization'], startsWith('Basic '));
        final url = request.url.toString();
        if (url == 'https://caldav.icloud.com/') {
          return http.Response(
            '',
            301,
            headers: {'location': 'https://p01-caldav.icloud.com/'},
          );
        }
        if (url == 'https://p01-caldav.icloud.com/') {
          return http.Response('''<?xml version="1.0"?>
<multistatus xmlns="DAV:"><response><href>/</href><propstat><prop>
<current-user-principal><href>/123/principal/</href></current-user-principal>
</prop></propstat></response></multistatus>''', 207);
        }
        if (url.endsWith('/123/principal/')) {
          return http.Response('''<?xml version="1.0"?>
<multistatus xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><response><href>/123/principal/</href><propstat><prop>
<C:calendar-home-set><href>https://p01-caldav.icloud.com/123/calendars/</href></C:calendar-home-set>
</prop></propstat></response></multistatus>''', 207);
        }
        if (url.endsWith('/123/calendars/') && request.method == 'PROPFIND') {
          return http.Response('''<?xml version="1.0"?>
<multistatus xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
<response><href>/123/calendars/</href><propstat><prop><resourcetype><collection/></resourcetype></prop></propstat></response>
<response><href>/123/calendars/home/</href><propstat><prop>
  <resourcetype><collection/><C:calendar/></resourcetype><displayname>Home</displayname>
  <C:supported-calendar-component-set><C:comp name="VEVENT"/></C:supported-calendar-component-set>
</prop></propstat></response>
<response><href>/123/calendars/reminders/</href><propstat><prop>
  <resourcetype><collection/><C:calendar/></resourcetype><displayname>Reminders</displayname>
  <C:supported-calendar-component-set><C:comp name="VTODO"/></C:supported-calendar-component-set>
</prop></propstat></response>
</multistatus>''', 207);
        }
        if (url.endsWith('/123/calendars/home/') &&
            request.method == 'REPORT') {
          expect(request.body, contains('time-range start="20261101T000000Z"'));
          return http.Response('''<?xml version="1.0"?>
<multistatus xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><response><href>/123/calendars/home/e1.ics</href>
<propstat><prop><C:calendar-data>${calendar('BEGIN:VEVENT\r\nUID:e1\r\nDTSTART:20261113T150000Z\r\nSUMMARY:Haircut\r\nEND:VEVENT')}</C:calendar-data></prop></propstat>
</response></multistatus>''', 207);
        }
        return http.Response('unexpected $url', 500);
      });

      final result = await CalDavClient(
        client,
        Uri.parse('https://caldav.icloud.com/'),
        'me@icloud.com',
        'pw',
      ).fetchEvents(windowStart, windowEnd);
      expect(result.map((c) => c.name), [
        'Home',
      ]); // the VTODO-only list is skipped
      expect(parseIcs(result.single.ics.single).single.summary, 'Haircut');
    },
  );
}
