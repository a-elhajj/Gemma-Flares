import '../contracts/health_bridge_contracts.dart';
import '../database/wearable_sample_repository.dart';
import 'cosinor_service.dart';
import 'daily_summary_service.dart';
import 'diagnostic_log_service.dart';
import 'health_bridge.dart';
import 'risk_engine_service.dart';
import 'wearable_normalization_service.dart';

class MetricSyncResult {
  const MetricSyncResult({
    required this.metricType,
    required this.status,
    required this.fetched,
    required this.inserted,
    required this.updated,
    required this.ignored,
    required this.invalid,
    required this.touchedDates,
    this.error,
  });

  final HealthMetricType metricType;
  final String status;
  final int fetched;
  final int inserted;
  final int updated;
  final int ignored;
  final int invalid;
  final List<String> touchedDates;
  final String? error;
}

class HealthSyncRunResult {
  const HealthSyncRunResult({
    required this.startedAt,
    required this.endedAt,
    required this.metricResults,
  });

  final DateTime startedAt;
  final DateTime endedAt;
  final List<MetricSyncResult> metricResults;

  int get inserted => metricResults.fold(0, (sum, item) => sum + item.inserted);
  int get updated => metricResults.fold(0, (sum, item) => sum + item.updated);
  int get ignored => metricResults.fold(0, (sum, item) => sum + item.ignored);
  int get invalid => metricResults.fold(0, (sum, item) => sum + item.invalid);
  bool get hasFailures => metricResults.any((item) => item.error != null);
}

class HealthSyncService {
  HealthSyncService({
    required HealthBridge bridge,
    required WearableNormalizationService normalizationService,
    required WearableSampleRepository repository,
    required DailySummaryService dailySummaryService,
    required CosinorService cosinorService,
    required RiskEngineService riskEngineService,
    DiagnosticLogService? diagnosticLogService,
  })  : _bridge = bridge,
        _normalizationService = normalizationService,
        _repository = repository,
        _dailySummaryService = dailySummaryService,
        _cosinorService = cosinorService,
        _riskEngineService = riskEngineService,
        _diagnosticLogService = diagnosticLogService;

  final HealthBridge _bridge;
  final WearableNormalizationService _normalizationService;
  final WearableSampleRepository _repository;
  final DailySummaryService _dailySummaryService;
  // Cosinor runs before risk engine so circadian features are ready for feature JSON.
  final CosinorService _cosinorService;
  final RiskEngineService _riskEngineService;
  final DiagnosticLogService? _diagnosticLogService;

  static const tier1Metrics = <HealthMetricType>[
    HealthMetricType.heartRateVariabilitySdnn,
    HealthMetricType.restingHeartRate,
    HealthMetricType.heartRate,
    HealthMetricType.sleepAnalysis,
    HealthMetricType.oxygenSaturation,
    HealthMetricType.stepCount,
    HealthMetricType.appleSleepingWristTemperature,
  ];

  static const activityContextMetrics = <HealthMetricType>[
    HealthMetricType.workout,
    HealthMetricType.activeEnergyBurned,
    HealthMetricType.appleExerciseTime,
    HealthMetricType.distanceWalkingRunning,
    HealthMetricType.flightsClimbed,
    HealthMetricType.walkingHeartRateAverage,
    HealthMetricType.heartRateRecoveryOneMinute,
    HealthMetricType.vo2Max,
  ];

  static const recoveryContextMetrics = <HealthMetricType>[
    HealthMetricType.respiratoryRate,
    HealthMetricType.sleepingBreathingDisturbance,
  ];

  static const appleHealthSymptomMetrics = <HealthMetricType>[
    HealthMetricType.abdominalCramps,
    HealthMetricType.bloating,
    HealthMetricType.constipation,
    HealthMetricType.diarrhea,
    HealthMetricType.heartburn,
    HealthMetricType.nausea,
    HealthMetricType.vomiting,
    HealthMetricType.appetiteChanges,
    HealthMetricType.chills,
    HealthMetricType.fatigue,
    HealthMetricType.fever,
  ];

  static const intakeContextMetrics = <HealthMetricType>[
    HealthMetricType.dietaryCaffeine,
    HealthMetricType.dietaryWater,
    HealthMetricType.dietaryEnergyConsumed,
    HealthMetricType.numberOfAlcoholicBeverages,
  ];

