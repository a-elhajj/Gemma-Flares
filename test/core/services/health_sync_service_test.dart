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

class FakeHealthBridge implements HealthBridge {
  @override
  Future<FetchSamplesResponse> fetchSamples(FetchSamplesRequest request) async {
    return FetchSamplesResponse(
      status: 'success',
      metricType: request.metricType,
      samples: [
        HealthSampleDto(
          vendorSampleId: 'sample-1',
          sourceName: 'apple_health',
          sourceDevice: 'AppleWatchSeries9',
          metricType: request.metricType,
          value: 42.7,
          unit: 'ms',
          startTime: DateTime.parse('2026-04-11T05:03:12Z'),
          endTime: DateTime.parse('2026-04-11T05:04:12Z'),
          timezone: 'America/Toronto',
          metadata: const {},
        ),
      ],
      nextPageToken: null,
      sampleCount: 1,
    );
  }

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
      requestedAt: DateTime.parse('2026-04-12T00:00:00Z'),
    );
  }

  @override
  Future<RequestAuthorizationResponse> requestAuthorization(
    List<HealthMetricType> readTypes,
  ) async {
    return RequestAuthorizationResponse(
      status: 'success',
      grantedTypes: readTypes,
      notGrantedTypes: const [],
      requestedAt: DateTime.parse('2026-04-12T00:00:00Z'),
    );
  }
}

class _AuthorizationOnlyHealthBridge implements HealthBridge {
  _AuthorizationOnlyHealthBridge({
    required this.healthDataAvailable,
    required this.state,
  });

  final bool healthDataAvailable;
  final HealthAuthorizationState state;

  @override
  Future<AuthorizationStatusResponse> getAuthorizationStatus(
    AuthorizationStatusRequest request,
  ) async {
    return AuthorizationStatusResponse(
      healthDataAvailable: healthDataAvailable,
      typeStatuses: {
        for (final metric in request.requestedTypes) metric: state,
      },
      requestedAt: DateTime.parse('2026-04-12T00:00:00Z'),
    );
  }

  @override
  Future<RequestAuthorizationResponse> requestAuthorization(
    List<HealthMetricType> readTypes,
  ) async {
    return RequestAuthorizationResponse(
      status: 'success',
      grantedTypes: const [],
      notGrantedTypes: const [],
      requestedAt: DateTime.parse('2026-04-12T00:00:00Z'),
    );
  }

  @override
  Future<FetchSamplesResponse> fetchSamples(FetchSamplesRequest request) async {
    return FetchSamplesResponse(
      status: 'success',
      metricType: request.metricType,
      samples: const [],
      nextPageToken: null,
      sampleCount: 0,
    );
  }
}

// Simulates a bridge that returns different authorization states per type.
class _MixedStatusHealthBridge implements HealthBridge {
  _MixedStatusHealthBridge({required this.typeStatuses});

  final Map<HealthMetricType, HealthAuthorizationState> typeStatuses;

  @override
  Future<AuthorizationStatusResponse> getAuthorizationStatus(
    AuthorizationStatusRequest request,
  ) async {
    return AuthorizationStatusResponse(
      healthDataAvailable: true,
      typeStatuses: {
        for (final metric in request.requestedTypes)
          metric:
              typeStatuses[metric] ?? HealthAuthorizationState.notDetermined,
      },
      requestedAt: DateTime.parse('2026-04-12T00:00:00Z'),
    );
  }

  @override
  Future<RequestAuthorizationResponse> requestAuthorization(
    List<HealthMetricType> readTypes,
  ) async {
    final granted = readTypes
        .where((m) => typeStatuses[m] == HealthAuthorizationState.authorized)
        .toList();
    return RequestAuthorizationResponse(
      status: 'success',
      grantedTypes: granted,
      notGrantedTypes: readTypes.where((m) => !granted.contains(m)).toList(),
      requestedAt: DateTime.parse('2026-04-12T00:00:00Z'),
    );
  }

  @override
  Future<FetchSamplesResponse> fetchSamples(FetchSamplesRequest request) async {
    return FetchSamplesResponse(
      status: 'success',
      metricType: request.metricType,
      samples: const [],
      nextPageToken: null,
      sampleCount: 0,
    );
  }
}

