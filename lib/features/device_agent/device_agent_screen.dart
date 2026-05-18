import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/services/device_autonomous_agent_service.dart';

class DeviceAgentScreen extends StatefulWidget {
  const DeviceAgentScreen({super.key});

  @override
  State<DeviceAgentScreen> createState() => _DeviceAgentScreenState();
}

class _DeviceAgentScreenState extends State<DeviceAgentScreen> {
  late final DeviceAutonomousAgentService _agent;
  StreamSubscription<DeviceAgentReport>? _subscription;
  DeviceAgentReport? _report;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _agent = DeviceAutonomousAgentService();
    _subscription = _agent.reports.listen((report) {
      if (mounted) setState(() => _report = report);
    });
    unawaited(_start());
  }

  Future<void> _start() async {
    if (_started) return;
    _started = true;
    final report = await _agent.run();
    if (mounted) setState(() => _report = report);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_agent.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('iPhone Agent'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: _StatusPill(status: report?.status ?? 'starting'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: report == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Physical iPhone autonomous run',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    report.reportPath == null
                        ? 'Running on this iPhone. Watch each step below; terminal logs also stream with GEMMA_FLARES_DEVICE_AGENT_EVENT.'
                        : 'Report saved on device: ${report.reportPath}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  _MetricRow(
                    personas: report.personas.length,
                    prompts: report.promptResults.length,
                    failures: report.errors.length +
                        report.promptResults
                            .where((item) => !item.passed)
                            .length,
                  ),
                  const SizedBox(height: 16),
                  Text('Steps', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  for (final step in report.steps.reversed.take(8))
                    _StepTile(step: step),
                  if (report.steps.isEmpty)
                    const LinearProgressIndicator(minHeight: 3),
                  const SizedBox(height: 18),
                  Text(
                    'Persona Findings',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  for (final result in report.promptResults.reversed.take(20))
                    _PromptResultTile(result: result),
                  if (report.promptResults.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text('Waiting for persona prompts...'),
                    ),
                  if (report.errors.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Text(
                      'Errors',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    for (final error in report.errors)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.error_outline),
                        title: Text(error['source']?.toString() ?? 'error'),
                        subtitle: Text(error['error']?.toString() ?? ''),
                      ),
                  ],
                ],
              ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final passed = status == 'passed';
    final failed = status == 'failed';
    final color = failed
        ? colorScheme.errorContainer
        : passed
            ? colorScheme.primaryContainer
            : colorScheme.secondaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(status),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.personas,
    required this.prompts,
    required this.failures,
  });

  final int personas;
  final int prompts;
  final int failures;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _MetricCard(label: 'Personas', value: '$personas'),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _MetricCard(label: 'Prompts', value: '$prompts'),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _MetricCard(label: 'Failures', value: '$failures'),
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(value, style: Theme.of(context).textTheme.titleLarge),
        ],
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({required this.step});

  final DeviceAgentStep step;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        step.status == 'passed'
            ? Icons.check_circle_outline
            : Icons.error_outline,
      ),
      title: Text(step.name),
      subtitle: Text('${step.status} • ${step.durationMs}ms'),
    );
  }
}

class _PromptResultTile extends StatelessWidget {
  const _PromptResultTile({required this.result});

  final DeviceAgentPromptResult result;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      leading: Icon(result.passed ? Icons.task_alt : Icons.report_outlined),
      title: Text(result.personaId),
      subtitle: Text(
        result.prompt,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      childrenPadding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            [
              'status: ${result.status}',
              'runtime: ${result.runtimeName}',
              'latency: ${result.latencyMs}ms',
              if (result.intent != null) 'intent: ${result.intent}',
              if (result.pendingActionType != null)
                'pending: ${result.pendingActionType}',
              '',
              result.response,
            ].join('\n'),
          ),
        ),
      ],
    );
  }
}
