import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_services.dart';
import '../../core/services/diagnostic_log_service.dart';
import '../../core/services/health_sync_service.dart';
import '../../core/services/local_model_runtime.dart';
import '../../core/theme/theme_mode_controller.dart';
import '../profile/profile_screen.dart';
import '../research/research_evaluation_screen.dart';
import 'diagnostics_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

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
    controller.setThemeMode(enabled ? ThemeMode.dark : ThemeMode.light);
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        children: [
          Text('Settings', style: tt.headlineMedium),
          const SizedBox(height: 6),
          Text(
            'Everything important, without the dashboard noise.',
            style: tt.bodyMedium?.copyWith(color: cs.outline),
          ),
          const SizedBox(height: 12),
          Text('Appearance', style: tt.titleMedium),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.dark_mode_outlined),
            title: const Text('Dark mode'),
            subtitle: const Text('Use a darker look across Gemma Flares.'),
            value: _isDarkModeEnabled(context),
            onChanged: (enabled) => _setDarkMode(context, enabled),
          ),
          const SizedBox(height: 20),
          _SettingsNavTile(
            icon: Icons.person_outline_rounded,
            title: 'My profile',
            subtitle: 'Personal details used to make local trends clearer.',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const ProfileScreen()),
              );
            },
          ),
          _SettingsNavTile(
            icon: Icons.shield_outlined,
            title: 'Privacy and safety',
            subtitle:
                'Local-only processing and what Gemma Flares can and cannot do.',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const _PrivacySafetyScreen(),
                ),
              );
            },
          ),
          _SettingsNavTile(
            icon: Icons.tune_rounded,
            title: 'App settings',
            subtitle: 'Health sync, local model, and data controls.',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const _AppSettingsScreen(),
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          Text(
            'Apple Watch writes to Health on this iPhone. Gemma Flares reads that data locally after you grant access.',
            textAlign: TextAlign.center,
            style: tt.bodySmall?.copyWith(color: cs.outline),
          ),
        ],
      ),
    );
  }
}

class _AppSettingsScreen extends StatefulWidget {
  const _AppSettingsScreen();

  @override
  State<_AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<_AppSettingsScreen> {
  String _healthStatus = '';
  String _syncStatus = '';
  String _runtimeName = '';
  String _runtimeDetail = '';
  String _activeProfile = 'phone_unknown';
  String _lastModelResult = '';
  bool _modelLoaded = false;
  bool _working = false;
  bool _researchUnlocked = false;
  Map<String, dynamic> _backends = const {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final status = await AppServices.healthSyncService.getAuthorizationStatus(
        metrics: HealthSyncService.allProductionMetrics,
      );
      final sync = await AppServices.wearableSampleRepository.getSyncState(
        'apple_health',
      );
      final rt = await AppServices.localModelRuntime.getRuntimeStatus();
      final backends =
          await AppServices.localModelRuntime.getAvailableBackends();
      if (!mounted) return;
      setState(() {
        _healthStatus = status.healthDataAvailable
            ? 'Authorized: ${status.typeStatuses.entries.where((e) => e.value.name == 'authorized').map((e) => e.key.name).join(', ')}'
            : 'Health data unavailable.';
        _syncStatus = sync?.lastSyncAt == null
            ? 'No sync completed yet.'
            : 'Last sync ${_formatDate(sync!.lastSyncAt!.toLocal())}';
        _runtimeName = rt.runtimeName;
        _activeProfile = rt.activeRuntimeProfile;
        _runtimeDetail = _formatRuntimeDetail(rt);
        _modelLoaded = rt.isModelLoaded;
        _backends = backends;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _healthStatus = 'Unavailable in this environment.';
        _runtimeDetail = 'Unavailable in this environment.';
      });
    }
  }

