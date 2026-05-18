import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/contracts/health_bridge_contracts.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/app_readiness_service.dart';
import 'package:gemma_flares/core/services/cosinor_service.dart';
import 'package:gemma_flares/core/services/daily_summary_service.dart';
import 'package:gemma_flares/core/services/guidance_service.dart';
import 'package:gemma_flares/core/services/health_bridge.dart';
import 'package:gemma_flares/core/services/health_refresh_coordinator.dart';
import 'package:gemma_flares/core/services/health_sync_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/risk_engine_service.dart';
import 'package:gemma_flares/core/services/system_status_service.dart';
import 'package:gemma_flares/core/services/wearable_normalization_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;
  late WearableSampleRepository repository;
  late GuidanceService guidanceService;
  late HealthSyncService placeholderSyncService;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('gemma_flares_readiness');
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

  test('open-ready success path publishes ready state', () async {
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
      guidanceRefreshRunnerOverride: (_, __) async {},
    );
    final service = AppReadinessService(
      healthRefreshCoordinator: coordinator,
      repository: repository,
      fastPathTimeout: const Duration(milliseconds: 120),
    );

    await service.refreshForOpen(reason: 'app_launch');

    expect(service.state.value.phase, 'ready');
    expect(service.state.value.isRefreshing, isFalse);
    expect(service.state.value.fastPathTimedOut, isFalse);
  });

  test(
    'open-ready timeout returns early then completes in background',
    () async {
      final completer = Completer<HealthSyncRunResult>();
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
        incrementalSyncRunnerOverride: (_) => completer.future,
        guidanceRefreshRunnerOverride: (_, __) async {},
      );
      final service = AppReadinessService(
        healthRefreshCoordinator: coordinator,
        repository: repository,
        fastPathTimeout: const Duration(milliseconds: 20),
      );

      await service.refreshForOpen(reason: 'app_resumed');
      expect(service.state.value.phase, 'refreshing_background');
      expect(service.state.value.isRefreshing, isTrue);
      expect(service.state.value.fastPathTimedOut, isTrue);

      completer.complete(_successResult());
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(service.state.value.phase, 'ready_after_background');
      expect(service.state.value.isRefreshing, isFalse);
    },
  );

  test(
    'open-ready repository lookup failure is contained and still returns',
    () async {
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
          throw StateError('sync_failed');
        },
        guidanceRefreshRunnerOverride: (_, __) async {},
      );
      final throwingRepository = _ThrowingRepository(database: database);
      final service = AppReadinessService(
        healthRefreshCoordinator: coordinator,
        repository: throwingRepository,
        fastPathTimeout: const Duration(milliseconds: 80),
      );

      await service.refreshForOpen(reason: 'app_launch');

      expect(service.state.value.phase, 'ready');
      expect(service.state.value.isRefreshing, isFalse);
    },
  );

  test(
    'open-ready skips foreground refresh when Health access is unavailable',
    () async {
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
          return _successResult();
        },
        guidanceRefreshRunnerOverride: (_, __) async {},
      );
      final service = AppReadinessService(
        healthRefreshCoordinator: coordinator,
        repository: repository,
        fastPathTimeout: const Duration(milliseconds: 120),
        shouldRefreshForOpen: () async => false,
      );

      await service.refreshForOpen(reason: 'app_launch');

      expect(syncCalls, 0);
      expect(service.state.value.phase, 'ready_without_refresh');
      expect(service.state.value.isRefreshing, isFalse);
    },
  );

  test('open-ready refresh is skipped during quick reopen cooldown', () async {
    var syncCalls = 0;
    var now = DateTime.utc(2026, 4, 18, 12);
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
        return _successResult();
      },
      guidanceRefreshRunnerOverride: (_, __) async {},
      nowProvider: () => now,
    );
    final service = AppReadinessService(
      healthRefreshCoordinator: coordinator,
      repository: repository,
      fastPathTimeout: const Duration(milliseconds: 120),
      nowProvider: () => now,
    );

    await service.refreshForOpen(reason: 'app_launch');
    now = now.add(const Duration(minutes: 1));
    await service.refreshForOpen(reason: 'app_resumed');

    expect(syncCalls, 1);
    expect(service.state.value.phase, 'ready_without_refresh');
    expect(service.state.value.reason, 'app_resumed');
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

class _ThrowingRepository extends WearableSampleRepository {
  _ThrowingRepository({required super.database});

  @override
  Future<SyncStateRecord?> getSyncState(String sourceName) async {
    throw StateError('repo_unavailable');
  }
}
