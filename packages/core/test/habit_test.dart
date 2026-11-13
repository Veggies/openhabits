import 'package:core/core.dart';
import 'package:test/test.dart';

// Friday 13 November 2026.
final today = DateTime(2026, 11, 13);

Habit habit({
  List<int> weekdays = const [1, 2, 3, 4, 5, 6, 7],
  String kind = 'build',
}) => Habit.fromFields('h', {
  'weekdays': weekdays,
  'kind': kind,
  'createdAt': DateTime(2026, 11, 1).toUtc().toIso8601String(),
});

bool Function(DateTime) doneOn(List<int> days) =>
    (d) => d.month == 11 && days.contains(d.day);

void main() {
  group('streaks', () {
    test('a strict streak ends at the first miss', () {
      expect(habit().streak(doneOn([10, 12, 13]), today), 2);
    });

    test('never miss twice: one miss is forgiven, two are not', () {
      final h = habit();
      // 11 missed alone: forgiven. Then 9 and 8 both missed: the streak ends.
      expect(h.streak(doneOn([5, 6, 10, 12, 13]), today, forgiving: true), 3);
      // 11 missed alone: forgiven. Then 8 and 7 in a row: ends.
      expect(h.streak(doneOn([6, 9, 10, 12, 13]), today, forgiving: true), 4);
    });

    test('streaks never count days before the habit existed', () {
      final all = doneOn(List.generate(30, (i) => i + 1));
      expect(habit().streak(all, today), 13); // Nov 1–13
    });

    test('missedLastTime flags the day after a miss', () {
      final h = habit(weekdays: [1, 3, 5]);
      expect(h.missedLastTime(doneOn([9]), today), isTrue); // Wed 11 missed
      expect(h.missedLastTime(doneOn([9, 11]), today), isFalse);
      expect(h.missedLastTime(doneOn([13]), today), isFalse); // done today
    });
  });

  test('quit habits count days since the last slip', () {
    final h = habit(kind: 'quit');
    expect(h.isQuit, isTrue);
    expect(h.isScheduled(DateTime(2026, 11, 14)), isTrue);
    expect(h.daysClean(doneOn([9]), today), 4);
    expect(h.daysClean(doneOn([]), today), 12); // since Nov 1
    expect(h.daysClean(doneOn([13]), today), 0);
  });

  test('the plan reads optional Atomic Habits fields', () {
    final h = Habit.fromFields('h', {
      'identity': 'I am a reader',
      'twoMinute': 'Read one page',
    });
    expect(h.plan.identity, 'I am a reader');
    expect(h.plan.twoMinute, 'Read one page');
    expect(h.plan.reward, '');
    expect(h.plan.isEmpty, isFalse);
    expect(Habit.fromFields('x', {}).plan.isEmpty, isTrue);
  });

  test('weeks start on Sunday by default', () {
    expect(startOfWeek(today), DateTime(2026, 11, 8));
    expect(startOfWeek(DateTime(2026, 11, 8)), DateTime(2026, 11, 8));
    expect(startOfWeek(today, DateTime.monday), DateTime(2026, 11, 9));
    expect(Prefs.fromFields(null).weekStart, DateTime.sunday);
  });
}
