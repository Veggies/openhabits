import 'package:server/remote/upnp.dart';
import 'package:test/test.dart';

void main() {
  group("this server's address on the router's network", () {
    test('prefers the home network over Docker and VM bridges', () {
      // A Mac running OrbStack: Wi-Fi plus two virtual bridges.
      expect(
        pickLocalAddress('192.168.0.1', [
          '127.0.0.1',
          '192.168.139.3',
          '192.168.0.12',
          '192.168.215.0',
        ]),
        '192.168.0.12',
      );
    });

    test('works on other common home ranges', () {
      expect(
        pickLocalAddress('10.0.0.1', ['172.17.0.1', '10.0.0.42']),
        '10.0.0.42',
      );
    });

    test("never answers with the router's own address", () {
      expect(
        pickLocalAddress('192.168.0.1', ['192.168.0.1', '192.168.0.12']),
        '192.168.0.12',
      );
      expect(
        () => pickLocalAddress('192.168.0.1', ['127.0.0.1']),
        throwsA(isA<UpnpException>()),
      );
    });
  });
}
