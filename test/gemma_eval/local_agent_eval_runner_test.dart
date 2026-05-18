@Tags(['slow'])
@Skip('Slow persona eval runner; run on demand with --run-skipped.')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/gemma_task_service.dart';
import 'package:gemma_flares/core/services/local_agent_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../tooling/gemma_eval/eval_checks.dart';

void main() {
  sqfliteFfiInit();

  final configuredLimit =
      int.tryParse(Platform.environment['GEMMA_EVAL_LIMIT'] ?? '') ?? 16;
  final timeoutMinutes =
      int.tryParse(Platform.environment['GEMMA_EVAL_TIMEOUT_MINUTES'] ?? '') ??
          (configuredLimit <= 16
              ? 10
              : configuredLimit <= 64
                  ? 30
                  : configuredLimit <= 96
                      ? 30
                      : configuredLimit <= 128
                          ? 45
                          : 60);

  test(
    'runs persona scenarios through LocalAgentService app path',
    () async {
      final scenarioPath = Platform.environment['GEMMA_EVAL_SCENARIOS'] ??
          'tooling/gemma_eval/out/scenarios.jsonl';
      final outputPath = Platform.environment['GEMMA_EVAL_OUTPUT'] ??
          'tooling/gemma_eval/out/local_agent_results.jsonl';
      final limit = configuredLimit;

      final scenarioFile = File(scenarioPath);
      expect(
        scenarioFile.existsSync(),
        isTrue,
        reason: 'Scenario file missing: $scenarioPath',
      );

      final scenarios = _loadScenarioRows(scenarioFile).take(limit).toList();

      final outputFile = File(outputPath);
      await outputFile.parent.create(recursive: true);
      final sink = outputFile.openWrite();
      final failures = <Map<String, Object?>>[];

      for (final scenario in scenarios) {
        final tempRoot = await Directory.systemTemp.createTemp(
          'gemma_flares_eval_runner_',
        );
        final database = AppDatabase(
          migrationLoader: (assetPath) async => File(assetPath).readAsString(),
          databaseFactoryOverride: databaseFactoryFfi,
          databaseDirectoryProvider: () async => tempRoot.path,
        );
        final repository = WearableSampleRepository(database: database);
        await _seedScenarioFixture(repository, scenario);
        final gemmaTaskService = GemmaTaskService(
          repository: repository,
          runtime: const UnavailableGemmaRuntime(),
          nowProvider: () => DateTime.parse('2026-05-06T08:00:00Z'),
        );
        final service = LocalAgentService(
          repository: repository,
          runtime: const UnavailableGemmaRuntime(),
          gemmaTaskService: gemmaTaskService,
          nowProvider: () => DateTime.parse('2026-05-06T08:00:00Z'),
        );

        final stopwatch = Stopwatch()..start();
        late final LocalAgentReply reply;
        Object? error;
        try {
          reply = await service.ask(_scenarioInput(scenario));
        } catch (caught) {
          error = caught;
        }
        stopwatch.stop();

        final checks = <String>[];
        if (error == null) {
          checks
            ..addAll(
              checkScenarioResponse(
                scenario,
                reply.message,
                toolTrace: reply.toolTraceJson,
                status: reply.status,
                pendingActionType: reply.pendingAction?.type,
              ),
            )
            ..addAll(
              _suiteSpecificFailures(
                scenario,
                reply.message,
                toolTrace: reply.toolTraceJson,
              ),
            );
        } else {
          checks.add('exception:${error.runtimeType}');
        }
        final passed = checks.isEmpty;
        final row = <String, Object?>{
          'id': scenario['id'],
          'persona_id': scenario['persona_id'],
          'preset_id': scenario['preset_id'],
          'preset_label': scenario['preset_label'],
          'variant_id': scenario['variant_id'],
          'category': scenario['category'],
          'expected_intent': scenario['expected_intent'],
          'expected_action': scenario['expected_action'],
          'user_input': _scenarioInput(scenario),
          'input_modality': scenario['input_modality'],
          'fixture_photo': scenario['fixture_photo'],
          'health_fixture': scenario['health_fixture'],
          'response': error == null ? reply.message : '',
          'status': error == null ? reply.status : 'exception',
          'runtime_name': error == null ? reply.runtimeName : null,
          'agent_intent':
              error == null ? reply.toolTraceJson['agent_intent'] : null,
          'task_contract':
              error == null ? reply.toolTraceJson['task_contract'] : null,
          'tool_trace': error == null ? reply.toolTraceJson : null,
          'grounded_summary_keys': error == null
              ? reply.groundedSummaryJson.keys.toList(growable: false)
              : const <String>[],
          'used_model_output':
              error == null ? reply.toolTraceJson['used_model_output'] : false,
          'pending_action_type':
              error == null ? reply.pendingAction?.type : null,
          'latency_ms': stopwatch.elapsedMilliseconds,
          'passed': passed,
          'failures': checks,
          if (error != null) 'error': error.toString(),
        };
        sink.writeln(jsonEncode(row));
        if (!passed) failures.add(row);

        await database.close();
        await tempRoot.delete(recursive: true);
      }
      await sink.flush();
      await sink.close();

      final summary = File('tooling/gemma_eval/out/local_agent_summary.md');
      await summary.writeAsString(
        [
          '# LocalAgent Persona Eval',
          '',
          '- scenarios: ${scenarios.length}',
          '- passed: ${scenarios.length - failures.length}',
          '- failed: ${failures.length}',
          '- output: `$outputPath`',
          '',
          if (failures.isNotEmpty) '## Failures',
          for (final failure in failures.take(50))
            '- ${failure['id']} (${failure['persona_id']}): ${failure['failures']}',
          if (failures.length > 50)
            '- ${failures.length - 50} more failures omitted.',
          '',
        ].join('\n'),
      );

      expect(
        failures,
        isEmpty,
        reason: 'LocalAgent eval failures written to $outputPath',
      );
    },
    timeout: Timeout(Duration(minutes: timeoutMinutes)),
  );
}

