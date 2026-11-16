import 'dart:math';
import 'dart:async';

import 'package:core/core.dart';
import 'package:material_ui/material_ui.dart';

import '../data/sync_engine.dart';
import 'common.dart';
import 'connect.dart';
import 'habit_editor.dart';

/// First-run setup: connect to a server (or skip), take the tour of how
/// the app uses Atomic Habits, and build a first habit.
class Onboarding extends StatefulWidget {
  final VoidCallback onDone;

  /// Opened again from Settings: takes the tour again, and skips connecting
  /// if already signed in.
  final bool replay;
  const Onboarding({super.key, required this.onDone, this.replay = false});

  @override
  State<Onboarding> createState() => _OnboardingState();
}

enum _Step { welcome, connect, tour, firstHabit, habit, done }

class _OnboardingState extends State<Onboarding> {
  _Step step = _Step.welcome;

  Future<void> _afterConnect() async {
    final sync = AppScope.read(context).sync;
    // Give the first sync a moment, so habits made on another device are
    // there by the time the tour ends.
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (sync.status == SyncStatus.syncing &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (mounted) _toTour();
  }

  void _afterWelcome() {
    final sync = AppScope.read(context).sync;
    if (widget.replay || (sync.isConfigured && sync.account != null)) {
      _toTour();
    } else {
      setState(() => step = _Step.connect);
    }
  }

  void _toTour() => setState(() => step = _Step.tour);

  void _finish() {
    // Older versions of the app still read this choice.
    AppScope.read(context).repo.setPrefs({'atomicHabits': true});
    if (!widget.replay) {
      AppScope.read(context).repo.store.setMeta('onboarded', '1');
    }
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final page = switch (step) {
      _Step.welcome => _Welcome(onNext: _afterWelcome),
      _Step.connect => _Connect(onConnected: _afterConnect, onSkip: _toTour),
      _Step.tour => _Tour(
        onFinish: () => setState(() => step = _Step.firstHabit),
      ),
      _Step.firstHabit => _FirstHabit(
        onChoice: (yes) =>
            setState(() => step = yes ? _Step.habit : _Step.done),
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
        icon: Icons.check_circle_outline,
        title: 'Welcome to OpenHabits',
        body:
            "Build habits that stick, one small step at a time. It's built around the ideas "
            "in James Clear's book Atomic Habits, and everything is kept on your own server.",
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

class _FirstHabit extends StatelessWidget {
  final ValueChanged<bool> onChoice;
  const _FirstHabit({required this.onChoice});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _Title(
        icon: Icons.add_circle_outline,
        title: 'Build your first habit?',
        body:
            "We'll go through it one step at a time: who you want to become, a small "
            "version to start with, and when and where you'll do it. It takes about a minute.",
      ),
      FilledButton(
        onPressed: () => onChoice(true),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        child: const Text("Let's build one"),
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed: () => onChoice(false),
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        child: const Text("I'll do it later"),
      ),
    ],
  );
}

/// A quick tour of what the app does, one idea per page, each with a
/// small picture of what you'll see. Matches the Apple app's tour.
class _Tour extends StatefulWidget {
  final VoidCallback onFinish;
  const _Tour({required this.onFinish});

  @override
  State<_Tour> createState() => _TourState();
}

class _TourState extends State<_Tour> {
  int page = 0;

  static const _stops = [
    (
      'Check in each day',
      "Each habit shows your last seven days. When you've done it, tap today's circle, "
          'the bigger one on the right. Forgot to tick one off? Tap an earlier day, or open '
          'the habit to change any day this month.',
    ),
    (
      'Miss once, but never twice',
      "Life happens. Missing one day won't break your streak, but missing two in a row will. "
          "If you missed a habit last time, it'll remind you, so you can get back on track today.",
    ),
    (
      'Start small, then grow it',
      "Begin with a version so small you can't say no, like reading one page. Every two weeks, "
          "you'll get a quick check-in. If it's sticking, you'll be asked whether it feels too "
          "easy. If you've been missing it, you'll get the option to make it smaller for a while.",
    ),
    (
      'Break bad habits too',
      'For a habit you want to quit, check in on the days you stayed clear of it. '
          "You'll see your days clean add up, and you can plan ways to make the habit harder "
          'to fall into.',
    ),
    (
      'Give each habit a plan',
      "Decide who you want to become, when and where you'll do it, what you'll do it "
          'straight after, and a small reward. Habits with a time can show up in your '
          'calendar app too.',
    ),
    (
      "See how it's going",
      'The Progress tab shows every habit week by week, and says plainly whether each one '
          'is going strong, getting there, or struggling.',
    ),
    (
      'Look back each week',
      'In Reflect, the weekly review asks a few short questions about your week. The '
          'scorecard helps you notice the habits you already have, and whether each one '
          'helps or hurts.',
    ),
    (
      'Focus, and earn your tomatoes',
      'The Focus timer helps you work on one thing for 25 minutes. Each session you finish '
          'earns a tomato toward your daily goal. You can start one straight from a habit.',
    ),
    (
      'On all your devices',
      'Your habits are kept on your own server and stay in sync on your phone and computer. '
          'To add a device, go to Settings and show its QR code.',
    ),
  ];

  void _next() {
    if (page == _stops.length - 1) {
      widget.onFinish();
    } else {
      setState(() => page++);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (title, message) = _stops[page];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: widget.onFinish,
            child: const Text('Skip tour'),
          ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0.08, 0),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: Column(
            key: ValueKey(page),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 180,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Center(child: _picture(context, page)),
              ),
              const SizedBox(height: 20),
              Text(
                title,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < _stops.length; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: i == page ? 18 : 7,
                height: 7,
                decoration: BoxDecoration(
                  color: i == page
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            if (page > 0)
              OutlinedButton(
                onPressed: () => setState(() => page--),
                child: const Text('Back'),
              ),
            const Spacer(),
            FilledButton(
              onPressed: _next,
              child: Text(page == _stops.length - 1 ? 'Continue' : 'Next'),
            ),
          ],
        ),
      ],
    );
  }

  /// Small pictures made from the same pieces the app uses.
  Widget _picture(BuildContext context, int page) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    Widget circle(
      bool done, {
      bool today = false,
      Color color = Colors.green,
    }) => Container(
      width: today ? 38 : 28,
      height: today ? 38 : 28,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done ? color : null,
        border: Border.all(color: today ? accent : color, width: today ? 3 : 2),
      ),
      child: done
          ? const Icon(Icons.check, size: 16, color: Colors.white)
          : null,
    );
    Widget pill(String text, Color color, {bool filled = true}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: filled ? Colors.white : color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    switch (page) {
      case 0:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 6; i++) circle(i != 2),
            circle(false, today: true),
          ],
        );
      case 1:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.local_fire_department,
                  color: Colors.deepOrange,
                  size: 32,
                ),
                Text(
                  ' 12 days',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: Colors.deepOrange,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            pill('You missed this last time', Colors.orange, filled: false),
          ],
        );
      case 2:
        return Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 8,
          children: [
            pill('Read one page', theme.colorScheme.outline, filled: false),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.arrow_forward),
            ),
            pill('Read five pages', accent),
          ],
        );
      case 3:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.shield, size: 52, color: Colors.green),
            Text(
              '8 days clean',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        );
      case 4:
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            'After I pour my coffee, I will read one page on the couch.',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
        );
      case 5:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in const [
              [3, 5, 7, 7, 6, 7],
              [2, 4, 3, 5, 4, 5],
            ])
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final n in row)
                    Container(
                      width: 32,
                      height: 32,
                      margin: const EdgeInsets.all(3),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: n == 7 ? accent : accent.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '$n',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: n == 7 ? Colors.white : null,
                        ),
                      ),
                    ),
                ],
              ),
          ],
        );
      case 6:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (text, sign, color) in const [
              ('Go for a walk', '+', Color(0xFF34C759)),
              ('Make coffee', '=', Color(0xFF8E8E93)),
              ('Check my phone', '−', Color(0xFFFF3B30)),
            ])
              Container(
                width: 260,
                margin: const EdgeInsets.symmetric(vertical: 3),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Expanded(child: Text(text)),
                    pill(sign, color),
                  ],
                ),
              ),
          ],
        );
      case 7:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '25:00',
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w300,
              ),
            ),
            const SizedBox(height: 8),
            const Text('🍅 🍅 🍅', style: TextStyle(fontSize: 26)),
          ],
        );
      default:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.smartphone, size: 44, color: accent),
            Icon(Icons.sync, size: 28, color: theme.colorScheme.outline),
            Icon(Icons.dns, size: 44, color: accent),
            Icon(Icons.sync, size: 28, color: theme.colorScheme.outline),
            Icon(Icons.laptop, size: 44, color: accent),
          ],
        );
    }
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
        body:
            "Check in on Today each day, and see how you're doing on the Progress tab. "
            'You can take this tour again any time from Settings.',
      ),
      FilledButton(
        onPressed: onFinish,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        child: const Text('Start using OpenHabits'),
      ),
    ],
  );
}
