import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/cosinor_service.dart';
import 'package:gemma_flares/core/services/daily_summary_service.dart';
import 'package:gemma_flares/core/services/guidance_service.dart';
import 'package:gemma_flares/core/services/health_bridge.dart';
import 'package:gemma_flares/core/services/risk_engine_service.dart';
import 'package:gemma_flares/core/services/wearable_normalization_service.dart';
import 'package:gemma_flares/core/services/health_refresh_coordinator.dart';
import 'package:gemma_flares/core/services/health_sync_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/system_status_service.dart';
import 'package:gemma_flares/core/contracts/health_bridge_contracts.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;
  late WearableSampleRepository repository;
  late GuidanceService guidanceService;
  late HealthSyncService placeholderSyncService;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_refresh_coord',
    );
    database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    repository = WearableSampleRepository(database: database);
    guidanceService = GuidanceService(
      repository: repository,
      runtime: const UnavailableGemmaRuntime(),
    );
    placeholderSyncService = HealthSyncService(
      bridge: _NoopHealthBridge(),
      normalizationService: const WearableNormalizationService(),
      repository: repository,
      dailySummaryService: DailySummaryService(repository: repository),
      cosinorService: CosinorService(repository: repository),
      riskEngineService: RiskEngineService(repository: repository),
    );
  });

  tearDown(() async {
    await database.close();
    await tempRoot.delete(recursive: true);
  });

  test('skips refresh when low power mode is enabled', () async {
    var syncCalls = 0;
    var guidanceCalls = 0;
    final coordinator = HealthRefreshCoordinator(
      healthSyncService: placeholderSyncService,
      guidanceService: guidanceService,
      systemStatusService: const _FakeSystemStatusService(
        SystemStatusSnapshot(
          lowPowerModeEnabled: true,
          thermalState: 'nominal',
          backgroundRefreshStatus: 'available',
        ),
      ),
      incrementalSyncRunnerOverride: (_) async {
        syncCalls += 1;
        return _successResult();
      },
      guidanceRefreshRunnerOverride: (_, __) async {
        guidanceCalls += 1;
      },
    );

    await coordinator.refreshNow(reason: 'test_low_power');

    expect(syncCalls, 0);
    expect(guidanceCalls, 0);
  });

  test('skips refresh when thermal state is serious', () async {
    var syncCalls = 0;
    final coordinator = HealthRefreshCoordinator(
      healthSyncService: placeholderSyncService,
      guidanceService: guidanceService,
      systemStatusService: const _FakeSystemStatusService(
        SystemStatusSnapshot(
          lowPowerModeEnabled: false,
          thermalState: 'serious',
          backgroundRefreshStatus: 'available',
        ),
      ),
      incrementalSyncRunnerOverride: (_) async {
        syncCalls += 1;
        return _successResult();
      },
    );

    await coordinator.refreshNow(reason: 'test_thermal');

    expect(syncCalls, 0);
  });

  test('avoids overlapping refresh runs', () async {
    var syncCalls = 0;
    final coordinator = HealthRefreshCoordinator(
      healthSyncService: placeholderSyncService,
      guidanceService: guidanceService,
      systemStatusService: const _FakeSystemStatusService(
        SystemStatusSnapshot(
          lowPowerModeEnabled: false,
          thermalState: 'nominal',
          backgroundRefreshStatus: 'available',
        ),
      ),
      incrementalSyncRunnerOverride: (_) async {
        syncCalls += 1;
        await Future<void>.delayed(const Duration(milliseconds: 120));
        return _successResult();
      },
    );

    final first = coordinator.refreshNow(reason: 'first');
    final second = coordinator.refreshNow(reason: 'second');
    await Future.wait([first, second]);

    expect(syncCalls, 1);
  });

  test('passes allowModel false to guidance when sync has failures', () async {
    bool? allowModel;
    final coordinator = HealthRefreshCoordinator(
      healthSyncService: placeholderSyncService,
      guidanceService: guidanceService,
      systemStatusService: const _FakeSystemStatusService(
        SystemStatusSnapshot(
          lowPowerModeEnabled: false,
          thermalState: 'nominal',
          backgroundRefreshStatus: 'available',
        ),
      ),
      incrementalSyncRunnerOverride: (_) async => _failureResult(),
      guidanceRefreshRunnerOverride: (_, allow) async {
        allowModel = allow;
      },
    );

    await coordinator.refreshNow(reason: 'sync_failure');

    expect(allowModel, isFalse);
  });

  test('passes allowModel false during automatic open-ready refresh', () async {
    bool? allowModel;
    final coordinator = HealthRefreshCoordinator(
      healthSyncService: placeholderSyncService,
      guidanceService: guidanceService,
      systemStatusService: const _FakeSystemStatusService(
        SystemStatusSnapshot(
          lowPowerModeEnabled: false,
          thermalState: 'nominal',
          backgroundRefreshStatus: 'available',
        ),
      ),
      incrementalSyncRunnerOverride: (_) async => _successResult(),
      guidanceRefreshRunnerOverride: (_, allow) async {
        allowModel = allow;
      },
    );

    await coordinator.refreshNow(reason: 'open_ready_app_launch');

    expect(allowModel, isFalse);
  });

  test('passes allowModel true during manual refresh', () async {
    bool? allowModel;
    final coordinator = HealthRefreshCoordinator(
      healthSyncService: placeholderSyncService,
      guidanceService: guidanceService,
      systemStatusService: const _FakeSystemStatusService(
        SystemStatusSnapshot(
          lowPowerModeEnabled: false,
          thermalState: 'nominal',
          backgroundRefreshStatus: 'available',
        ),
      ),
      incrementalSyncRunnerOverride: (_) async => _successResult(),
      guidanceRefreshRunnerOverride: (_, allow) async {
        allowModel = allow;
      },
    );

    await coordinator.refreshNow();

    expect(allowModel, isTrue);
  });

  test('skips refresh when Health access is unavailable', () async {
    var syncCalls = 0;
    final coordinator = HealthRefreshCoordinator(
      healthSyncService: placeholderSyncService,
      guidanceService: guidanceService,
      systemStatusService: const _FakeSystemStatusService(
        SystemStatusSnapshot(
          lowPowerModeEnabled: false,
          thermalState: 'nominal',
          backgroundRefreshStatus: 'available',
        ),
      ),
      authorizationCheckOverride: () async => false,
      incrementalSyncRunnerOverride: (_) async {
        syncCalls += 1;
        return _successResult();
      },
    );

    await coordinator.refreshNow(reason: 'no_health_access');

    expect(syncCalls, 0);
  });
}

