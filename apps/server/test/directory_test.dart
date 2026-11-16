import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:server/remote/directory.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('directory-test'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('the shared record matches what this server derives from its key', () {
    // fixtures/directory_record.json is also checked by the directory's
    // tests (JavaScript, WebCrypto) and both apps. If the ID or key format
    // drifted here, every address update would be refused.
    final record =
        jsonDecode(File('../../fixtures/directory_record.json').readAsStringSync())
            as Map<String, Object?>;
    final identity = DirectoryIdentity.fromPem(record['privateKeyPem'] as String);
    expect(identity.id, record['id']);
    expect(identity.publicKeyBase64Url, record['key']);
    expect((jsonDecode(record['payload'] as String) as Map)['id'], identity.id);
  });

  test('the identity is created once and kept', () {
    final first = DirectoryIdentity.loadOrCreate(dir);
    expect(first.id, matches(RegExp(r'^[a-z2-7]{26}$')));
    expect(first.publicKey, hasLength(65));
    expect(DirectoryIdentity.loadOrCreate(dir).id, first.id);
    expect(
      DirectoryIdentity.loadOrCreate(Directory.systemTemp.createTempSync()).id,
      isNot(first.id),
    );
  });

  test('signatures are raw r‖s and check out against the public key', () {
    final identity = DirectoryIdentity.loadOrCreate(dir);
    final data = utf8.encode('hello');
    final sig = identity.sign(data);
    expect(sig, hasLength(64));
    final params = CryptoUtils.ecPrivateKeyFromPem(
      File('${dir.path}/directory-key.pem').readAsStringSync(),
    ).parameters!;
    final key = ECPublicKey(
      params.curve.decodePoint(identity.publicKey),
      params,
    );
    BigInt n(List<int> b) =>
        b.fold(BigInt.zero, (v, x) => (v << 8) | BigInt.from(x));
    expect(
      CryptoUtils.ecVerify(
        key,
        Uint8List.fromList(data),
        ECSignature(n(sig.sublist(0, 32)), n(sig.sublist(32))),
        algorithm: 'SHA-256/ECDSA',
      ),
      isTrue,
    );
  });

  test('a publish carries the key, a signed payload and the time', () async {
    final identity = DirectoryIdentity.loadOrCreate(dir);
    late http.Request sent;
    final client = DirectoryClient(
      Uri.parse('https://directory.example'),
      identity,
      now: () => DateTime.fromMillisecondsSinceEpoch(1700000000000),
      client: MockClient((r) async {
        sent = r;
        return http.Response('{"ok":true}', 200);
      }),
    );
    await client.publish(['https://203.0.113.7:8443']);
    expect(sent.method, 'PUT');
    expect(sent.url.path, '/v1/servers/${identity.id}');
    final body = jsonDecode(sent.body) as Map;
    expect(jsonDecode(body['payload'] as String), {
      'id': identity.id,
      'urls': ['https://203.0.113.7:8443'],
      'ts': 1700000000000,
    });
  });

  test("the directory's reason is passed on when it refuses", () async {
    final client = DirectoryClient(
      Uri.parse('https://directory.example'),
      DirectoryIdentity.loadOrCreate(dir),
      client: MockClient(
        (_) async =>
            http.Response('{"error":"Check the server\'s clock."}', 400),
      ),
    );
    expect(
      () => client.publish(['https://203.0.113.7:8443']),
      throwsA(
        isA<HttpException>().having(
          (e) => e.message,
          'message',
          contains("clock"),
        ),
      ),
    );
  });
}
