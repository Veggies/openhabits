import 'dart:convert';

import 'package:core/core.dart';
import 'package:material_ui/material_ui.dart';

import '../data/reminders.dart';
import '../data/repo.dart';
import 'common.dart';

/// Creates or edits a habit, including its Atomic Habits plan.
Future<void> editHabit(BuildContext context, {Habit? existing}) =>
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => HabitEditor(existing: existing),
      ),
    );

class HabitEditor extends StatefulWidget {
  final Habit? existing;
  const HabitEditor({super.key, this.existing});

  @override
  State<HabitEditor> createState() => _HabitEditorState();
}

class _HabitEditorState extends State<HabitEditor> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late int color = widget.existing?.color ?? listColors[3];
  late String icon = widget.existing?.icon ?? 'check';
  late HabitKind kind = widget.existing?.kind ?? HabitKind.build;
  late Set<int> weekdays = {...?widget.existing?.weekdays};
  late int duration = widget.existing?.duration ?? 15;
  late bool remind = widget.existing?.remind ?? true;
  late final Map<String, TextEditingController> _plan = {
    for (final f in HabitPlan.fieldNames)
      f: TextEditingController(
        text: widget.existing == null
            ? ''
            : _planValue(widget.existing!.plan, f),
      ),
  };

  /// The fields as the editor opened, to save only what the person
  /// changed. Saving everything would undo edits another device made to
  /// other fields while this editor was open.
  late final Map<String, Object?> _loaded;

  @override
  void initState() {
    super.initState();
    if (widget.existing == null) weekdays = {1, 2, 3, 4, 5, 6, 7};
    _loaded = _fields();
  }

  Map<String, Object?> _fields() => {
    'name': _name.text.trim(),
    'color': color,
    'icon': icon,
    'kind': kind.name,
    'weekdays': weekdays.toList()..sort(),
    'duration': duration,
    'remind': remind,
    for (final MapEntry(:key, :value) in _plan.entries) key: value.text.trim(),
  };

  @override
  void dispose() {
    _name.dispose();
    for (final c in _plan.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final repo = AppScope.of(context).repo;
    final fields = _fields();
    if (widget.existing == null) {
      repo.createHabit(fields);
    } else {
      final existing = repo.habit(widget.existing!.id)!;
      final changed = {
        for (final MapEntry(:key, :value) in fields.entries)
          if (jsonEncode(value) != jsonEncode(_loaded[key])) key: value,
      };
      final version = fields['twoMinute'] as String;
      repo.updateHabit(existing.id, {
        ...changed,
        // A changed version joins the habit's history.
        if (changed.containsKey('twoMinute') &&
            version.isNotEmpty &&
            existing.plan.twoMinute.isNotEmpty)
          ...repo.resizeFields(existing, version),
      });
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New habit' : 'Edit habit'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(onPressed: _save, child: const Text('Save')),
          ),
        ],
      ),
      body: CenteredListView(
        maxWidth: 620,
        padding: const EdgeInsets.all(20),
        children: [
          SegmentedButton<HabitKind>(
            segments: const [
              ButtonSegment(
                value: HabitKind.build,
                icon: Icon(Icons.trending_up),
                label: Text('Build a habit'),
              ),
              ButtonSegment(
                value: HabitKind.quit,
                icon: Icon(Icons.block),
                label: Text('Break a habit'),
              ),
            ],
            selected: {kind},
            onSelectionChanged: (s) => setState(() => kind = s.first),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              _IconButton(icon: icon, color: color, onTap: _pickIcon),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _name,
                  autofocus: widget.existing == null,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: kind == HabitKind.build
                        ? 'Habit'
                        : 'Habit to break',
                    hintText: kind == HabitKind.build
                        ? 'e.g. Read'
                        : 'e.g. Scrolling in bed',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ColorPicker(
            selected: color,
            onChanged: (c) => setState(() => color = c),
          ),
          if (kind == HabitKind.build) ...[
            const SizedBox(height: 20),
            Text('Repeat on', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            WeekdayPicker(
              selected: weekdays,
              weekStart: repo.weekStart,
              onChanged: (d) => setState(() => weekdays = d),
            ),
            const SizedBox(height: 12),
            _timeRow(),
          ],
          ...[
            const SizedBox(height: 28),
            Text('Atomic Habits', style: theme.textTheme.titleMedium),
            Text(
              'Everything here is optional. Just fill in what helps you.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 8),
            _field(
              'identity',
              'Who do you want to become?',
              'I am a person who…',
              help: "Each time you do the habit, it's a vote for becoming this person.",
            ),
            if (kind == HabitKind.build)
              ...buildPlanFields(context, _plan, habit: widget.existing)
            else
              ...quitPlanFields(_plan),
          ],
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  /// An optional time puts the habit in your calendar app, as a block of
  /// [duration] minutes.
  Widget _timeRow() {
    final time = _plan['time']!;
    final hasTime = time.text.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _timeFields(time, hasTime),
        if (hasTime) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Remind me'),
            subtitle: Text(
              Reminders.supported
                  ? 'Reminders need to be on in Settings, under Reminders. It can also show up in '
                        "your calendar app, from Settings (once you're connected to your server)."
                  : "It can show up in your calendar app, from Settings (once you're connected "
                        'to your server). Reminders at set times need a phone or Windows.',
            ),
            value: remind,
            onChanged: Reminders.supported
                ? (v) => setState(() => remind = v)
                : null,
          ),
        ],
      ],
    );
  }

  Widget _timeFields(TextEditingController time, bool hasTime) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: PlanField(
            controller: time,
            label: 'Time (optional)',
            hint: 'Pick a time',
            help: hasTime ? null : 'Give it a time to get a reminder, and to see it in your calendar app.',
            onTap: _pickTime,
            suffix: hasTime
                ? IconButton(
                    tooltip: 'Clear time',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(time.clear),
                  )
                : null,
          ),
        ),
        if (hasTime) ...[
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: DropdownButtonFormField<int>(
                initialValue: duration,
                decoration: const InputDecoration(
                  labelText: 'How long',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final m in {
                    ...durationChoices,
                    duration,
                  }.toList()..sort())
                    DropdownMenuItem(value: m, child: Text(durationLabel(m))),
                ],
                onChanged: (m) => setState(() => duration = m ?? duration),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _field(String name, String label, String hint, {String? help}) =>
      PlanField(controller: _plan[name]!, label: label, hint: hint, help: help);

  Future<void> _pickTime() async {
    final current = _plan['time']!.text;
    final initial = current.isEmpty
        ? const TimeOfDay(hour: 7, minute: 0)
        : () {
            final t = parseTime(current);
            return TimeOfDay(hour: t.hour, minute: t.minute);
          }();
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked != null) {
      setState(
        () => _plan['time']!.text = formatTime(picked.hour, picked.minute),
      );
    }
  }

  Future<void> _pickIcon() async {
    final picked = await pickHabitIcon(context, selected: icon, color: color);
    if (picked != null) setState(() => icon = picked);
  }
}