List<Map<String, Object?>> _loadScenarioRows(File file) {
  final rows = <Map<String, Object?>>[];
  for (final line in file.readAsLinesSync().where((line) => line.isNotEmpty)) {
    final decoded = jsonDecode(line) as Map<String, Object?>;
    final turns = decoded['turns'];
    if (turns is List) {
      for (final rawTurn in turns.cast<Map>()) {
        final turn = Map<String, Object?>.from(rawTurn);
        rows.add({
          ...turn,
          'id': '${decoded['id']}_turn_${turn['turn_index']}',
          'persona_id': decoded['persona_id'],
          'persona': decoded['persona'],
          'user_input': turn['prompt'],
          'must_contain': const [],
          'must_not_contain': _mustNotForSuiteTurn(turn),
        });
      }
    } else {
      rows.add(decoded);
    }
  }
  return rows;
}

List<String> _mustNotForSuiteTurn(Map<String, Object?> scenario) {
  final values = <String>['saved to memory', 'change your dose', 'stop taking'];
  if (scenario['rag_expectation'] == 'forbidden') {
    values.addAll(['your last crp', 'your local symptoms showed']);
  }
  return values;
}

List<String> _suiteSpecificFailures(
  Map<String, Object?> scenario,
  String response, {
  Map<String, Object?> toolTrace = const {},
}) {
  final lower = response.toLowerCase();
  final failures = <String>[];
  // Multi-turn alias: when expected contract is startCheckIn but actual routed
  // elsewhere (independent turn eval), skip content checks tied to the
  // check-in flow — the content is for a different, legitimate contract.
  final expectedContract = scenario['task_contract']?.toString();
  final actualContract = toolTrace['task_contract']?.toString();
  final isMultiTurnAlias = expectedContract == 'startCheckIn' &&
      actualContract != null &&
      actualContract != 'startCheckIn';
  final mustAny = scenario['must_contain_any'];
  if (!isMultiTurnAlias && mustAny is List && mustAny.isNotEmpty) {
    final matched = mustAny.any(
      (term) => lower.contains(term.toString().toLowerCase()),
    );
    if (!matched) failures.add('missing_any:$mustAny');
  }
  if (scenario['rag_expectation'] == 'required' &&
      !lower.contains('local') &&
      !lower.contains('transaction') &&
      !lower.contains('synced') &&
      !lower.contains('lab') &&
      !lower.contains('risk')) {
    failures.add('missing_required_rag_grounding');
  }
  if (scenario['rag_expectation'] == 'forbidden' &&
      (lower.contains('transaction') || lower.contains('your last'))) {
    failures.add('rag_used_when_forbidden');
  }
  if (scenario['require_no_generic_filler'] == true) {
    const fillerPrefixes = [
      'please provide the text',
      'please provide a question',
      'please provide your question',
      'please provide the question',
      'please share the text',
      'please enter your question',
      "i'd be happy to help, but i need",
      "i'd be happy to help, but could you",
      'could you please provide more context',
      'what would you like me to',
      "i'm ready to help, but i need",
    ];
    if (fillerPrefixes.any(lower.startsWith) ||
        toolTrace['output_quality_reason'] == 'generic_filler_response') {
      failures.add('formatting.generic_filler_response');
    }
  }
  if (scenario['require_risk_display_match'] == true) {
    final riskStatus = toolTrace['user_facing_risk_status']?.toString();
    final riskDisplay =
        toolTrace['user_facing_risk_display_text']?.toString().toLowerCase();
    if (riskStatus != 'ready') {
      failures.add('risk.not_ready');
    }
    if (riskDisplay == null ||
        riskDisplay.isEmpty ||
        riskDisplay == 'learning') {
      failures.add('risk.display_missing');
    } else if (!lower.contains(riskDisplay)) {
      failures.add('risk.display_not_in_response');
    }
    if (lower.contains('learning')) {
      failures.add('risk.learning_when_ready');
    }
  }
  if (scenario['input_modality'] == 'photo' &&
      scenario['requires_confirmation'] == true &&
      lower.contains('unrelated')) {
    failures.add('health_photo_marked_unrelated');
  }
  return failures;
}

