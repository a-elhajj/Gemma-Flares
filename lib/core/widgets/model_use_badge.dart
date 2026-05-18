import 'package:flutter/material.dart';

class ModelUseBadge extends StatelessWidget {
  const ModelUseBadge({
    super.key,
    required this.usedModelOutput,
    this.compact = false,
  });

  final bool usedModelOutput;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = usedModelOutput ? Colors.teal.shade700 : cs.outline;
    final background = usedModelOutput
        ? Colors.teal.shade50
        : cs.surfaceContainerHighest.withValues(alpha: 0.8);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 5 : 8,
        vertical: compact ? 1 : 3,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.14)),
      ),
      child: Text(
        usedModelOutput
            ? 'Gemma 4 used local evidence'
            : 'Local rules fallback',
        style: TextStyle(
          fontSize: compact ? 9 : 11,
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class EvidenceReceipt extends StatelessWidget {
  const EvidenceReceipt({
    super.key,
    required this.usedModelOutput,
    required this.evidenceHash,
    required this.generatedAt,
    this.status,
    this.traceJson = const {},
  });

  final bool usedModelOutput;
  final String? evidenceHash;
  final DateTime? generatedAt;
  final String? status;
  final Map<String, Object?> traceJson;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final hash = evidenceHash == null || evidenceHash!.isEmpty
        ? 'not available'
        : evidenceHash!.substring(
            0,
            evidenceHash!.length < 10 ? evidenceHash!.length : 10,
          );
    final profile = traceJson['active_runtime_profile'];
    final latency = traceJson['latency_ms'];
    final fallback = traceJson['fallback_reason'];
    return Theme(
      data: Theme.of(context).copyWith(
        dividerColor: Colors.transparent,
        visualDensity: VisualDensity.compact,
      ),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        dense: true,
        title: Text(
          'Evidence receipt',
          style: tt.labelMedium?.copyWith(color: cs.outline),
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              [
                usedModelOutput
                    ? 'Gemma 4 generated this from local evidence.'
                    : 'Deterministic fallback used local evidence.',
                if (status != null) 'Status: $status',
                'Evidence hash: $hash',
                if (generatedAt != null)
                  'Prepared: ${generatedAt!.toLocal().toString()}',
                if (profile != null) 'Runtime profile: $profile',
                if (latency != null) 'Latency: ${latency}ms',
                if (fallback != null) 'Fallback reason: $fallback',
                'Not a diagnosis or medication recommendation.',
              ].join('\n'),
              style: tt.bodySmall?.copyWith(color: cs.outline),
            ),
          ),
        ],
      ),
    );
  }
}
