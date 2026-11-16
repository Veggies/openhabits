import 'dart:convert';

import 'package:http/http.dart' as http;

/// A problem talking to Cloudflare, worded for the person reading the setup
/// page.
class CloudflareException implements Exception {
  final String message;
  const CloudflareException(this.message);

  @override
  String toString() => message;
}

/// Keeps one DNS record on Cloudflare pointed at this home: dynamic DNS
/// built into the server, so there's no separate updater to run.
///
/// The token only needs the "Edit zone DNS" permission for one domain.
class CloudflareDns {
  final String token;
  final http.Client _http;
  static final _api = Uri.parse('https://api.cloudflare.com/client/v4/');

  CloudflareDns(this.token, {http.Client? client})
    : _http = client ?? http.Client();

  /// Makes [host] an A record for [ip], "DNS only" (not proxied, so devices
  /// reach the server directly and its own certificate is used). Creates
  /// the record if it's missing and leaves it alone if it's already right.
  Future<void> point(String host, String ip) async {
    final zone = await _zoneFor(host);
    final records = await _get('zones/${zone.id}/dns_records', {'name': host});
    final existing = records.cast<Map<String, Object?>>();

    final other = existing.where((r) => r['type'] != 'A').firstOrNull;
    if (other != null) {
      throw CloudflareException(
        '$host already has a ${other['type']} record on Cloudflare. Delete it, '
        'or pick a different hostname, and OpenHabits will create the right one.',
      );
    }

    final body = {
      'type': 'A',
      'name': host,
      'content': ip,
      'proxied': false,
      'ttl': 60,
      'comment': 'Kept up to date by OpenHabits',
    };
    final a = existing.firstOrNull;
    if (a == null) {
      await _send('POST', 'zones/${zone.id}/dns_records', body);
    } else if (a['content'] != ip || a['proxied'] == true) {
      await _send('PATCH', 'zones/${zone.id}/dns_records/${a['id']}', body);
    }
  }

  /// The domain on this account that [host] belongs to: the longest zone
  /// name it ends with, so habits.example.co.uk finds example.co.uk.
  Future<({String id, String name})> _zoneFor(String host) async {
    final zones = (await _get('zones', {'per_page': '50'}))
        .cast<Map<String, Object?>>()
        .map((z) => (id: z['id'] as String, name: z['name'] as String))
        .where((z) => host == z.name || host.endsWith('.${z.name}'))
        .toList();
    if (zones.isEmpty) {
      throw CloudflareException(
        "This Cloudflare token can't see the domain $host belongs to. "
        'Create the token for that domain (Zone Resources → your domain).',
      );
    }
    zones.sort((a, b) => b.name.length.compareTo(a.name.length));
    return zones.first;
  }

  Future<List<Object?>> _get(String path, Map<String, String> query) async {
    final result = await _send('GET', path, null, query);
    return result as List<Object?>;
  }

  Future<Object?> _send(
    String method,
    String path, [
    Map<String, Object?>? body,
    Map<String, String>? query,
  ]) async {
    final request = http.Request(
      method,
      _api.resolve(path).replace(queryParameters: query),
    );
    request.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _http.send(request).timeout(const Duration(seconds: 10)),
      );
    } catch (_) {
      throw const CloudflareException(
        "Couldn't reach Cloudflare to update your hostname. "
        "We'll try again in a few minutes.",
      );
    }

    Map<String, Object?> json;
    try {
      json = (jsonDecode(response.body) as Map).cast<String, Object?>();
    } catch (_) {
      json = const {};
    }
    if (response.statusCode == 200 && json['success'] == true) {
      return json['result'];
    }
    if (response.statusCode == 401 ||
        response.statusCode == 403 ||
        _codes(json).any(_authCodes.contains)) {
      throw const CloudflareException(
        'Cloudflare refused the token. Check it was copied in full, '
        "hasn't expired, and was made from the \"Edit zone DNS\" template.",
      );
    }
    final reason = (json['errors'] as List?)
        ?.map((e) => (e as Map)['message'])
        .whereType<String>()
        .join('; ');
    throw CloudflareException(
      'Cloudflare couldn\'t update the record'
      '${reason == null || reason.isEmpty ? ' (error ${response.statusCode})' : ': $reason'}.',
    );
  }

  /// Cloudflare's "this token can't do that" error codes.
  static const _authCodes = {6003, 9109, 10000};

  static Iterable<int> _codes(Map<String, Object?> json) =>
      ((json['errors'] as List?) ?? const [])
          .map((e) => (e as Map)['code'])
          .whereType<int>();
}
