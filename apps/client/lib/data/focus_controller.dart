import 'dart:async';

import 'package:flutter/foundation.dart';

import 'repo.dart';

enum FocusPhase { focus, rest }

/// The Pomodoro timer. Lives above the navigation so it keeps running while
/// you switch screens. Time is measured against an end timestamp rather than
/// by counting ticks, so it stays accurate if the app is suspended.
class FocusController extends ChangeNotifier {
  final Repo repo;
  Timer? _ticker;

  FocusPhase phase = FocusPhase.focus;
  Map<FocusPhase, int> minutes = {FocusPhase.focus: 25, FocusPhase.rest: 5};

  String? taskId;

  DateTime? _endsAt;
  DateTime? _startedAt;
  Duration? _pausedRemaining;

  FocusController(this.repo);

  bool get running => _endsAt != null;
  bool get paused => _pausedRemaining != null;

  Duration get total => Duration(minutes: minutes[phase]!);

  Duration get remaining {
    if (_pausedRemaining != null) return _pausedRemaining!;
    if (_endsAt == null) return total;
    final left = _endsAt!.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  double get progress => 1 - remaining.inMilliseconds / total.inMilliseconds;

  void start() {
    _startedAt ??= DateTime.now();
    _endsAt = DateTime.now().add(_pausedRemaining ?? remaining);
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

  void reset() {
    _ticker?.cancel();
    _endsAt = null;
    _startedAt = null;
    _pausedRemaining = null;
    notifyListeners();
  }

  /// Ends the current phase now. Skipping a focus session doesn't record it.
  void skip() => _finish(record: false);

  void selectPhase(FocusPhase p) {
    reset();
    phase = p;
    notifyListeners();
  }

  void setMinutes(FocusPhase p, int value) {
    minutes = {...minutes, p: value.clamp(1, 180)};
    notifyListeners();
  }

  void selectTask(String? id) {
    taskId = id;
    notifyListeners();
  }

  void _tick() {
    if (remaining == Duration.zero) {
      _finish(record: true);
    } else {
      notifyListeners();
    }
  }

  void _finish({required bool record}) {
    if (phase == FocusPhase.focus) {
      if (record && _startedAt != null) {
        repo.recordFocus(
          start: _startedAt!,
          minutes: minutes[FocusPhase.focus]!,
          taskId: taskId,
        );
      }
      phase = FocusPhase.rest;
    } else {
      phase = FocusPhase.focus;
    }
    reset();
    onPhaseComplete?.call(phase);
  }

  /// Called with the next phase whenever one ends, e.g. to show a message.
  void Function(FocusPhase next)? onPhaseComplete;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}
