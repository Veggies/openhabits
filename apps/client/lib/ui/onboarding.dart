import 'dart:math';
import 'dart:async';

import 'package:core/core.dart';
import 'package:material_ui/material_ui.dart';

import '../data/sync_engine.dart';
import 'common.dart';
import 'connect.dart';
import 'habit_editor.dart';

/// First-run setup: connect to a server (or skip), choose whether to use
/// the Atomic Habits framework, and if so build a first habit with it.
class Onboarding extends StatefulWidget {
  final VoidCallback onDone;

  /// Opened again from Settings: always asks the framework question (even
  /// though it was answered before) and skips connecting if already signed in.
  final bool replay;
  const Onboarding({super.key, required this.onDone, this.replay = false});

  @override
  State<Onboarding> createState() => _OnboardingState();
}

enum _Step { welcome, connect, framework, habit, done }

class _OnboardingState extends State<Onboarding> {
  _Step step = _Step.welcome;

  Future<void> _afterConnect() async {
    final sync = AppScope.read(context).sync;
    // Give the first sync a moment so preferences made on another device
    // (like the Atomic Habits choice) arrive before deciding what to ask.
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (sync.status == SyncStatus.syncing &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (mounted) _toFramework();
  }

  void _afterWelcome() {
    final sync = AppScope.read(context).sync;
    if (widget.replay && sync.isConfigured && sync.account != null) {
      _toFramework();
    } else {
      setState(() => step = _Step.connect);
    }
  }

  void _toFramework() {
    final answered =
        !widget.replay &&
        AppScope.read(context).repo.prefs.atomicHabits != null;
    setState(() => step = answered ? _Step.done : _Step.framework);
  }

  void _finish() {
    if (!widget.replay) {
      AppScope.read(context).repo.store.setMeta('onboarded', '1');
    }
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final page = switch (step) {
      _Step.welcome => _Welcome(onNext: _afterWelcome),
      _Step.connect => _Connect(
        onConnected: _afterConnect,
        onSkip: _toFramework,
      ),
      _Step.framework => _Framework(
        onChoice: (yes) {
          AppScope.read(context).repo.setPrefs({'atomicHabits': yes});
          setState(() => step = yes ? _Step.habit : _Step.done);
        },
      ),
      _Step.habit => _GuidedHabit(
        onDone: () => setState(() => step = _Step.done),
      ),
      _Step.done => _Done(onFinish: _finish),
    };
    return Scaffold(
      appBar: widget.replay ? AppBar() : null,
      // The scroll view fills the window (so scrolling works anywhere in it);
      // the content is centered inside it.
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, viewport) => SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: max(0, viewport.maxWidth - 48),
                minHeight: max(0, viewport.maxHeight - 48),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: KeyedSubtree(key: ValueKey(step), child: page),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _Title({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 40, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(title, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          body,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _Welcome extends StatelessWidget {
  final VoidCallback onNext;
  const _Welcome({required this.onNext});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _Title(
        icon: Icons.check_box,
        title: 'Welcome to Tasks',
        body: 'Tasks, calendar, habits and focus in one place, synced through your own server.',
      ),
      FilledButton(
        onPressed: onNext,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        child: const Text('Get started'),
      ),
    ],
  );
}

class _Connect extends StatelessWidget {
  final VoidCallback onConnected;
  final VoidCallback onSkip;
  const _Connect({required this.onConnected, required this.onSkip});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _Title(
        icon: Icons.dns_outlined,
        title: 'Connect to your server',
        body: 'Sign in to sync with your other devices. You can also do this later in Settings.',
      ),
      ConnectForm(onSignedIn: (_) => onConnected()),
      const SizedBox(height: 16),
      TextButton(
        onPressed: onSkip,
        child: const Text('Skip — use on this device only'),
      ),
    ],
  );
}

class _Framework extends StatelessWidget {
  final ValueChanged<bool> onChoice;
  const _Framework({required this.onChoice});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget law(String n, String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            child: Text(n, style: theme.textTheme.labelSmall),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$title. ',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(text: body),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Title(
          icon: Icons.auto_graph,
          title: 'Build habits with Atomic Habits?',
          body:
              "James Clear's framework: small habits, tied to who you want to become, "
              'compound into big results. It rests on four laws:',
        ),
        law(
          '1',
          'Make it obvious',
          'Decide when and where, and stack it onto something you already do.',
        ),
        law('2', 'Make it attractive', 'Pair it with something you enjoy.'),
        law('3', 'Make it easy', 'Start with a two-minute version.'),
        law(
          '4',
          'Make it satisfying',
          'Reward yourself, keep track, and try never to miss two days in a row.',
        ),
        const SizedBox(height: 8),
        Text(
          "It's optional. You can turn it on or off any time in Settings.",
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () => onChoice(true),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: const Text('Yes, walk me through my first habit'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => onChoice(false),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          child: const Text('No thanks'),
        ),
      ],
    );
  }
}

/// Builds one habit step by step, one law at a time.
class _GuidedHabit extends StatefulWidget {
  final VoidCallback onDone;
  const _GuidedHabit({required this.onDone});

  @override
  State<_GuidedHabit> createState() => _GuidedHabitState();
}

class _GuidedHabitState extends State<_GuidedHabit> {
  int page = 0;
  String icon = 'book';
  final _name = TextEditingController();
  final _plan = {
    for (final f in HabitPlan.fieldNames) f: TextEditingController(),
  };

