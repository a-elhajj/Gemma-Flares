import 'package:flutter/material.dart';

/// 7-day HRV/risk sparkline. Tapping expands to a full multi-series chart
/// in a DraggableScrollableSheet.
class SparklineWidget extends StatefulWidget {
  const SparklineWidget({super.key, required this.values});

  /// Normalized values in [0, 1]. Null entries render as gaps.
  final List<double?> values;

  @override
  State<SparklineWidget> createState() => _SparklineWidgetState();
}

class _SparklineWidgetState extends State<SparklineWidget> {
  void _openExpandedChart() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.45,
        maxChildSize: 0.85,
        minChildSize: 0.3,
        expand: false,
        builder: (context, scrollController) => _ExpandedChartSheet(
          values: widget.values,
          scrollController: scrollController,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      label: 'Risk trend sparkline, tap to expand full chart',
      button: true,
      child: GestureDetector(
        onTap: _openExpandedChart,
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
          ),
          child: widget.values.isEmpty
              ? Center(
                  child: Text(
                    'No data yet',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                )
              : CustomPaint(
                  painter: _SparklinePainter(
                    values: widget.values,
                    lineColor: colorScheme.primary,
                  ),
                  size: Size.infinite,
                ),
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.values, required this.lineColor});

  final List<double?> values;
  final Color lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;

    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final step = size.width / (values.length - 1).clamp(1, double.infinity);
    final path = Path();
    bool moved = false;

    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v == null) {
        moved = false;
        continue;
      }
      final x = i * step;
      final y = size.height - v * size.height;
      if (!moved) {
        path.moveTo(x, y);
        moved = true;
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.values != values || old.lineColor != lineColor;
}

class _ExpandedChartSheet extends StatelessWidget {
  const _ExpandedChartSheet({
    required this.values,
    required this.scrollController,
  });

  final List<double?> values;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: colorScheme.onSurfaceVariant.withAlpha(80),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                Text('Trends', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close chart',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.all(20),
              child: SizedBox(
                height: 220,
                child: CustomPaint(
                  painter: _SparklinePainter(
                    values: values,
                    lineColor: colorScheme.primary,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
