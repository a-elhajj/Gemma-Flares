import 'dart:math' as math;

import 'diagnostic_log_service.dart';
import 'local_model_runtime.dart';
import 'runtime_telemetry_service.dart';

class RuntimeBenchmarkService {
  RuntimeBenchmarkService({
    required LocalModelRuntime runtime,
    DiagnosticLogService? diagnosticLogService,
    RuntimeTelemetryService? runtimeTelemetryService,
    DateTime Function()? nowProvider,
  })  : _runtime = runtime,
        _diagnosticLogService = diagnosticLogService,
        _runtimeTelemetryService = runtimeTelemetryService,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final LocalModelRuntime _runtime;
  final DiagnosticLogService? _diagnosticLogService;
  final RuntimeTelemetryService? _runtimeTelemetryService;
  final DateTime Function() _nowProvider;

  Future<RuntimeBenchmarkReport> runProfile({
    String profile = 'phone_balanced',
    int shortIterations = 10,
    int taskIterations = 3,
  }) async {
    final startedAt = _nowProvider();
    final loadStartedAt = _nowProvider();
    final samples = <RuntimeBenchmarkSample>[];
    final loaded = await _runtime.loadBundledModel(profile: profile);
    final loadLatencyMs =
        _nowProvider().difference(loadStartedAt).inMilliseconds;

    if (!loaded.isModelLoaded) {
      final report = RuntimeBenchmarkReport(
        profile: loaded.activeRuntimeProfile,
        startedAt: startedAt,
        completedAt: _nowProvider(),
        loadLatencyMs: loadLatencyMs,
        loadEngineCreateLatencyMs: loaded.engineCreateLatencyMs,
        loadBackendRequested: loaded.backendRequested,
        loadBackendUsed: loaded.backendUsed,
        loadBackendFallbackReason: loaded.backendFallbackReason,
        successCount: 0,
        fallbackCount: 1,
        timeoutCount: 0,
        decodeFailureCount: 0,
        emptyOutputCount: 0,
        rejectedOutputCount: 0,
        coldStartLatencyMs: 0,
        warmP50LatencyMs: 0,
        warmP95LatencyMs: 0,
        gpuSampleCount: 0,
        cpuSampleCount: 0,
        p50LatencyMs: 0,
        p95LatencyMs: 0,
        samples: const [],
      );
      await _logReport(report, loaded: false);
      return report;
    }

    var firstGeneration = true;

    for (var i = 0; i < shortIterations; i++) {
      samples.add(
        await _runCase(
          label: 'short_hi',
          systemPrompt: _systemPrompt,
          userPrompt: 'hi',
          groundedContext: const {'task': 'short_hi'},
          maxTokens: 16,
          taskType: 'chat',
          phase: firstGeneration ? 'cold_start' : 'warm',
        ),
      );
      firstGeneration = false;
    }

    for (var i = 0; i < taskIterations; i++) {
      for (final benchmarkCase in _benchmarkCases) {
        samples.add(
          await _runCase(
            label: benchmarkCase.label,
            systemPrompt: _systemPrompt,
            userPrompt: benchmarkCase.userPrompt,
            groundedContext: benchmarkCase.groundedContext,
            maxTokens: benchmarkCase.maxTokens,
            taskType: benchmarkCase.taskType,
            phase: firstGeneration ? 'cold_start' : 'warm',
          ),
        );
        firstGeneration = false;
      }
    }

    final latencies = samples
        .where((sample) => sample.latencyMs > 0)
        .map((sample) => sample.latencyMs)
        .toList(growable: false)
      ..sort();
    final warmLatencies = samples
        .where((sample) => sample.phase == 'warm' && sample.latencyMs > 0)
        .map((sample) => sample.latencyMs)
        .toList(growable: false)
      ..sort();
    final coldStartSample = samples
        .where((sample) => sample.phase == 'cold_start')
        .cast<RuntimeBenchmarkSample?>()
        .firstWhere((sample) => sample != null, orElse: () => null);
    final report = RuntimeBenchmarkReport(
      profile: loaded.activeRuntimeProfile,
      startedAt: startedAt,
      completedAt: _nowProvider(),
      loadLatencyMs: loadLatencyMs,
      loadEngineCreateLatencyMs: loaded.engineCreateLatencyMs,
      loadBackendRequested: loaded.backendRequested,
      loadBackendUsed: loaded.backendUsed,
      loadBackendFallbackReason: loaded.backendFallbackReason,
      successCount: samples.where((sample) => sample.usedModelOutput).length,
      fallbackCount: samples.where((sample) => !sample.usedModelOutput).length,
      timeoutCount: samples
          .where((sample) => sample.fallbackReason == 'generation_timeout')
          .length,
      decodeFailureCount:
          samples.where((sample) => (sample.nativeDecodeRc ?? 0) != 0).length,
      emptyOutputCount: samples
          .where((sample) => sample.fallbackReason == 'empty_model_output')
          .length,
      rejectedOutputCount: samples
          .where((sample) => sample.outputQualityStatus == 'rejected')
          .length,
      coldStartLatencyMs: coldStartSample?.latencyMs ?? 0,
      warmP50LatencyMs: _percentile(warmLatencies, 0.50),
      warmP95LatencyMs: _percentile(warmLatencies, 0.95),
      gpuSampleCount:
          samples.where((sample) => sample.backendUsed == 'gpu').length,
      cpuSampleCount:
          samples.where((sample) => sample.backendUsed == 'cpu').length,
      p50LatencyMs: _percentile(latencies, 0.50),
      p95LatencyMs: _percentile(latencies, 0.95),
      samples: samples,
    );
    await _logReport(report, loaded: true);
    return report;
  }

