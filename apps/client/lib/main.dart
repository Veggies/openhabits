import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'data/focus_controller.dart';
import 'data/local_store.dart';
import 'data/reminders.dart';
import 'data/repo.dart';
import 'data/sync_engine.dart';
import 'ui/common.dart';
import 'ui/onboarding.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  final store = LocalStore.open('${dir.path}/data.sqlite');
  final repo = Repo(store);
  final sync = SyncEngine(store)..start();
  final reminders = Reminders.supported ? (Reminders(repo)..start()) : null;
  runApp(
    App(
      repo: repo,
      sync: sync,
      focus: FocusController(repo),
      reminders: reminders,
    ),
  );
}

class App extends StatefulWidget {
  final Repo repo;
  final SyncEngine sync;
  final FocusController focus;
  final Reminders? reminders;
  const App({
    super.key,
    required this.repo,
    required this.sync,
    required this.focus,
    this.reminders,
  });

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  late final nav = AppNav(widget.repo.store);

  /// The device's own colour, for the "System" accent: the wallpaper
  /// colours on Android 12 and later, the accent colour on Windows.
  Color? systemColor;

  @override
  void initState() {
    super.initState();
    _loadSystemColor();
  }

  Future<void> _loadSystemColor() async {
    try {
      final palette = await DynamicColorPlugin.getCorePalette();
      final accent = palette != null
          ? Color(palette.primary.get(40))
          : await DynamicColorPlugin.getAccentColor();
      if (accent != null && mounted) setState(() => systemColor = accent);
    } catch (_) {
      // Not available here (tests, older systems): use the default.
    }
  }

  @override
  void dispose() {
    nav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: nav.accent,
    builder: (context, _) {
      final chosen = accentChoices.where((c) => c.$1 == nav.accent.value);
      final seed = chosen.isNotEmpty
          ? chosen.first.$3
          : systemColor ?? const Color(0xFF4772FA);
      return AppScope(
        repo: widget.repo,
        sync: widget.sync,
        focus: widget.focus,
        nav: nav,
        reminders: widget.reminders,
        child: MaterialApp(
          title: 'OpenHabits',
          debugShowCheckedModeBanner: false,
          theme: _theme(seed, Brightness.light),
          darkTheme: _theme(seed, Brightness.dark),
          home: _Root(store: widget.repo.store),
        ),
      );
    },
  );
}

ThemeData _theme(Color seed, Brightness brightness) => ThemeData(
  colorSchemeSeed: seed,
  brightness: brightness,
  // The spreading "ripple" on tap is an Android convention; elsewhere it
  // looks like a glitch, so only hover and press highlights are kept.
  splashFactory: defaultTargetPlatform == TargetPlatform.android
      ? null
      : NoSplash.splashFactory,
);

/// Shows the setup wizard until it has been completed on this device.
class _Root extends StatefulWidget {
  final LocalStore store;
  const _Root({required this.store});

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  late bool onboarded = widget.store.meta('onboarded') != null;

  @override
  Widget build(BuildContext context) => onboarded
      ? const Shell()
      : Onboarding(onDone: () => setState(() => onboarded = true));
}
