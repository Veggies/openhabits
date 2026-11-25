import 'dart:math';

import 'package:core/core.dart';
import 'package:material_ui/material_ui.dart';

import '../data/focus_controller.dart';
import '../data/local_store.dart';
import '../data/reminders.dart';
import '../data/repo.dart';
import '../data/sync_engine.dart';

/// App-wide services, available to every screen via [AppScope.of].
class AppScope extends InheritedWidget {
  final Repo repo;
  final SyncEngine sync;
  final FocusController focus;
  final AppNav nav;

  /// Null where reminders can't be scheduled (and in tests).
  final Reminders? reminders;

  const AppScope({
    super.key,
    required this.repo,
    required this.sync,
    required this.focus,
    required this.nav,
    this.reminders,
    required super.child,
  });

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  /// Like [of], but safe to call from `initState`.
  static AppScope read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope oldWidget) => false;
}

/// The main screens.
enum AppTab { habits, progress, reflect, focus, settings }

/// Navigation state that menus and links anywhere can change: which tab is
/// showing, which habit is open in the desktop preview, and the accent
/// colour (kept per device).
class AppNav extends ChangeNotifier {
  final LocalStore store;
  AppNav(this.store);

  AppTab tab = AppTab.habits;

  /// The habit whose page is open over the list (wide screens).
  String? preview;

  /// Reflect shows the scorecard instead of the weekly review.
  bool scorecard = false;

  void go(AppTab next) {
    tab = next;
    notifyListeners();
  }

  void openPreview(String? habitId) {
    preview = habitId;
    notifyListeners();
  }

  void showScorecard(bool value) {
    scorecard = value;
    notifyListeners();
  }

  /// "system", or one of [accentChoices]. Has its own notifier, since
  /// changing it rebuilds the whole app.
  late final ValueNotifier<String> accent = ValueNotifier(
    store.meta('accent') ?? 'system',
  )..addListener(() => store.setMeta('accent', accent.value));

  /// "system", "light" or "dark". Rebuilds the whole app, like [accent].
  late final ValueNotifier<String> appearance = ValueNotifier(
    store.meta('appearance') ?? 'system',
  )..addListener(() => store.setMeta('appearance', appearance.value));

  /// Starts a pomodoro for [habit] and shows the timer.
  void focusOn(Habit habit, FocusController focus) {
    if (focus.running || focus.paused) {
      focus.selectHabit(habit.id);
      focus.show(focus.phase);
    } else {
      focus.selectPhase(FocusPhase.focus);
      focus.selectHabit(habit.id);
      focus.start();
    }
    preview = null;
    go(AppTab.focus);
  }
}

/// Accent colours to choose from. "System" follows the device: the
/// wallpaper colours on Android (Material You), the accent colour on
/// Windows, and blue elsewhere.
const accentChoices = <(String, String, Color)>[
  ('blue', 'Blue', Color(0xFF007AFF)),
  ('purple', 'Purple', Color(0xFFAF52DE)),
  ('pink', 'Pink', Color(0xFFFF2D55)),
  ('red', 'Red', Color(0xFFFF3B30)),
  ('orange', 'Orange', Color(0xFFFF9500)),
  ('yellow', 'Yellow', Color(0xFFFFCC00)),
  ('green', 'Green', Color(0xFF34C759)),
  ('mint', 'Mint', Color(0xFF00C7BE)),
  ('teal', 'Teal', Color(0xFF30B0C7)),
  ('indigo', 'Indigo', Color(0xFF5856D6)),
  ('graphite', 'Graphite', Color(0xFF8E8E93)),
];