/// How "start small and grow it" works, in one place so the editor and the
/// setup wizard say the same thing. The numbers match
/// [Repo.growDaysNeeded] and [Repo.sizeSuggestion].
const buildUpExplanation =
    "Start with a version so small you can't say no, like reading one page. "
    "Every two weeks, you'll get a quick check-in. "
    "If you've been doing it most days, you'll be asked whether it's starting to feel too easy, "
    'and you can make it a bit bigger if you like. '
    "If you've been missing it a lot, you'll get the option to make it smaller for a while. "
    'You can always keep it as it is, or say the size feels right.\n\n'
    'For a daily habit, "most days" means 12 out of 14. For one you do 3 times a week, it\'s 5 out of 6.';

/// The optional "start small and grow it" part of a habit: a switch, and
/// when it's on, the current version and how size check-ins work. Turning
/// it off clears the version (so no check-ins happen), but remembers it in
/// case it's turned back on.
class BuildUpFields extends StatefulWidget {
  final TextEditingController startWith;

  /// The habit being edited, if any: used to show "you said this size feels
  /// right" with a way to undo it.
  final Habit? habit;
  const BuildUpFields({super.key, required this.startWith, this.habit});

  @override
  State<BuildUpFields> createState() => _BuildUpFieldsState();
}

class _BuildUpFieldsState extends State<BuildUpFields> {
  late bool on = widget.startWith.text.trim().isNotEmpty;
  String _saved = '';

