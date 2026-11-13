import 'dart:async';

import 'package:core/core.dart';
import 'package:material_ui/material_ui.dart';

import '../data/repo.dart';
import 'common.dart';

/// The habits scorecard: list what you already do each day and rate each
/// habit good (+), bad (−) or neutral (=). The point is awareness, not
/// judgement. Shown as a tab on the Habits page.
class ScorecardView extends StatefulWidget {
  const ScorecardView({super.key});

  @override
  State<ScorecardView> createState() => _ScorecardViewState();
}

class _ScorecardViewState extends State<ScorecardView> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DataBuilder(
      builder: (context, repo) => CenteredListView(
        maxWidth: 640,
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'List your daily habits in order, from waking up to going to bed. Then rate each one: '
            'does it help (+) or hurt (−) the person you want to become, or is it neutral (=)?',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 16),
          for (final item in repo.scorecard)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(item.text),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: const [
                      ButtonSegment(value: '+', label: Text('+')),
                      ButtonSegment(value: '=', label: Text('=')),
                      ButtonSegment(value: '-', label: Text('−')),
                    ],
                    selected: {item.rating},
                    onSelectionChanged: (s) =>
                        repo.updateScorecardItem(item.id, {'rating': s.first}),
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => repo.deleteScorecardItem(item.id),
                  ),
                ],
              ),
            ),
          TextField(
            controller: _controller,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.add),
              hintText: 'e.g. Wake up, check phone, make coffee…',
            ),
            onSubmitted: (v) {
              if (v.trim().isEmpty) return;
              repo.addScorecardItem(v.trim());
              _controller.clear();
            },
          ),
          if (repo.scorecard.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              '${repo.scorecard.where((s) => s.rating == '+').length} helping · '
              '${repo.scorecard.where((s) => s.rating == '-').length} hurting · '
              '${repo.scorecard.where((s) => s.rating == '=').length} neutral',
              style: theme.textTheme.titleSmall,
            ),
          ],
        ],
      ),
    );
  }
}

/// A weekly reflection with a summary of how each habit went. Shown as a
/// tab on the Habits page.
class WeeklyReviewView extends StatefulWidget {
  /// Any day in the week to review. Defaults to this week.
  final DateTime? day;
  const WeeklyReviewView({super.key, this.day});

  @override
  State<WeeklyReviewView> createState() => _WeeklyReviewViewState();
}

class _WeeklyReviewViewState extends State<WeeklyReviewView> {
  late DateTime day = widget.day ?? DateTime.now();
  final _controllers = <String, TextEditingController>{};
  Timer? _save;

  @override
  void dispose() {
    _flush();
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // Kept so answers can still be saved while the tab is being closed, when
  // looking things up through `context` is no longer allowed.
  late Repo _repo;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _repo = AppScope.of(context).repo;
  }

  void _flush() {
    _save?.cancel();
    final repo = _repo;
    final saved = repo.review(day).answers;
    for (final MapEntry(:key, :value) in _controllers.entries) {
      if ((saved[key] ?? '') != value.text) {
        repo.saveReview(day, key, value.text);
      }
    }
  }

  void _changeWeek(int delta) {
    _flush();
    setState(() {
      day = addDays(day, 7 * delta);
      for (final c in _controllers.values) {
        c.dispose();
      }
      _controllers.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final theme = Theme.of(context);
    final start = startOfWeek(day, repo.weekStart);
    final end = addDays(start, 6);
    final today = dateOnly(repo.clock());
    final review = repo.review(day);

    return CenteredListView(
      maxWidth: 640,
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Previous week',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => _changeWeek(-1),
            ),
            Expanded(
              child: Text(
                'Week of ${shortDate(start)}',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: 'Next week',
              icon: const Icon(Icons.chevron_right),
              onPressed: start.isAfter(addDays(today, -7))
                  ? null
                  : () => _changeWeek(1),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('How the week went', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final h in repo.habits)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(habitIcon(h.icon), color: Color(h.color)),
            title: Text(h.name),
            trailing: Text(
              '${(repo.completionRate(h, end.isAfter(today) ? today : end, end.isAfter(today) ? daysBetween(start, today) + 1 : 7) * 100).round()}%'
              '${h.isQuit ? ' clean' : ''}',
              style: theme.textTheme.titleSmall,
            ),
          ),
        const Divider(height: 32),
        for (final MapEntry(key: id, value: prompt)
            in WeeklyReview.prompts.entries) ...[
          Text(prompt, style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          TextField(
            controller: _controllers.putIfAbsent(
              id,
              () => TextEditingController(text: review.answers[id] ?? ''),
            ),
            minLines: 2,
            maxLines: null,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            onChanged: (_) {
              _save?.cancel();
              _save = Timer(const Duration(milliseconds: 800), _flush);
            },
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}
