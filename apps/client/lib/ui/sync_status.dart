import 'package:material_ui/material_ui.dart';

import '../data/sync_engine.dart';
import 'common.dart';

/// A cloud icon showing how syncing is going, with the details on hover or
/// long press. Tapping it syncs now. Used in the app bar and in Settings.
class SyncStatusButton extends StatelessWidget {
  final SyncEngine sync;
  const SyncStatusButton({super.key, required this.sync});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
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
        SyncStatus.idle => (
          Icons.cloud_done,
          Colors.green,
          sync.lastSynced == null
              ? 'Connected'
              : 'Synced at ${clockLabel(context, sync.lastSynced!)}',
        ),
        SyncStatus.error => (
          Icons.cloud_off,
          scheme.error,
          sync.lastError ?? "Couldn't sync just now",
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