  static const medicationContextMetrics = <HealthMetricType>[
    HealthMetricType.medicationDoseEvent,
  ];

  static const mobilityContextMetrics = <HealthMetricType>[
    HealthMetricType.walkingSpeed,
    HealthMetricType.walkingStepLength,
    HealthMetricType.walkingAsymmetryPercentage,
    HealthMetricType.walkingDoubleSupportPercentage,
    HealthMetricType.stairAscentSpeed,
    HealthMetricType.stairDescentSpeed,
    HealthMetricType.sixMinuteWalkTestDistance,
  ];

  static const rhythmReliabilityMetrics = <HealthMetricType>[
    HealthMetricType.highHeartRateEvent,
    HealthMetricType.lowHeartRateEvent,
    HealthMetricType.irregularHeartRhythmEvent,
    HealthMetricType.atrialFibrillationBurden,
    HealthMetricType.electrocardiogram,
  ];

  static const productionContextMetrics = <HealthMetricType>[
    ...activityContextMetrics,
    ...recoveryContextMetrics,
    ...appleHealthSymptomMetrics,
    ...intakeContextMetrics,
    ...medicationContextMetrics,
    ...mobilityContextMetrics,
    ...rhythmReliabilityMetrics,
  ];

  static const allProductionMetrics = <HealthMetricType>[
    ...tier1Metrics,
    ...productionContextMetrics,
  ];

  Future<AuthorizationStatusResponse> getAuthorizationStatus({
    List<HealthMetricType> metrics = tier1Metrics,
  }) {
    return _bridge.getAuthorizationStatus(
      AuthorizationStatusRequest(requestedTypes: metrics),
    );
  }

  Future<bool> hasAuthorizedHealthAccess({
    List<HealthMetricType> metrics = tier1Metrics,
  }) async {
    final status = await getAuthorizationStatus(metrics: metrics);
    if (!status.healthDataAvailable) {
      return false;
    }
    // HealthKit does not expose read authorization state directly for read
    // types. Only return true for bridges/tests that can explicitly report an
    // authorized state; do not treat denied/unnecessary as proof of read access.
    return status.typeStatuses.values.any(
      (state) => state == HealthAuthorizationState.authorized,
    );
  }

  Future<RequestAuthorizationResponse> requestAuthorization({
    List<HealthMetricType> metrics = tier1Metrics,
  }) {
    return _bridge.requestAuthorization(metrics);
  }