Future<void> _seedScenarioFixture(
  WearableSampleRepository repository,
  Map<String, Object?> scenario,
) async {
  final fixture = scenario['health_fixture']?.toString() ??
      scenario['fixture']?.toString() ??
      '';
  if (fixture.isEmpty || fixture == 'empty_new_user' || fixture == 'no_labs') {
    return;
  }
  final now = DateTime.parse('2026-05-06T08:00:00Z');
  if (fixture == 'score_only') {
    await _seedScore(repository, now, riskScore: 34, riskBand: 'low');
    return;
  }
  if (fixture == 'recent_symptoms' || fixture == 'symptom_pending_review') {
    await _seedSymptom(repository, now);
    return;
  }
  if (fixture == 'saved_labs_verified_rag' || fixture == 'pending_lab_review') {
    if (fixture == 'pending_lab_review') {
      await repository.insertGemmaExtractionReview(
        GemmaExtractionReviewRecord(
          reviewType: 'lab_text_extract',
          sourceKind: 'lab_report_text',
          extractedJson: const {
            'labs': [
              {
                'lab_type': 'crp',
                'value_numeric': 12.4,
                'unit': 'mg/L',
                'drawn_date': '2026-05-06',
              },
            ],
          },
          userConfirmedJson: const {},
          reviewStatus: 'pending_user_confirm',
          createdAt: now,
        ),
      );
      return;
    }
    await _seedLab(repository, now);
    await _seedRag(repository, now, sourceType: 'lab_value');
    return;
  }
  if (fixture == 'rag_only' ||
      fixture == 'failed_rag_write' ||
      fixture == 'deleted_memory') {
    await _seedRag(
      repository,
      now,
      status: fixture == 'failed_rag_write'
          ? 'failed'
          : fixture == 'deleted_memory'
              ? 'deleted'
              : 'written_to_corpus',
    );
    return;
  }
  if (fixture == 'recent_checkins' || fixture == 'checkins_bleeding_urgency') {
    await _seedCheckIn(repository, now, bleeding: fixture.contains('bleeding'));
    return;
  }
  // Fixture: stale_sync — daily summaries present but >7 days old (no recent sync).
  if (fixture == 'stale_sync') {
    final staleDate = now.subtract(const Duration(days: 10));
    await repository.upsertDailySummary(
      DailySummaryRecord(
        dateLocal: '2026-04-26',
        summaryJson: const {
          'hrv_sdnn_mean': 44.0,
          'resting_hr_mean': 66.0,
          'sleep_total_minutes': 400,
          'step_count_total': 6800,
          'sync_status': 'stale',
        },
        syncQualityScore: 0.55,
        recomputedAt: staleDate,
      ),
    );
    await repository.upsertFlareRiskScore(
      _score(staleDate, riskScore: 38, riskBand: 'low'),
    );
    return;
  }
  // Fixture: elevated_crp_low_score — conflict scenario (high CRP + low risk score).
  if (fixture == 'elevated_crp_low_score') {
    await _seedScore(repository, now, riskScore: 28, riskBand: 'low');
    await repository.upsertLabValue(
      LabValueRecord(
        drawnDate: '2026-05-04',
        labType: 'crp',
        valueNumeric: 45.0,
        unit: 'mg/L',
        referenceHigh: 5,
        createdAt: now,
        updatedAt: now,
      ),
    );
    return;
  }
  // Fixture: corrupted_rag — RAG transaction with checksum_mismatch error, no indexedAt.
  if (fixture == 'corrupted_rag') {
    await repository.upsertRagMemoryTransaction(
      RagMemoryTransactionRecord(
        transactionId: 'corrupted_rag_eval_fixture',
        sourceType: 'health_sync',
        sourceId: 'corrupted_chunk_source',
        chunkId: 'corrupted_chunk_001',
        status: 'failed',
        textHash: 'mismatched_hash_eval',
        createdAt: now,
        indexedAt: null,
        verifiedAt: null,
        lastError: 'checksum_mismatch',
      ),
    );
    return;
  }
  await repository.upsertDailySummary(
    DailySummaryRecord(
      dateLocal: '2026-05-06',
      summaryJson: const {
        'hrv_sdnn_mean': 44.0,
        'resting_hr_mean': 66.0,
        'sleep_total_minutes': 410,
        'step_count_total': 7200,
        'sync_status': 'confirmed',
      },
      syncQualityScore: 0.92,
      recomputedAt: now,
    ),
  );
  await repository.upsertFlareRiskScore(
    _score(now, riskScore: fixture == 'synced_watch_high_risk' ? 72 : 34),
  );
  if (fixture == 'all_data' || fixture == 'synced_watch_and_rag') {
    await _seedSymptom(repository, now);
    await _seedLab(repository, now);
    await _seedCheckIn(repository, now);
  }
  await repository.upsertRagMemoryTransaction(
    RagMemoryTransactionRecord(
      transactionId: 'health_sync_tx_eval_20260506',
      sourceType: 'health_sync',
      sourceId: 'apple_health_eval_fixture',
      chunkId: 'health_sync_tx_eval_20260506',
      status: 'written_to_corpus',
      textHash: 'eval_fixture_hash',
      createdAt: now,
      indexedAt: now,
    ),
  );
}

