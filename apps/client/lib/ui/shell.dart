import 'package:material_ui/material_ui.dart';

import '../data/focus_controller.dart';
import '../data/sync_engine.dart';
import 'atomic_pages.dart';
import 'common.dart';
import 'sync_status.dart';
import 'focus_page.dart';
import 'growth_chart.dart';
import 'habits_page.dart';
import 'settings_page.dart';
import 'tasks_page.dart';

/// Top-level navigation, matching the Apple app: a bottom bar in a narrow
/// window, with Settings behind a gear on Habits so the bar fits five tabs,
/// and on computers the tabs across the top of the window with Settings
/// behind a gear. Pages stay alive in an [IndexedStack] so each keeps its
/// state.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  static const _destinations = [
    (AppTab.habits, Icons.checklist_outlined, Icons.checklist, 'Habits'),
    (AppTab.tasks, Icons.check_circle_outline, Icons.check_circle, 'Tasks'),
    (AppTab.progress, Icons.grid_view_outlined, Icons.grid_view, 'Progress'),
    (AppTab.reflect, Icons.menu_book_outlined, Icons.menu_book, 'Reflect'),
    (AppTab.focus, Icons.timer_outlined, Icons.timer, 'Focus'),
  ];

  static const _pages = [
    HabitsPage(),
    TasksPage(),
    ProgressPage(),
    ReflectPage(),
    FocusPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final nav = scope.nav;
    return ListenableBuilder(
      listenable: nav,
      builder: (context, _) {
        final index = AppTab.values.indexOf(nav.tab);
        final body = IndexedStack(index: index, children: _pages);

        if (isWide(context)) {
          return Scaffold(
            body: Column(
              children: [
                _TopBar(nav: nav, sync: scope.sync),
                const Divider(height: 1),
                Expanded(child: body),
              ],
            ),
          );
        }
        return Scaffold(
          body: body,
          bottomNavigationBar: NavigationBar(
            // Settings isn't in the bar. If it was left open in a wide
            // window that's since been made narrow, Habits stays lit, since
            // its gear leads there.
            selectedIndex: nav.tab == AppTab.settings ? 0 : index,
            onDestinationSelected: (i) => nav.go(AppTab.values[i]),
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: [
              for (final (tab, icon, selected, label) in _destinations)
                NavigationDestination(
                  icon: tab == AppTab.focus
                      ? _EndedDot(Icon(icon))
                      : Icon(icon),
                  selectedIcon: Icon(selected),
                  label: label,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// A small dot on the Focus tab while there's a note that time's up.
class _EndedDot extends StatelessWidget {
  final Widget icon;
  const _EndedDot(this.icon);

  @override
  Widget build(BuildContext context) {
    final focus = AppScope.of(context).focus;
    return ListenableBuilder(
      listenable: focus,
      builder: (context, _) =>
          Badge(isLabelVisible: focus.ended != null, child: icon),
    );
  }
}

/// The computer layout's top bar: the tabs in the middle, and the sync
/// status and Settings on the right. It's the same on every screen, so it
/// never shifts as you move around.
class _TopBar extends StatelessWidget {
  final AppNav nav;
  final SyncEngine sync;
  const _TopBar({required this.nav, required this.sync});

  @override
  Widget build(BuildContext context) {
    final focus = AppScope.of(context).focus;
    // Full width, so the buttons on the right sit at the window's edge
    // rather than on top of the last tab.
    return SizedBox(
      height: 60,
      width: double.infinity,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SegmentedButton<AppTab>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: AppTab.habits, label: Text('Today')),
              ButtonSegment(value: AppTab.tasks, label: Text('Tasks')),
              ButtonSegment(value: AppTab.progress, label: Text('Progress')),
              ButtonSegment(value: AppTab.reflect, label: Text('Reflect')),
              ButtonSegment(value: AppTab.focus, label: Text('Focus')),
            ],
            // Settings isn't a tab here, so no segment is picked while it's open.
            emptySelectionAllowed: true,
            selected: {if (nav.tab != AppTab.settings) nav.tab},
            onSelectionChanged: (s) {
              if (s.isNotEmpty) nav.go(s.first);
            },
          ),
          Positioned(
            left: 16,
            child: ListenableBuilder(
              listenable: focus,
              builder: (context, _) =>
                  (focus.running || focus.paused || focus.ended != null) &&
                      nav.tab != AppTab.focus
                  ? TextButton.icon(
                      icon: Icon(focus.paused ? Icons.pause : Icons.timer),
                      label: Text(
                        switch (focus.ended) {
                          FocusPhase.focus => "Time's up",
                          FocusPhase.rest => "Break's over",
                          null => _clock(focus.remaining),
                        },
                        style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      onPressed: () => nav.go(AppTab.focus),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          Positioned(
            right: 12,
            child: Row(
              children: [
                SyncStatusButton(sync: sync),
                IconButton(
                  tooltip: 'Settings',
                  isSelected: nav.tab == AppTab.settings,
                  icon: const Icon(Icons.settings_outlined),
                  selectedIcon: const Icon(Icons.settings),
                  onPressed: () => nav.go(AppTab.settings),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _clock(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}

/// The Progress tab.
class ProgressPage extends StatelessWidget {
  const ProgressPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: isWide(context) ? null : AppBar(title: const Text('Progress')),
    body: const GrowthView(),
  );
}

/// The Reflect tab: the weekly review and the scorecard, with a switch
/// between them.
class ReflectPage extends StatelessWidget {
  const ReflectPage({super.key});

  @override
  Widget build(BuildContext context) {
    final nav = AppScope.of(context).nav;
    return ListenableBuilder(
      listenable: nav,
      builder: (context, _) {
        final picker = SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, label: Text('Weekly review')),
            ButtonSegment(value: true, label: Text('Scorecard')),
          ],
          selected: {nav.scorecard},
          onSelectionChanged: (s) => nav.showScorecard(s.first),
        );
        return Scaffold(
          appBar: isWide(context) ? null : AppBar(title: const Text('Reflect')),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: picker,
              ),
              Expanded(
                child: nav.scorecard
                    ? const ScorecardView()
                    : const WeeklyReviewView(),
              ),
            ],
          ),
        );
      },
    );
  }
}
