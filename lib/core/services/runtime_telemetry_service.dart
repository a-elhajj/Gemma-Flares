import '../database/wearable_sample_repository.dart';
import 'local_model_runtime.dart';

class RuntimeTelemetryService {
  RuntimeTelemetryService({
    required WearableSampleRepository repository,
    DateTime Function()? nowProvider,
    String? sessionId,
    bool swallowFailures = true,
  })  : _repository = repository,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc()),
        _sessionId = sessionId,
        _swallowFailures = swallowFailures;

  final WearableSampleRepository _repository;
  final DateTime Function() _nowProvider;
  final String? _sessionId;
  final bool _swallowFailures;
  String? _resolvedSessionId;

  Future<void> recordGenerationComplete({
    required LocalModelResponse response,
    int? availableMemoryMbBeforeLoad,
    Map<String, Object?> extraMetadata = const {},
  }) async {
    try {
      await _repository.insertRuntimeEvent(
        RuntimeEventRecord(
          createdAt: _nowProvider(),
          sessionId: _getSessionId(),
          eventKind: 'generate.complete',
          modelRole: _modelRoleFrom(response.modelIdUsed),
          profile: response.activeRuntimeProfile,
          availableMb: availableMemoryMbBeforeLoad ??
              _nonNegative(response.availableMemoryMbBeforeLoad),
          residentMb: _roundedOrMinusOne(response.ramUsageMb),
          durationMs: response.generationLatencyMs,
          metadataJson: {
            'model_id_used': response.modelIdUsed,
            'model_role_used': response.modelRoleUsed,
            'status': response.status,
            'used_model_output':
                response.status == 'success' && response.outputText.isNotEmpty,
            'model_load_latency_ms': response.modelLoadLatencyMs,
            'time_to_first_token_ms': response.timeToFirstTokenMs,
            'generation_latency_ms': response.generationLatencyMs,
            'decode_tps': response.decodeTps,
            'prefill_tps': response.prefillTps,
            'prefill_token_count': response.prefillTokenCount,
            'decode_token_count': response.decodeTokenCount,
            'total_token_count': _totalTokenCount(response),
            'ram_usage_mb': response.ramUsageMb,
            'npu_prefill_available': response.npuPrefillAvailable,
            'backend_used': response.backendUsed,
            'backend_fallback_reason':
                response.backendFallbackReason ?? response.fallbackReason,
            'memory_warning_count': response.memoryWarningCount,
            'thermal_state_after_generation': response.thermalState,
            'local_only_verified': response.localOnlyVerified,
            ...extraMetadata,
          },
        ),
      );
    } catch (_) {
      if (!_swallowFailures) rethrow;
    }
  }

  Future<void> recordBenchmarkCompleted({
    required Map<String, Object?> reportJson,
    String profile = 'unknown',
    int durationMs = 0,
  }) async {
    try {
      await _repository.insertRuntimeEvent(
        RuntimeEventRecord(
          createdAt: _nowProvider(),
          sessionId: _getSessionId(),
          eventKind: 'benchmark.complete',
          profile: profile,
          durationMs: durationMs,
          metadataJson: reportJson,
        ),
      );
    } catch (_) {
      if (!_swallowFailures) rethrow;
    }
  }

  int _totalTokenCount(LocalModelResponse response) {
    if (response.totalTokenCount > 0) return response.totalTokenCount;
    return response.prefillTokenCount + response.decodeTokenCount;
  }

  int _roundedOrMinusOne(double? value) {
    if (value == null || value < 0) return -1;
    return value.round();
  }

  int _nonNegative(int value) => value >= 0 ? value : -1;

  String _modelRoleFrom(String modelId) {
    final normalized = modelId.toLowerCase();
    if (normalized.contains('e2b')) return 'e2b';
    return 'unknown';
  }

  String _getSessionId() {
    final existing = _resolvedSessionId ?? _sessionId;
    if (existing != null && existing.isNotEmpty) {
      _resolvedSessionId = existing;
      return existing;
    }
    _resolvedSessionId = 'runtime-${_nowProvider().microsecondsSinceEpoch}';
    return _resolvedSessionId!;
  }
}
