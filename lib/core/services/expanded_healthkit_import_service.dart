import 'health_sync_service.dart';

class ExpandedHealthKitImportService {
  const ExpandedHealthKitImportService({required this.healthSync});

  final HealthSyncService healthSync;

  Future<HealthSyncRunResult> runProductionBackfill({
    DateTime? now,
    Duration lookback = const Duration(days: 30),
  }) {
    return healthSync.runInitialBackfill(
      metrics: HealthSyncService.allProductionMetrics,
      now: now,
      lookback: lookback,
    );
  }

  Future<HealthSyncRunResult> runContextOnlyBackfill({
    DateTime? now,
    Duration lookback = const Duration(days: 30),
  }) {
    return healthSync.runInitialBackfill(
      metrics: HealthSyncService.productionContextMetrics,
      now: now,
      lookback: lookback,
    );
  }
}
