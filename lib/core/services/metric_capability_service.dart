import '../contracts/health_bridge_contracts.dart';
import '../database/wearable_sample_repository.dart';
import 'health_sync_service.dart';
import 'wearable_normalization_service.dart';

class MetricCapabilityService {
  MetricCapabilityService({
    required WearableSampleRepository repository,
    required WearableNormalizationService normalizationService,
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _normalizationService = normalizationService,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final WearableSampleRepository _repository;
  final WearableNormalizationService _normalizationService;
  final DateTime Function() _nowProvider;

  Future<void> seedProductionRegistry() async {
    for (final metric in HealthSyncService.allProductionMetrics) {
      final requiredForCore = HealthSyncService.tier1Metrics.contains(metric);
      await _repository.upsertHealthKitMetricRegistry(
        HealthKitMetricRegistryRecord(
          metricKey: metric.wireName,
          healthkitIdentifier: metric.wireName,
          normalizedMetricName: _normalizationService.normalizedMetricName(
            metric,
          ),
          metricFamily: _normalizationService.normalizedMetricFamily(metric),
          availability: 'unknown',
          permissionStatus: 'not_requested',
          requiredForCoreScore: requiredForCore,
          usedForContextOnly: !requiredForCore,
          updatedAt: _nowProvider(),
        ),
      );
    }
  }
}
