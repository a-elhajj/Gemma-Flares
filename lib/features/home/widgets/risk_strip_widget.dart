import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Displays deterministic flare-risk context using a single canonical headline:
/// 7-day flare probability, with compact 14-day and 21-day outlook chips.
class RiskStripWidget extends StatelessWidget {
  const RiskStripWidget({
    super.key,
    required this.riskScore,
    required this.riskBand,
    this.outlook7d,
    this.outlook14d,
    this.outlook21d,
  });

  final double? riskScore;
  final String riskBand;
  final double? outlook7d;
  final double? outlook14d;
  final double? outlook21d;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final hasOutlook = outlook7d != null;
    final primaryBand =
        hasOutlook ? _bandForProbability(outlook7d!) : 'learning';
    final bandColor =
        hasOutlook ? AppTheme.riskColor(primaryBand) : colorScheme.primary;
    final headline = hasOutlook ? _percentText(outlook7d!) : 'Learning';
    final headlineBaseStyle = (textTheme.headlineSmall ?? const TextStyle())
        .copyWith(color: bandColor, fontWeight: FontWeight.w700, height: 1.05);
    final headlineScale = hasOutlook ? 2.0 : 2.2;
    final headlineStyle = headlineBaseStyle.copyWith(
      fontSize: (headlineBaseStyle.fontSize ?? 24) * headlineScale,
    );
    final actionTextStyleBase = (textTheme.bodyMedium ?? const TextStyle())
        .copyWith(color: colorScheme.onSurfaceVariant, height: 1.35);
    final actionTextStyle = (hasOutlook && primaryBand == 'critical')
        ? actionTextStyleBase.copyWith(
            fontSize: (actionTextStyleBase.fontSize ?? 14) * 0.9,
          )
        : actionTextStyleBase;

    return Semantics(
      label: outlook7d == null
          ? 'Flare chance next 7 days learning state'
          : 'Flare chance next 7 days $headline, $primaryBand risk',
      child: Card(
        color: colorScheme.surfaceContainerLow,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 126),
            child: Column(
              mainAxisAlignment: hasOutlook
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '7d flare chance',
                            style: Theme.of(context)
                                .textTheme
                                .labelMedium
                                ?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                  fontSize: hasOutlook
                                      ? null
                                      : ((Theme.of(context)
                                                  .textTheme
                                                  .labelMedium
                                                  ?.fontSize ??
                                              11) *
                                          1.15),
                                ),
                          ),
                          SizedBox(height: hasOutlook ? 2 : 6),
                          Text(headline, style: headlineStyle),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _BandChip(
                      band: hasOutlook ? primaryBand : 'learning',
                      color: bandColor,
                    ),
                  ],
                ),
                SizedBox(height: hasOutlook ? 10 : 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _HorizonPill(label: '14d', probability: outlook14d),
                    _HorizonPill(label: '21d', probability: outlook21d),
                  ],
                ),
                if (hasOutlook) ...[
                  const SizedBox(height: 10),
                  Text(
                    _actionLine(primaryBand),
                    maxLines: 4,
                    style: actionTextStyle,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _percentText(double probability) {
    final pct = (probability.clamp(0.0, 1.0) * 100).round();
    return '$pct%';
  }

  static String _actionLine(String band) {
    switch (band) {
      case 'critical':
        return 'High concern window over the next 7 days. If symptoms are worsening, contact your GI team today.';
      case 'high':
        return 'Risk is elevated in the next 7 days. Watch symptoms closely over the next 24-48 hours and log any changes.';
      case 'moderate':
        return 'Signals are mixed but not severe right now. Stay consistent with routines and keep tracking for trend changes.';
      default:
        return 'Signals look stable right now. Keep your routine and continue logging.';
    }
  }

  static String _bandForProbability(double p) {
    if (p < 0.2) return 'low';
    if (p < 0.4) return 'moderate';
    if (p < 0.6) return 'high';
    return 'critical';
  }
}

class _BandChip extends StatelessWidget {
  const _BandChip({required this.band, required this.color});

  final String band;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha(36),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        band.toUpperCase(),
        style: textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _HorizonPill extends StatelessWidget {
  const _HorizonPill({required this.label, required this.probability});

  final String label;
  final double? probability;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final accent = colorScheme.primary;
    final outlineColor = colorScheme.outlineVariant;
    final surfaceColor = colorScheme.surfaceContainerHighest.withAlpha(120);
    final text = probability == null
        ? 'N/A'
        : '${(probability!.clamp(0.0, 1.0) * 100).round()}%';

    return Semantics(
      label: '$label outlook $text',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: outlineColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(width: 4),
            Text(
              text,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
