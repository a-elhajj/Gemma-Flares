import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/services/app_readiness_service.dart';
import '../../core/services/dashboard_snapshot_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/section_card.dart';
import '../chat/chat_controller.dart';
import '../chat/embedded_today_chat.dart';
import '../timeline/timeline_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    this.chatController,
    this.readinessState,
    this.onExplainRequested,
    this.onOpenFullChatRequested,
    this.onOpenSymptomsRequested,
    this.onStartCheckInRequested,
  });

  final ChatController? chatController;
  final AppReadinessState? readinessState;
  final ValueChanged<String>? onExplainRequested;
  final VoidCallback? onOpenFullChatRequested;
  final VoidCallback? onOpenSymptomsRequested;
  final VoidCallback? onStartCheckInRequested;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  DashboardSnapshot? _snapshot;
  int _todayChatPromptToken = 0;
  String? _queuedTodayChatPrompt;

  @override
  void initState() {
    super.initState();
    _refreshDashboard();
  }

  Future<void> _refreshDashboard() async {
    try {
      final snapshotFuture =
          AppServices.dashboardSnapshotService.loadDashboardSnapshot();
      final snapshot = await snapshotFuture;
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _snapshot = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _refreshDashboard,
        child: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    try {
      return _buildDashboard(context);
    } catch (_) {
      return _buildError(context);
    }
  }

  Widget _buildError(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 64),
        Icon(
          Icons.error_outline_rounded,
          size: 56,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(height: 16),
        Text(
          'Something went wrong',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const Text(
          'Pull down to refresh or try syncing again.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Center(
          child: FilledButton(
            onPressed: _refreshDashboard,
            child: const Text('Retry'),
          ),
        ),
      ],
    );
  }

  Widget _buildDashboard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final score = _snapshot?.latestScore;
    final hasScore = score != null;
    final showReadinessBanner = widget.readinessState?.isRefreshing == true ||
        _snapshot?.isSyncStale == true;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      children: [
        _HeroCard(snapshot: _snapshot, onExplain: _queueTodayChatPrompt),
        const SizedBox(height: 12),
        EmbeddedTodayChat(
          snapshot: _snapshot,
          controller: widget.chatController,
          queuedPrompt: _queuedTodayChatPrompt,
          queuedPromptToken: _todayChatPromptToken,
          onExpand: widget.onOpenFullChatRequested,
          onOpenSymptoms: widget.onOpenSymptomsRequested,
        ),
        if (showReadinessBanner) ...[
          const SizedBox(height: 12),
          _ReadinessBanner(
            readinessState: widget.readinessState,
            snapshot: _snapshot,
          ),
        ],
        const SizedBox(height: 20),
        if (_snapshot?.checkinStatusLabel != null) ...[
          _CheckInReminderCard(
            label: _snapshot!.checkinStatusLabel!,
            onStartCheckIn: widget.onStartCheckInRequested,
          ),
          const SizedBox(height: 20),
        ],
        if (hasScore) ...[
          _DriverChips(snapshot: _snapshot!),
          const SizedBox(height: 20),
        ],
        if (_snapshot != null && _snapshot!.scoreTrend.length >= 2) ...[
          SectionCard(
            title: 'Risk trend',
            child: SizedBox(
              height: 80,
              child: CustomPaint(
                size: const Size(double.infinity, 80),
                painter: _SparklinePainter(
                  values: _snapshot!.scoreTrend,
                  color: hasScore
                      ? AppTheme.riskColor(score.riskBand)
                      : cs.primary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
        if (_snapshot != null && _snapshot!.earlyWarningOutlook.isNotEmpty) ...[
          _EarlyWarningOutlookCard(snapshot: _snapshot!),
          const SizedBox(height: 20),
        ],
        const SizedBox(height: 12),
        Center(
          child: TextButton.icon(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(builder: (_) => const TimelineScreen()),
            ),
            icon: const Icon(Icons.timeline_outlined, size: 16),
            label: const Text('View history'),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Gemma Flares shows local trend signals. It does not diagnose or replace clinician advice.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.outline),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  void _queueTodayChatPrompt(String prompt) {
    widget.onExplainRequested?.call(prompt);
    setState(() {
      _queuedTodayChatPrompt = prompt;
      _todayChatPromptToken += 1;
    });
  }
}

class _ReadinessBanner extends StatelessWidget {
  const _ReadinessBanner({
    required this.readinessState,
    required this.snapshot,
  });

  final AppReadinessState? readinessState;
  final DashboardSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    final state = readinessState;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final syncLabel =
        snapshot?.syncFreshnessLabel ?? 'Sync status unavailable.';

    if (state?.isRefreshing == true) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: cs.primaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: cs.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Updating your latest Health data in the background. Showing cached results now.',
                style: tt.bodySmall,
              ),
            ),
          ],
        ),
      );
    }

    final stale = snapshot?.isSyncStale == true;
    if (stale) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: cs.tertiaryContainer.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text('Data may be stale. $syncLabel', style: tt.bodySmall),
      );
    }

    return const SizedBox.shrink();
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.snapshot, required this.onExplain});

  final DashboardSnapshot? snapshot;
  final ValueChanged<String>? onExplain;

  @override
  Widget build(BuildContext context) {
    final score = snapshot?.latestScore;
    final hasScore = score != null;
    final riskBand = score?.riskBand ?? '';
    final bandColor = hasScore ? AppTheme.riskColor(riskBand) : AppTheme.teal;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          colors: [bandColor, bandColor.withValues(alpha: 0.72)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Today',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (hasScore) ...[
                Text(
                  '${score.riskScore.round()}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 52,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '/100',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 18,
                    ),
                  ),
                ),
                const Spacer(),
                _HeroPill(label: _capitalize(riskBand)),
              ] else ...[
                const Expanded(
                  child: Text(
                    'Baseline building',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Text(
            hasScore
                ? 'Data confidence ${score.confidenceScore.round()}/100. ${snapshot?.syncFreshnessLabel ?? ''}'
                : 'Sync Health data to compute your first local score.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            snapshot?.baselineStatusLabel ?? 'Baseline not started',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.65),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: () => onExplain?.call(
              hasScore
                  ? 'Why is my risk $riskBand today?'
                  : 'Summarize my recent pattern.',
            ),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.2),
              foregroundColor: Colors.white,
            ),
            child: Text(hasScore ? 'Explain score' : 'Open summary'),
          ),
        ],
      ),
    );
  }

  static String _capitalize(String v) =>
      v.isEmpty ? v : '${v[0].toUpperCase()}${v.substring(1)}';
}

