import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/guidance_service.dart';
import 'package:gemma_flares/core/services/ibd_checkin_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;
  late WearableSampleRepository repository;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_guidance_test',
    );
    database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    repository = WearableSampleRepository(database: database);
  });

  tearDown(() async {
    await database.close();
    await tempRoot.delete(recursive: true);
  });

  test(
    'guidance sends compact model evidence with feature and cosinor context',
    () async {
      await repository.upsertDailyFeature(
        DailyFeatureRecord(
          featureDateLocal: '2026-04-18',
          featureJson: const {
            'hrv_3d_pct_delta_vs_baseline': -12.4,
            'sleep_3d_pct_delta_vs_baseline': -8.2,
            'custom_metric_x': 17.0,
          },
          missingnessJson: const {},
          recomputedAt: DateTime.utc(2026, 4, 18, 10),
        ),
      );
      await repository.upsertCosinorFeature(
        CosinorFeatureRecord(
          featureDate: '2026-04-18',
          fitValid: true,
          mesor: 42.3,
          amplitude: 9.4,
          acrophaseRad: 1.2,
          peakTimeHours: 6.1,
          rSquared: 0.72,
          sampleCount: 96,
          recomputedAt: DateTime.utc(2026, 4, 18, 10),
        ),
      );
      await repository.insertPro2Survey(
        Pro2SurveyRecord(
          surveyDate: '2026-04-18',
          diseaseType: 'UC',
          ucRectalBleeding: 1,
          ucStoolFrequency: 2,
          pro2Score: 3,
          isFlare: true,
          scoreVersion: Pro2SurveyRecord.ucV1BleedingStool,
          notes: IbdCheckInService.encodeNotes(
            diseaseType: 'UC',
            dailyCore: const {
              'rectal_bleeding_0_3': 1,
              'bathroom_frequency_0_3': 2,
            },
            dailyDetails: const {'urgency_0_3': 2},
            completedSections: const ['core', 'daily_details'],
          ),
          createdAt: DateTime.utc(2026, 4, 18, 8),
        ),
      );
      final runtime = _FakeRuntime();
      final service = GuidanceService(
        repository: repository,
        runtime: runtime,
        nowProvider: () => DateTime.utc(2026, 4, 18, 12),
      );

      final snapshot = await service.refreshLatestGuidance(
        reason: 'test_evidence',
        allowModel: true,
      );

      expect(snapshot.traceJson['used_model_output'], isTrue);
      expect(runtime.generateCalls, 1);
      final grounded = runtime.lastRequest!.groundedContext;
      expect(grounded['daily_features_full'], isNull);
      expect(grounded['features'], isA<Map>());
      expect(
        (grounded['features'] as Map)['hrv_3d_pct_delta_vs_baseline'],
        -12.4,
      );
      expect(grounded['cosinor'], isA<Map>());
      expect((grounded['cosinor'] as Map)['mesor'], 42.3);
      expect(grounded['checkin_7d'], isA<Map>());
      expect(
        ((grounded['checkin'] as Map)['summary'] as String),
        contains('UC check-in'),
      );
      final stored = await repository.getAppSettingJson(
        'guidance_cache:2026-04-18',
      );
      final json = Map<String, Object?>.from(stored as Map);
      final trace = Map<String, Object?>.from(json['trace_json'] as Map);
      expect((trace['model_evidence_chars'] as int), lessThan(1800));
      expect(trace['model_backoff_applied'], isFalse);
    },
  );

  test('guidance model generation is backoff-limited', () async {
    final runtime = _FakeRuntime();
    final service = GuidanceService(
      repository: repository,
      runtime: runtime,
      nowProvider: () => DateTime.utc(2026, 4, 18, 12),
    );

    await service.refreshLatestGuidance(reason: 'first', allowModel: true);
    await repository.insertSymptom(
      SymptomRecord(
        loggedAt: DateTime.utc(2026, 4, 18, 12, 1),
        symptomType: 'nausea',
        severity: 4,
        extractionMethod: 'deterministic',
        extractionConfidence: 0.9,
        createdAt: DateTime.utc(2026, 4, 18, 12, 1),
      ),
    );
    final second = await service.refreshLatestGuidance(
      reason: 'second',
      allowModel: true,
    );

    expect(runtime.generateCalls, 1);
    expect(second.traceJson['model_backoff_applied'], isTrue);
  });

  test(
    'guidance fallback cache is stable across sync timestamp changes',
    () async {
      var now = DateTime.utc(2026, 4, 18, 12);
      final runtime = _FakeRuntime(succeed: false);
      final service = GuidanceService(
        repository: repository,
        runtime: runtime,
        nowProvider: () => now,
      );
      await repository.updateSyncState(
        sourceName: 'apple_health',
        lastSyncAt: now,
      );

      final first = await service.refreshLatestGuidance(reason: 'first');
      now = DateTime.utc(2026, 4, 18, 12, 1);
      await repository.updateSyncState(
        sourceName: 'apple_health',
        lastSyncAt: now,
      );
      final second = await service.refreshLatestGuidance(reason: 'second');

      expect(first.status, 'fallback');
      expect(second.status, 'fallback');
      expect(first.evidenceHash, second.evidenceHash);
      expect(runtime.generateCalls, 1);
    },
  );
}

class _FakeRuntime implements LocalModelRuntime {
  _FakeRuntime({this.succeed = true});

  final bool succeed;
  int generateCalls = 0;
  LocalModelRequest? lastRequest;

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    generateCalls += 1;
    lastRequest = request;
    if (!succeed) {
      return const LocalModelResponse(
        status: 'unavailable',
        outputText: '',
        runtimeName: 'fake_runtime',
        reason: 'prompt_preflight_context_overflow',
        fallbackReason: 'prompt_preflight_context_overflow',
      );
    }
    return const LocalModelResponse(
      status: 'success',
      outputText: 'Keep hydration steady and log any symptom changes today.',
      runtimeName: 'fake_runtime',
      outputQualityStatus: 'accepted',
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    return const LocalModelRuntimeStatus(
      status: 'loaded',
      runtimeName: 'fake_runtime',
      backendStyle: 'fake',
      modelId: 'fake',
      quantization: 'none',
      expectedModelFilename: 'fake.bin',
      isBackendLinked: true,
      isBundledModelPresent: true,
      isModelLoaded: true,
      reason: 'ready',
    );
  }

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) {
    return getRuntimeStatus();
  }

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) {
    return getRuntimeStatus();
  }
}
