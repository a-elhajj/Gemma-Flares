import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/services/evaluation_service.dart';
import '../../core/services/runtime_benchmark_service.dart';
import '../../core/widgets/section_card.dart';

class ResearchEvaluationScreen extends StatefulWidget {
  const ResearchEvaluationScreen({
    super.key,
    this.reportLoader,
  });

  final Future<EvaluationReport> Function()? reportLoader;

  @override
  State<ResearchEvaluationScreen> createState() =>
      _ResearchEvaluationScreenState();
}

class _ResearchEvaluationScreenState extends State<ResearchEvaluationScreen> {
  EvaluationReport? _report;
  RuntimeBenchmarkReport? _benchmarkReport;
  Object? _error;
  Object? _benchmarkError;
  bool _loading = false;
  bool _benchmarking = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final report = await (widget.reportLoader?.call() ??
          AppServices.evaluationService.generateReport());
      if (!mounted) {
        return;
      }
      setState(() => _report = report);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _runBenchmark(String profile) async {
    setState(() {
      _benchmarking = true;
      _benchmarkError = null;
    });
    try {
      final report = await AppServices.runtimeBenchmarkService.runProfile(
        profile: profile,
      );
      if (!mounted) return;
      setState(() => _benchmarkReport = report);
    } catch (error) {
      if (!mounted) return;
      setState(() => _benchmarkError = error);
    } finally {
      if (mounted) {
        setState(() => _benchmarking = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Local diagnostics')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            Text('Local model diagnostics', style: tt.headlineMedium),
            const SizedBox(height: 8),
            Text(
              'This view audits the local flare models against labeled days already stored on device. Metrics are diagnostic only and are not clinical validation.',
              style: tt.bodyMedium,
            ),
            const SizedBox(height: 20),
            _RuntimeBenchmarkCard(
              report: _benchmarkReport,
              error: _benchmarkError,
              running: _benchmarking,
              onRun: _runBenchmark,
            ),
            const SizedBox(height: 16),
            if (_loading && _report == null) ...[
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 20),
            ] else if (_error != null && _report == null) ...[
              SectionCard(
                title: 'Evaluation unavailable',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Could not generate the local research report right now.',
                    ),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ),
              ),
            ] else if (_report != null) ...[
              _OverviewCard(
                report: _report!,
                loading: _loading,
                onRefresh: _load,
              ),
              const SizedBox(height: 16),
              _CoverageCard(report: _report!),
              const SizedBox(height: 16),
              if (_report!.metrics.isEmpty)
                const SectionCard(
                  title: 'Model metrics',
                  child: Text(
                    'Not enough labeled days yet. Add more check-ins, procedures, and lab-backed flare labels to unlock AUC, AUPRC, and F1 reporting.',
                  ),
                )
              else
                ..._report!.metrics.map(
                  (metric) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _MetricCard(metric: metric),
                  ),
                ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _RuntimeBenchmarkCard extends StatelessWidget {
  const _RuntimeBenchmarkCard({
    required this.report,
    required this.error,
    required this.running,
    required this.onRun,
  });

  final RuntimeBenchmarkReport? report;
  final Object? error;
  final bool running;
  final void Function(String profile) onRun;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return SectionCard(
      title: 'Gemma runtime benchmark',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Run this on the target iPhone before recording. Check which backend actually loaded, the first-turn cold latency, and whether quality rejections or decode failures force fallback.',
            style: tt.bodySmall,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: running ? null : () => onRun('phone_safe'),
                child: const Text('Benchmark phone_safe'),
              ),
              FilledButton.tonal(
                onPressed: running ? null : () => onRun('phone_balanced'),
                child: const Text('Benchmark phone_balanced'),
              ),
            ],
          ),
          if (running) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          if (error != null) ...[
            const SizedBox(height: 12),
            Text('Benchmark unavailable right now.', style: tt.bodySmall),
          ],
          if (report != null) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _MetricPill(label: 'Profile', value: report!.profile),
                _MetricPill(
                  label: 'Load backend',
                  value: report!.loadBackendUsed,
                ),
                _MetricPill(
                  label: 'Load latency',
                  value: '${report!.loadLatencyMs} ms',
                ),
                _MetricPill(
                  label: 'Engine create',
                  value: '${report!.loadEngineCreateLatencyMs} ms',
                ),
                _MetricPill(label: 'Success', value: '${report!.successCount}'),
                _MetricPill(
                  label: 'Fallback',
                  value: '${report!.fallbackCount}',
                ),
                _MetricPill(
                  label: 'Decode fails',
                  value: '${report!.decodeFailureCount}',
                ),
                _MetricPill(
                  label: 'Rejected',
                  value: '${report!.rejectedOutputCount}',
                ),
                _MetricPill(
                  label: 'Cold start',
                  value: '${report!.coldStartLatencyMs} ms',
                ),
                _MetricPill(
                  label: 'Warm p50',
                  value: '${report!.warmP50LatencyMs} ms',
                ),
                _MetricPill(
                  label: 'Warm p95',
                  value: '${report!.warmP95LatencyMs} ms',
                ),
                _MetricPill(
                  label: 'GPU runs',
                  value: '${report!.gpuSampleCount}',
                ),
                _MetricPill(
                  label: 'CPU runs',
                  value: '${report!.cpuSampleCount}',
                ),
                _MetricPill(
                  label: 'p50 latency',
                  value: '${report!.p50LatencyMs} ms',
                ),
                _MetricPill(
                  label: 'p95 latency',
                  value: '${report!.p95LatencyMs} ms',
                ),
                _MetricPill(label: 'Model', value: _firstModelId(report!)),
                _MetricPill(label: 'TTFT', value: '${_firstTtft(report!)} ms'),
                _MetricPill(
                  label: 'Decode TPS',
                  value: _formatDouble(_firstDecodeTps(report!)),
                ),
                _MetricPill(
                  label: 'RAM MB',
                  value: _formatDouble(_firstRamUsage(report!)),
                ),
              ],
            ),
            if (report!.loadBackendFallbackReason != null) ...[
              const SizedBox(height: 10),
              Text(
                'Load fallback: ${report!.loadBackendFallbackReason}',
                style: tt.bodySmall,
              ),
            ],
          ],
        ],
      ),
    );
  }

  String _firstModelId(RuntimeBenchmarkReport report) {
    if (report.samples.isEmpty) return 'unknown';
    return report.samples.first.modelIdUsed;
  }

  int _firstTtft(RuntimeBenchmarkReport report) {
    if (report.samples.isEmpty) return 0;
    return report.samples.first.timeToFirstTokenMs;
  }

  double? _firstDecodeTps(RuntimeBenchmarkReport report) {
    for (final sample in report.samples) {
      if (sample.decodeTps != null) return sample.decodeTps;
    }
    return null;
  }

  double? _firstRamUsage(RuntimeBenchmarkReport report) {
    for (final sample in report.samples) {
      if (sample.ramUsageMb != null) return sample.ramUsageMb;
    }
    return null;
  }

  String _formatDouble(double? value) {
    if (value == null) return 'n/a';
    return value.toStringAsFixed(1);
  }
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({
    required this.report,
    required this.loading,
    required this.onRefresh,
  });

  final EvaluationReport report;
  final bool loading;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Overview',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(report.statusLabel),
          const SizedBox(height: 8),
          Text(
            'Generated ${_formatTimestamp(report.generatedAt.toLocal())}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: loading ? null : onRefresh,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(loading ? 'Refreshing...' : 'Recompute evaluation'),
          ),
        ],
      ),
    );
  }

  static String _formatTimestamp(DateTime dt) {
    final date =
        '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    final time =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return '$date at $time';
  }
}