  Future<void> _requestAccess() async {
    setState(() => _working = true);
    try {
      final response = await AppServices.healthSyncService.requestAuthorization(
        metrics: HealthSyncService.allProductionMetrics,
      );
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            response.status == 'success'
                ? 'Health authorization request completed. Confirm access toggles in Apple Health.'
                : 'Health access was not granted yet.',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Health access could not be requested right now.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _syncHealthData() async {
    setState(() => _working = true);
    try {
      final sync = await AppServices.wearableSampleRepository.getSyncState(
        'apple_health',
      );
      final result = sync?.lastSyncAt == null
          ? await AppServices.healthSyncService.runInitialBackfill(
              metrics: HealthSyncService.allProductionMetrics,
            )
          : await AppServices.healthSyncService.runIncrementalSync(
              metrics: HealthSyncService.allProductionMetrics,
            );
      try {
        await AppServices.guidanceService.refreshLatestGuidance(
          reason: 'manual_health_sync',
        );
      } catch (_) {
        // The Health sync succeeded; guidance can retry on resume.
      }
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Health sync finished: ${result.inserted} new, ${result.updated} updated.',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Health sync could not finish right now.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _loadGemma({bool reload = false}) async {
    setState(() => _working = true);
    try {
      final profile = reload && _activeProfile != 'phone_unknown'
          ? _activeProfile
          : 'phone_balanced';
      final status = await AppServices.localModelRuntime.loadBundledModel(
        profile: profile,
      );
      await AppServices.diagnosticLogService.info(
        reload ? 'gemma_reload_requested' : 'gemma_load_requested',
        category: DiagnosticLogService.categoryModelRuntime,
        message: 'Local Gemma model load requested from Settings.',
        metadata: {
          'active_runtime_profile': status.activeRuntimeProfile,
          'runtime_loaded': status.isModelLoaded,
          'backend_requested': status.backendRequested,
          'backend_used': status.backendUsed,
          'backend_fallback_reason': status.backendFallbackReason,
          'engine_create_latency_ms': status.engineCreateLatencyMs,
          'context_window': status.contextWindow,
          'batch_size': status.batchSize,
        },
      );
      if (!mounted) return;
      setState(() {
        _lastModelResult = status.isModelLoaded
            ? _researchUnlocked
                ? 'Gemma loaded with ${status.activeRuntimeProfile} on ${status.backendUsed}.'
                : 'Gemma is loaded locally on this iPhone.'
            : 'Gemma did not load: ${status.status}.';
      });
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_lastModelResult)));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _runQuickModelTest() async {
    setState(() {
      _working = true;
      _lastModelResult = 'Running quick local model test...';
    });
    try {
      var status = await AppServices.localModelRuntime.getRuntimeStatus();
      if (!status.isModelLoaded &&
          status.isBundledModelPresent &&
          status.isBackendLinked) {
        status = await AppServices.localModelRuntime.loadBundledModel(
          profile: 'phone_balanced',
        );
      }
      LocalModelResponse response;
      if (status.isModelLoaded) {
        response = await AppServices.localModelRuntime.generate(
          const LocalModelRequest(
            systemPrompt:
                'You are Gemma Flares. Reply with exactly: OK Gemma ready.',
            userPrompt: 'Run a short readiness check.',
            groundedContext: {'task': 'quick_model_test'},
            maxTokens: 32,
            temperature: 0.01,
            taskType: 'quick_readiness',
          ),
        );
      } else {
        response = LocalModelResponse(
          status: 'unavailable',
          outputText: '',
          runtimeName: status.runtimeName,
          reason: status.reason,
          fallbackReason: status.status,
        );
      }
      final used = _isQuickTestSuccess(response);
      await AppServices.diagnosticLogService.info(
        used
            ? 'gemma_quick_test_success'
            : response.outputQualityStatus == 'rejected'
                ? 'gemma_quick_test_quality_failed'
                : 'gemma_quick_test_fallback',
        category: DiagnosticLogService.categoryModelRuntime,
        message: 'Local Gemma quick model test completed.',
        metadata: {
          'generation_status': response.status,
          'used_model_output': used,
          'fallback_reason': response.fallbackReason ?? response.reason,
          'output_quality_status': response.outputQualityStatus,
          'output_quality_reason': response.outputQualityReason,
          'prompt_template_version': response.promptTemplateVersion,
          'sanitizer_version': response.sanitizerVersion,
          'raw_output_hash': response.rawOutputHash,
          'estimated_prompt_tokens': response.estimatedPromptTokens,
          'prompt_budget': response.promptBudget,
          'generation_limit': response.generationLimit,
          'latency_ms': response.generationLatencyMs,
          'native_decode_rc': response.nativeDecodeRc,
          'failure_stage': response.failureStage,
          'active_runtime_profile': response.activeRuntimeProfile,
          'backend_requested': response.backendRequested,
          'backend_used': response.backendUsed,
          'backend_fallback_reason': response.backendFallbackReason,
          'engine_create_latency_ms': response.engineCreateLatencyMs,
          'quality_signals': response.qualitySignals,
        },
      );
      if (!mounted) return;
      setState(() {
        if (used) {
          _lastModelResult =
              'Local Gemma is ready in ${response.generationLatencyMs} ms.';
        } else {
          _lastModelResult = _formatQuickModelFailure(
            status: status,
            response: response,
          );
        }
      });
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_lastModelResult)));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _formatDate(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  bool _isQuickTestSuccess(LocalModelResponse response) {
    final normalized = response.outputText
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z\s]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return response.status == 'success' &&
        response.outputQualityStatus != 'rejected' &&
        (normalized == 'ok' ||
            normalized == 'ok gemma ready' ||
            normalized == 'gemma ready');
  }

  String _formatQuickModelFailure({
    required LocalModelRuntimeStatus status,
    required LocalModelResponse response,
  }) {
    if (!status.isModelLoaded) {
      return 'Local Gemma is not loaded on this iPhone yet.';
    }
    if (response.outputQualityStatus == 'rejected') {
      return 'Local Gemma answered, but the quick check failed the local quality guard.';
    }
    if (response.status == 'success' && response.outputText.trim().isNotEmpty) {
      return 'Local Gemma answered, but the quick check reply was not in the expected readiness format.';
    }
    return _researchUnlocked
        ? 'Local Gemma could not complete the quick check. Open Debug / Research for the internal reason.'
        : 'Local Gemma could not complete the quick check. Unlock Debug / Research if you need internal runtime details.';
  }

  String _formatRuntimeDetail(LocalModelRuntimeStatus status) {
    if (!status.isBundledModelPresent) {
      return 'The bundled local model is not present in this build.';
    }
    if (!status.isBackendLinked) {
      return 'The local runtime is not linked in this build.';
    }
    if (!_researchUnlocked) {
      if (status.isModelLoaded) {
        return 'Loaded locally on this iPhone.';
      }
      return 'Available on this iPhone but not loaded yet.';
    }
    return '${status.backendStyle} · ${status.modelId} ${status.quantization}\n'
        'Bundled: ${status.isBundledModelPresent ? 'yes' : 'no'} · '
        'Backend: ${status.isBackendLinked ? 'linked' : 'missing'} · '
        'Loaded: ${status.isModelLoaded ? 'yes' : 'no'}\n'
        'Requested: ${status.backendRequested} · '
        'Used: ${status.backendUsed} · '
        'Engine create: ${status.engineCreateLatencyMs} ms\n'
        'Profile: ${status.activeRuntimeProfile} · '
        'Context: ${status.contextWindow} · '
        'Batch: ${status.batchSize} · '
        'Timeout: ${status.generationTimeoutSeconds}s'
        '${status.backendFallbackReason == null ? '' : '\nFallback: ${status.backendFallbackReason}'}';
  }

  Future<void> _export() async {
    setState(() => _working = true);
    try {
      await AppServices.diagnosticLogService.info(
        'export_started',
        category: DiagnosticLogService.categoryExport,
        message: 'Local export preview started.',
      );
      final bundle =
          await AppServices.localDataControlsService.buildExportBundle();
      final json = bundle.toPrettyJson();
      if (!mounted) return;
      final copy = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Export preview'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(child: SelectableText(json)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Close'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Copy JSON'),
            ),
          ],
        ),
      );
      if (copy == true) {
        await Clipboard.setData(ClipboardData(text: json));
        await AppServices.diagnosticLogService.info(
          'export_copied',
          category: DiagnosticLogService.categoryExport,
          message: 'Local export copied to clipboard.',
          metadata: {'byte_count': json.length},
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Export copied to clipboard.')),
          );
        }
      }
    } catch (error, stackTrace) {
      await AppServices.diagnosticLogService.error(
        'export_failed',
        category: DiagnosticLogService.categoryExport,
        message: 'Local export could not be prepared.',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Export could not be prepared right now.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: const Text('Delete local data?'),
        content: const Text(
          'This removes Health imports, summaries, scores, symptoms, and chat from this device. Apple Health data is not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _working = true);
    try {
      await AppServices.diagnosticLogService.warning(
        'delete_local_data_confirmed',
        category: DiagnosticLogService.categorySettings,
        message: 'Local data deletion was confirmed by the user.',
      );
      await AppServices.localDataControlsService.clearLocalData();
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Local data deleted.')));
      }
    } catch (error, stackTrace) {
      await AppServices.diagnosticLogService.error(
        'delete_local_data_failed',
        category: DiagnosticLogService.categorySettings,
        message: 'Local data could not be deleted.',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Local data could not be deleted right now.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _showMemoryStatus() async {
    setState(() => _working = true);
    try {
      final stats = await AppServices.ragIndexService.getStoreStats();
      final summary = await AppServices.wearableSampleRepository
          .getRagMemoryTransactionSummary();
      final rows = await AppServices.wearableSampleRepository
          .getRagMemoryTransactions(limit: 25);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Memory status'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: SelectableText(
                [
                  'RAG enabled: ${stats['rag_enabled'] == true}',
                  'Corpus chunks: ${stats['chunk_count'] ?? 0}',
                  'Corpus bytes: ${stats['total_bytes'] ?? 0}',
                  'Ledger transactions: ${summary.totalCount}',
                  'Showing recent: ${rows.length} of ${summary.totalCount}',
                  '',
                  'By source type:',
                  ..._formatCountLines(summary.bySourceType),
                  '',
                  'By status:',
                  ..._formatCountLines(summary.byStatus),
                  '',
                  'Recent transactions:',
                  for (final row in rows)
                    '${row.transactionId} • ${row.status} • ${row.sourceType}/${row.sourceId}',
                ].join('\n'),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  List<String> _formatCountLines(Map<String, int> counts) {
    if (counts.isEmpty) return const ['- none'];
    return counts.entries
        .map((entry) => '- ${entry.key}: ${entry.value}')
        .toList(growable: false);
  }

  Future<void> _exportMemory() async {
    setState(() => _working = true);
    try {
      final json = (await AppServices.ragMemoryService.exportRagContents())
          .toPrettyJson();
      if (!mounted) return;
      final copy = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Memory export'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(child: SelectableText(json)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Close'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Copy JSON'),
            ),
          ],
        ),
      );
      if (copy == true) {
        await Clipboard.setData(ClipboardData(text: json));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Memory export copied.')),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _deleteMemory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_sweep_outlined),
        title: const Text('Delete memory contents?'),
        content: const Text(
          'This removes the local RAG corpus and marks memory transactions deleted. Health records, symptoms, labs, and chat history are not deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete memory'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _working = true);
    try {
      await AppServices.localDataControlsService.clearRagMemory();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Memory contents deleted.')),
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _retryMemory() async {
    setState(() => _working = true);
    try {
      await AppServices.ragMemoryService.retryPending();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Memory indexing retry complete.')),
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _runMemorySelfTest() async {
    setState(() => _working = true);
    try {
      final result = await AppServices.ragMemoryService.runSelfTest();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.verified
                ? 'Memory self-test verified in RAG.'
                : 'Memory write is durable; retrieval will activate after Gemma reloads.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _unlockResearchMode() async {
    final unlocked = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.science_outlined),
        title: const Text('Open Debug / Research?'),
        content: const Text(
          'This local-only screen shows diagnostic model metrics for builders. It is not clinical validation.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open'),
          ),
        ],
      ),
    );
    if (unlocked == true && mounted) {
      setState(() => _researchUnlocked = true);
    }
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
    controller.setThemeMode(enabled ? ThemeMode.dark : ThemeMode.light);
  }

  @override
  Widget build(BuildContext context) {
    final showDeveloperTools = !kReleaseMode;
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('App settings')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            children: [
              Text('Appearance', style: tt.titleMedium),
              const SizedBox(height: 8),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.dark_mode_outlined),
                title: const Text('Dark mode'),
                subtitle: const Text('Use a darker look across Gemma Flares.'),
                value: _isDarkModeEnabled(context),
                onChanged: (enabled) => _setDarkMode(context, enabled),
              ),
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 12),
              Text('Health sync', style: tt.titleMedium),
              const SizedBox(height: 8),
              _SettingsTile(
                icon: Icons.health_and_safety_outlined,
                title: 'Health permissions',
                subtitle: _healthStatus.isEmpty ? 'Checking...' : _healthStatus,
              ),
              _SettingsTile(
                icon: Icons.sync_rounded,
                title: 'Sync freshness',
                subtitle: _syncStatus.isEmpty ? 'Checking...' : _syncStatus,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _working ? null : _requestAccess,
                    icon: const Icon(Icons.verified_user_outlined, size: 18),
                    label: const Text('Request Health access'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _working ? null : _syncHealthData,
                    icon: const Icon(Icons.sync_rounded, size: 18),
                    label: const Text('Sync now'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 12),
              Text('Local model', style: tt.titleMedium),
              const SizedBox(height: 8),
              _SettingsTile(
                icon: Icons.memory_rounded,
                title: _researchUnlocked && _runtimeName.isNotEmpty
                    ? _runtimeName
                    : 'Local model',
                subtitle:
                    _runtimeDetail.isEmpty ? 'Checking...' : _runtimeDetail,
                trailing: _modelLoaded
                    ? Icon(
                        Icons.check_circle_rounded,
                        size: 20,
                        color: cs.primary,
                      )
                    : null,
              ),
              if (_backends.isNotEmpty && _researchUnlocked) ...[
                const SizedBox(height: 8),
                _BackendStatusChip(backends: _backends),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _working ? null : () => _loadGemma(),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('Load Gemma'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _working ? null : () => _loadGemma(reload: true),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Reload Gemma'),
                  ),
                  if (showDeveloperTools)
                    OutlinedButton.icon(
                      onPressed: _working ? null : _runQuickModelTest,
                      icon: const Icon(Icons.speed_rounded, size: 18),
                      label: const Text('Run quick model test'),
                    ),
                ],
              ),
              if (_lastModelResult.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _lastModelResult,
                  style: tt.bodySmall?.copyWith(color: cs.outline),
                ),
              ],
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 12),
              Text('Memory', style: tt.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _working ? null : _showMemoryStatus,
                    icon: const Icon(Icons.fact_check_outlined, size: 18),
                    label: const Text('View memory status'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _working ? null : _exportMemory,
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const Text('Export memory'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _working ? null : _retryMemory,
                    icon: const Icon(Icons.replay_outlined, size: 18),
                    label: const Text('Retry memory'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _working ? null : _runMemorySelfTest,
                    icon: const Icon(Icons.verified_outlined, size: 18),
                    label: const Text('Run memory self-test'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _working ? null : _deleteMemory,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    label: const Text('Delete memory'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 12),
              if (showDeveloperTools && _researchUnlocked)
                Column(
                  children: [
                    _SettingsNavTile(
                      icon: Icons.monitor_heart_outlined,
                      title: 'Local diagnostics',
                      subtitle:
                          'Scrubbed local logs, runtime status, and support audit trail.',
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const DiagnosticsScreen(),
                          ),
                        );
                      },
                    ),
                    _SettingsNavTile(
                      icon: Icons.science_outlined,
                      title: 'Debug / Research',
                      subtitle: 'Local diagnostic metrics for builders only.',
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const ResearchEvaluationScreen(),
                          ),
                        );
                      },
                    ),
                  ],
                )
              else if (showDeveloperTools)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Developer tools', style: tt.titleSmall),
                        const SizedBox(height: 6),
                        Text(
                          'Diagnostics, benchmark tooling, and research views stay hidden by default. Unlock them only if you are validating the local runtime.',
                          style: tt.bodySmall?.copyWith(color: cs.outline),
                        ),
                        const SizedBox(height: 10),
                        TextButton.icon(
                          onPressed: _unlockResearchMode,
                          icon: const Icon(
                            Icons.lock_outline_rounded,
                            size: 18,
                          ),
                          label: const Text('Unlock Debug / Research'),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 12),
              Text('Data controls', style: tt.titleMedium),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _working ? null : _export,
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: const Text('Export'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _working ? null : _delete,
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      label: const Text('Delete data'),
                      style: FilledButton.styleFrom(
                        backgroundColor: cs.error,
                        foregroundColor: cs.onError,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrivacySafetyScreen extends StatelessWidget {
  const _PrivacySafetyScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy and safety')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: const [
            _SettingsTile(
              icon: Icons.lock_outline_rounded,
              title: 'Local by default',
              subtitle:
                  'Health data, symptoms, scores, and guidance stay on this iPhone. Gemma Flares does not use a cloud health-data path.',
            ),
            _SettingsTile(
              icon: Icons.health_and_safety_outlined,
              title: 'Not a diagnosis',
              subtitle:
                  'Gemma Flares highlights trend changes and confidence. It does not diagnose flares, replace clinicians, or recommend medication changes.',
            ),
            _SettingsTile(
              icon: Icons.chat_bubble_outline_rounded,
              title: 'Review before save',
              subtitle:
                  'Symptoms extracted from Chat are saved only after you confirm them. Confirmed symptoms appear in Health > Symptoms and Timeline.',
            ),
            _SettingsTile(
              icon: Icons.auto_awesome_outlined,
              title: 'Gemma guidance',
              subtitle:
                  'Gemma 4 can explain grounded local evidence, but deterministic code remains the source of truth for scores and risk labels.',
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: cs.primaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: cs.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: tt.titleMedium),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: tt.bodySmall?.copyWith(color: cs.outline),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

class _SettingsNavTile extends StatelessWidget {
  const _SettingsNavTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: cs.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: tt.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: tt.bodySmall?.copyWith(color: cs.outline),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

class _BackendStatusChip extends StatelessWidget {
  const _BackendStatusChip({required this.backends});

  final Map<String, dynamic> backends;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    final litert = backends['litert-lm'] ?? backends['litert_lm'];
    final backendDict = (litert is Map) ? litert : null;
    final linked = (backendDict is Map) && backendDict['linked'] == true;
    final modelBundled =
        (backendDict is Map) && backendDict['modelBundled'] == true;
    final ready = linked && modelBundled;
    final activeBackend = (backendDict is Map)
        ? (backendDict['activeBackend'] as String? ?? 'unknown')
        : 'unknown';

    final String label;
    final Color color;
    final IconData icon;
    if (ready) {
      label = activeBackend == 'standby'
          ? 'Gemma E2B • LiteRT-LM model available'
          : 'Gemma E2B • LiteRT-LM ready';
      color = cs.primary;
      icon = Icons.check_circle_outlined;
    } else if (linked) {
      label = 'Gemma E2B • LiteRT-LM linked — model not installed';
      color = cs.error;
      icon = Icons.warning_amber_rounded;
    } else {
      label = 'Gemma E2B • LiteRT-LM not linked';
      color = cs.error;
      icon = Icons.error_outline_rounded;
    }

    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(label, style: tt.bodySmall?.copyWith(color: color)),
        ],
      ),
    );
  }
}
