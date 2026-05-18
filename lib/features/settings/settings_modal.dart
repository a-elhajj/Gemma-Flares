import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_services.dart';
import '../../core/database/wearable_sample_repository.dart';
import '../../core/services/health_sync_service.dart';
import '../../core/services/local_model_runtime.dart';
import '../../core/services/pinned_fact_service.dart';
import '../../core/theme/theme_mode_controller.dart';

class SettingsModal extends StatefulWidget {
  const SettingsModal({super.key});

  @override
  State<SettingsModal> createState() => _SettingsModalState();
}

class _SettingsModalState extends State<SettingsModal> {
  late Future<_SettingsSnapshot> _snapshotFuture;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _snapshotFuture = _loadSnapshot();
  }

  Future<_SettingsSnapshot> _loadSnapshot() async {
    final runtime = await AppServices.localModelRuntime.getRuntimeStatus();
    final health = await AppServices.healthSyncService.getAuthorizationStatus(
      metrics: HealthSyncService.allProductionMetrics,
    );
    final fact = await AppServices.pinnedFactService.load();
    final auditRows = await AppServices.toolAuditService.latest(limit: 8);
    final ragSummary = await AppServices.wearableSampleRepository
        .getRagMemoryTransactionSummary()
        .catchError(
          (_) => const RagMemoryTransactionSummary(
            totalCount: 0,
            bySourceType: {},
            byStatus: {},
          ),
        );
    final ragTransactions = await AppServices.wearableSampleRepository
        .getRagMemoryTransactions(limit: 25)
        .catchError((_) => const <RagMemoryTransactionRecord>[]);
    final pendingDeletes = await AppServices.memoryControlsService
        .pendingDeletes(limit: 8)
        .catchError((_) => const <Map<String, Object?>>[]);
    return _SettingsSnapshot(
      runtime: runtime,
      healthAvailable: health.healthDataAvailable,
      authorizedHealthTypes: health.typeStatuses.entries
          .where((entry) => entry.value.name == 'authorized')
          .map((entry) => entry.key.name)
          .toList(growable: false),
      fact: fact,
      auditRows: auditRows,
      ragSummary: ragSummary,
      ragTransactions: ragTransactions,
      pendingDeletes: pendingDeletes,
    );
  }

  Future<void> _refresh() async {
    setState(() {
      _snapshotFuture = _loadSnapshot();
    });
  }

  Future<void> _requestHealthAccess() async {
    setState(() {
      _working = true;
    });
    try {
      await AppServices.healthSyncService.requestAuthorization(
        metrics: HealthSyncService.allProductionMetrics,
      );
      await _refresh();
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
        });
      }
    }
  }

  Future<void> _exportData() async {
    setState(() {
      _working = true;
    });
    try {
      final export =
          await AppServices.localDataControlsService.buildExportBundle();
      await Clipboard.setData(ClipboardData(text: export.toPrettyJson()));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Local export copied to clipboard.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
        });
      }
    }
  }

  Future<void> _wipeLocalData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete local data?'),
        content: const Text(
          'This removes local health samples, chat history, summaries, memory, and audit rows from this iPhone. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _working = true;
    });
    try {
      await AppServices.localDataControlsService.clearLocalData();
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Local Gemma Flares data was deleted.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
        });
      }
    }
  }

  Future<void> _resetGemmaModels() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Gemma 4 models?'),
        content: const Text(
          'This deletes local Gemma 4 model artifacts and marks setup for model repair. Health data, chat history, memory, and audit rows stay on this iPhone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _working = true;
    });
    try {
      // Reset the LiteRT-LM artifact unconditionally so the next cold-start
      // triggers a fresh download and validation in the setup wizard.
      await AppServices.liteRtLmDownloadService.resetArtifact();
      await AppServices.setupStateService.markModelNeedsRepair();
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Gemma 4 model reset. Reopen the app to reinstall.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
        });
      }
    }
  }

  Future<void> _resetSetup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset setup wizard?'),
        content: const Text(
          'Clears your profile and setup state. Health data, chat history, and memory stay on this iPhone. The setup wizard will open immediately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _working = true);
    try {
      await AppServices.resetSetupForDevelopment();
    } finally {
      if (mounted) setState(() => _working = false);
    }
    if (!mounted) return;
    // Pop settings with a sentinel value so HomeScreen re-opens the wizard.
    Navigator.of(context).pop('reset_setup');
  }

  bool _isDarkModeEnabled(BuildContext context) {
    final controller = ThemeModeControllerScope.of(context);
    switch (controller.themeMode) {
      case ThemeMode.dark:
        return true;
      case ThemeMode.light:
        return false;
      case ThemeMode.system:
        return Theme.of(context).brightness == Brightness.dark;
    }
  }

  void _setDarkMode(BuildContext context, bool enabled) {
    final controller = ThemeModeControllerScope.of(context);
    unawaited(
      controller.setThemeMode(enabled ? ThemeMode.dark : ThemeMode.light),
    );
  }

  String _formatCountInline(Map<String, int> counts) {
    if (counts.isEmpty) return 'none';
    return counts.entries
        .map((entry) => '${entry.key} ${entry.value}')
        .join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close settings',
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (_working)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: FutureBuilder<_SettingsSnapshot>(
        future: _snapshotFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snapshot.data!;
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _SectionHeader('Appearance'),
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.dark_mode_outlined),
                  title: const Text('Dark mode'),
                  subtitle: const Text(
                    'Use a darker look across Gemma Flares.',
                  ),
                  value: _isDarkModeEnabled(context),
                  onChanged: (enabled) => _setDarkMode(context, enabled),
                ),
                _SectionHeader('Privacy'),
                _InfoTile(
                  icon: Icons.lock_outline,
                  title: 'Local-only health data',
                  subtitle:
                      'Gemma Flares stores health data in an encrypted database on this iPhone. Model processing is local; there is no cloud handoff.',
                  color: colorScheme.primary,
                ),
                _InfoTile(
                  icon: Icons.medical_information_outlined,
                  title: 'Not a diagnosis',
                  subtitle:
                      'Risk scores and chat responses describe patterns. They do not diagnose a flare or recommend medication changes.',
                  color: colorScheme.tertiary,
                ),
                _SectionHeader('Health'),
                ListTile(
                  leading: const Icon(Icons.health_and_safety_outlined),
                  title: Text(
                    data.healthAvailable
                        ? '${data.authorizedHealthTypes.length} Health types authorized'
                        : 'Health data unavailable',
                  ),
                  subtitle: Text(
                    data.authorizedHealthTypes.isEmpty
                        ? 'Grant Apple Health access to improve wearable-based risk estimates.'
                        : data.authorizedHealthTypes.take(5).join(', '),
                  ),
                  trailing: TextButton(
                    onPressed: _working ? null : _requestHealthAccess,
                    child: const Text('Manage'),
                  ),
                ),
                _SectionHeader('Model'),
                ListTile(
                  leading: const Icon(Icons.memory_outlined),
                  title: Text(data.runtime.runtimeName),
                  subtitle: Text(
                    '${data.runtime.status} · ${data.runtime.activeRuntimeProfile} · ${data.runtime.backendUsed}',
                  ),
                ),
                _SectionHeader('Memory'),
                ExpansionTile(
                  leading: const Icon(Icons.push_pin_outlined),
                  title: const Text('Pinned health facts'),
                  subtitle: Text(
                    data.fact == null
                        ? 'No pinned facts saved yet.'
                        : '${data.fact!.content.length} fields saved, updated ${data.fact!.updatedAt.toLocal()}',
                  ),
                  children: data.fact == null
                      ? const []
                      : data.fact!.content.entries
                          .take(12)
                          .map(
                            (entry) => ListTile(
                              dense: true,
                              title: Text(entry.key),
                              subtitle: Text('${entry.value}'),
                            ),
                          )
                          .toList(growable: false),
                ),
                ExpansionTile(
                  leading: const Icon(Icons.storage_outlined),
                  title: const Text('RAG memory ledger'),
                  subtitle: Text(
                    data.ragSummary.totalCount == 0
                        ? 'No RAG transactions saved yet.'
                        : 'Showing ${data.ragTransactions.length} of ${data.ragSummary.totalCount} memory transactions',
                  ),
                  children: [
                    if (data.ragSummary.totalCount > 0)
                      ListTile(
                        dense: true,
                        title: const Text('Ledger summary'),
                        subtitle: Text(
                          [
                            'Total ${data.ragSummary.totalCount}',
                            'Source types: ${_formatCountInline(data.ragSummary.bySourceType)}',
                            'Statuses: ${_formatCountInline(data.ragSummary.byStatus)}',
                          ].join('\n'),
                        ),
                      ),
                    ...data.ragTransactions.map(
                      (row) => ListTile(
                        dense: true,
                        title: Text(row.transactionId),
                        subtitle: Text(
                          [
                            row.createdAt.toLocal().toString(),
                            row.sourceType,
                            'source #${row.sourceId}',
                            row.status,
                            if (row.indexedAt != null) 'indexed',
                            if (row.verifiedAt != null) 'verified',
                          ].join(' · '),
                        ),
                      ),
                    ),
                  ],
                ),
                ExpansionTile(
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: const Text('Tool audit'),
                  subtitle: Text(
                    data.auditRows.isEmpty
                        ? 'No tool calls recorded yet.'
                        : '${data.auditRows.length} recent local tool call records',
                  ),
                  children: data.auditRows
                      .map(
                        (row) => ListTile(
                          dense: true,
                          title: Text(
                            row['tool_name']?.toString() ?? 'unknown_tool',
                          ),
                          subtitle: Text(
                            [
                              if (row['called_at'] != null)
                                row['called_at'].toString(),
                              if (row['error'] != null) 'error recorded',
                              'retry ${row['retry_count'] ?? 0}',
                            ].join(' · '),
                          ),
                        ),
                      )
                      .toList(growable: false),
                ),
                ExpansionTile(
                  leading: const Icon(Icons.history_toggle_off_outlined),
                  title: const Text('Forget queue'),
                  subtitle: Text(
                    data.pendingDeletes.isEmpty
                        ? 'No pending memory deletes.'
                        : '${data.pendingDeletes.length} items pending hard delete',
                  ),
                  children: data.pendingDeletes
                      .map(
                        (row) => ListTile(
                          dense: true,
                          title: Text(
                            '${row['target_table']} #${row['target_row_id']}',
                          ),
                          subtitle: Text(
                            'Hard delete after ${row['hard_delete_after']}',
                          ),
                        ),
                      )
                      .toList(growable: false),
                ),
                _SectionHeader('Data Controls'),
                ListTile(
                  leading: const Icon(Icons.ios_share_outlined),
                  title: const Text('Export local data'),
                  subtitle: const Text(
                    'Create a local JSON export for review or backup.',
                  ),
                  onTap: _working ? null : _exportData,
                ),
                ListTile(
                  leading: const Icon(Icons.model_training_outlined),
                  title: const Text('Reset Gemma 4 models'),
                  subtitle: const Text(
                    'Delete model artifacts only; keep health data and memory.',
                  ),
                  onTap: _working ? null : _resetGemmaModels,
                ),
                ListTile(
                  leading: const Icon(Icons.restart_alt_outlined),
                  title: const Text('Reset setup wizard'),
                  subtitle: const Text(
                    'Clear profile and setup state; re-opens the setup wizard. Health data and memory are kept.',
                  ),
                  onTap: _working ? null : _resetSetup,
                ),
                ListTile(
                  leading: Icon(
                    Icons.delete_forever_outlined,
                    color: colorScheme.error,
                  ),
                  title: Text(
                    'Delete local data',
                    style: TextStyle(color: colorScheme.error),
                  ),
                  subtitle: const Text(
                    'Remove local records from this iPhone.',
                  ),
                  onTap: _working ? null : _wipeLocalData,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SettingsSnapshot {
  const _SettingsSnapshot({
    required this.runtime,
    required this.healthAvailable,
    required this.authorizedHealthTypes,
    required this.fact,
    required this.auditRows,
    required this.ragSummary,
    required this.ragTransactions,
    required this.pendingDeletes,
  });

  final LocalModelRuntimeStatus runtime;
  final bool healthAvailable;
  final List<String> authorizedHealthTypes;
  final PinnedFact? fact;
  final List<Map<String, Object?>> auditRows;
  final RagMemoryTransactionSummary ragSummary;
  final List<RagMemoryTransactionRecord> ragTransactions;
  final List<Map<String, Object?>> pendingDeletes;
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 20, 0, 6),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title),
      subtitle: Text(subtitle),
    );
  }
}
