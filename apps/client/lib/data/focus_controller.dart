import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'repo.dart';

enum FocusPhase { focus, rest }

/// The Pomodoro timer. Lives above the navigation so it keeps running while
/// you switch screens. Time is measured against an end timestamp rather than
/// by counting ticks, so it stays accurate if the app is suspended.
class FocusController extends ChangeNotifier {
  final Repo repo;
  Timer? _ticker;

  FocusPhase phase = FocusPhase.focus;

  /// The phase on screen. You can look at the other one while the timer
  /// runs, without stopping it.
  FocusPhase shown = FocusPhase.focus;

  /// The phase whose time ran out. Goes away after a minute, or sooner if
  /// the next one starts or it's dismissed. Nothing starts on its own, so
  /// working past the end is fine.
  FocusPhase? ended;
  Timer? _endedTimer;
  static const endedShowsFor = Duration(minutes: 1);

  Map<FocusPhase, int> minutes = {FocusPhase.focus: 25, FocusPhase.rest: 5};

  /// The habit this session is for, if one was picked.
  String? habitId;

  DateTime? _endsAt;
  DateTime? _startedAt;
  Duration? _pausedRemaining;

  final DateTime Function() _clock;

  FocusController(this.repo, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// Whether the end makes a sound. Kept per device.
  bool get playsSound => repo.store.meta('focusSound') != '0';

  set playsSound(bool on) {
    repo.store.setMeta('focusSound', on ? null : '0');
    // Lets you hear it when you turn it on.
    if (on) SystemSound.play(SystemSoundType.alert);
    notifyListeners();
  }

  bool get running => _endsAt != null;
  bool get paused => _pausedRemaining != null;

  Duration get total => Duration(minutes: minutes[phase]!);

  Duration get remaining {
    if (_pausedRemaining != null) return _pausedRemaining!;
    if (_endsAt == null) return total;
    final left = _endsAt!.difference(_clock());
    return left.isNegative ? Duration.zero : left;
  }

  double get progress => 1 - remaining.inMilliseconds / total.inMilliseconds;

  void start() {
    _clearEnded();
    _startedAt ??= _clock();
    _endsAt = _clock().add(_pausedRemaining ?? remaining);
    _pausedRemaining = null;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
    notifyListeners();
  }

  void pause() {
    if (!running) return;
    _pausedRemaining = remaining;
    _endsAt = null;
    _ticker?.cancel();
    notifyListeners();
  }

  /// Stops the timer, or clears the note that time's up.
  void reset() {
    _ticker?.cancel();
    _clearEnded();
    _endsAt = null;
    _startedAt = null;
    _pausedRemaining = null;
    notifyListeners();
  }

  /// Ends the current phase now. Skipping a focus session doesn't record it.
  void skip() => _finish(record: false);

  void _clearEnded() {
    _endedTimer?.cancel();
    ended = null;
  }

  /// Looks at a phase. While the timer is going, that's all it does.
  void show(FocusPhase p) {
    if (running || paused) {
      shown = p;
      notifyListeners();
    } else if (p != phase) {
      selectPhase(p);
    }
  }

  void selectPhase(FocusPhase p) {
    reset();
    phase = p;
    shown = p;
    notifyListeners();
  }

  void setMinutes(FocusPhase p, int value) {
    minutes = {...minutes, p: value.clamp(1, 180)};
    notifyListeners();
  }

  void selectHabit(String? id) {
    habitId = id;
    notifyListeners();
  }

  void _tick() {
    if (remaining == Duration.zero) {
      _timeRanOut();
    } else {
      notifyListeners();
    }
  }

  void _timeRanOut() {
    final finished = phase;
    // If the computer slept through the end, a late sound would only be
    // confusing.
    final onTime = _clock().difference(_endsAt!) < const Duration(seconds: 10);
    _finish(record: true);
    ended = finished;
    _endedTimer = Timer(endedShowsFor, () {
      ended = null;
      notifyListeners();
    });
    if (playsSound && onTime) SystemSound.play(SystemSoundType.alert);
    notifyListeners();
  }

  void _finish({required bool record}) {
    if (phase == FocusPhase.focus) {
      if (record && _startedAt != null) {
        repo.recordFocus(
          start: _startedAt!,
          minutes: minutes[FocusPhase.focus]!,
          habitId: habitId,
        );
      }
      phase = FocusPhase.rest;
    } else {
      phase = FocusPhase.focus;
    }
    shown = phase;
    reset();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _endedTimer?.cancel();
    super.dispose();
  }
}
