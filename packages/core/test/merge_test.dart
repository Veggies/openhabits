import 'dart:math';

import 'package:core/core.dart';
import 'package:test/test.dart';

Change set(String field, Object? value, int millis, [String node = 'a']) =>
    Change(
      table: 'habits',
      rowId: 't1',
      field: field,
      value: value,
      hlc: Hlc(millis, 0, node),
    );

void main() {
  test('first write to a field applies', () {
    expect(shouldApply(set('title', 'Milk', 1), null), isTrue);
  });

  test('newer edit replaces older', () {
    expect(
      shouldApply(set('title', 'Oat milk', 2), set('title', 'Milk', 1)),
      isTrue,
    );
  });

  test('older edit arriving late is ignored', () {
    expect(
      shouldApply(set('title', 'Milk', 1), set('title', 'Oat milk', 2)),
      isFalse,
    );
  });

  test('the same change delivered twice is a no-op', () {
    final c = set('title', 'Milk', 1);
    expect(shouldApply(c, c), isFalse);
  });

  test('devices converge regardless of delivery order', () {
    final changes = [
      set('title', 'Milk', 1, 'phone'),
      set('title', 'Oat milk', 3, 'laptop'),
      set('due', '2026-11-14', 2, 'phone'),
      set('title', 'Soy milk', 3, 'phone'), // same millis as laptop's edit
      set(deletedField, true, 4, 'laptop'),
      set(deletedField, false, 5, 'phone'), // restored from trash
      set('done', true, 6, 'laptop'),
    ];
    final random = Random(42);
    Map<String, Object?>? result;
    for (var i = 0; i < 50; i++) {
      final store = FieldStore();
      // Shuffle and duplicate some deliveries, as a flaky network would.
      final delivery = [...changes, ...changes.take(3)]..shuffle(random);
      delivery.forEach(store.apply);
      final row = store.row('habits', 't1');
      result ??= row;
      expect(row, result, reason: 'delivery order: $delivery');
    }
  });
}