class _HeroPill extends StatelessWidget {
  const _HeroPill({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _DriverChips extends StatelessWidget {
  const _DriverChips({required this.snapshot});

  final DashboardSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final chips = snapshot.driverChips;
    if (chips.isEmpty) return const SizedBox.shrink();

    return SectionCard(
      title: 'What stood out today',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: chips
            .map(
              (c) => Chip(
                avatar: CircleAvatar(
                  radius: 12,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.primaryContainer,
                  child: Text(
                    '${c.points}',
                    style: const TextStyle(fontSize: 10),
                  ),
                ),
                label: Text(c.label),
              ),
            )
            .toList(growable: false),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final minV = values.reduce((a, b) => a < b ? a : b);
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final range = maxV - minV;
    final eff = range < 1 ? 1.0 : range;

    final pts = <Offset>[];
    for (var i = 0; i < values.length; i++) {
      final x = (i / (values.length - 1)) * size.width;
      final y = size.height -
          ((values[i] - minV) / eff) * size.height * 0.85 -
          size.height * 0.075;
      pts.add(Offset(x, y));
    }

    final fill = Path()..moveTo(pts.first.dx, size.height);
    for (final p in pts) {
      fill.lineTo(p.dx, p.dy);
    }
    fill.lineTo(pts.last.dx, size.height);
    fill.close();

    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.18), color.withValues(alpha: 0.0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );

    final line = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      line.lineTo(pts[i].dx, pts[i].dy);
    }
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );

    canvas.drawCircle(pts.last, 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.values != values || old.color != color;
}

// ─────────────────────────────────────────────────────────────────────────────
// _CheckInReminderCard
// ─────────────────────────────────────────────────────────────────────────────

class _CheckInReminderCard extends StatelessWidget {
  const _CheckInReminderCard({required this.label, this.onStartCheckIn});

  final String label;
  final VoidCallback? onStartCheckIn;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final isPending = label.startsWith('Daily check-in not');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isPending
            ? cs.tertiaryContainer.withValues(alpha: 0.4)
            : cs.secondaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isPending
                    ? Icons.sentiment_satisfied_alt_outlined
                    : Icons.assignment_turned_in_outlined,
                size: 20,
                color: isPending ? cs.tertiary : cs.secondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isPending
                      ? 'How are you feeling today?'
                      : 'Today\'s check-in is done',
                  style: tt.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            isPending
                ? 'A quick check-in keeps your score accurate and helps the model stay grounded.'
                : label,
            style: tt.bodyMedium,
          ),
          if (isPending) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  onPressed: onStartCheckIn,
                  child: const Text('Start check-in (30 sec)'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _LogisticPredictionCard
// ─────────────────────────────────────────────────────────────────────────────

class _EarlyWarningOutlookCard extends StatelessWidget {
  const _EarlyWarningOutlookCard({required this.snapshot});

  final DashboardSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final focusHorizons = <int>{7, 14, 21};
    final focusRows = snapshot.earlyWarningOutlook
        .where((point) => focusHorizons.contains(point.horizonDays))
        .toList(growable: false);
    final rows = (focusRows.isNotEmpty
            ? focusRows
            : snapshot.earlyWarningOutlook.take(3))
        .toList(growable: false);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.insights_rounded, size: 18, color: cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'What to watch next',
                  style: tt.titleSmall?.copyWith(color: cs.primary),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '7d 14d 21d',
                  style: tt.labelSmall?.copyWith(
                    color: cs.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < rows.length; i++) ...[
            _PredRow(
              horizonDays: rows[i].horizonDays,
              probability: rows[i].probability,
              trainingSamples: rows[i].trainingSamples,
              colorScheme: cs,
              isLearning: rows[i].isLearning,
              textTheme: tt,
            ),
            if (i < rows.length - 1) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _PredRow extends StatelessWidget {
  const _PredRow({
    required this.horizonDays,
    required this.probability,
    required this.trainingSamples,
    required this.colorScheme,
    required this.isLearning,
    required this.textTheme,
  });

  final int horizonDays;
  final double probability;
  final int trainingSamples;
  final ColorScheme colorScheme;
  final bool isLearning;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    final safeProbability = probability.clamp(0.0, 1.0);
    final pct = (safeProbability * 100).round();
    final color = isLearning
        ? colorScheme.primary
        : pct >= 50
            ? colorScheme.error
            : pct >= 30
                ? colorScheme.tertiary
                : pct >= 15
                    ? colorScheme.secondary
                    : colorScheme.primary;
    final band = isLearning
        ? 'Learning'
        : pct >= 50
            ? 'Act now'
            : pct >= 30
                ? 'Watch'
                : pct >= 15
                    ? 'Heads up'
                    : 'Steady';
    final windowLabel = _windowLabel(horizonDays);
    final supportLabel =
        isLearning ? '$trainingSamples samples so far' : '$windowLabel chance';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 58,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${horizonDays}d',
                  style: textTheme.titleMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _windowShortLabel(horizonDays),
                  style: textTheme.labelSmall?.copyWith(
                    color: colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '$pct%',
                      style: textTheme.titleLarge?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w700,
                        height: 1,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      supportLabel,
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        band,
                        style: textTheme.labelSmall?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: safeProbability,
                    minHeight: 8,
                    backgroundColor: color.withValues(alpha: 0.16),
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _windowLabel(int days) {
    if (days == 7) return 'next week';
    if (days % 7 == 0) return 'next ${days ~/ 7} weeks';
    return 'next $days days';
  }

  String _windowShortLabel(int days) {
    if (days == 7) return '1 wk';
    if (days % 7 == 0) return '${days ~/ 7} wk';
    return '$days d';
  }
}
