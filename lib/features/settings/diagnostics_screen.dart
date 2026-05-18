import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_services.dart';
import '../../core/database/wearable_sample_repository.dart';
import '../../core/services/diagnostic_log_service.dart';
import '../../core/services/gemma_audit_service.dart';
import '../../core/services/local_model_runtime.dart';

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  bool _loading = true;
  Map<String, Object?> _summary = const {};
  List<DiagnosticLogRecord> _logs = const [];
  List<GemmaTaskAuditView> _gemmaAudits = const [];
  LocalModelRuntimeStatus? _runtimeStatus;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final futures = await Future.wait([
      AppServices.diagnosticLogService.buildDiagnosticSummary(limit: 100),
      AppServices.wearableSampleRepository.getDiagnosticLogs(limit: 100),
      AppServices.localModelRuntime.getRuntimeStatus(),
      AppServices.gemmaAuditService.recent(limit: 8),
    ]);
    if (!mounted) return;
    setState(() {
      _summary = futures[0] as Map<String, Object?>;
      _logs = futures[1] as List<DiagnosticLogRecord>;
      _runtimeStatus = futures[2] as LocalModelRuntimeStatus;
      _gemmaAudits = futures[3] as List<GemmaTaskAuditView>;
      _loading = false;
    });
  }

  Future<void> _copySummary() async {
    final json = const JsonEncoder.withIndent('  ').convert(_summary);
    await Clipboard.setData(ClipboardData(text: json));
    await AppServices.diagnosticLogService.info(
      'diagnostics_summary_copied',
      category: 'diagnostics',
      message: 'Diagnostics summary copied locally.',
      metadata: {'row_count': _logs.length},
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Diagnostics summary copied.')),
    );
  }

  Future<void> _prune() async {
    await AppServices.diagnosticLogService.prune();
    await AppServices.diagnosticLogService.info(
      'diagnostics_pruned',
      category: 'diagnostics',
      message: 'Diagnostic log retention was applied.',
    );
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Old diagnostics pruned.')));
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final countsByLevel =
        (_summary['counts_by_level'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final countsByCategory =
        (_summary['counts_by_category'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final filteredLogs = _filteredLogs();
    final runtimeHealth = _runtimeHealthSummary();

    return Scaffold(
      appBar: AppBar(title: const Text('Local diagnostics')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text('Local app logs', style: tt.headlineSmall),
              const SizedBox(height: 8),
              Text(
                'These logs stay on this iPhone. Metadata is scrubbed so raw health values and chat text are not written to diagnostic log rows.',
                style: tt.bodyMedium?.copyWith(color: cs.outline),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: _loading ? null : _copySummary,
                    icon: const Icon(Icons.copy_rounded),
                    label: const Text('Copy summary'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _loading ? null : _prune,
                    icon: const Icon(Icons.cleaning_services_outlined),
                    label: const Text('Apply retention'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _KeyValueSection(title: 'By level', values: countsByLevel),
              const SizedBox(height: 16),
              _KeyValueSection(title: 'By category', values: countsByCategory),
              const SizedBox(height: 20),
              _KeyValueSection(
                title: 'Gemma runtime health',
                values: runtimeHealth,
              ),
              if (_gemmaAudits.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text('Gemma proof path', style: tt.titleMedium),
                const SizedBox(height: 8),
                for (final audit in _gemmaAudits) _GemmaAuditTile(audit: audit),
              ],
              const SizedBox(height: 20),
              Text('Filters', style: tt.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _FilterChip(
                    label: 'All',
                    selected: _filter == 'all',
                    onSelected: () => setState(() => _filter = 'all'),
                  ),
                  _FilterChip(
                    label: 'Chat',
                    selected: _filter == 'chat',
                    onSelected: () => setState(() => _filter = 'chat'),
                  ),
                  _FilterChip(
                    label: 'Gemma tasks',
                    selected: _filter == 'gemma_tasks',
                    onSelected: () => setState(() => _filter = 'gemma_tasks'),
                  ),
                  _FilterChip(
                    label: 'Runtime errors',
                    selected: _filter == 'runtime_errors',
                    onSelected: () =>
                        setState(() => _filter = 'runtime_errors'),
                  ),
                  _FilterChip(
                    label: 'Health sync',
                    selected: _filter == 'health_sync',
                    onSelected: () => setState(() => _filter = 'health_sync'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text('Latest events', style: tt.titleLarge),
              const SizedBox(height: 8),
              if (_loading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (filteredLogs.isEmpty)
                Text(
                  'No diagnostic events match this filter.',
                  style: tt.bodyMedium?.copyWith(color: cs.outline),
                )
              else
                for (final log in filteredLogs) _DiagnosticLogTile(log: log),
            ],
          ),
        ),
      ),
    );
  }

  List<DiagnosticLogRecord> _filteredLogs() {
    return _logs.where((log) {
      switch (_filter) {
        case 'chat':
          return log.category == DiagnosticLogService.categoryChat;
        case 'gemma_tasks':
          return log.eventName.contains('gemma_task') ||
              log.eventName.contains('doctor_summary') ||
              log.category == DiagnosticLogService.categoryModelRuntime;
        case 'runtime_errors':
          return log.level == DiagnosticLogService.levelError ||
              log.category == DiagnosticLogService.categoryModelRuntime ||
              log.metadataJson['fallback_reason'] != null ||
              log.metadataJson['failure_stage'] != null ||
              log.metadataJson['native_decode_rc'] != null;
        case 'health_sync':
          return log.category == DiagnosticLogService.categoryHealthSync;
        default:
          return true;
      }
    }).toList(growable: false);
  }

  Map<String, Object?> _runtimeHealthSummary() {
    final status = _runtimeStatus;
    final chatModelResponses =
        _logs.where((log) => log.eventName == 'chat_model_response').length;
    final chatFallbackResponses =
        _logs.where((log) => log.eventName == 'chat_fallback_response').length;
    final taskRows = _logs.where(
      (log) =>
          log.eventName == 'gemma_task_completed' ||
          log.eventName == 'doctor_summary_model_response' ||
          log.eventName == 'doctor_summary_fallback_response',
    );
    final taskSuccessRows = taskRows
        .where((log) => log.metadataJson['used_model_output'] == true)
        .length;
    final latencyValues = _logs
        .map((log) => log.metadataJson['latency_ms'])
        .whereType<num>()
        .map((value) => value.toDouble())
        .toList(growable: false);
    final avgLatency = latencyValues.isEmpty
        ? null
        : latencyValues.reduce((a, b) => a + b) / latencyValues.length;
    final latestGeneration = _logs
        .map((log) => log.metadataJson['generation_status'])
        .whereType<String>()
        .firstOrNull;
    final latestFallback = _logs
        .map((log) => log.metadataJson['fallback_reason'])
        .whereType<String>()
        .firstOrNull;
    return {
      'model_loaded': status?.isModelLoaded ?? false,
      'active_profile': status?.activeRuntimeProfile ?? 'unknown',
      'context_window': status?.contextWindow ?? 0,
      'batch_size': status?.batchSize ?? 0,
      'last_generation_status': latestGeneration ?? 'none',
      'last_fallback_reason': latestFallback ?? 'none',
      'model_responses_today': chatModelResponses,
      'fallback_responses_today': chatFallbackResponses,
      'structured_task_success_rate': taskRows.isEmpty
          ? 'n/a'
          : '${((taskSuccessRows / taskRows.length) * 100).round()}%',
      'avg_generation_latency_ms':
          avgLatency == null ? 'n/a' : avgLatency.round(),
    };
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
    );
  }
}

class _KeyValueSection extends StatelessWidget {
  const _KeyValueSection({required this.title, required this.values});

  final String title;
  final Map<String, Object?> values;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: tt.titleMedium),
        const SizedBox(height: 8),
        if (values.isEmpty)
          Text(
            'No entries yet.',
            style: tt.bodySmall?.copyWith(color: cs.outline),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: values.entries
                .map(
                  (entry) => Chip(label: Text('${entry.key}: ${entry.value}')),
                )
                .toList(growable: false),
          ),
      ],
    );
  }
}

class _DiagnosticLogTile extends StatelessWidget {
  const _DiagnosticLogTile({required this.log});

  final DiagnosticLogRecord log;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final metadataPreview = _metadataPreview(log.metadataJson);
    return Semantics(
      label: 'Diagnostic event ${log.eventName}, ${log.level}',
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(_iconForLevel(log.level), color: _colorForLevel(cs)),
        title: Text(
          '${log.category} · ${log.eventName}',
          style: tt.titleMedium,
        ),
        subtitle: Text(
          [
            log.message,
            log.createdAt.toLocal().toString(),
            if (metadataPreview.isNotEmpty) metadataPreview,
          ].join('\n'),
          style: tt.bodySmall?.copyWith(color: cs.outline),
        ),
      ),
    );
  }

  IconData _iconForLevel(String level) {
    return switch (level) {
      'error' => Icons.error_outline_rounded,
      'warning' => Icons.warning_amber_rounded,
      'debug' => Icons.bug_report_outlined,
      _ => Icons.info_outline_rounded,
    };
  }

  Color _colorForLevel(ColorScheme cs) {
    return switch (log.level) {
      'error' => cs.error,
      'warning' => cs.tertiary,
      _ => cs.primary,
    };
  }

  String _metadataPreview(Map<String, Object?> metadata) {
    const preferredKeys = [
      'used_model_output',
      'generation_status',
      'fallback_reason',
      'runtime_loaded',
      'estimated_prompt_tokens',
      'prompt_budget',
      'generation_limit',
      'latency_ms',
      'active_runtime_profile',
      'native_decode_rc',
      'failure_stage',
    ];
    final entries = <String>[];
    for (final key in preferredKeys) {
      if (metadata.containsKey(key)) {
        entries.add('$key: ${metadata[key]}');
      }
    }
    if (entries.isEmpty) {
      entries.addAll(
        metadata.entries.take(4).map((entry) => '${entry.key}: ${entry.value}'),
      );
    }
    return entries.isEmpty ? '' : 'Metadata: ${entries.take(8).join(' · ')}';
  }
}

class _GemmaAuditTile extends StatelessWidget {
  const _GemmaAuditTile({required this.audit});

  final GemmaTaskAuditView audit;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final hash = audit.outputHash == null || audit.outputHash!.isEmpty
        ? 'none'
        : audit.outputHash!.substring(
            0,
            audit.outputHash!.length < 10 ? audit.outputHash!.length : 10,
          );
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        audit.usedModelOutput
            ? Icons.auto_awesome_rounded
            : Icons.rule_folder_outlined,
        color: audit.usedModelOutput ? Colors.teal.shade700 : cs.outline,
      ),
      title: Text(
        '${audit.taskType} · ${audit.qualityLabel}',
        style: tt.titleSmall,
      ),
      subtitle: Text(
        [
          'Prompt: ${audit.promptVersion}',
          'Status: ${audit.status} / ${audit.validationStatus}',
          'Latency: ${audit.latencyMs}ms · Output hash: $hash',
          audit.createdAt.toLocal().toString(),
        ].join('\n'),
        style: tt.bodySmall?.copyWith(color: cs.outline),
      ),
    );
  }
}