/// Rebuilds whenever local data changes (local edits or synced changes).
class DataBuilder extends StatelessWidget {
  final Widget Function(BuildContext context, Repo repo) builder;
  const DataBuilder({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    return ListenableBuilder(
      listenable: repo.store,
      builder: (context, _) => builder(context, repo),
    );
  }
}

const listColors = [
  0xFF4772FA,
  0xFFE5534B,
  0xFFF0A020,
  0xFF3DAE5C,
  0xFF8E5CD9,
  0xFFE05FA0,
  0xFF2BB3C0,
  0xFF7A8794,
];

const _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const monthNamesLong = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String weekdayShort(int weekday) => _weekdayNames[weekday - 1];

String monthShort(int month) => _monthNames[month - 1];

/// Weekday numbers in display order for weeks starting on [first].
List<int> weekdayOrder(int first) => [
  for (var i = 0; i < 7; i++) (first - 1 + i) % 7 + 1,
];

/// Icons for habits, keyed by the name stored on the habit.
const habitIcons = <String, IconData>{
  'check': Icons.check_circle_outline,
  'book': Icons.menu_book,
  'run': Icons.directions_run,
  'walk': Icons.directions_walk,
  'bike': Icons.directions_bike,
  'gym': Icons.fitness_center,
  'yoga': Icons.self_improvement,
  'water': Icons.water_drop_outlined,
  'sleep': Icons.bedtime_outlined,
  'sun': Icons.wb_sunny_outlined,
  'food': Icons.restaurant,
  'fruit': Icons.eco_outlined,
  'pill': Icons.medication_outlined,
  'tooth': Icons.clean_hands_outlined,
  'journal': Icons.edit_note,
  'write': Icons.create_outlined,
  'study': Icons.school_outlined,
  'language': Icons.translate,
  'code': Icons.code,
  'music': Icons.music_note,
  'art': Icons.brush_outlined,
  'camera': Icons.photo_camera_outlined,
  'money': Icons.savings_outlined,
  'clean': Icons.cleaning_services_outlined,
  'plant': Icons.local_florist_outlined,
  'pet': Icons.pets,
  'call': Icons.call_outlined,
  'family': Icons.people_outline,
  'heart': Icons.favorite_border,
  'pray': Icons.spa_outlined,
  'focus': Icons.center_focus_strong_outlined,
  'no-phone': Icons.phonelink_off,
  'no-smoking': Icons.smoke_free,
  'no-alcohol': Icons.no_drinks_outlined,
  'no-sugar': Icons.no_food_outlined,
  'no-tv': Icons.tv_off_outlined,
};

/// A habit's icon is either one of [habitIcons] (stored by its key) or any
/// single emoji, stored as itself. Matches the Apple app.
bool isEmojiIcon(String icon) =>
    icon.isNotEmpty &&
    !habitIcons.containsKey(icon) &&
    icon.characters.length == 1 &&
    icon.runes.first >= 0x2000;

/// Just the icon: a symbol in the habit's colour, or the emoji itself.
class HabitGlyph extends StatelessWidget {
  final String icon;
  final int color;
  final double size;
  const HabitGlyph({
    super.key,
    required this.icon,
    required this.color,
    this.size = 22,
  });

  @override
  Widget build(BuildContext context) => isEmojiIcon(icon)
      ? Text(icon, style: TextStyle(fontSize: size * 0.95, height: 1.1))
      : Icon(habitIcon(icon), color: Color(color), size: size);
}

IconData habitIcon(String name) =>
    habitIcons[name] ?? Icons.check_circle_outline;

String shortDate(DateTime d) => '${_monthNames[d.month - 1]} ${d.day}';

const _weekdayNamesLong = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// "Sunday, November 15".
String fullDate(DateTime d) =>
    '${_weekdayNamesLong[d.weekday - 1]}, ${monthNamesLong[d.month - 1]} ${d.day}';

/// "Today", "Tomorrow", "Yesterday", "Mon", or "Nov 20" (with the year if
/// it isn't this year).
String relativeDate(DateTime d, DateTime now) {
  final diff = daysBetween(now, d);
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  if (diff > 1 && diff < 7) return weekdayShort(d.weekday);
  return d.year == now.year ? shortDate(d) : '${shortDate(d)}, ${d.year}';
}

String timeLabel(BuildContext context, String hhmm) {
  final t = parseTime(hhmm);
  return TimeOfDay(hour: t.hour, minute: t.minute).format(context);
}

String clockLabel(BuildContext context, DateTime d) =>
    TimeOfDay.fromDateTime(d).format(context);

/// True when the layout has room for side-by-side panes.
bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= 840;

Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = '',
  String action = 'Save',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: Text(action),
        ),
      ],
    ),
  );
}

class ColorDot extends StatelessWidget {
  final int color;
  final double size;
  const ColorDot(this.color, {super.key, this.size = 10});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: Color(color), shape: BoxShape.circle),
  );
}

class ColorPicker extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onChanged;
  const ColorPicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final c in listColors)
        InkWell(
          onTap: () => onChanged(c),
          customBorder: const CircleBorder(),
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: Color(c),
              shape: BoxShape.circle,
              border: c == selected
                  ? Border.all(
                      color: Theme.of(context).colorScheme.onSurface,
                      width: 2.5,
                    )
                  : null,
            ),
          ),
        ),
    ],
  );
}

/// A list whose content is centered at a readable [maxWidth], but which
/// scrolls across the full width: the mouse wheel works anywhere in the
/// window, and the scrollbar sits at the window's edge.
class CenteredListView extends StatelessWidget {
  final double maxWidth;
  final EdgeInsets padding;
  final List<Widget> children;
  const CenteredListView({
    super.key,
    required this.maxWidth,
    this.padding = EdgeInsets.zero,
    required this.children,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final side = max(0.0, (constraints.maxWidth - maxWidth) / 2);
      return ListView(
        padding:
            padding.add(EdgeInsets.symmetric(horizontal: side)) as EdgeInsets,
        children: children,
      );
    },
  );
}
