import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/app_services.dart';
import 'package:gemma_flares/core/services/setup_state_service.dart';
import 'package:gemma_flares/features/home/home_screen.dart';
import 'package:gemma_flares/features/home/setup_wizard_dialog.dart';
import 'package:gemma_flares/main.dart' as app;
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('physical iPhone app functionality smoke report', (tester) async {
    final report = <String, Object?>{
      'scenario': 'physical_iphone_app_functionality_smoke',
      'started_at': DateTime.now().toUtc().toIso8601String(),
      'steps': <Map<String, Object?>>[],
      'errors': <Map<String, Object?>>[],
    };
    final steps = report['steps']! as List<Map<String, Object?>>;
    final errors = report['errors']! as List<Map<String, Object?>>;
    final originalOnError = FlutterError.onError;

    FlutterError.onError = (details) {
      errors.add({
        'source': 'flutter_error',
        'message': details.exceptionAsString(),
        'stack': details.stack?.toString(),
      });
      originalOnError?.call(details);
    };

    try {
      await _recordStep(steps, errors, 'launch_real_app', () async {
        await app.main();
        await tester.pump();
      });

      await _recordStep(steps, errors, 'wait_for_shell_or_setup', () async {
        await _pumpUntil(
          tester,
          () =>
              find.byType(SetupWizardDialog).evaluate().isNotEmpty ||
              find.byType(HomeScreen).evaluate().isNotEmpty,
          description: 'SetupWizardDialog or HomeScreen',
          maxPumps: 180,
        );
      });

      await _recordStep(steps, errors, 'collect_device_state', () async {
        final setupStatus = await AppServices.setupStateService.loadStatus();
        final runtimeStatus =
            await AppServices.localModelRuntime.getRuntimeStatus();
        final corpusStats = await AppServices.ragIndexService.getStoreStats();
        final ragLedger = await AppServices.wearableSampleRepository
            .getRagMemoryTransactions(limit: 8);
        final diagnostics = await AppServices.diagnosticLogService
            .buildDiagnosticSummary(limit: 20);
        report['device_state'] = {
          'setup': {
            'completed': setupStatus.completed,
            'is_ready_for_app_use': setupStatus.isReadyForAppUse,
            'schema_version': setupStatus.schemaVersion,
            'current_schema_version': SetupStatus.currentSchemaVersion,
            'has_validated_profile': setupStatus.hasValidatedProfile,
            'has_validated_model': setupStatus.hasValidatedModel,
            'has_resolved_health': setupStatus.hasResolvedHealth,
            'health_enabled': setupStatus.healthEnabled,
          },
          'visible_surface': {
            'setup_wizard_visible':
                find.byType(SetupWizardDialog).evaluate().isNotEmpty,
            'home_screen_visible':
                find.byType(HomeScreen).evaluate().isNotEmpty,
          },
          'runtime': {
            'status': runtimeStatus.status,
            'runtime_name': runtimeStatus.runtimeName,
            'backend_used': runtimeStatus.backendUsed,
            'is_model_loaded': runtimeStatus.isModelLoaded,
            'is_bundled_model_present': runtimeStatus.isBundledModelPresent,
            'npu_prefill_available': runtimeStatus.npuPrefillAvailable,
            'reason': runtimeStatus.reason,
          },
          'rag': {
            'corpus_stats': corpusStats,
            'latest_transactions': ragLedger
                .map(
                  (row) => {
                    'transaction_id': row.transactionId,
                    'source_type': row.sourceType,
                    'source_id': row.sourceId,
                    'status': row.status,
                    'indexed_at': row.indexedAt?.toUtc().toIso8601String(),
                    'verified_at': row.verifiedAt?.toUtc().toIso8601String(),
                    'retry_count': row.retryCount,
                    'last_error': row.lastError,
                  },
                )
                .toList(growable: false),
          },
          'diagnostics': diagnostics,
        };
      });

      final setup = (report['device_state'] as Map<String, Object?>)['setup']!
          as Map<String, Object?>;
      final visible = (report['device_state']
          as Map<String, Object?>)['visible_surface']! as Map<String, Object?>;
      if (setup['is_ready_for_app_use'] != true) {
        expect(visible['setup_wizard_visible'], isTrue);
      }
      expect(
        errors,
        isEmpty,
        reason: const JsonEncoder.withIndent('  ').convert(report),
      );
    } finally {
      report['ended_at'] = DateTime.now().toUtc().toIso8601String();
      report['status'] =
          errors.isEmpty && steps.every((step) => step['status'] == 'passed')
              ? 'passed'
              : 'failed';
      // Printed with a stable prefix so a fixer agent can scrape it from logs.
      // ignore: avoid_print
      print(
        'GEMMA_FLARES_DEVICE_SMOKE_REPORT ${const JsonEncoder.withIndent('  ').convert(report)}',
      );
      FlutterError.onError = originalOnError;
    }
  });
}

Future<void> _recordStep(
  List<Map<String, Object?>> steps,
  List<Map<String, Object?>> errors,
  String name,
  Future<void> Function() body,
) async {
  final startedAt = DateTime.now().toUtc();
  try {
    await body();
    steps.add({
      'name': name,
      'status': 'passed',
      'started_at': startedAt.toIso8601String(),
      'ended_at': DateTime.now().toUtc().toIso8601String(),
    });
  } catch (error, stackTrace) {
    final payload = {
      'name': name,
      'status': 'failed',
      'started_at': startedAt.toIso8601String(),
      'ended_at': DateTime.now().toUtc().toIso8601String(),
      'error': error.toString(),
      'stack': stackTrace.toString(),
    };
    steps.add(payload);
    errors.add({
      'source': name,
      'message': error.toString(),
      'stack': stackTrace.toString(),
    });
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  required String description,
  int maxPumps = 120,
}) async {
  for (var index = 0; index < maxPumps; index++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (predicate()) return;
  }
  throw TestFailure('Timed out waiting for $description');
}