  static const _pages = 5;

  @override
  void dispose() {
    _name.dispose();
    for (final c in _plan.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _v(String f) => _plan[f]!.text.trim();

  void _create() {
    final repo = AppScope.read(context).repo;
    repo.createHabit({
      'name': _name.text.trim(),
      'icon': icon,
      'color': listColors[3],
      'kind': 'build',
      'weekdays': [1, 2, 3, 4, 5, 6, 7],
      for (final f in HabitPlan.fieldNames) f: _v(f),
    });
    widget.onDone();
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 7, minute: 0),
    );
    if (picked != null) {
      setState(
        () => _plan['time']!.text = formatTime(picked.hour, picked.minute),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canContinue = page != 1 || _name.text.trim().isNotEmpty;

    final content = switch (page) {
      0 => [
        const _Title(
          icon: Icons.person_outline,
          title: 'Who do you want to become?',
          body: "Think about the kind of person you want to be, not just a result you want. Each time you do the habit, it's a vote for becoming that person.",
        ),
        PlanField(
          controller: _plan['identity']!,
          label: 'I am…',
          hint: 'e.g. a reader',
        ),
      ],
      1 => [
        const _Title(
          icon: Icons.bolt_outlined,
          title: 'What small habit proves it?',
          body:
              'Now make it easy. If you like, you can start with a tiny version and grow it '
              'over time. That part is up to you.',
        ),
        Row(
          children: [
            Tooltip(
              message: 'Choose icon',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () async {
                  final picked = await pickHabitIcon(
                    context,
                    selected: icon,
                    color: listColors[3],
                  );
                  if (picked != null) setState(() => icon = picked);
                },
                child: HabitAvatar(icon: icon, color: listColors[3], size: 52),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _name,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Habit',
                  hintText: 'e.g. Read',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        BuildUpFields(startWith: _plan['twoMinute']!),
      ],
      2 => [
        const _Title(
          icon: Icons.visibility_outlined,
          title: 'Make it obvious',
          body: 'Decide exactly when and where, and tie it to something you already do every day.',
        ),
        PlanField(
          controller: _plan['time']!,
          label: 'When',
          hint: 'Pick a time',
          onTap: _pickTime,
        ),
        PlanField(
          controller: _plan['location']!,
          label: 'Where',
          hint: 'e.g. On the couch',
        ),
        PlanField(
          controller: _plan['stackAfter']!,
          label: 'After I…',
          hint: 'e.g. pour my morning coffee',
        ),
      ],
      3 => [
        const _Title(
          icon: Icons.favorite_border,
          title: 'Make it attractive and satisfying',
          body: 'Pair it with something you enjoy, and give yourself a small reward right after.',
        ),
        PlanField(
          controller: _plan['bundle']!,
          label: 'Pair it with',
          hint: 'e.g. My favorite tea',
        ),
        PlanField(
          controller: _plan['reward']!,
          label: 'Reward',
          hint: 'e.g. Check off my streak',
        ),
      ],
      _ => [
        const _Title(
          icon: Icons.flag_outlined,
          title: 'Your plan',
          body: 'Here it is in one sentence:',
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_summary(context), style: theme.textTheme.titleMedium),
          ),
        ),
      ],
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(value: (page + 1) / _pages),
        const SizedBox(height: 24),
        ...content,
        const SizedBox(height: 24),
        Row(
          children: [
            if (page > 0)
              TextButton(
                onPressed: () => setState(() => page--),
                child: const Text('Back'),
              ),
            const Spacer(),
            TextButton(onPressed: widget.onDone, child: const Text('Skip')),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: !canContinue
                  ? null
                  : (page == _pages - 1
                        ? _create
                        : () => setState(() => page++)),
              child: Text(page == _pages - 1 ? 'Create habit' : 'Next'),
            ),
          ],
        ),
      ],
    );
  }

  /// "After I pour my coffee, I will read one page at 7:00 AM on the couch."
  String _summary(BuildContext context) {
    final what = (_v('twoMinute').isNotEmpty
        ? _v('twoMinute')
        : _name.text.trim());
    final parts = <String>[
      if (_v('stackAfter').isNotEmpty) 'After I ${_v('stackAfter')},',
      'I will ${what.isEmpty ? 'do my habit' : what.substring(0, 1).toLowerCase() + what.substring(1)}',
      if (_v('time').isNotEmpty) 'at ${timeLabel(context, _v('time'))}',
      if (_v('location').isNotEmpty)
        _v('location').toLowerCase().startsWith(RegExp('(in|on|at) '))
            ? _v('location')
            : 'at ${_v('location')}',
    ];
    var sentence = '${parts.join(' ')}.';
    sentence = sentence[0].toUpperCase() + sentence.substring(1);
    if (_v('identity').isNotEmpty) {
      sentence += '\n\nBecause I am ${_v('identity')}.';
    }
    return sentence;
  }
}

class _Done extends StatelessWidget {
  final VoidCallback onFinish;
  const _Done({required this.onFinish});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _Title(
        icon: Icons.celebration_outlined,
        title: "You're all set",
        body: "To add a task, just type it the way you'd say it, like \"Call mom tomorrow 5pm #family\".",
      ),
      FilledButton(
        onPressed: onFinish,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        child: const Text('Start using Tasks'),
      ),
    ],
  );
}