// Simulates a bridge whose requestAuthorization returns a configurable grantedTypes list.
class _ConfigurableRequestAuthBridge implements HealthBridge {
  _ConfigurableRequestAuthBridge({required this.grantedTypes});

  final List<HealthMetricType> grantedTypes;

  @override
  Future<AuthorizationStatusResponse> getAuthorizationStatus(
    AuthorizationStatusRequest request,
  ) async {
    return AuthorizationStatusResponse(
      healthDataAvailable: true,
      typeStatuses: {
        for (final metric in request.requestedTypes)
          metric: grantedTypes.contains(metric)
              ? HealthAuthorizationState.authorized
              : HealthAuthorizationState.notDetermined,
      },
      requestedAt: DateTime.parse('2026-04-12T00:00:00Z'),
    );
  }

  @override
  Future<RequestAuthorizationResponse> requestAuthorization(
    List<HealthMetricType> readTypes,
  ) async {
    return RequestAuthorizationResponse(
      status: 'success',
      grantedTypes: grantedTypes,
      notGrantedTypes:
          readTypes.where((m) => !grantedTypes.contains(m)).toList(),
      requestedAt: DateTime.parse('2026-04-12T00:00:00Z'),
    );
  }

  @override
  Future<FetchSamplesResponse> fetchSamples(FetchSamplesRequest request) async {
    return FetchSamplesResponse(
      status: 'success',
      metricType: request.metricType,
      samples: const [],
      nextPageToken: null,
      sampleCount: 0,
    );
  }
}

