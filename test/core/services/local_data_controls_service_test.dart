import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/local_data_controls_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('export bundle includes local records and clear removes them', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_local_data_controls_test',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final repository = WearableSampleRepository(database: database);
    final service = LocalDataControlsService(
      repository: repository,
      runtime: const _FakeRuntime(),
      earlyWarningSnapshotLoader: () async => {
        'generated_at': '2026-04-20T08:00:00Z',
        'outlook': [
          {
            'horizon_days': 7,
            'label': 'Next 7 days',
            'probability': 0.31,
            'training_samples': 14,
            'is_learning': true,
          },
        ],
      },
      nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
    );

    await repository.upsertAppSettingJson(
      key: 'user_profile',
      value: const {'disease_type': 'CD', 'watch_series': 'Series 9'},
    );
    await repository.upsertAppSettingJson(
      key: 'eval_results_json',
      value: const {'has_enough_data': true, 'note': 'diagnostic only'},
    );
    await repository.upsertDailySummary(
      DailySummaryRecord(
        dateLocal: '2026-04-19',
        summaryJson: const {
          'hrv_sdnn_mean': 45.0,
          'sleep_total_minutes': 410,
          'step_count_total': 7600,
        },
        syncQualityScore: 1,
        recomputedAt: DateTime.parse('2026-04-20T08:00:00Z'),
      ),
    );
    await repository.upsertBaselineSnapshot(
      BaselineSnapshotRecord(
        snapshotDateLocal: '2026-04-19',
        readinessState: 'ready',
        baselineJson: const {'baseline_hrv_sdnn': 48.0},
        validDays: 14,
        createdAt: DateTime.parse('2026-04-20T08:00:00Z'),
      ),
    );
    await repository.upsertDailyFeature(
      DailyFeatureRecord(
        featureDateLocal: '2026-04-19',
        featureJson: const {'logistic_p_flare_7d': 0.21},
        missingnessJson: const {'hrv_sdnn_mean': false},
        recomputedAt: DateTime.parse('2026-04-20T08:00:00Z'),
      ),
    );
    await repository.upsertFlareRiskScore(
      FlareRiskScoreRecord(
        dateLocal: '2026-04-19',
        riskScore: 33,
        riskBand: 'moderate',
        confidenceScore: 88,
        contributionJson: const {'resting_hr_points': 14},
        featureSnapshotJson: const {'resting_hr_3d_delta_vs_baseline': 7.5},
        modelVersion: 'risk_v1',
        createdAt: DateTime.parse('2026-04-20T08:00:00Z'),
      ),
    );
    await repository.upsertLabValue(
      LabValueRecord(
        drawnDate: '2026-04-18',
        labType: 'crp',
        valueNumeric: 7.2,
        unit: 'mg/dL',
        referenceHigh: 5.0,
        createdAt: DateTime.parse('2026-04-18T10:00:00Z'),
        updatedAt: DateTime.parse('2026-04-18T10:00:00Z'),
      ),
    );
    await repository.insertEndoscopyRecord(
      EndoscopyRecord(
        procedureDate: '2026-04-17',
        procedureType: 'colonoscopy',
        sesCdScore: 9,
        biopsiesTaken: true,
        biopsyResult: 'active_inflammation',
        createdAt: DateTime.parse('2026-04-17T10:00:00Z'),
      ),
    );
    await repository.insertPro2Survey(
      Pro2SurveyRecord(
        surveyDate: '2026-04-19',
        diseaseType: 'CD',
        cdAbdominalPain: 2,
        cdStoolFrequency: 2,
        pro2Score: 6,
        isFlare: false,
        scoreVersion: Pro2SurveyRecord.cdV2Pain2Stool1,
        createdAt: DateTime.parse('2026-04-19T09:00:00Z'),
      ),
    );
    await repository.upsertFlareLabel(
      FlareLabelRecord(
        labelDate: '2026-04-19',
        inflammatoryFlare: true,
        symptomaticFlare: false,
        clinicalFlare: true,
        combinedFlare: true,
        labelSource: 'combined',
        confidence: 'high',
        recomputedAt: DateTime.parse('2026-04-20T08:00:00Z'),
      ),
    );
    await repository.upsertCosinorFeature(
      CosinorFeatureRecord(
        featureDate: '2026-04-19',
        mesor: 41.2,
        amplitude: 6.8,
        peakTimeHours: 10.5,
        sampleCount: 9,
        timeSpanHours: 13,
        fitValid: true,
        recomputedAt: DateTime.parse('2026-04-20T08:00:00Z'),
      ),
    );
    await repository.upsertLogisticModelState(
      LogisticModelStateRecord(
        modelKey: 'logistic_v1_inflammatory_7d',
        horizonDays: 7,
        flareType: 'inflammatory',
        coefficientsJson: const {'hr_mean': 0.05},
        intercept: -1.2,
        trainingSamples: 14,
        updatedAt: DateTime.parse('2026-04-20T08:00:00Z'),
      ),
    );
    await repository.upsertExperimentAssignment(
      ExperimentAssignmentRecord(
        experimentKey: 'risk_explanation_length',
        variant: 'B',
        assignedAt: DateTime.parse('2026-04-20T08:00:00Z'),
      ),
    );
    await repository.insertExperimentEvent(
      ExperimentEventRecord(
        eventName: 'exposure',
        experimentKey: 'risk_explanation_length',
        variant: 'B',
        sessionId: 'session-1',
        metadataJson: const {'screen': 'dashboard'},
        createdAt: DateTime.parse('2026-04-20T08:01:00Z'),
      ),
    );
    await repository.insertDiagnosticLog(
      DiagnosticLogRecord(
        createdAt: DateTime.parse('2026-04-20T08:02:00Z'),
        sessionId: 'session-1',
        level: 'info',
        category: 'export',
        eventName: 'export_started',
        message: 'Export started.',
        metadataJson: const {'screen': 'settings'},
      ),
    );
    await repository.insertSymptom(
      SymptomRecord(
        loggedAt: DateTime.parse('2026-04-19T12:00:00Z'),
        symptomType: 'cramping',
        severity: 4,
        durationMinutes: 30,
        mealRelation: 'after_lunch',
        notes: 'Cramping after lunch',
        sourceTranscript: 'Cramping after lunch',
        extractionMethod: 'deterministic',
        extractionConfidence: 0.91,
        createdAt: DateTime.parse('2026-04-19T12:01:00Z'),
      ),
    );
    await repository.insertConversation(
      ConversationRecord(
        createdAt: DateTime.parse('2026-04-19T12:05:00Z'),
        userMessage: 'Why is my score higher?',
        assistantMessage: 'Your resting heart rate and symptoms were elevated.',
        toolTraceJson: const {'source': 'deterministic'},
        groundedSummaryJson: const {'risk_band': 'moderate'},
      ),
    );
    await repository.updateSyncState(
      sourceName: 'apple_health',
      lastSyncAt: DateTime.parse('2026-04-19T11:00:00Z'),
      lastBackfillStart: DateTime.parse('2026-03-20T11:00:00Z'),
      lastBackfillEnd: DateTime.parse('2026-04-19T11:00:00Z'),
    );

    final exportBundle = await service.buildExportBundle();
    final decoded =
        jsonDecode(exportBundle.toPrettyJson()) as Map<String, Object?>;

    expect(decoded['product'], 'gemma_flares');
    expect(
      decoded['export_scope'],
      'local_diagnostics_and_friend_testing_audit',
    );
    expect((decoded['profile'] as Map<String, Object?>)['disease_type'], 'CD');
    expect(
      (decoded['evaluation_results']
          as Map<String, Object?>)['has_enough_data'],
      isTrue,
    );
    expect((decoded['baseline_snapshots'] as List<Object?>), hasLength(1));
    expect((decoded['daily_summaries'] as List<Object?>), hasLength(1));
    expect((decoded['daily_features'] as List<Object?>), hasLength(1));
    expect((decoded['flare_risk_scores'] as List<Object?>), hasLength(1));
    expect(
      (decoded['early_warning_outlook'] as Map<String, Object?>)['outlook'],
      isA<List<Object?>>(),
    );
    expect((decoded['lab_values'] as List<Object?>), hasLength(1));
    expect((decoded['endoscopy_records'] as List<Object?>), hasLength(1));
    expect((decoded['pro2_surveys'] as List<Object?>), hasLength(1));
    expect((decoded['flare_labels'] as List<Object?>), hasLength(1));
    expect((decoded['cosinor_features'] as List<Object?>), hasLength(1));
    expect((decoded['logistic_model_states'] as List<Object?>), hasLength(1));
    expect((decoded['experiment_assignments'] as List<Object?>), hasLength(1));
    expect((decoded['experiment_events'] as List<Object?>), hasLength(1));
    expect((decoded['diagnostic_logs'] as List<Object?>), hasLength(1));
    expect((decoded['symptoms'] as List<Object?>), hasLength(1));
    expect((decoded['conversations'] as List<Object?>), hasLength(1));
    expect(
      (decoded['runtime_status'] as Map<String, Object?>)['status'],
      'unavailable',
    );

    await service.clearLocalData();

    expect(await repository.getDailySummaries(), isEmpty);
    expect(await repository.getDailyFeatures(), isEmpty);
    expect(await repository.getFlareRiskScores(), isEmpty);
    expect(await repository.getLabValues(), isEmpty);
    expect(await repository.getEndoscopyRecords(), isEmpty);
    expect(await repository.getPro2Surveys(), isEmpty);
    expect(await repository.getAllFlareLabels(), isEmpty);
    expect(await repository.getCosinorFeatures(), isEmpty);
    expect(await repository.getAllLogisticModelStates(), isEmpty);
    expect(await repository.getExperimentAssignments(), isEmpty);
    expect(await repository.getExperimentEvents(), isEmpty);
    expect(await repository.getDiagnosticLogs(), isEmpty);
    expect(await repository.getRecentSymptoms(limit: null), isEmpty);
    expect(await repository.getRecentConversations(limit: null), isEmpty);
    expect(await repository.getSyncState('apple_health'), isNull);

    await database.close();
    await tempRoot.delete(recursive: true);
  });
}

class _FakeRuntime implements LocalModelRuntime {
  const _FakeRuntime();

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    return const LocalModelRuntimeStatus(
      status: 'unavailable',
      runtimeName: 'litert-lm-ios-gemma4',
      backendStyle: 'litert-lm',
      modelId: 'gemma-4-e2b',
      quantization: 'int4_litert_lm_bundle',
      expectedModelFilename: 'Models/litert-lm/gemma-4-E2B-it',
      isBackendLinked: false,
      isBundledModelPresent: false,
      isModelLoaded: false,
      reason: 'Native backend not linked in test.',
    );
  }

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) {
    return getRuntimeStatus();
  }

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    return const LocalModelResponse(
      status: 'unavailable',
      outputText: '',
      runtimeName: 'litert-lm-ios-gemma4',
      reason: 'not_linked',
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) =>
      getRuntimeStatus();
}
