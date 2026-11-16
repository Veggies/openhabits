import 'dart:math';

/// A hybrid logical clock timestamp.
///
/// Combines wall-clock time with a counter so every edit gets a unique,
/// totally ordered timestamp, even when two devices' clocks disagree or
/// several edits happen within the same millisecond. [nodeId] identifies the
/// device and breaks any remaining ties.
class Hlc implements Comparable<Hlc> {
  final int millis;
  final int counter;
  final String nodeId;

  const Hlc(this.millis, this.counter, this.nodeId);

  const Hlc.zero(this.nodeId) : millis = 0, counter = 0;

  /// Returns the timestamp for a new local edit.
  Hlc send(int nowMillis) {
    if (nowMillis > millis) return Hlc(nowMillis, 0, nodeId);
    return Hlc(millis, counter + 1, nodeId);
  }

  /// How far ahead of this device's clock a received timestamp may be and
  /// still move the clock forward.
  static const maxDriftMillis = 24 * 60 * 60 * 1000;

  /// Advances this clock past a timestamp received from another device, so
  /// the next local edit is ordered after everything this device has seen.
  ///
  /// A timestamp more than [maxDriftMillis] ahead (a device whose date is
  /// set wrong) is still merged by the usual rule, but doesn't drag this
  /// clock into the future with it.
  Hlc receive(Hlc remote, int nowMillis) {
    if (remote.millis - nowMillis > maxDriftMillis) remote = this;
    final m = max(max(millis, remote.millis), nowMillis);
    final int c;
    if (m == millis && m == remote.millis) {
      c = max(counter, remote.counter) + 1;
    } else if (m == millis) {
      c = counter + 1;
    } else if (m == remote.millis) {
      c = remote.counter + 1;
    } else {
      c = 0;
    }
    return Hlc(m, c, nodeId);
  }

  @override
  int compareTo(Hlc other) {
    if (millis != other.millis) return millis.compareTo(other.millis);
    if (counter != other.counter) return counter.compareTo(other.counter);
    return nodeId.compareTo(other.nodeId);
  }

  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator <(Hlc other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) => other is Hlc && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(millis, counter, nodeId);

  /// Encodes as a string whose lexical order matches [compareTo], so
  /// databases can index and sort timestamps as plain text.
  String pack() =>
      '${millis.toString().padLeft(15, '0')}'
      '-${counter.toRadixString(16).padLeft(4, '0')}'
      '-$nodeId';

  static Hlc parse(String packed) {
    final first = packed.indexOf('-');
    final second = packed.indexOf('-', first + 1);
    return Hlc(
      int.parse(packed.substring(0, first)),
      int.parse(packed.substring(first + 1, second), radix: 16),
      packed.substring(second + 1),
    );
  }

  @override
  String toString() => pack();
}