  void _toggle(bool value) => setState(() {
    on = value;
    if (value) {
      if (widget.startWith.text.isEmpty) widget.startWith.text = _saved;
    } else {
      _saved = widget.startWith.text;
      widget.startWith.clear();
    }
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = AppScope.of(context).repo;
    final habit = widget.habit == null ? null : repo.habit(widget.habit!.id);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.outline,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Start small and grow it'),
          subtitle: const Text(
            'Begin with a tiny version of the habit and let it grow over time.',
          ),
          value: on,
          onChanged: _toggle,
        ),
        if (on) ...[
          Text(buildUpExplanation, style: muted),
          PlanField(
            controller: widget.startWith,
            label: 'Your version for now',
            hint: 'e.g. Read one page',
            help: 'Something that takes two minutes or less to begin with.',
          ),
          if (habit != null && habit.plan.sizeSettled)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      "You said this size feels right, so you won't be asked about changing it.",
                      style: muted,
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        setState(() => repo.settleSize(habit, settled: false)),
                    child: const Text('Start checking in again'),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

/// Lengths offered for a habit's calendar block, in minutes.
const durationChoices = [5, 10, 15, 30, 45, 60, 90, 120];

/// "5 min", "1 hr", "1 hr 30 min".
String durationLabel(int minutes) {
  final h = minutes ~/ 60, m = minutes % 60;
  return [if (h > 0) '$h hr', if (m > 0 || h == 0) '$m min'].join(' ');
}

/// A grid of habit icons. Returns the chosen icon's name.
/// A few emoji to start with; any emoji can be typed or pasted.
const _emojiSuggestions = [
  '📚',
  '🏃',
  '🚶',
  '🧘',
  '💧',
  '😴',
  '🥗',
  '🍎',
  '💪',
  '🚴',
  '✍️',
  '🎸',
  '🎨',
  '🧹',
  '🌱',
  '🐶',
  '🙏',
  '💊',
  '🦷',
  '☀️',
  '📵',
  '🚭',
  '💰',
  '🧠',
];

/// Emoji first, then the built-in symbols. Returns the chosen icon: a
/// symbol's key, or the emoji itself.
Future<String?> pickHabitIcon(
  BuildContext context, {
  required String selected,
  required int color,
}) => showDialog<String>(
  context: context,
  builder: (context) {
    final theme = Theme.of(context);
    Widget tile(bool on, Widget child, VoidCallback onTap, String tip) =>
        Tooltip(
          message: tip,
          child: Material(
            color: on ? Color(color) : Color(color).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
              child: SizedBox(
                width: 48,
                height: 48,
                child: Center(child: child),
              ),
            ),
          ),
        );
    return AlertDialog(
      title: const Text('Choose an icon'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Emoji', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in _emojiSuggestions)
                    tile(
                      e == selected,
                      Text(e, style: const TextStyle(fontSize: 24)),
                      () => Navigator.pop(context, e),
                      e,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                decoration: const InputDecoration(
                  hintText: 'Or type any emoji',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (text) {
                  final emoji = lastEmoji(text);
                  if (emoji != null) Navigator.pop(context, emoji);
                },
              ),
              const SizedBox(height: 16),
              Text('Symbols', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final MapEntry(:key, :value) in habitIcons.entries)
                    tile(
                      key == selected,
                      Icon(
                        value,
                        color: key == selected ? Colors.white : Color(color),
                      ),
                      () => Navigator.pop(context, key),
                      key,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  },
);

String _planValue(HabitPlan p, String name) => switch (name) {
  'identity' => p.identity,
  'time' => p.time,
  'location' => p.location,
  'stackAfter' => p.stackAfter,
  'twoMinute' => p.twoMinute,
  'goal' => p.goal,
  'bundle' => p.bundle,
  'reward' => p.reward,
  'invisible' => p.invisible,
  'unattractive' => p.unattractive,
  'difficult' => p.difficult,
  'unsatisfying' => p.unsatisfying,
  _ => p.contract,
};

/// The four laws for building a habit, as form sections.
List<Widget> buildPlanFields(
  BuildContext context,
  Map<String, TextEditingController> plan, {
  Habit? habit,
}) => [
  const LawHeader('1', 'Make it obvious'),
  PlanField(
    controller: plan['location']!,
    label: 'Where',
    hint: 'e.g. In the kitchen',
  ),
  PlanField(
    controller: plan['stackAfter']!,
    label: 'After I…',
    hint: 'e.g. pour my morning coffee',
    help: 'Tie it to something you already do every day, like making your morning coffee.',
  ),
  const LawHeader('2', 'Make it attractive'),
  PlanField(
    controller: plan['bundle']!,
    label: 'Pair it with something you enjoy',
    hint: 'e.g. Only listen to my podcast while walking',
  ),
  const LawHeader('3', 'Make it easy'),
  BuildUpFields(startWith: plan['twoMinute']!, habit: habit),
  const LawHeader('4', 'Make it satisfying'),
  PlanField(
    controller: plan['reward']!,
    label: 'Reward right after',
    hint: 'e.g. A square of chocolate',
  ),
];

/// The inverted four laws for breaking a habit.
List<Widget> quitPlanFields(Map<String, TextEditingController> plan) => [
  const LawHeader('1', 'Make it invisible'),
  PlanField(
    controller: plan['invisible']!,
    label: 'Remove the cue',
    hint: 'e.g. Charge my phone outside the bedroom',
  ),
  const LawHeader('2', 'Make it unattractive'),
  PlanField(
    controller: plan['unattractive']!,
    label: 'Reframe it',
    hint: 'e.g. Remember how tired I feel the next day',
  ),
  const LawHeader('3', 'Make it difficult'),
  PlanField(
    controller: plan['difficult']!,
    label: 'Add friction',
    hint: 'e.g. Log out of the app after every use',
  ),
  const LawHeader('4', 'Make it unsatisfying'),
  PlanField(
    controller: plan['unsatisfying']!,
    label: 'Accountability',
    hint: 'e.g. Tell Sam if I slip',
  ),
  PlanField(
    controller: plan['contract']!,
    label: 'Habit contract',
    hint: "e.g. If I slip, I'll do the dishes for a week",
    help: 'Make a promise to someone, with a real cost if you break it. It helps the change stick.',
  ),
];

class LawHeader extends StatelessWidget {
  final String number;
  final String title;
  const LawHeader(this.number, this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 6),
      child: Row(
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Text(number, style: theme.textTheme.labelSmall),
          ),
          const SizedBox(width: 8),
          Text(title, style: theme.textTheme.titleSmall),
        ],
      ),
    );
  }
}

class PlanField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final String? help;

  /// When set, the field can't be typed in; clicking it calls this instead
  /// (e.g. to open a time picker). The field's own hover and focus styling
  /// then matches its box exactly.
  final VoidCallback? onTap;

  /// Shown at the end of the box, e.g. a clear button.
  final Widget? suffix;
  const PlanField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    this.help,
    this.onTap,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: TextField(
      controller: controller,
      readOnly: onTap != null,
      onTap: onTap,
      mouseCursor: onTap != null ? SystemMouseCursors.click : null,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: help,
        helperMaxLines: 2,
        suffixIcon: suffix,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}

/// Seven day toggles in one row, in the person's week order.
class WeekdayPicker extends StatelessWidget {
  final Set<int> selected;
  final int weekStart;
  final ValueChanged<Set<int>> onChanged;
  const WeekdayPicker({
    super.key,
    required this.selected,
    required this.weekStart,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        for (final d in weekdayOrder(weekStart))
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: AspectRatio(
                aspectRatio: 1,
                child: Material(
                  shape: CircleBorder(
                    side: BorderSide(
                      color: selected.contains(d)
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
                  color: selected.contains(d)
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () {
                      final next = {...selected};
                      next.contains(d) ? next.remove(d) : next.add(d);
                      if (next.isNotEmpty) onChanged(next);
                    },
                    child: Center(
                      child: Text(
                        weekdayShort(d),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: selected.contains(d)
                              ? theme.colorScheme.onPrimary
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _IconButton extends StatelessWidget {
  final String icon;
  final int color;
  final VoidCallback onTap;
  const _IconButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Choose icon',
    child: InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: HabitAvatar(icon: icon, color: color, size: 56),
    ),
  );
}

class HabitAvatar extends StatelessWidget {
  final String icon;
  final int color;
  final double size;
  const HabitAvatar({
    super.key,
    required this.icon,
    required this.color,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: Color(color).withValues(alpha: 0.18),
      shape: BoxShape.circle,
    ),
    alignment: Alignment.center,
    child: HabitGlyph(icon: icon, color: color, size: size * 0.55),
  );
}