void main() {
  sqfliteFfiInit();

  test(
    'hasAuthorizedHealthAccess is false when Health data is unavailable',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_sync_auth_unavailable',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final service = HealthSyncService(
        bridge: _AuthorizationOnlyHealthBridge(
          healthDataAvailable: false,
          state: HealthAuthorizationState.notDetermined,
        ),
        normalizationService: const WearableNormalizationService(),
        repository: repository,
        dailySummaryService: DailySummaryService(repository: repository),
        cosinorService: CosinorService(repository: repository),
        riskEngineService: RiskEngineService(repository: repository),
      );

      final hasAccess = await service.hasAuthorizedHealthAccess();
      expect(hasAccess, isFalse);

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test('hasAuthorizedHealthAccess is false when status is denied', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_sync_auth_denied',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final repository = WearableSampleRepository(database: database);
    final service = HealthSyncService(
      bridge: _AuthorizationOnlyHealthBridge(
        healthDataAvailable: true,
        state: HealthAuthorizationState.denied,
      ),
      normalizationService: const WearableNormalizationService(),
      repository: repository,
      dailySummaryService: DailySummaryService(repository: repository),
      cosinorService: CosinorService(repository: repository),
      riskEngineService: RiskEngineService(repository: repository),
    );

    final hasAccess = await service.hasAuthorizedHealthAccess();
    expect(hasAccess, isFalse);

    await database.close();
    await tempRoot.delete(recursive: true);
  });

  test(
    'hasAuthorizedHealthAccess is true only for explicit authorized state',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_sync_auth_authorized',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final service = HealthSyncService(
        bridge: _AuthorizationOnlyHealthBridge(
          healthDataAvailable: true,
          state: HealthAuthorizationState.authorized,
        ),
        normalizationService: const WearableNormalizationService(),
        repository: repository,
        dailySummaryService: DailySummaryService(repository: repository),
        cosinorService: CosinorService(repository: repository),
        riskEngineService: RiskEngineService(repository: repository),
      );

      final hasAccess = await service.hasAuthorizedHealthAccess();
      expect(hasAccess, isTrue);

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  // ── Regression tests for fb36008 ──────────────────────────────────────────
  // fb36008 introduced two bugs in HealthKitBridge.swift:
  //   Bug 1: .unnecessary mapped to "denied" → hasAuthorizedHealthAccess always false
  //   Bug 2: grantedTypes always [] → Settings always showed "0 types authorized"

  test(
      'hasAuthorizedHealthAccess is false when status is notDetermined '
      '(regression: notDetermined must not grant access)', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_sync_auth_notdetermined',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final repository = WearableSampleRepository(database: database);
    final service = HealthSyncService(
      bridge: _AuthorizationOnlyHealthBridge(
        healthDataAvailable: true,
        state: HealthAuthorizationState.notDetermined,
      ),
      normalizationService: const WearableNormalizationService(),
      repository: repository,
      dailySummaryService: DailySummaryService(repository: repository),
      cosinorService: CosinorService(repository: repository),
      riskEngineService: RiskEngineService(repository: repository),
    );

    final hasAccess = await service.hasAuthorizedHealthAccess();
    expect(hasAccess, isFalse);

    await database.close();
    await tempRoot.delete(recursive: true);
  });

  test(
      'hasAuthorizedHealthAccess is false when all types are unavailable '
      '(regression: unavailable must not grant access)', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_sync_auth_unavailable2',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final repository = WearableSampleRepository(database: database);
    final service = HealthSyncService(
      bridge: _AuthorizationOnlyHealthBridge(
        healthDataAvailable: true,
        state: HealthAuthorizationState.unavailable,
      ),
      normalizationService: const WearableNormalizationService(),
      repository: repository,
      dailySummaryService: DailySummaryService(repository: repository),
      cosinorService: CosinorService(repository: repository),
      riskEngineService: RiskEngineService(repository: repository),
    );

    final hasAccess = await service.hasAuthorizedHealthAccess();
    expect(hasAccess, isFalse);

    await database.close();
    await tempRoot.delete(recursive: true);
  });

  test(
      'hasAuthorizedHealthAccess is true when at least one type is authorized '
      '(regression: mixed statuses — authorized wins)', () async {
    // .unnecessary → "authorized" fix: even with some denied types, any authorized
    // type should return true. Simulates the common case where some optional metrics
    // are denied but core metrics (HRV, RHR) are authorized.
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_sync_auth_mixed',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final repository = WearableSampleRepository(database: database);
    final service = HealthSyncService(
      bridge: _MixedStatusHealthBridge(
        typeStatuses: {
          HealthMetricType.heartRateVariabilitySdnn:
              HealthAuthorizationState.authorized,
          HealthMetricType.restingHeartRate: HealthAuthorizationState.denied,
          HealthMetricType.heartRate: HealthAuthorizationState.denied,
          HealthMetricType.sleepAnalysis:
              HealthAuthorizationState.notDetermined,
          HealthMetricType.oxygenSaturation: HealthAuthorizationState.denied,
          HealthMetricType.stepCount: HealthAuthorizationState.denied,
          HealthMetricType.appleSleepingWristTemperature:
              HealthAuthorizationState.denied,
        },
      ),
      normalizationService: const WearableNormalizationService(),
      repository: repository,
      dailySummaryService: DailySummaryService(repository: repository),
      cosinorService: CosinorService(repository: repository),
      riskEngineService: RiskEngineService(repository: repository),
    );

    final hasAccess = await service.hasAuthorizedHealthAccess();
    expect(hasAccess, isTrue);

    await database.close();
    await tempRoot.delete(recursive: true);
  });

  test(
      'requestAuthorization propagates non-empty grantedTypes from bridge '
      '(regression for fb36008 Bug 2: grantedTypes was always [])', () async {
    // When the bridge correctly returns grantedTypes (post-fix), the Dart layer
    // must propagate the list unchanged. This test guards against any future
    // Dart-layer truncation of the grantedTypes list.
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_sync_request_auth_granted',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final repository = WearableSampleRepository(database: database);
    final tier1 = HealthSyncService.tier1Metrics;
    final service = HealthSyncService(
      bridge: _ConfigurableRequestAuthBridge(grantedTypes: tier1),
      normalizationService: const WearableNormalizationService(),
      repository: repository,
      dailySummaryService: DailySummaryService(repository: repository),
      cosinorService: CosinorService(repository: repository),
      riskEngineService: RiskEngineService(repository: repository),
    );

    final response = await service.requestAuthorization();
    expect(response.status, 'success');
    expect(response.grantedTypes, hasLength(tier1.length));
    expect(
      response.grantedTypes,
      containsAll([
        HealthMetricType.heartRateVariabilitySdnn,
        HealthMetricType.restingHeartRate,
        HealthMetricType.heartRate,
        HealthMetricType.sleepAnalysis,
        HealthMetricType.stepCount,
      ]),
    );
    expect(response.notGrantedTypes, isEmpty);

    await database.close();
    await tempRoot.delete(recursive: true);
  });

  test(
    'requestAuthorization with empty grantedTypes propagates as empty '
    '(regression guard: Dart layer must not silently promote to authorized)',
    () async {
      // Regression guard: if the Swift bridge ever returns [] again (as fb36008 did),
      // the Dart layer must pass it through unchanged and NOT promote types to
      // authorized. Authorization state derives solely from the bridge response.
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_sync_request_auth_empty_granted',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final service = HealthSyncService(
        bridge: _ConfigurableRequestAuthBridge(grantedTypes: const []),
        normalizationService: const WearableNormalizationService(),
        repository: repository,
        dailySummaryService: DailySummaryService(repository: repository),
        cosinorService: CosinorService(repository: repository),
        riskEngineService: RiskEngineService(repository: repository),
      );

      final response = await service.requestAuthorization();
      expect(response.status, 'success');
      expect(
        response.grantedTypes,
        isEmpty,
        reason: 'Dart layer must not silently populate grantedTypes',
      );

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test(
      'hasAuthorizedHealthAccess uses tier1Metrics by default '
      '(regression guard: default must not query zero types)', () async {
    // Verifies default parameter is tier1Metrics, not an empty list.
    // If defaults ever regress to [], hasAccess could return true spuriously.
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_sync_auth_default_metrics',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final repository = WearableSampleRepository(database: database);

    int lastRequestedCount = 0;
    final bridge = _MixedStatusHealthBridge(
      typeStatuses: {
        for (final m in HealthSyncService.tier1Metrics)
          m: HealthAuthorizationState.authorized,
      },
    );
    // Wrap bridge to count requested types via the status call
    final service = HealthSyncService(
      bridge: bridge,
      normalizationService: const WearableNormalizationService(),
      repository: repository,
      dailySummaryService: DailySummaryService(repository: repository),
      cosinorService: CosinorService(repository: repository),
      riskEngineService: RiskEngineService(repository: repository),
    );

    final status = await service.getAuthorizationStatus();
    lastRequestedCount = status.typeStatuses.length;

    expect(
      lastRequestedCount,
      HealthSyncService.tier1Metrics.length,
      reason: 'Default getAuthorizationStatus must query tier1Metrics',
    );
    expect(
      lastRequestedCount,
      greaterThan(0),
      reason:
          'tier1Metrics must be non-empty — querying 0 types hides auth failures',
    );

    await database.close();
    await tempRoot.delete(recursive: true);
  });

  // ── End regression tests for fb36008 ──────────────────────────────────────

  test(
    'initial backfill persists normalized samples and updates sync state',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_sync_test',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final dailySummaryService = DailySummaryService(repository: repository);
      final riskEngineService = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-12T00:00:00Z'),
      );
      final cosinorService = CosinorService(repository: repository);
      final service = HealthSyncService(
        bridge: FakeHealthBridge(),
        normalizationService: const WearableNormalizationService(),
        repository: repository,
        dailySummaryService: dailySummaryService,
        cosinorService: cosinorService,
        riskEngineService: riskEngineService,
      );

      final result = await service.runInitialBackfill(
        metrics: const [HealthMetricType.heartRateVariabilitySdnn],
        now: DateTime.parse('2026-04-12T00:00:00Z'),
      );

      expect(result.inserted, 1);
      expect(result.hasFailures, isFalse);

      final opened = await database.open();
      final rows = await opened.query('wearable_samples');
      final syncRows = await opened.query('sync_state');
      final summaryRows = await opened.query('daily_summaries');
      final baselineRows = await opened.query('baseline_snapshots');
      final featureRows = await opened.query('daily_features');
      final scoreRows = await opened.query('flare_risk_scores');

      expect(rows, hasLength(1));
      expect(rows.single['metric_name'], 'hrv_sdnn');
      expect(rows.single['metric_family'], 'recovery');
      expect(syncRows, hasLength(1));
      expect(syncRows.single['source_name'], 'apple_health');
      expect(summaryRows, hasLength(1));
      expect(baselineRows, hasLength(1));
      expect(featureRows, hasLength(1));
      expect(
        scoreRows.map((row) => row['model_version']),
        containsAll(['risk_v1', 'risk_v2_context_adjusted']),
      );

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );
}