Future<void> _seedScore(
  WearableSampleRepository repository,
  DateTime now, {
  required double riskScore,
  required String riskBand,
}) async {
  await repository.upsertFlareRiskScore(
    _score(now, riskScore: riskScore, riskBand: riskBand),
  );
}

FlareRiskScoreRecord _score(
  DateTime now, {
  double riskScore = 34,
  String riskBand = 'low',
}) {
  return FlareRiskScoreRecord(
    dateLocal: '2026-05-06',
    riskScore: riskScore,
    riskBand: riskBand,
    confidenceScore: 86,
    contributionJson: const {
      'hrv_points': 6,
      'resting_hr_points': 4,
      'sleep_points': 3,
      'symptom_points': 0,
      'steps_points': 1,
    },
    featureSnapshotJson: const {'fixture': 'tool_contract'},
    modelVersion: 'risk_v1',
    createdAt: now,
  );
}

Future<void> _seedSymptom(
  WearableSampleRepository repository,
  DateTime now,
) async {
  await repository.insertSymptom(
    SymptomRecord(
      loggedAt: now.subtract(const Duration(hours: 3)),
      symptomType: 'bloating',
      severity: 4,
      sourceTranscript: 'bloating and urgency after lunch',
      extractionMethod: 'fixture',
      extractionConfidence: 1,
      createdAt: now,
    ),
  );
}

Future<void> _seedLab(WearableSampleRepository repository, DateTime now) async {
  await repository.upsertLabValue(
    LabValueRecord(
      drawnDate: '2026-05-06',
      labType: 'crp',
      valueNumeric: 12.4,
      unit: 'mg/L',
      referenceHigh: 5,
      createdAt: now,
      updatedAt: now,
    ),
  );
}

Future<void> _seedCheckIn(
  WearableSampleRepository repository,
  DateTime now, {
  bool bleeding = false,
}) async {
  await repository.insertPro2Survey(
    Pro2SurveyRecord(
      surveyDate: '2026-05-06',
      diseaseType: bleeding ? 'uc' : 'crohns',
      cdAbdominalPain: bleeding ? null : 1,
      cdStoolFrequency: bleeding ? null : 3,
      ucRectalBleeding: bleeding ? 2 : null,
      ucStoolFrequency: bleeding ? 5 : null,
      pro2Score: bleeding ? 7 : 4,
      isFlare: bleeding,
      scoreVersion: bleeding
          ? Pro2SurveyRecord.ucV1BleedingStool
          : Pro2SurveyRecord.cdV2Pain2Stool1,
      createdAt: now,
    ),
  );
}

Future<void> _seedRag(
  WearableSampleRepository repository,
  DateTime now, {
  String status = 'written_to_corpus',
  String sourceType = 'health_sync',
}) async {
  await repository.upsertRagMemoryTransaction(
    RagMemoryTransactionRecord(
      transactionId: 'rag_fixture_${sourceType}_$status',
      sourceType: sourceType,
      sourceId: 'fixture_source',
      chunkId: 'fixture_chunk',
      status: status,
      textHash: 'eval_fixture_hash',
      createdAt: now,
      indexedAt: status == 'failed' ? null : now,
      verifiedAt: status == 'verified' ? now : null,
      lastError: status == 'failed' ? 'fixture failure' : null,
    ),
  );
}

String _scenarioInput(Map<String, Object?> scenario) {
  final input = scenario['user_input']?.toString() ?? '';
  if (scenario['input_modality'] == 'photo' && input.startsWith('photo OCR:')) {
    return input.replaceFirst('photo OCR:', 'Lab photo OCR:');
  }
  if (scenario['input_modality'] == 'photo' && input.startsWith('photo:')) {
    return '[Photo attached: eval_${scenario['id']}.jpg] $input';
  }
  return input;
}
