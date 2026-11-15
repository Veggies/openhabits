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
                  RatingPicker(
                    rating: item.rating,
                    onChanged: (r) =>
                        repo.updateScorecardItem(item.id, {'rating': r}),
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
            Wrap(
              spacing: 20,
              children: [
                for (final r in ratings)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(r.icon, size: 18, color: r.color),
                      const SizedBox(width: 6),
                      Text(
                        '${repo.scorecard.where((s) => s.rating == r.value).length} ${r.total.toLowerCase()}',
                        style: theme.textTheme.titleSmall,
                      ),
                    ],
                  ),
              ],
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
  // Opens on last week while its review is still to do.
  late DateTime day =
      widget.day ??
      (AppScope.read(context).repo.lastWeekReviewDue
          ? addDays(DateTime.now(), -7)
          : DateTime.now());
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
            leading: HabitGlyph(icon: h.icon, color: h.color),
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

/// The scorecard's ratings and their colours: green for habits that help,
/// red for ones that need to go, grey for neutral. The + = − signs stay,
/// so the meaning never relies on colour alone.
typedef Rating = ({
  String value,
  String sign,
  String name,
  String total,
  IconData icon,
  Color color,
});

const List<Rating> ratings = [
  (
    value: '+',
    sign: '+',
    name: 'Helps',
    total: 'Helping',
    icon: Icons.add_circle,
    color: Color(0xFF34C759),
  ),
  (
    value: '=',
    sign: '=',
    name: 'Neutral',
    total: 'Neutral',
    icon: Icons.drag_handle,
    color: Color(0xFF8E8E93),
  ),
  (
    value: '-',
    sign: '−',
    name: 'Hurts',
    total: 'Hurting',
    icon: Icons.remove_circle,
    color: Color(0xFFFF3B30),
  ),
];

/// + = − as three pills. The chosen one fills with its colour.
class RatingPicker extends StatelessWidget {
  final String rating;
  final ValueChanged<String> onChanged;
  const RatingPicker({
    super.key,
    required this.rating,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final r in ratings)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Tooltip(
            message: r.name,
            child: Material(
              color: rating == r.value
                  ? r.color
                  : r.color.withValues(alpha: 0.12),
              shape: const StadiumBorder(),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => onChanged(r.value),
                child: SizedBox(
                  width: 38,
                  height: 28,
                  child: Center(
                    child: Text(
                      r.sign,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: rating == r.value ? Colors.white : r.color,
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