  Future<RuntimeBenchmarkSample> _runCase({
    required String label,
    required String systemPrompt,
    required String userPrompt,
    required Map<String, Object?> groundedContext,
    required int maxTokens,
    required String taskType,
    required String phase,
  }) async {
    final response = await _runtime.generate(
      LocalModelRequest(
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        groundedContext: groundedContext,
        maxTokens: maxTokens,
        temperature: 0.0,
        taskType: taskType,
        modelRole:
            taskType == 'doctor_summary' ? 'doctor_summary' : 'daily_fast',
        contextPolicy: taskType == 'doctor_summary' ? 'large_128k' : 'standard',
        privacyMode: 'local_only',
      ),
    );
    final usedModelOutput = response.status == 'success' &&
        response.outputText.trim().isNotEmpty &&
        response.outputQualityStatus != 'rejected';
    return RuntimeBenchmarkSample(
      label: label,
      status: response.status,
      usedModelOutput: usedModelOutput,
      fallbackReason: response.fallbackReason ?? response.failureStage,
      latencyMs: response.generationLatencyMs,
      estimatedPromptTokens: response.estimatedPromptTokens,
      promptBudget: response.promptBudget,
      generationLimit: response.generationLimit,
      nativeDecodeRc: response.nativeDecodeRc,
      activeRuntimeProfile: response.activeRuntimeProfile,
      taskType: response.taskType,
      phase: phase,
      backendRequested: response.backendRequested,
      backendUsed: response.backendUsed,
      backendFallbackReason: response.backendFallbackReason,
      engineCreateLatencyMs: response.engineCreateLatencyMs,
      outputQualityStatus: response.outputQualityStatus,
      qualitySignals: response.qualitySignals,
      modelIdUsed: response.modelIdUsed,
      timeToFirstTokenMs: response.timeToFirstTokenMs,
      prefillTps: response.prefillTps,
      decodeTps: response.decodeTps,
      ramUsageMb: response.ramUsageMb,
      totalTokenCount: response.totalTokenCount > 0
          ? response.totalTokenCount
          : response.prefillTokenCount + response.decodeTokenCount,
      npuPrefillAvailable: response.npuPrefillAvailable,
      availableMemoryMbBeforeLoad: response.availableMemoryMbBeforeLoad,
    );
  }

  Future<void> _logReport(
    RuntimeBenchmarkReport report, {
    required bool loaded,
  }) async {
    await _diagnosticLogService?.info(
      'gemma_runtime_benchmark_completed',
      category: DiagnosticLogService.categoryModelRuntime,
      message: 'Local Gemma runtime benchmark completed.',
      metadata: {
        'runtime_loaded': loaded,
        'active_runtime_profile': report.profile,
        'load_latency_ms': report.loadLatencyMs,
        'load_engine_create_latency_ms': report.loadEngineCreateLatencyMs,
        'load_backend_requested': report.loadBackendRequested,
        'load_backend_used': report.loadBackendUsed,
        'load_backend_fallback_reason': report.loadBackendFallbackReason,
        'success_count': report.successCount,
        'fallback_count': report.fallbackCount,
        'timeout_count': report.timeoutCount,
        'decode_failure_count': report.decodeFailureCount,
        'empty_output_count': report.emptyOutputCount,
        'rejected_output_count': report.rejectedOutputCount,
        'cold_start_latency_ms': report.coldStartLatencyMs,
        'warm_p50_latency_ms': report.warmP50LatencyMs,
        'warm_p95_latency_ms': report.warmP95LatencyMs,
        'gpu_sample_count': report.gpuSampleCount,
        'cpu_sample_count': report.cpuSampleCount,
        'p50_latency_ms': report.p50LatencyMs,
        'p95_latency_ms': report.p95LatencyMs,
      },
    );
    await _runtimeTelemetryService?.recordBenchmarkCompleted(
      reportJson: report.toJson(),
      profile: report.profile,
      durationMs:
          report.completedAt.difference(report.startedAt).inMilliseconds,
    );
  }

