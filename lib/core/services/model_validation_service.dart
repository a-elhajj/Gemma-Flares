import '../database/wearable_sample_repository.dart';

class ModelValidationService {
  ModelValidationService({
    required WearableSampleRepository repository,
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final WearableSampleRepository _repository;
  final DateTime Function() _nowProvider;

  Future<String> createLocalDiagnosticRun({
    required String runKey,
    required Map<String, Object?> datasetSummary,
    String? notes,
  }) async {
    await _repository.createValidationRun(
      ModelValidationRunRecord(
        runKey: runKey,
        startedAt: _nowProvider(),
        status: 'started',
        datasetSummaryJson: datasetSummary,
        notes: notes,
      ),
    );
    return runKey;
  }

  Future<void> recordMetric({
    required String runKey,
    required String modelVersion,
    required String labelType,
    int? horizonDays,
    required String metricName,
    required double? metricValue,
    Map<String, Object?> metadata = const {},
  }) {
    return _repository.upsertValidationMetric(
      ModelValidationMetricRecord(
        runKey: runKey,
        modelVersion: modelVersion,
        labelType: labelType,
        horizonDays: horizonDays,
        metricName: metricName,
        metricValue: metricValue,
        metadataJson: {'local_diagnostic_only': true, ...metadata},
        createdAt: _nowProvider(),
      ),
    );
  }
}
