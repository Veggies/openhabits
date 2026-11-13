import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'data/focus_controller.dart';
import 'data/local_store.dart';
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
  runApp(App(repo: repo, sync: sync, focus: FocusController(repo)));
}

class App extends StatelessWidget {
  final Repo repo;
  final SyncEngine sync;
  final FocusController focus;
  const App({
    super.key,
    required this.repo,
    required this.sync,
    required this.focus,
  });

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF4772FA);
    return AppScope(
      repo: repo,
      sync: sync,
      focus: focus,
      child: MaterialApp(
        title: 'Tasks',
        debugShowCheckedModeBanner: false,
        theme: _theme(seed, Brightness.light),
        darkTheme: _theme(seed, Brightness.dark),
        home: _Root(store: repo.store),
      ),
    );
  }
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