  int _percentile(List<int> sortedValues, double percentile) {
    if (sortedValues.isEmpty) return 0;
    final index = math.min(
      sortedValues.length - 1,
      (sortedValues.length * percentile).ceil() - 1,
    );
    return sortedValues[index];
  }

  static const _systemPrompt =
      'You are Gemma Flares. Use only the compact local evidence. Be concise, safe, and non-diagnostic.';

  static const _benchmarkCases = [
    _BenchmarkCase(
      label: 'risk_explain',
      userPrompt: 'Why is my risk higher?',
      groundedContext: {
        'score': {
          'value': 58,
          'band': 'elevated',
          'drivers': [
            {'label': 'recent symptoms', 'points': 14},
            {'label': 'reduced sleep', 'points': 9},
          ],
        },
        'limits': 'Local estimate only; not diagnosis.',
      },
      maxTokens: 96,
      taskType: 'chat',
    ),
    _BenchmarkCase(
      label: 'week_summary',
      userPrompt: 'Summarize my week.',
      groundedContext: {
        'symptoms': 3,
        'labs': 1,
        'sleep_changed': true,
        'limits': 'Local estimate only; not diagnosis.',
      },
      maxTokens: 96,
      taskType: 'chat',
    ),
    _BenchmarkCase(
      label: 'lab_context',
      userPrompt: 'Do my labs add context?',
      groundedContext: {
        'labs': [
          {'type': 'CRP', 'value': 13.2, 'unit': 'mg/L', 'elevated': true},
        ],
        'limits': 'Lab interpretation needs clinician review.',
      },
      maxTokens: 96,
      taskType: 'chat',
    ),
    _BenchmarkCase(
      label: 'doctor_summary',
      userPrompt: 'Prepare a short GI visit summary.',
      groundedContext: {
        'changed': ['symptoms on 3 days', 'sleep lower'],
        'stable': ['resting heart rate'],
        'limits': 'No diagnosis.',
      },
      maxTokens: 240,
      taskType: 'doctor_summary',
    ),
    _BenchmarkCase(
      label: 'symptom_extract',
      userPrompt:
          'Return JSON for: cramps after dinner, bathroom trips up, skipped meds yesterday, tired.',
      groundedContext: {'schema': 'symptom_extract_v1'},
      maxTokens: 140,
      taskType: 'symptom_extract',
    ),
    _BenchmarkCase(
      label: 'lab_extract_bad_ocr',
      userPrompt:
          'Return JSON for OCR: CRP 13.2 mg/L H, ESR 28 mm/hr, Calprotectin 650 ug/g.',
      groundedContext: {'schema': 'lab_text_extract_v1'},
      maxTokens: 180,
      taskType: 'lab_text_extract',
    ),
  ];
}

class RuntimeBenchmarkReport {
  const RuntimeBenchmarkReport({
    required this.profile,
    required this.startedAt,
    required this.completedAt,
    required this.loadLatencyMs,
    required this.loadEngineCreateLatencyMs,
    required this.loadBackendRequested,
    required this.loadBackendUsed,
    required this.loadBackendFallbackReason,
    required this.successCount,
    required this.fallbackCount,
    required this.timeoutCount,
    required this.decodeFailureCount,
    required this.emptyOutputCount,
    required this.rejectedOutputCount,
    required this.coldStartLatencyMs,
    required this.warmP50LatencyMs,
    required this.warmP95LatencyMs,
    required this.gpuSampleCount,
    required this.cpuSampleCount,
    required this.p50LatencyMs,
    required this.p95LatencyMs,
    required this.samples,
  });

  final String profile;
  final DateTime startedAt;
  final DateTime completedAt;
  final int loadLatencyMs;
  final int loadEngineCreateLatencyMs;
  final String loadBackendRequested;
  final String loadBackendUsed;
  final String? loadBackendFallbackReason;
  final int successCount;
  final int fallbackCount;
  final int timeoutCount;
  final int decodeFailureCount;
  final int emptyOutputCount;
  final int rejectedOutputCount;
  final int coldStartLatencyMs;
  final int warmP50LatencyMs;
  final int warmP95LatencyMs;
  final int gpuSampleCount;
  final int cpuSampleCount;
  final int p50LatencyMs;
  final int p95LatencyMs;
  final List<RuntimeBenchmarkSample> samples;

