import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/contracts/health_bridge_contracts.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/cosinor_service.dart';
import 'package:gemma_flares/core/services/daily_summary_service.dart';
import 'package:gemma_flares/core/services/health_bridge.dart';
import 'package:gemma_flares/core/services/health_sync_service.dart';
import 'package:gemma_flares/core/services/risk_engine_service.dart';
import 'package:gemma_flares/core/services/wearable_normalization_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;
  late WearableSampleRepository repository;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_sync_ignored_',
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

  test('ignored re-fetched samples do not trigger risk recompute', () async {
    final bridge = _StaticHealthBridge([
      HealthSampleDto(
        vendorSampleId: 'hrv-1',
        sourceName: 'apple_health',
        sourceDevice: 'AppleWatch',
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        value: 42,
        unit: 'ms',
        startTime: DateTime.parse('2026-05-01T08:00:00Z'),
        endTime: DateTime.parse('2026-05-01T08:01:00Z'),
        timezone: 'America/Toronto',
        metadata: const {},
      ),
    ]);
    final riskEngine = _CountingRiskEngine(repository: repository);
    final service = HealthSyncService(
      bridge: bridge,
      normalizationService: const WearableNormalizationService(),
      repository: repository,
      dailySummaryService: DailySummaryService(repository: repository),
      cosinorService: CosinorService(repository: repository),
      riskEngineService: riskEngine,
    );

    final first = await service.runIncrementalSync(
      metrics: const [HealthMetricType.heartRateVariabilitySdnn],
      now: DateTime.parse('2026-05-01T12:00:00Z'),
    );
    final second = await service.runIncrementalSync(
      metrics: const [HealthMetricType.heartRateVariabilitySdnn],
      now: DateTime.parse('2026-05-01T12:01:00Z'),
    );

    expect(first.inserted, 1);
    expect(first.metricResults.single.touchedDates, ['2026-05-01']);
    expect(second.ignored, 1);
    expect(second.metricResults.single.touchedDates, isEmpty);
    expect(riskEngine.recomputeCalls, 1);
  });
}

class _CountingRiskEngine extends RiskEngineService {
  _CountingRiskEngine({required super.repository});

  int recomputeCalls = 0;

  @override
  Future<RiskEngineComputationResult> recomputeDates(
    List<String> dates, {
    String? sessionId,
    String? triggerReason,
    bool isUserAction = false,
  }) async {
    recomputeCalls += 1;
    return RiskEngineComputationResult(
      recomputedDates: dates,
      failedDates: const [],
    );
  }
}

class _StaticHealthBridge implements HealthBridge {
  const _StaticHealthBridge(this.samples);

  final List<HealthSampleDto> samples;

  @override
  Future<AuthorizationStatusResponse> getAuthorizationStatus(
    AuthorizationStatusRequest request,
  ) async {
    return AuthorizationStatusResponse(
      healthDataAvailable: true,
      typeStatuses: {
        for (final metric in request.requestedTypes)
          metric: HealthAuthorizationState.authorized,
      },
      requestedAt: DateTime.parse('2026-05-01T12:00:00Z'),
    );
  }

  @override
  Future<FetchSamplesResponse> fetchSamples(FetchSamplesRequest request) async {
    return FetchSamplesResponse(
      status: 'success',
      metricType: request.metricType,
      samples: samples,
      nextPageToken: null,
      sampleCount: samples.length,
    );
  }

  @override
  Future<RequestAuthorizationResponse> requestAuthorization(
    List<HealthMetricType> readTypes,
  ) {
    throw UnimplementedError();
  }
}
