import 'package:core/core.dart';
import 'package:test/test.dart';

void main() {
  test('daily, monthly and yearly', () {
    expect(
      const RepeatRule(Freq.daily, interval: 3).next(DateTime(2026, 11, 13)),
      DateTime(2026, 11, 16),
    );
    expect(
      const RepeatRule(Freq.monthly).next(DateTime(2026, 1, 31)),
      DateTime(2026, 2, 28),
    );
    expect(
      const RepeatRule(Freq.yearly).next(DateTime(2028, 2, 29)),
      DateTime(2029, 2, 28),
    );
  });

  test('weekly on specific days', () {
    const rule = RepeatRule(Freq.weekly, weekdays: {1, 3, 5});
    expect(
      rule.next(DateTime(2026, 11, 13)),
      DateTime(2026, 11, 16),
    ); // Fri → Mon
    expect(
      rule.next(DateTime(2026, 11, 16)),
      DateTime(2026, 11, 18),
    ); // Mon → Wed
  });

  test('every other week skips the off week', () {
    const rule = RepeatRule(Freq.weekly, interval: 2, weekdays: {2, 4});
    expect(
      rule.next(DateTime(2026, 11, 17)),
      DateTime(2026, 11, 19),
    ); // Tue → Thu
    expect(
      rule.next(DateTime(2026, 11, 19)),
      DateTime(2026, 12, 1),
    ); // Thu → Tue+2w
  });

  test('weekly across a daylight-saving change', () {
    const rule = RepeatRule(Freq.weekly, interval: 2, weekdays: {7});
    // Sunday 25 Oct 2026 → two weeks later, regardless of the clocks moving.
    expect(rule.next(DateTime(2026, 10, 25)), DateTime(2026, 11, 8));
  });

  test('encode and decode round-trip', () {
    const rule = RepeatRule(Freq.weekly, interval: 2, weekdays: {5, 1});
    expect(rule.encode(), 'weekly;2;1,5');
    expect(RepeatRule.decode(rule.encode()), rule);
    expect(RepeatRule.decode(null), isNull);
  });

  test('describe', () {
    expect(RepeatRule.weekdaysOnly.describe(), 'Every weekday');
    expect(
      const RepeatRule(Freq.daily, interval: 2).describe(),
      'Every 2 days',
    );
  });

  test('habit streaks skip unscheduled days', () {
    final habit = Habit.fromFields('h', {
      'weekdays': [1, 3, 5],
    });
    final done = {
      DateTime(2026, 11, 9),
      DateTime(2026, 11, 11),
      DateTime(2026, 11, 13),
    };
    bool isDone(DateTime d) => done.contains(d);
    expect(habit.streak(isDone, DateTime(2026, 11, 13)), 3);
    // Saturday: not scheduled, so the streak carries over.
    expect(habit.streak(isDone, DateTime(2026, 11, 14)), 3);
    // The following Monday, not yet done: still counts up to Friday.
    expect(habit.streak(isDone, DateTime(2026, 11, 16)), 3);
  });
}
