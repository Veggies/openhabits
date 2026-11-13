import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// A minimal CalDAV client: discovers a user's calendars and fetches the
/// events in a time range. Works with iCloud, Fastmail, Nextcloud and other
/// standard servers that accept basic auth.
class CalDavClient {
  final http.Client _http;
  final Uri baseUrl;
  final String username;
  final String password;

  CalDavClient(this._http, this.baseUrl, this.username, this.password);

  /// Returns each calendar's display name and raw iCalendar documents.
  Future<List<({String name, List<String> ics})>> fetchEvents(
    DateTime from,
    DateTime to,
  ) async {
    final principal = await _findHref(baseUrl, 'current-user-principal');
    final home = await _findHref(principal, 'calendar-home-set');
    final calendars = await _listCalendars(home);
    return [
      for (final cal in calendars)
        (name: cal.name, ics: await _query(cal.url, from, to)),
    ];
  }

  Future<Uri> _findHref(Uri url, String property) async {
    final xml = await _request(
      'PROPFIND',
      url,
      depth: '0',
      body:
          '''
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop><${property == 'calendar-home-set' ? 'c' : 'd'}:$property/></d:prop>
</d:propfind>''',
    );
    final prop = _elements(xml.root, property).firstOrNull;
    final href = prop == null
        ? null
        : _elements(prop, 'href').firstOrNull?.innerText.trim();
    if (href == null || href.isEmpty) {
      throw CalDavException('Server did not return $property for $url');
    }
    return url.resolve(href);
  }

  Future<List<({String name, Uri url})>> _listCalendars(Uri home) async {
    final xml = await _request(
      'PROPFIND',
      home,
      depth: '1',
      body: '''
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop><d:resourcetype/><d:displayname/><c:supported-calendar-component-set/></d:prop>
</d:propfind>''',
    );
    return [
      for (final response in _elements(xml.root, 'response'))
        if (_elements(response, 'calendar').isNotEmpty &&
            _supportsEvents(response))
          (
            name:
                _elements(
                  response,
                  'displayname',
                ).firstOrNull?.innerText.trim() ??
                'Calendar',
            url: home.resolve(
              _elements(response, 'href').first.innerText.trim(),
            ),
          ),
    ];
  }

  bool _supportsEvents(XmlElement response) {
    final comps = _elements(response, 'comp');
    // No component set means the calendar accepts everything.
    return comps.isEmpty ||
        comps.any((c) => c.getAttribute('name') == 'VEVENT');
  }

  Future<List<String>> _query(Uri calendar, DateTime from, DateTime to) async {
    String stamp(DateTime d) =>
        '${d.toUtc().toIso8601String().replaceAll(RegExp(r'[-:]'), '').split('.').first}Z';
    final xml = await _request(
      'REPORT',
      calendar,
      depth: '1',
      body:
          '''
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop><c:calendar-data/></d:prop>
  <c:filter>
    <c:comp-filter name="VCALENDAR">
      <c:comp-filter name="VEVENT">
        <c:time-range start="${stamp(from)}" end="${stamp(to)}"/>
      </c:comp-filter>
    </c:comp-filter>
  </c:filter>
</c:calendar-query>''',
    );
    return [
      for (final data in _elements(xml.root, 'calendar-data')) data.innerText,
    ];
  }

  Future<XmlDocument> _request(
    String method,
    Uri url, {
    required String depth,
    required String body,
  }) async {
    var target = url;
    // dart:io only follows redirects for GET/HEAD, and iCloud redirects
    // discovery requests to a per-account host.
    for (var hop = 0; hop < 5; hop++) {
      final request = http.Request(method, target)
        ..followRedirects = false
        ..headers.addAll({
          'Authorization':
              'Basic ${base64Encode(utf8.encode('$username:$password'))}',
          'Depth': depth,
          'Content-Type': 'application/xml; charset=utf-8',
        })
        ..body = body;
      final response = await http.Response.fromStream(
        await _http.send(request),
      );
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers['location'];
        if (location == null) break;
        target = target.resolve(location);
        continue;
      }
      if (response.statusCode == 401) {
        throw CalDavException(
          'Authentication failed for $username. For iCloud, use an app-specific password.',
        );
      }
      if (response.statusCode >= 400) {
        throw CalDavException(
          '$method $target failed: HTTP ${response.statusCode}',
        );
      }
      return XmlDocument.parse(utf8.decode(response.bodyBytes));
    }
    throw CalDavException('Too many redirects from $url');
  }
}

/// Elements below [root] with [localName], in any namespace.
Iterable<XmlElement> _elements(XmlNode root, String localName) => root
    .descendants
    .whereType<XmlElement>()
    .where((e) => e.name.local == localName);

class CalDavException implements Exception {
  final String message;
  CalDavException(this.message);

  @override
  String toString() => message;
}
