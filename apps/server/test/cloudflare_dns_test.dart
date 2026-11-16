import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:server/remote/cloudflare_dns.dart';
import 'package:test/test.dart';

/// Just enough of Cloudflare's API: zones, and DNS records in them.
class FakeCloudflare {
  final zones = {'z1': 'example.com', 'z2': 'home.example.com'};
  final records = <Map<String, Object?>>[];
  String goodToken = 'good-token';
  final calls = <String>[];
  var _ids = 0;

  late final client = MockClient((request) async {
    calls.add('${request.method} ${request.url.path}');
    if (request.headers['authorization'] != 'Bearer $goodToken') {
      return _reply(403, {
        'success': false,
        'errors': [
          {'code': 10000, 'message': 'Authentication error'},
        ],
      });
    }
    final path = request.url.pathSegments.skip(2).toList(); // after client/v4
    if (path.length == 1 && path[0] == 'zones') {
      return _ok([
        for (final MapEntry(:key, :value) in zones.entries)
          {'id': key, 'name': value},
      ]);
    }
    if (path.length >= 3 && path[2] == 'dns_records') {
      final zone = path[1];
      if (request.method == 'GET') {
        final name = request.url.queryParameters['name'];
        return _ok([
          for (final r in records)
            if (r['zone'] == zone && r['name'] == name) r,
        ]);
      }
      final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
      if (request.method == 'POST') {
        final record = {...body, 'id': 'r${++_ids}', 'zone': zone};
        records.add(record);
        return _ok(record);
      }
      if (request.method == 'PATCH') {
        final record = records.firstWhere((r) => r['id'] == path[3]);
        record.addAll(body);
        return _ok(record);
      }
    }
    return _reply(404, {'success': false, 'errors': []});
  });

  http.Response _ok(Object? result) =>
      _reply(200, {'success': true, 'result': result});
  http.Response _reply(int status, Object body) =>
      http.Response(jsonEncode(body), status);
}

void main() {
  late FakeCloudflare cf;
  CloudflareDns dns([String token = 'good-token']) =>
      CloudflareDns(token, client: cf.client);

  setUp(() => cf = FakeCloudflare());

  test('creates a DNS-only A record when there is none', () async {
    await dns().point('habits.example.com', '203.0.113.7');
    expect(cf.records, hasLength(1));
    expect(cf.records.single, containsPair('type', 'A'));
    expect(cf.records.single, containsPair('content', '203.0.113.7'));
    expect(cf.records.single, containsPair('proxied', false));
    expect(cf.records.single, containsPair('zone', 'z1'));
  });

  test('leaves a correct record alone', () async {
    await dns().point('habits.example.com', '203.0.113.7');
    cf.calls.clear();
    await dns().point('habits.example.com', '203.0.113.7');
    expect(cf.calls.where((c) => !c.startsWith('GET')), isEmpty);
  });

  test('moves the record when the home address changes', () async {
    await dns().point('habits.example.com', '203.0.113.7');
    await dns().point('habits.example.com', '198.51.100.9');
    expect(cf.records, hasLength(1));
    expect(cf.records.single['content'], '198.51.100.9');
  });

  test("turns off Cloudflare's proxy, which would hide the server", () async {
    cf.records.add({
      'id': 'old',
      'zone': 'z1',
      'type': 'A',
      'name': 'habits.example.com',
      'content': '203.0.113.7',
      'proxied': true,
    });
    await dns().point('habits.example.com', '203.0.113.7');
    expect(cf.records.single['proxied'], false);
  });

  test('picks the most specific domain on the account', () async {
    await dns().point('habits.home.example.com', '203.0.113.7');
    expect(cf.records.single['zone'], 'z2');
  });

  test('a hostname outside the token\'s domains is explained', () async {
    expect(
      () => dns().point('habits.other.org', '203.0.113.7'),
      throwsA(
        isA<CloudflareException>().having(
          (e) => e.message,
          'message',
          contains("can't see the domain"),
        ),
      ),
    );
  });

  test('a bad token is explained', () async {
    expect(
      () => dns('wrong').point('habits.example.com', '203.0.113.7'),
      throwsA(
        isA<CloudflareException>().having(
          (e) => e.message,
          'message',
          contains('refused the token'),
        ),
      ),
    );
  });

  test("an existing CNAME isn't overwritten", () async {
    cf.records.add({
      'id': 'c',
      'zone': 'z1',
      'type': 'CNAME',
      'name': 'habits.example.com',
      'content': 'elsewhere.example.net',
    });
    expect(
      () => dns().point('habits.example.com', '203.0.113.7'),
      throwsA(isA<CloudflareException>()),
    );
    expect(cf.records.single['type'], 'CNAME');
  });
}