HealthSyncRunResult _successResult() {
  return HealthSyncRunResult(
    startedAt: DateTime.utc(2026, 4, 18, 12),
    endedAt: DateTime.utc(2026, 4, 18, 12, 1),
    metricResults: const [
      MetricSyncResult(
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        status: 'success',
        fetched: 1,
        inserted: 1,
        updated: 0,
        ignored: 0,
        invalid: 0,
        touchedDates: ['2026-04-18'],
      ),
    ],
  );
}

HealthSyncRunResult _failureResult() {
  return HealthSyncRunResult(
    startedAt: DateTime.utc(2026, 4, 18, 12),
    endedAt: DateTime.utc(2026, 4, 18, 12, 1),
    metricResults: const [
      MetricSyncResult(
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        status: 'failed',
        fetched: 0,
        inserted: 0,
        updated: 0,
        ignored: 0,
        invalid: 0,
        touchedDates: [],
        error: 'test',
      ),
    ],
  );
}

class _FakeSystemStatusService implements SystemStatusService {
  const _FakeSystemStatusService(this.snapshot);

  final SystemStatusSnapshot snapshot;

  @override
  Future<SystemStatusSnapshot> getStatus() async => snapshot;
}

class _NoopHealthBridge implements HealthBridge {
  @override
  Future<AuthorizationStatusResponse> getAuthorizationStatus(
    AuthorizationStatusRequest request,
  ) {
    return Future.value(
      AuthorizationStatusResponse(
        healthDataAvailable: true,
        typeStatuses: {
          for (final metric in request.requestedTypes)
            metric: HealthAuthorizationState.authorized,
        },
        requestedAt: DateTime.parse('2026-04-18T12:00:00Z'),
      ),
    );
  }

  @override
  Future<FetchSamplesResponse> fetchSamples(FetchSamplesRequest request) {
    throw UnimplementedError();
  }

  @override
  Future<RequestAuthorizationResponse> requestAuthorization(
    List<HealthMetricType> readTypes,
  ) {
    throw UnimplementedError();
  }
}
