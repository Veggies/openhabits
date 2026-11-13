import 'package:core/core.dart';
import 'package:test/test.dart';

void main() {
  test('send uses wall clock when it has moved forward', () {
    expect(const Hlc(100, 5, 'a').send(200), const Hlc(200, 0, 'a'));
  });

  test('send bumps the counter when the wall clock has not moved', () {
    expect(const Hlc(100, 5, 'a').send(100), const Hlc(100, 6, 'a'));
    // A clock that jumped backwards still produces increasing timestamps.
    expect(const Hlc(100, 5, 'a').send(50), const Hlc(100, 6, 'a'));
  });

  test('receive orders the next local edit after the remote one', () {
    final local = const Hlc(100, 0, 'a');
    final remote = const Hlc(500, 3, 'b'); // b's clock is ahead
    final merged = local.receive(remote, 120);
    expect(merged.send(120) > remote, isTrue);
  });

  test('pack preserves ordering as plain strings', () {
    final stamps = [
      const Hlc(9, 0, 'z'),
      const Hlc(10, 0, 'a'),
      const Hlc(10, 15, 'a'),
      const Hlc(10, 15, 'b'),
      const Hlc(1700000000000, 0, 'a'),
    ];
    final packed = stamps.map((h) => h.pack()).toList()..shuffle();
    packed.sort();
    expect(packed.map(Hlc.parse), stamps);
  });
}
