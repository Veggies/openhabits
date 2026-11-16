// Writes fixtures/directory_record.json: a directory record signed by this
// server's real signing code, with a fresh test-only key. Run from
// apps/server with `fvm dart run tool/make_directory_record.dart`, then run
// every suite that reads it (see fixtures/README.md).
import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:server/remote/directory.dart';

void main() {
  final pair = CryptoUtils.generateEcKeyPair();
  final pem = CryptoUtils.encodeEcPrivateKeyToPem(
    pair.privateKey as ECPrivateKey,
  );
  final identity = DirectoryIdentity.fromPem(pem);
  final payload = jsonEncode({
    'id': identity.id,
    'urls': ['https://203.0.113.7:8443'],
    // Fixed, so the record never changes between runs of the tests.
    'ts': 1794816000000,
  });
  final sig = base64Url
      .encode(identity.sign(utf8.encode(payload)))
      .replaceAll('=', '');
  File('../../fixtures/directory_record.json').writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({
      'about': 'A directory record signed by the Dart server. The server, the directory and both apps check it the same way. Test-only key.',
      'privateKeyPem': pem,
      'key': identity.publicKeyBase64Url,
      'id': identity.id,
      'payload': payload,
      'sig': sig,
    })}\n',
  );
}