  Future<HealthSyncRunResult> runInitialBackfill({
    List<HealthMetricType> metrics = tier1Metrics,
    DateTime? now,
    Duration lookback = const Duration(days: 30),
  }) async {
    final startedAt = now?.toUtc() ?? DateTime.now().toUtc();
    final startTime = startedAt.subtract(lookback);
    await _diagnosticLogService?.info(
      'initial_backfill_started',
      category: DiagnosticLogService.categoryHealthSync,
      message: 'Apple Health backfill started.',
      metadata: {
        'metric_count': metrics.length,
        'lookback_days': lookback.inDays,
      },
    );
    final results = <MetricSyncResult>[];
    final touchedDates = <String>{};

    for (final metric in metrics) {
      try {
        final response = await _bridge.fetchSamples(
          FetchSamplesRequest(
            metricType: metric,
            startTime: startTime,
            endTime: startedAt,
            mode: FetchMode.backfill,
          ),
        );

        final normalized = _normalizationService.normalizeBatch(
          metricType: metric,
          samples: response.samples,
          importedAt: startedAt,
        );
        final persisted = await _repository.upsertSamples(normalized.samples);
        await _recordMetricRegistry(
          metric: metric,
          status: response.status,
          importedAt: startedAt,
          lastErrorKind: normalized.invalid > 0 ? 'invalid_samples' : null,
        );

        results.add(
          MetricSyncResult(
            metricType: metric,
            status: response.status,
            fetched: response.sampleCount,
            inserted: persisted.inserted,
            updated: persisted.updated,
            ignored: persisted.ignored,
            invalid: normalized.invalid,
            touchedDates: persisted.touchedDates,
          ),
        );
        touchedDates.addAll(persisted.touchedDates);
      } catch (error) {
        await _recordMetricRegistry(
          metric: metric,
          status: 'failed',
          importedAt: null,
          lastErrorKind: error.runtimeType.toString(),
        );
        await _diagnosticLogService?.error(
          'metric_backfill_failed',
          category: DiagnosticLogService.categoryHealthSync,
          message: 'A Health metric could not be imported.',
          error: error,
          metadata: {'metric_index': results.length},
        );
        results.add(
          MetricSyncResult(
            metricType: metric,
            status: 'failed',
            fetched: 0,
            inserted: 0,
            updated: 0,
            ignored: 0,
            invalid: 0,
            touchedDates: const [],
            error: error.toString(),
          ),
        );
      }
    }

    final endedAt = DateTime.now().toUtc();
    final failedMessages = results
        .where((item) => item.error != null)
        .map((item) => '${item.metricType.wireName}: ${item.error!}')
        .toList();
    final coreFailedMessages = results
        .where(
          (item) =>
              item.error != null && tier1Metrics.contains(item.metricType),
        )
        .map((item) => '${item.metricType.wireName}: ${item.error!}')
        .toList();
    await _repository.updateSyncState(
      sourceName: 'apple_health',
      lastSyncAt: endedAt,
      lastBackfillStart: startTime,
      lastBackfillEnd: endedAt,
      lastError:
          coreFailedMessages.isEmpty ? null : coreFailedMessages.join(' | '),
    );

    if (touchedDates.isNotEmpty) {
      final sortedDates = touchedDates.toList()..sort();
      await _dailySummaryService.recomputeDates(sortedDates);
      await _dailySummaryService.recomputeBaseline(asOfDate: sortedDates.last);
      // Cosinor BEFORE risk engine: feature JSON needs circadian parameters to be present.
      await _cosinorService.recomputeDates(sortedDates);
      await _riskEngineService.recomputeDates(sortedDates);
    }

    await _diagnosticLogService?.info(
      results.any((item) => item.error != null)
          ? 'initial_backfill_completed_with_failures'
          : 'initial_backfill_completed',
      category: DiagnosticLogService.categoryHealthSync,
      message: 'Apple Health backfill completed.',
      metadata: {
        'metric_count': results.length,
        'inserted_count': results.fold<int>(
          0,
          (sum, item) => sum + item.inserted,
        ),
        'updated_count': results.fold<int>(
          0,
          (sum, item) => sum + item.updated,
        ),
        'invalid_count': results.fold<int>(
          0,
          (sum, item) => sum + item.invalid,
        ),
        'touched_date_count': touchedDates.length,
        'has_failures': results.any((item) => item.error != null),
        'core_failure_count': coreFailedMessages.length,
        'context_failure_count':
            failedMessages.length - coreFailedMessages.length,
      },
    );

    return HealthSyncRunResult(
      startedAt: startedAt,
      endedAt: endedAt,
      metricResults: results,
    );
  }

