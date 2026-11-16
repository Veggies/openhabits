import 'dart:async';

import 'package:core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'repo.dart';

/// Reminders, scheduled on this device (no server needed, and they work
/// offline). Matches the Apple app:
///
/// - at each habit's set time, with a Mark as done button, and
/// - a daily check-in at a time you choose, listing what's still left.
///
/// The next week of reminders is worked out whenever habits change or the
/// app opens, so a habit that's already done today doesn't nag. Which kinds
/// are on is kept per device.
class Reminders extends ChangeNotifier {
  final Repo repo;
  final _plugin = FlutterLocalNotificationsPlugin();
  Timer? _pending;
  bool _ready = false;

  Reminders(this.repo);

  /// Android and Windows can schedule reminders. (The Apple apps have their
  /// own; Linux can only show a notification while the app is open.)
  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows);

  bool get habitTimes => repo.store.meta('remindHabitTimes') == '1';
  bool get checkIn => repo.store.meta('remindCheckIn') == '1';
  String get checkInTime => repo.store.meta('remindCheckInTime') ?? '20:00';

  /// Notifications are turned off for the app in the system's settings.
  bool denied = false;

  Future<void> start() async {
    if (!supported) return;
    tzdata.initializeTimeZones();
    try {
      final local = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(local.identifier));
    } catch (_) {
      // Unknown zone: times are still right, worked out from UTC offsets.
    }
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_notification'),
        windows: WindowsInitializationSettings(
          appName: 'OpenHabits',
          appUserModelId: 'OpenHabits.App',
          guid: '6f2b5e8c-3b1d-4c4e-9a7f-2f1c0e9d8b41',
        ),
      ),
      onDidReceiveNotificationResponse: _answered,
    );
    // Tapping "Mark as done" while the app was closed starts the app, and
    // then the tap only arrives here, not through the callback above.
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      if (launch?.notificationResponse case final response?) {
        _answered(response);
      }
    }
    _ready = true;
    repo.store.addListener(refreshSoon);
    refreshSoon();
  }

  Future<void> setHabitTimes(bool on) => _set('remindHabitTimes', on);
  Future<void> setCheckIn(bool on) => _set('remindCheckIn', on);

  void setCheckInTime(String hhmm) {
    repo.store.setMeta('remindCheckInTime', hhmm);
    notifyListeners();
    refreshSoon();
  }

  Future<void> _set(String key, bool on) async {
    repo.store.setMeta(key, on ? '1' : null);
    notifyListeners();
    if (on) {
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      denied = granted == false;
      notifyListeners();
    }
    refreshSoon();
  }

  /// Reworks the schedule shortly, so a burst of changes (like a sync)
  /// only does it once.
  void refreshSoon() {
    if (!_ready) return;
    _pending?.cancel();
    _pending = Timer(const Duration(seconds: 1), refresh);
  }

  Future<void> refresh() async {
    if (!_ready) return;
    await _plugin.cancelAllPendingNotifications();
    if (!habitTimes && !checkIn) return;

    final now = DateTime.now();
    final today = dateOnly(now);
    final habits = repo.habits;
    final requests = <_Reminder>[];

    // As many days ahead as the 60 notifications kept below cover, so
    // reminders keep coming for weeks even if the app isn't opened (it
    // reschedules whenever it is). Matches Reminders.swift.
    for (var offset = 0; offset < 60; offset++) {
      final day = addDays(today, offset);
      if (habitTimes) {
        for (final h in habits) {
          if (h.isQuit || !h.remind || !h.isScheduled(day)) continue;
          if (h.plan.time.isEmpty) continue;
          final t = parseTime(h.plan.time);
          final at = DateTime(day.year, day.month, day.day, t.hour, t.minute);
          if (!at.isAfter(now) || repo.isHabitDone(h.id, day)) continue;
          requests.add((
            at: at,
            id: Object.hash(h.id, dateKey(day)) & 0x7fffffff,
            title: h.name,
            body: _habitMessage(h),
            payload: '${h.id}|${dateKey(day)}',
            isHabit: true,
          ));
        }
      }
      if (checkIn) {
        final t = parseTime(checkInTime);
        final at = DateTime(day.year, day.month, day.day, t.hour, t.minute);
        if (!at.isAfter(now)) continue;
        final left = [
          for (final h in habits)
            if (h.isScheduled(day) && !repo.isHabitDone(h.id, day)) h,
        ];
        // Nothing left today: no need to remind.
        if (offset == 0 && left.isEmpty) continue;
        requests.add((
          at: at,
          id: offset + 1,
          title: 'Time to check in on your habits',
          body: offset != 0
              ? 'Take a minute to mark off what you did today.'
              : left.length == 1
              ? "You haven't marked ${left.single.name} yet today."
              : "You haven't marked these yet today: ${_names(left)}.",
          payload: null,
          isHabit: false,
        ));
      }
    }
    requests.sort((a, b) => a.at.compareTo(b.at));
    for (final (:at, :id, :title, :body, :payload, :isHabit)
        in requests.take(60)) {
      await _plugin.zonedSchedule(
        id: id,
        scheduledDate: tz.TZDateTime.from(at, tz.local),
        title: title,
        body: body,
        payload: payload,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            isHabit ? 'habits' : 'checkin',
            isHabit ? 'Habit reminders' : 'Daily check-in',
            channelDescription: isHabit
                ? "At each habit's set time"
                : "A daily reminder of what's left to do",
            importance: Importance.high,
            priority: Priority.high,
            actions: isHabit
                ? const [
                    AndroidNotificationAction(
                      'done',
                      'Mark as done',
                      showsUserInterface: true,
                    ),
                  ]
                : null,
          ),
        ),
      );
    }
  }

  void _answered(NotificationResponse response) {
    final parts = response.payload?.split('|');
    if (response.actionId != 'done' || parts == null || parts.length != 2) {
      return;
    }
    repo.setHabitDone(parts[0], parseDateKey(parts[1]), true);
  }

  static String _habitMessage(Habit h) {
    String lower(String s) =>
        s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);
    final plan = h.plan;
    if (plan.stackAfter.isNotEmpty && plan.twoMinute.isNotEmpty) {
      return 'After you ${plan.stackAfter}, ${lower(plan.twoMinute)}.';
    }
    if (plan.twoMinute.isNotEmpty) return 'Time for ${lower(plan.twoMinute)}.';
    return "It's time for this habit.";
  }

  static String _names(List<Habit> habits) {
    final names = [for (final h in habits) h.name];
    return names.length == 1
        ? names.single
        : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }

  @override
  void dispose() {
    _pending?.cancel();
    repo.store.removeListener(refreshSoon);
    super.dispose();
  }
}

/// One notification to schedule. [payload] identifies the habit and day
/// for "Mark as done"; it's null for the daily check-in.
typedef _Reminder = ({
  DateTime at,
  int id,
  String title,
  String body,
  String? payload,
  bool isHabit,
});
