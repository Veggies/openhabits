import 'package:core/core.dart';
import 'package:test/test.dart';

// Friday 13 November 2026, 10:00.
final now = DateTime(2026, 11, 13, 10);

QuickAdd parse(String s) => parseQuickAdd(s, now);

void main() {
  test('plain text is all title', () {
    final q = parse('Buy milk');
    expect(q.title, 'Buy milk');
    expect(q.dueDate, isNull);
  });

  test('the full example', () {
    final q = parse('Call mom tomorrow 5pm #family !high ^Personal');
    expect(q.title, 'Call mom');
    expect(q.dueDate, DateTime(2026, 11, 14));
    expect(q.dueTime, '17:00');
    expect(q.tags, ['family']);
    expect(q.priority, Priority.high);
    expect(q.listName, 'Personal');
  });

  group('dates', () {
    test('today and tomorrow', () {
      expect(parse('x today').dueDate, DateTime(2026, 11, 13));
      expect(parse('x tmr').dueDate, DateTime(2026, 11, 14));
    });

    test('a weekday is the next one, including today', () {
      expect(parse('x monday').dueDate, DateTime(2026, 11, 16));
      expect(parse('x fri').dueDate, DateTime(2026, 11, 13));
      expect(parse('x next fri').dueDate, DateTime(2026, 11, 20));
      expect(parse('x on tuesday').dueDate, DateTime(2026, 11, 17));
    });

    test('next week means next Monday', () {
      expect(parse('x next week').dueDate, DateTime(2026, 11, 16));
    });

    test('relative offsets', () {
      expect(parse('x in 3 days').dueDate, DateTime(2026, 11, 16));
      expect(parse('x in 2 weeks').dueDate, DateTime(2026, 11, 27));
      expect(parse('x in 1 month').dueDate, DateTime(2026, 12, 13));
    });

    test('month and day, rolling past dates into next year', () {
      expect(parse('x nov 20').dueDate, DateTime(2026, 11, 20));
      expect(parse('x 3rd january').dueDate, DateTime(2027, 1, 3));
      expect(parse('x 11/20').dueDate, DateTime(2026, 11, 20));
      expect(parse('x 2027-02-01').dueDate, DateTime(2027, 2, 1));
    });
  });

  group('times', () {
    test('12-hour and 24-hour', () {
      expect(parse('x 5pm').dueTime, '17:00');
      expect(parse('x at 9:30am').dueTime, '09:30');
      expect(parse('x 12am').dueTime, '00:00');
      expect(parse('x 12pm').dueTime, '12:00');
      expect(parse('x 5 pm').dueTime, '17:00');
      expect(parse('x 14:45').dueTime, '14:45');
      expect(parse('x noon').dueTime, '12:00');
    });

    test('a time alone means today', () {
      expect(parse('x 5pm').dueDate, DateTime(2026, 11, 13));
    });

    test('"at" without a time stays in the title', () {
      expect(parse('Meet at the cafe').title, 'Meet at the cafe');
    });

    test('bare numbers are not times', () {
      expect(parse('Buy 5 apples').title, 'Buy 5 apples');
    });
  });

  group('repeats', () {
    test('simple frequencies start today', () {
      final q = parse('Stretch every day');
      expect(q.title, 'Stretch');
      expect(q.repeat, const RepeatRule(Freq.daily));
      expect(q.dueDate, DateTime(2026, 11, 13));
      expect(parse('x monthly').repeat, const RepeatRule(Freq.monthly));
    });

    test('intervals', () {
      expect(
        parse('x every 2 weeks').repeat,
        const RepeatRule(Freq.weekly, interval: 2),
      );
    });

    test('specific weekdays start on the first match', () {
      final q = parse('Gym every mon wed and fri 7am');
      expect(q.title, 'Gym');
      expect(q.repeat, const RepeatRule(Freq.weekly, weekdays: {1, 3, 5}));
      expect(q.dueDate, DateTime(2026, 11, 13)); // today is Friday
      expect(q.dueTime, '07:00');
    });

    test('every weekday', () {
      expect(parse('x every weekday').repeat, RepeatRule.weekdaysOnly);
    });
  });
}