  Future<HealthSyncRunResult> runIncrementalSync({
    List<HealthMetricType> metrics = tier1Metrics,
    DateTime? now,
    Duration safetyLookback = const Duration(minutes: 90),
    Duration coldStartLookback = const Duration(hours: 6),
    String? sessionId,
    String? triggerReason,
    bool isUserAction = false,
  }) async {
    final startedAt = now?.toUtc() ?? DateTime.now().toUtc();
    final priorState = await _repository.getSyncState('apple_health');
    final priorSync = priorState?.lastSyncAt?.toUtc();
    final startTime = priorSync == null
        ? startedAt.subtract(coldStartLookback)
        : priorSync.subtract(safetyLookback);
    await _diagnosticLogService?.info(
      'incremental_sync_started',
      category: DiagnosticLogService.categoryHealthSync,
      message: 'Apple Health incremental sync started.',
      metadata: {
        'metric_count': metrics.length,
        'has_prior_sync': priorSync != null,
      },
    );

    final results = <MetricSyncResult>[];
    final touchedDates = <String>{};
    for (final metric in metrics) {
      try {
        final response = await _bridge.fetchSamples(
          FetchSamplesRequest(
            metricType: metric,
            startTime: startTime,
            endTime: startedAt,
            mode: FetchMode.incremental,
          ),
        );
        final normalized = _normalizationService.normalizeBatch(
          metricType: metric,
          samples: response.samples,
          importedAt: startedAt,
        );
        final persisted = await _repository.upsertSamples(normalized.samples);
        await _recordMetricRegistry(
          metric: metric,
          status: response.status,
          importedAt: startedAt,
          lastErrorKind: normalized.invalid > 0 ? 'invalid_samples' : null,
        );
        results.add(
          MetricSyncResult(
            metricType: metric,
            status: response.status,
            fetched: response.sampleCount,
            inserted: persisted.inserted,
            updated: persisted.updated,
            ignored: persisted.ignored,
            invalid: normalized.invalid,
            touchedDates: persisted.touchedDates,
          ),
        );
        touchedDates.addAll(persisted.touchedDates);
      } catch (error) {
        await _recordMetricRegistry(
          metric: metric,
          status: 'failed',
          importedAt: null,
          lastErrorKind: error.runtimeType.toString(),
        );
        await _diagnosticLogService?.error(
          'metric_incremental_sync_failed',
          category: DiagnosticLogService.categoryHealthSync,
          message: 'A Health metric could not be imported incrementally.',
          error: error,
          metadata: {'metric_index': results.length},
        );
        results.add(
          MetricSyncResult(
            metricType: metric,
            status: 'failed',
            fetched: 0,
            inserted: 0,
            updated: 0,
            ignored: 0,
            invalid: 0,
            touchedDates: const [],
            error: error.toString(),
          ),
        );
      }
    }

    final endedAt = DateTime.now().toUtc();
    final coreFailedMessages = results
        .where(
          (item) =>
              item.error != null && tier1Metrics.contains(item.metricType),
        )
        .map((item) => '${item.metricType.wireName}: ${item.error!}')
        .toList();
    await _repository.updateSyncState(
      sourceName: 'apple_health',
      lastSyncAt: endedAt,
      lastBackfillStart: priorState?.lastBackfillStart,
      lastBackfillEnd: priorState?.lastBackfillEnd,
      syncCursorJson: priorState?.syncCursorJson,
      lastError:
          coreFailedMessages.isEmpty ? null : coreFailedMessages.join(' | '),
    );

    if (touchedDates.isNotEmpty) {
      final sortedDates = touchedDates.toList()..sort();
      await _dailySummaryService.recomputeDates(sortedDates);
      await _dailySummaryService.recomputeBaseline(asOfDate: sortedDates.last);
      await _cosinorService.recomputeDates(sortedDates);
      await _riskEngineService.recomputeDates(
        sortedDates,
        sessionId: sessionId,
        triggerReason: triggerReason ?? 'incremental_sync',
        isUserAction: isUserAction,
      );
    }

    await _diagnosticLogService?.info(
      results.any((item) => item.error != null)
          ? 'incremental_sync_completed_with_failures'
          : 'incremental_sync_completed',
      category: DiagnosticLogService.categoryHealthSync,
      message: 'Apple Health incremental sync completed.',
      metadata: {
        'metric_count': results.length,
        'inserted_count': results.fold<int>(
          0,
          (sum, item) => sum + item.inserted,
        ),
        'updated_count': results.fold<int>(
          0,
          (sum, item) => sum + item.updated,
        ),
        'invalid_count': results.fold<int>(
          0,
          (sum, item) => sum + item.invalid,
        ),
        'touched_date_count': touchedDates.length,
        'has_failures': results.any((item) => item.error != null),
        'core_failure_count': coreFailedMessages.length,
      },
    );

    return HealthSyncRunResult(
      startedAt: startedAt,
      endedAt: endedAt,
      metricResults: results,
    );
  }

  Future<void> _recordMetricRegistry({
    required HealthMetricType metric,
    required String status,
    required DateTime? importedAt,
    required String? lastErrorKind,
  }) {
    final requiredForCore = tier1Metrics.contains(metric);
    return _repository.upsertHealthKitMetricRegistry(
      HealthKitMetricRegistryRecord(
        metricKey: metric.wireName,
        healthkitIdentifier: metric.wireName,
        normalizedMetricName: _normalizationService.normalizedMetricName(
          metric,
        ),
        metricFamily: _normalizationService.normalizedMetricFamily(metric),
        availability:
            status == 'failed' ? 'unavailable_or_denied' : 'available',
        permissionStatus:
            status == 'failed' ? 'unknown_or_denied' : 'authorized',
        lastSuccessfulImportAt: status == 'failed' ? null : importedAt,
        lastErrorKind: lastErrorKind,
        requiredForCoreScore: requiredForCore,
        usedForContextOnly: !requiredForCore,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }
}
