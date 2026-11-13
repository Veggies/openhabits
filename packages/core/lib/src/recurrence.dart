import 'dates.dart';

enum Freq { daily, weekly, monthly, yearly }

/// How a task repeats. Stored as a compact string, e.g. `weekly;2;1,3,5`
/// (every 2 weeks on Mon, Wed, Fri).
class RepeatRule {
  final Freq freq;
  final int interval;

  /// For weekly rules: the weekdays to repeat on, using [DateTime.monday]
  /// through [DateTime.sunday]. Empty means "same weekday as the due date".
  final Set<int> weekdays;

  const RepeatRule(this.freq, {this.interval = 1, this.weekdays = const {}});

  static const weekdaysOnly = RepeatRule(
    Freq.weekly,
    weekdays: {1, 2, 3, 4, 5},
  );

  String encode() => [
    freq.name,
    interval,
    if (weekdays.isNotEmpty) (weekdays.toList()..sort()).join(','),
  ].join(';');

  static RepeatRule? decode(String? value) {
    if (value == null || value.isEmpty) return null;
    final parts = value.split(';');
    final freq = Freq.values.asNameMap()[parts[0]];
    if (freq == null) return null;
    return RepeatRule(
      freq,
      interval: parts.length > 1 ? int.tryParse(parts[1]) ?? 1 : 1,
      weekdays: parts.length > 2 && parts[2].isNotEmpty
          ? parts[2].split(',').map(int.parse).toSet()
          : const {},
    );
  }

  /// The first occurrence strictly after [from] (a date; time is ignored).
  DateTime next(DateTime from) {
    final d = dateOnly(from);
    switch (freq) {
      case Freq.daily:
        return addDays(d, interval);
      case Freq.monthly:
        return addMonths(d, interval);
      case Freq.yearly:
        return addMonths(d, 12 * interval);
      case Freq.weekly:
        if (weekdays.isEmpty) return addDays(d, 7 * interval);
        final weekStart = addDays(d, 1 - d.weekday);
        for (var i = 1; i <= 7 * interval + 7; i++) {
          final candidate = addDays(d, i);
          final weeksApart =
              daysBetween(
                weekStart,
                addDays(candidate, 1 - candidate.weekday),
              ) ~/
              7;
          if (weekdays.contains(candidate.weekday) &&
              weeksApart % interval == 0) {
            return candidate;
          }
        }
        return addDays(d, 7 * interval);
    }
  }

  String describe() {
    const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    if (freq == Freq.weekly &&
        interval == 1 &&
        weekdays.length == 5 &&
        weekdays.containsAll({1, 2, 3, 4, 5})) {
      return 'Every weekday';
    }
    final unit = switch (freq) {
      Freq.daily => 'day',
      Freq.weekly => 'week',
      Freq.monthly => 'month',
      Freq.yearly => 'year',
    };
    final base = interval == 1 ? 'Every $unit' : 'Every $interval ${unit}s';
    if (weekdays.isEmpty) return base;
    final days = (weekdays.toList()..sort()).map((d) => dayNames[d - 1]);
    return '$base on ${days.join(', ')}';
  }

  @override
  bool operator ==(Object other) =>
      other is RepeatRule && other.encode() == encode();

  @override
  int get hashCode => encode().hashCode;

  @override
  String toString() => encode();
}