class _CoverageCard extends StatelessWidget {
  const _CoverageCard({required this.report});

  final EvaluationReport report;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Label coverage',
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _CountChip(
            label: 'Labeled days',
            value: '${report.totalLabeledDays}',
          ),
          _CountChip(
            label: 'Inflammatory flare days',
            value: '${report.inflammatoryFlareDays}',
          ),
          _CountChip(
            label: 'Symptomatic flare days',
            value: '${report.symptomaticFlareDays}',
          ),
        ],
      ),
    );
  }
}

class _CountChip extends StatelessWidget {
  const _CountChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 2),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.metric});

  final EvaluationMetrics metric;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SectionCard(
      title:
          '${_titleCase(metric.flareType)} flare · ${metric.horizonDays} days',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            metric.vsTargetLabel,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.primary),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _MetricPill(label: 'AUC', value: metric.auc.toStringAsFixed(2)),
              _MetricPill(
                label: 'AUPRC',
                value: metric.auprc.toStringAsFixed(2),
              ),
              _MetricPill(label: 'F1', value: metric.f1.toStringAsFixed(2)),
              _MetricPill(
                label: 'Sensitivity',
                value: metric.sensitivity.toStringAsFixed(2),
              ),
              _MetricPill(
                label: 'Specificity',
                value: metric.specificity.toStringAsFixed(2),
              ),
              _MetricPill(
                label: 'Threshold',
                value: metric.optimalThreshold.toStringAsFixed(2),
              ),
              _MetricPill(label: 'Samples', value: '${metric.sampleCount}'),
            ],
          ),
        ],
      ),
    );
  }

  static String _titleCase(String value) =>
      value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';
}

class _MetricPill extends StatelessWidget {
  const _MetricPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 2),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
