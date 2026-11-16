// What the app trusts: certificates when away from home, and the
// addresses the directory hands back. Run against a real TLS server and a
// record the Dart server really signed, not fakes.
import 'dart:convert';
import 'dart:io';

import 'package:client/data/directory_record.dart';
import 'package:client/data/local_store.dart';
import 'package:client/data/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:server/remote/tls.dart';

/// Signed by the server's DirectoryIdentity; also checked by the
/// directory's tests and the Swift tests.
final _record =
    jsonDecode(File('../../fixtures/directory_record.json').readAsStringSync())
        as Map<String, Object?>;

void main() {
  group('directory records', () {
    Map<String, Object?> answer({String? payload}) => {
      'urls': ['https://evil.example'], // unsigned, and ignored
      'payload': payload ?? _record['payload'],
      'sig': _record['sig'],
    };

    test('a record the server signed gives its addresses', () {
      final record = DirectoryRecord.verify(
        answer(),
        key: _record['key'] as String,
        id: _record['id'] as String,
      );
      expect(record?.urls, ['https://203.0.113.7:8443']);
    });

    test('a changed record, another server\'s, or an old one is refused', () {
      final key = _record['key'] as String;
      final id = _record['id'] as String;
      final tampered = (_record['payload'] as String).replaceAll(
        '203.0.113.7',
        '198.51.100.66',
      );
      expect(
        DirectoryRecord.verify(answer(payload: tampered), key: key, id: id),
        isNull,
      );
      expect(
        DirectoryRecord.verify(answer(), key: key, id: 'someone-else'),
        isNull,
      );
      final ts = (jsonDecode(_record['payload'] as String) as Map)['ts'] as int;
      expect(
        DirectoryRecord.verify(answer(), key: key, id: id, notBefore: ts + 1),
        isNull,
      );
      expect(
        DirectoryRecord.verify({'urls': ['https://x.example']}, key: key, id: id),
        isNull,
      );
    });
  });

  group('the server\'s own certificate', () {
    late HttpServer server;
    late ServerCertificate certificate;
    late String url;

    setUpAll(() async {
      final dir = Directory.systemTemp.createTempSync('tls');
      addTearDown(() => dir.deleteSync(recursive: true));
      certificate = ServerCertificate.loadOrCreate(dir);
      server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        certificate.securityContext,
      );
      server.listen((request) {
        request.response
          // A new connection, and so a new certificate check, every time.
          ..persistentConnection = false
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'name': 'Home'}))
          ..close();
      });
      url = 'https://127.0.0.1:${server.port}';
    });

    tearDownAll(() => server.close(force: true));

    test('is refused until the person confirms its security code', () async {
      final sync = SyncEngine(LocalStore.inMemory(), deviceName: 'Test');
      await expectLater(
        sync.serverInfo(url),
        throwsA(
          isA<UntrustedServerException>().having(
            (e) => e.fingerprint,
            'fingerprint',
            certificate.fingerprint,
          ),
        ),
      );
      sync.trustCertificate(certificate.fingerprint, url: url);
      expect((await sync.serverInfo(url)).name, 'Home');
      sync.dispose();
    });

    test('an approval only counts for the address it was given for', () async {
      final sync = SyncEngine(LocalStore.inMemory(), deviceName: 'Test');
      sync.trustCertificate(
        certificate.fingerprint,
        url: 'https://somewhere-else.example',
      );
      await expectLater(
        sync.serverInfo(url),
        throwsA(isA<UntrustedServerException>()),
      );
      sync.dispose();
    });

    test("an approval is forgotten when sign-in doesn't work", () async {
      final sync = SyncEngine(LocalStore.inMemory(), deviceName: 'Test');
      sync.trustCertificate(certificate.fingerprint, url: url);
      // This test server isn't a real one, so signing in fails.
      await expectLater(sync.signIn(url, 'ryan', 'pw'), throwsA(anything));
      await expectLater(
        sync.serverInfo(url),
        throwsA(isA<UntrustedServerException>()),
      );
      expect(sync.store.meta('fingerprint'), isNull);
      sync.dispose();
    });

    test('a pinned certificate is accepted, a different one isn\'t', () async {
      final pinned = LocalStore.inMemory()
        ..setMeta('fingerprint', certificate.fingerprint);
      final sync = SyncEngine(pinned, deviceName: 'Test');
      expect((await sync.serverInfo(url)).name, 'Home');
      sync.dispose();

      final other = LocalStore.inMemory()
        ..setMeta('fingerprint', 'AA:BB:CC:DD:EE:FF:00:11');
      final wrong = SyncEngine(other, deviceName: 'Test');
      await expectLater(
        wrong.serverInfo(url),
        throwsA(isA<UntrustedServerException>()),
      );
      wrong.dispose();
    });
  });
}