  Map<String, Object?> toJson() {
    return {
      'profile': profile,
      'started_at': startedAt.toIso8601String(),
      'completed_at': completedAt.toIso8601String(),
      'load_latency_ms': loadLatencyMs,
      'load_engine_create_latency_ms': loadEngineCreateLatencyMs,
      'load_backend_requested': loadBackendRequested,
      'load_backend_used': loadBackendUsed,
      'load_backend_fallback_reason': loadBackendFallbackReason,
      'success_count': successCount,
      'fallback_count': fallbackCount,
      'timeout_count': timeoutCount,
      'decode_failure_count': decodeFailureCount,
      'empty_output_count': emptyOutputCount,
      'rejected_output_count': rejectedOutputCount,
      'cold_start_latency_ms': coldStartLatencyMs,
      'warm_p50_latency_ms': warmP50LatencyMs,
      'warm_p95_latency_ms': warmP95LatencyMs,
      'gpu_sample_count': gpuSampleCount,
      'cpu_sample_count': cpuSampleCount,
      'p50_latency_ms': p50LatencyMs,
      'p95_latency_ms': p95LatencyMs,
      'samples': samples.map((sample) => sample.toJson()).toList(),
    };
  }
}

class RuntimeBenchmarkSample {
  const RuntimeBenchmarkSample({
    required this.label,
    required this.status,
    required this.usedModelOutput,
    required this.fallbackReason,
    required this.latencyMs,
    required this.estimatedPromptTokens,
    required this.promptBudget,
    required this.generationLimit,
    required this.nativeDecodeRc,
    required this.activeRuntimeProfile,
    required this.taskType,
    required this.phase,
    required this.backendRequested,
    required this.backendUsed,
    required this.backendFallbackReason,
    required this.engineCreateLatencyMs,
    required this.outputQualityStatus,
    required this.qualitySignals,
    required this.modelIdUsed,
    required this.timeToFirstTokenMs,
    required this.prefillTps,
    required this.decodeTps,
    required this.ramUsageMb,
    required this.totalTokenCount,
    required this.npuPrefillAvailable,
    required this.availableMemoryMbBeforeLoad,
  });

  final String label;
  final String status;
  final bool usedModelOutput;
  final String? fallbackReason;
  final int latencyMs;
  final int estimatedPromptTokens;
  final int promptBudget;
  final int generationLimit;
  final int? nativeDecodeRc;
  final String activeRuntimeProfile;
  final String taskType;
  final String phase;
  final String backendRequested;
  final String backendUsed;
  final String? backendFallbackReason;
  final int engineCreateLatencyMs;
  final String outputQualityStatus;
  final List<String> qualitySignals;
  final String modelIdUsed;
  final int timeToFirstTokenMs;
  final double? prefillTps;
  final double? decodeTps;
  final double? ramUsageMb;
  final int totalTokenCount;
  final bool npuPrefillAvailable;
  final int availableMemoryMbBeforeLoad;

  Map<String, Object?> toJson() {
    return {
      'label': label,
      'status': status,
      'used_model_output': usedModelOutput,
      'fallback_reason': fallbackReason,
      'latency_ms': latencyMs,
      'estimated_prompt_tokens': estimatedPromptTokens,
      'prompt_budget': promptBudget,
      'generation_limit': generationLimit,
      'native_decode_rc': nativeDecodeRc,
      'active_runtime_profile': activeRuntimeProfile,
      'task_type': taskType,
      'phase': phase,
      'backend_requested': backendRequested,
      'backend_used': backendUsed,
      'backend_fallback_reason': backendFallbackReason,
      'engine_create_latency_ms': engineCreateLatencyMs,
      'output_quality_status': outputQualityStatus,
      'quality_signals': qualitySignals,
      'model_id_used': modelIdUsed,
      'time_to_first_token_ms': timeToFirstTokenMs,
      'prefill_tps': prefillTps,
      'decode_tps': decodeTps,
      'ram_usage_mb': ramUsageMb,
      'total_token_count': totalTokenCount,
      'npu_prefill_available': npuPrefillAvailable,
      'available_memory_mb_before_load': availableMemoryMbBeforeLoad,
    };
  }
}

class _BenchmarkCase {
  const _BenchmarkCase({
    required this.label,
    required this.userPrompt,
    required this.groundedContext,
    required this.maxTokens,
    required this.taskType,
  });

  final String label;
  final String userPrompt;
  final Map<String, Object?> groundedContext;
  final int maxTokens;
  final String taskType;
}
