// Shared by the server tests: calls the handler the way a device or
// browser would, and reads the answer.
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

/// What shelf's server puts in a request's context: who connected.
class FakeConnection implements HttpConnectionInfo {
  @override
  final InternetAddress remoteAddress;
  FakeConnection(String ip) : remoteAddress = InternetAddress(ip);
  @override
  int get localPort => 8080;
  @override
  int get remotePort => 50000;
}

/// Sends one request to [handler] and returns the status and the JSON
/// answer (or `{'body': text}` for anything that isn't JSON). A [body]
/// that's a String is sent as-is, anything else as JSON.
Future<(int, Map<String, Object?>)> send(
  Handler handler,
  String method,
  String path, {
  Object? body,
  String? token,
  String contentType = 'application/json',
  Map<String, String> headers = const {},
  String? ip,
}) async {
  final response = await handler(
    Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: {
        ...headers,
        'authorization': ?(token == null ? null : 'Bearer $token'),
        if (body != null) 'content-type': contentType,
      },
      body: body == null ? null : (body is String ? body : jsonEncode(body)),
      context: {'shelf.io.connection_info': ?(ip == null ? null : FakeConnection(ip))},
    ),
  );
  final text = await response.readAsString();
  return (
    response.statusCode,
    text.startsWith('{')
        ? jsonDecode(text) as Map<String, Object?>
        : <String, Object?>{'body': text},
  );
}
