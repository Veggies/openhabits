import 'package:material_ui/material_ui.dart';

import '../data/focus_controller.dart';
import '../data/sync_engine.dart';
import 'common.dart';
import 'focus_page.dart';
import 'habits_page.dart';
import 'settings_page.dart';

/// Top-level navigation: a rail on wide screens, a bottom bar on phones.
/// Pages stay alive in an [IndexedStack] so each keeps its state.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int index = 0;

  static const _destinations = [
    (
      Icons.local_fire_department_outlined,
      Icons.local_fire_department,
      'Habits',
    ),
    (Icons.timer_outlined, Icons.timer, 'Focus'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  static const _pages = [HabitsPage(), FocusPage(), SettingsPage()];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    AppScope.of(context).focus.onPhaseComplete = (next) {
      final message = next == FocusPhase.focus
          ? "Break's over. Ready to get back to it?"
          : "Nice work, that focus session's done. Time for a break.";
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    };
  }

  @override
  Widget build(BuildContext context) {
    final sync = AppScope.of(context).sync;
    final body = IndexedStack(index: index, children: _pages);

    if (isWide(context)) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: index,
              onDestinationSelected: (i) => setState(() => index = i),
              labelType: NavigationRailLabelType.all,
              trailing: Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _SyncIndicator(sync: sync),
                  ),
                ),
              ),
              destinations: [
                for (final (icon, selected, label) in _destinations)
                  NavigationRailDestination(
                    icon: Icon(icon),
                    selectedIcon: Icon(selected),
                    label: Text(label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() => index = i),
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        destinations: [
          for (final (icon, selected, label) in _destinations)
            NavigationDestination(
              icon: Icon(icon),
              selectedIcon: Icon(selected),
              label: label,
            ),
        ],
      ),
    );
  }
}

class _SyncIndicator extends StatelessWidget {
  final SyncEngine sync;
  const _SyncIndicator({required this.sync});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final (icon, color, tip) = switch (sync.status) {
          SyncStatus.notConfigured => (
            Icons.cloud_off,
            scheme.outline,
            'Not connected to a server',
          ),
          SyncStatus.syncing => (Icons.cloud_sync, scheme.primary, 'Syncing…'),
          SyncStatus.idle => (Icons.cloud_done, Colors.green, 'Synced'),
          SyncStatus.error => (
            Icons.cloud_off,
            scheme.error,
            sync.lastError ?? 'Sync failed',
          ),
          SyncStatus.signedOut => (
            Icons.cloud_off,
            scheme.error,
            "You've been signed out. Sign back in from Settings to keep syncing.",
          ),
        };
        return IconButton(
          tooltip: tip,
          icon: Icon(icon, color: color),
          onPressed: sync.syncNow,
        );
      },
    );
  }
}
