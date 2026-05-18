import '../database/wearable_sample_repository.dart';

class GemmaTaskAuditView {
  const GemmaTaskAuditView({
    required this.id,
    required this.taskType,
    required this.promptVersion,
    required this.status,
    required this.usedModelOutput,
    required this.validationStatus,
    required this.latencyMs,
    required this.outputHash,
    required this.createdAt,
    required this.qualityLabel,
  });

  final int? id;
  final String taskType;
  final String promptVersion;
  final String status;
  final bool usedModelOutput;
  final String validationStatus;
  final int latencyMs;
  final String? outputHash;
  final DateTime createdAt;
  final String qualityLabel;
}

class GemmaAuditService {
  GemmaAuditService({required WearableSampleRepository repository})
      : _repository = repository;

  final WearableSampleRepository _repository;

  Future<List<GemmaTaskAuditView>> recent({int limit = 20}) async {
    final runs = await _repository.getGemmaTaskRuns(limit: limit);
    return runs.map(_toView).toList(growable: false);
  }

  GemmaTaskAuditView _toView(GemmaTaskRunRecord run) {
    final hasErrors = run.validationErrorsJson.isNotEmpty;
    final qualityLabel = run.usedModelOutput && !hasErrors
        ? 'accepted'
        : hasErrors
            ? 'rejected_by_validation'
            : 'fallback';
    return GemmaTaskAuditView(
      id: run.id,
      taskType: run.taskType,
      promptVersion: run.promptVersion,
      status: run.status,
      usedModelOutput: run.usedModelOutput,
      validationStatus: run.validationStatus,
      latencyMs: run.latencyMs,
      outputHash: run.outputHash,
      createdAt: run.createdAt,
      qualityLabel: qualityLabel,
    );
  }
}
