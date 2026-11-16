import 'dart:convert';
import 'dart:io';

import 'package:core/core.dart';
import 'package:test/test.dart';

/// Shared with the Swift tests, so both apps and the server agree.
final _fixture =
    jsonDecode(File('../../fixtures/hlc.json').readAsStringSync()) as Map;

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

  group('shared cases (fixtures/hlc.json)', () {
    test('ordering, including ties broken by device', () {
      for (final [a, b, expected] in _fixture['compare'] as List) {
        expect(
          Hlc.parse(a as String).compareTo(Hlc.parse(b as String)).sign,
          expected,
          reason: '$a vs $b',
        );
        // The packed text sorts the same way, for the server's database.
        expect(a.compareTo(b).sign, expected, reason: 'packed $a vs $b');
      }
    });

    test('send', () {
      for (final [clock, now, expected] in _fixture['send'] as List) {
        expect(Hlc.parse(clock as String).send(now as int).pack(), expected);
      }
    });

    test('receive, including a device whose date is far ahead', () {
      for (final [clock, remote, now, expected] in _fixture['receive'] as List) {
        expect(
          Hlc.parse(
            clock as String,
          ).receive(Hlc.parse(remote as String), now as int).pack(),
          expected,
          reason: '$clock receives $remote at $now',
        );
      }
    });

    test('the merge rule', () {
      for (final [incoming, current, expected] in _fixture['shouldApply'] as List) {
        Change at(String packed) => Change(
          table: 't',
          rowId: 'r',
          field: 'f',
          value: null,
          hlc: Hlc.parse(packed),
        );
        expect(
          shouldApply(
            at(incoming as String),
            current == null ? null : at(current as String),
          ),
          expected,
          reason: '$incoming over $current',
        );
      }
    });
  });
}
