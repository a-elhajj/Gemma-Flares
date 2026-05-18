// =============================================================================
// GEMMA 4 — LiteRT-LM Runtime Bridge
// =============================================================================
// This file defines the shared Flutter/Dart contract for the native on-device
// runtime. Production inference uses LiteRT-LM through LiteRtLmMethodChannelRuntime.
//
// How Gemma 4 runs on-device:
//   - [LocalModelRuntime] is an abstract interface used by services and tests.
//   - Swift: LiteRtLmRuntimeManager.swift owns the production model lifecycle.
//   - Model is NOT bundled in the IPA. First-run setup downloads the approved
//     LiteRT-LM artifact, verifies SHA-256, and installs it in the app sandbox.
//   - [LocalModelRequest.privacyMode] is always 'local_only' — no data leaves the device.
//   - [LocalModelRequest.temperature] is 0.2 for factual tasks (chat, risk explanation)
//     and 0.3 for creative drafts (visit summary).
//   - If the model is unavailable, every caller has a deterministic fallback path.
// =============================================================================

import 'package:flutter/services.dart';

class LocalModelRequest {
  const LocalModelRequest({
    required this.systemPrompt,
    required this.userPrompt,
    required this.groundedContext,
    this.maxTokens = 160,
    this.temperature = 0.2,
    this.taskType = 'chat',
    this.modelRole = 'daily_fast',
    this.privacyMode = 'local_only',
    this.contextPolicy = 'standard',
    this.toolSchemas = const [],
    this.attachments = const {},
    this.conversationId,
    this.requestId,
  });

  final String systemPrompt;
  final String userPrompt;
  final Map<String, Object?> groundedContext;
  final int maxTokens;
  final double temperature;
  final String taskType;
  final String modelRole;
  final String privacyMode;
  final String contextPolicy;
  final List<Map<String, Object?>> toolSchemas;
  final Map<String, Object?> attachments;
  final String? conversationId;
  final String? requestId;

  Map<String, Object?> toJson() {
    return {
      'systemPrompt': systemPrompt,
      'userPrompt': userPrompt,
      'groundedContext': groundedContext,
      'maxTokens': maxTokens,
      'temperature': temperature,
      'taskType': taskType,
      'modelRole': modelRole,
      'privacyMode': privacyMode,
      'contextPolicy': contextPolicy,
      'toolSchemas': toolSchemas,
      'attachments': attachments,
      'conversationId': conversationId,
      'requestId': requestId,
    };
  }
}

class LocalModelResponse {
  const LocalModelResponse({
    required this.status,
    required this.outputText,
    required this.runtimeName,
    this.reason,
    this.promptCharCount = 0,
    this.estimatedPromptTokens = 0,
    this.promptTokenCountNative = 0,
    this.promptBudget = 0,
    this.generationLimit = 0,
    this.generationLatencyMs = 0,
    this.nativeDecodeRc,
    this.failureStage,
    this.fallbackReason,
    this.activeRuntimeProfile = 'phone_unknown',
    this.rawOutputCharCount = 0,
    this.cleanedOutputCharCount = 0,
    this.outputQualityStatus = 'unknown',
    this.outputQualityReason,
    this.promptTemplateVersion = 'unknown',
    this.sanitizerVersion = 'unknown',
    this.rawOutputHash,
    this.generatedTokenCount = 0,
    this.prefillTps,
    this.decodeTps,
    this.ramUsageMb,
    this.totalTokenCount = 0,
    this.stopReason,
    this.samplerProfile,
    this.chatTemplateSource,
    this.taskType = 'unknown',
    this.backendRequested = 'cpu',
    this.backendUsed = 'unknown',
    this.npuPrefillAvailable = false,
    this.backendFallbackReason,
    this.engineCreateLatencyMs = 0,
    this.qualitySignals = const [],
    this.rawAlphaRatio,
    this.cleanedAlphaRatio,
    this.rawSymbolRatio,
    this.cleanedSymbolRatio,
    this.qualityLengthBucket,
    this.rawAccepted = false,
    this.cleanedAccepted = false,
    this.modelRoleUsed = 'daily_fast',
    this.modelIdUsed = 'gemma-4-e2b',
    this.engineUsed = 'litert-lm',
    this.contextWindowConfigured = 0,
    this.promptTokensActual = 0,
    this.contextPolicyUsed = 'standard',
    this.toolCalls = const [],
    this.toolCallParseStatus = 'not_used',
    this.localOnlyVerified = true,
    this.modalityUsed = 'text',
    this.modelLoadLatencyMs = 0,
    this.modelSwitchLatencyMs = 0,
    this.memoryWarningCount = 0,
    this.thermalState = 'unknown',
    this.availableMemoryMbBeforeLoad = -1,
    this.answerEvidenceHash,
    this.timeToFirstTokenMs = 0,
  });

  final String status;
  final String outputText;
  final String runtimeName;
  final String? reason;
  final int promptCharCount;
  final int estimatedPromptTokens;
  final int promptTokenCountNative;
  final int promptBudget;
  final int generationLimit;
  final int generationLatencyMs;
  final int? nativeDecodeRc;
  final String? failureStage;
  final String? fallbackReason;
  final String activeRuntimeProfile;
  final int rawOutputCharCount;
  final int cleanedOutputCharCount;
  final String outputQualityStatus;
  final String? outputQualityReason;
  final String promptTemplateVersion;
  final String sanitizerVersion;
  final String? rawOutputHash;
  final int generatedTokenCount;
  final double? prefillTps;
  final double? decodeTps;
  final double? ramUsageMb;
  final int totalTokenCount;
  final String? stopReason;
  final String? samplerProfile;
  final String? chatTemplateSource;
  final String taskType;
  final String backendRequested;
  final String backendUsed;
  final bool npuPrefillAvailable;
  final String? backendFallbackReason;
  final int engineCreateLatencyMs;
  final List<String> qualitySignals;
  final double? rawAlphaRatio;
  final double? cleanedAlphaRatio;
  final double? rawSymbolRatio;
  final double? cleanedSymbolRatio;
  final String? qualityLengthBucket;
  final bool rawAccepted;
  final bool cleanedAccepted;
  final String modelRoleUsed;
  final String modelIdUsed;
  final String engineUsed;
  final int contextWindowConfigured;
  final int promptTokensActual;
  final String contextPolicyUsed;
  final List<Map<String, Object?>> toolCalls;
  final String toolCallParseStatus;
  final bool localOnlyVerified;
  final String modalityUsed;
  final int modelLoadLatencyMs;
  final int modelSwitchLatencyMs;
  final int memoryWarningCount;
  final String thermalState;
  final int availableMemoryMbBeforeLoad;
  final String? answerEvidenceHash;

  /// Wall-clock ms from generation start to first token received from native.
  /// Zero if streaming was not active or no token was emitted.
  final int timeToFirstTokenMs;

  factory LocalModelResponse.fromJson(Map<Object?, Object?> json) {
    return LocalModelResponse(
      status: json['status'] as String? ?? 'unavailable',
      outputText: json['outputText'] as String? ?? '',
      runtimeName: json['runtimeName'] as String? ?? 'unknown',
      reason: json['reason'] as String?,
      promptCharCount: _intFromJson(json['promptCharCount']),
      estimatedPromptTokens: _intFromJson(json['estimatedPromptTokens']),
      promptTokenCountNative: _intFromJson(json['promptTokenCountNative']),
      promptBudget: _intFromJson(json['promptBudget']),
      generationLimit: _intFromJson(json['generationLimit']),
      generationLatencyMs: _intFromJson(json['generationLatencyMs']),
      nativeDecodeRc: _nullableIntFromJson(json['nativeDecodeRc']),
      failureStage: json['failureStage'] as String?,
      fallbackReason: json['fallbackReason'] as String?,
      activeRuntimeProfile:
          json['activeRuntimeProfile'] as String? ?? 'phone_unknown',
      rawOutputCharCount: _intFromJson(json['rawOutputCharCount']),
      cleanedOutputCharCount: _intFromJson(json['cleanedOutputCharCount']),
      outputQualityStatus: json['outputQualityStatus'] as String? ?? 'unknown',
      outputQualityReason: json['outputQualityReason'] as String?,
      promptTemplateVersion:
          json['promptTemplateVersion'] as String? ?? 'unknown',
      sanitizerVersion: json['sanitizerVersion'] as String? ?? 'unknown',
      rawOutputHash: json['rawOutputHash'] as String?,
      generatedTokenCount: _intFromJson(json['generatedTokenCount']),
      prefillTps: _nullableDoubleFromJson(json['prefillTps']),
      decodeTps: _nullableDoubleFromJson(json['decodeTps']),
      ramUsageMb: _nullableDoubleFromJson(json['ramUsageMb']),
      totalTokenCount: _intFromJson(json['totalTokenCount']),
      stopReason: json['stopReason'] as String?,
      samplerProfile: json['samplerProfile'] as String?,
      chatTemplateSource: json['chatTemplateSource'] as String?,
      taskType: json['taskType'] as String? ?? 'unknown',
      backendRequested: json['backendRequested'] as String? ?? 'cpu',
      backendUsed: json['backendUsed'] as String? ?? 'unknown',
      npuPrefillAvailable: json['npuPrefillAvailable'] as bool? ?? false,
      backendFallbackReason: json['backendFallbackReason'] as String?,
      engineCreateLatencyMs: _intFromJson(json['engineCreateLatencyMs']),
      qualitySignals: _stringListFromJson(json['qualitySignals']),
      rawAlphaRatio: _nullableDoubleFromJson(json['rawAlphaRatio']),
      cleanedAlphaRatio: _nullableDoubleFromJson(json['cleanedAlphaRatio']),
      rawSymbolRatio: _nullableDoubleFromJson(json['rawSymbolRatio']),
      cleanedSymbolRatio: _nullableDoubleFromJson(json['cleanedSymbolRatio']),
      qualityLengthBucket: json['qualityLengthBucket'] as String?,
      rawAccepted: json['rawAccepted'] as bool? ?? false,
      cleanedAccepted: json['cleanedAccepted'] as bool? ?? false,
      modelRoleUsed: json['modelRoleUsed'] as String? ?? 'daily_fast',
      modelIdUsed: json['modelIdUsed'] as String? ?? 'gemma-4-e2b',
      engineUsed: json['engineUsed'] as String? ?? 'litert-lm',
      contextWindowConfigured: _intFromJson(json['contextWindowConfigured']),
      promptTokensActual: _intFromJson(json['promptTokensActual']),
      contextPolicyUsed: json['contextPolicyUsed'] as String? ?? 'standard',
      toolCalls: _mapListFromJson(json['toolCalls']),
      toolCallParseStatus: json['toolCallParseStatus'] as String? ?? 'not_used',
      localOnlyVerified: json['localOnlyVerified'] as bool? ?? true,
      modalityUsed: json['modalityUsed'] as String? ?? 'text',
      modelLoadLatencyMs: _intFromJson(json['modelLoadLatencyMs']),
      modelSwitchLatencyMs: _intFromJson(json['modelSwitchLatencyMs']),
      memoryWarningCount: _intFromJson(json['memoryWarningCount']),
      thermalState: json['thermalState'] as String? ?? 'unknown',
      availableMemoryMbBeforeLoad: _intFromJson(
        json['availableMemoryMbBeforeLoad'],
      ),
      answerEvidenceHash: json['answerEvidenceHash'] as String?,
      timeToFirstTokenMs: _intFromJson(json['timeToFirstTokenMs']),
    );
  }

  int get prefillTokenCount => promptTokenCountNative;

  int get decodeTokenCount => generatedTokenCount;
}

class LocalModelRuntimeStatus {
  const LocalModelRuntimeStatus({
    required this.status,
    required this.runtimeName,
    required this.backendStyle,
    required this.modelId,
    required this.quantization,
    required this.expectedModelFilename,
    required this.isBackendLinked,
    required this.isBundledModelPresent,
    required this.isModelLoaded,
    required this.reason,
    this.contextWindow = 0,
    this.batchSize = 0,
    this.gpuLayers = 0,
    this.defaultMaxTokens = 0,
    this.generationTimeoutSeconds = 0,
    this.activeRuntimeProfile = 'phone_unknown',
    this.bundledModelFileSizeBytes,
    this.loadedModelPathHash,
    this.backendRequested = 'cpu',
    this.backendUsed = 'unknown',
    this.npuPrefillAvailable = false,
    this.backendFallbackReason,
    this.engineCreateLatencyMs = 0,
    this.availableMemoryMB,
    this.memoryWarningCount = 0,
    this.availableModels = const [],
    this.loadedModelId = 'gemma-4-e2b',
    this.loadedModelRole = 'daily_fast',
    this.supportsTools = false,
    this.supportsVision = false,
    this.supportsAudio = false,
    this.supportsStreaming = false,
    this.maxContextWindow = 0,
    this.safeContextWindow = 0,
    this.localOnlyEnforced = true,
    this.cloudFallbackEnabled = false,
    this.lastModelSwitchReason,
    this.lastNativeRuntimeAbort,
  });

  final String status;
  final String runtimeName;
  final String backendStyle;
  final String modelId;
  final String quantization;
  final String expectedModelFilename;
  final bool isBackendLinked;
  final bool isBundledModelPresent;
  final bool isModelLoaded;
  final String reason;
  final int contextWindow;
  final int batchSize;
  final int gpuLayers;
  final int defaultMaxTokens;
  final int generationTimeoutSeconds;
  final String activeRuntimeProfile;
  final int? bundledModelFileSizeBytes;
  final String? loadedModelPathHash;
  final String backendRequested;
  final String backendUsed;
  final bool npuPrefillAvailable;
  final String? backendFallbackReason;
  final int engineCreateLatencyMs;
  final int? availableMemoryMB;
  final int memoryWarningCount;
  final List<Map<String, Object?>> availableModels;
  final String loadedModelId;
  final String loadedModelRole;
  final bool supportsTools;
  final bool supportsVision;
  final bool supportsAudio;
  final bool supportsStreaming;
  final int maxContextWindow;
  final int safeContextWindow;
  final bool localOnlyEnforced;
  final bool cloudFallbackEnabled;
  final String? lastModelSwitchReason;

  /// BUG-052: short code for the most recent non-fatal pre-generate guard
  /// event raised by the iOS native runtime (e.g.
  /// `runtime_thermal_critical`, `runtime_headroom_below_floor`). `null`
  /// when no guard has fired for the active model handle. QA telemetry can
  /// route on this; it MUST NOT be shown to the user verbatim.
  final String? lastNativeRuntimeAbort;

  factory LocalModelRuntimeStatus.fromJson(Map<Object?, Object?> json) {
    return LocalModelRuntimeStatus(
      status: json['status'] as String? ?? 'unavailable',
      runtimeName: json['runtimeName'] as String? ?? 'unknown',
      backendStyle: json['backendStyle'] as String? ?? 'unknown',
      modelId: json['modelId'] as String? ?? 'unknown',
      quantization: json['quantization'] as String? ?? 'unknown',
      expectedModelFilename:
          json['expectedModelFilename'] as String? ?? 'unknown',
      isBackendLinked: json['isBackendLinked'] as bool? ?? false,
      isBundledModelPresent: json['isBundledModelPresent'] as bool? ?? false,
      isModelLoaded: json['isModelLoaded'] as bool? ?? false,
      reason: json['reason'] as String? ?? 'Unavailable.',
      contextWindow: _intFromJson(json['contextWindow']),
      batchSize: _intFromJson(json['batchSize']),
      gpuLayers: _intFromJson(json['gpuLayers']),
      defaultMaxTokens: _intFromJson(json['defaultMaxTokens']),
      generationTimeoutSeconds: _intFromJson(json['generationTimeoutSeconds']),
      activeRuntimeProfile:
          json['activeRuntimeProfile'] as String? ?? 'phone_unknown',
      bundledModelFileSizeBytes: _nullableIntFromJson(
        json['bundledModelFileSizeBytes'],
      ),
      loadedModelPathHash: json['loadedModelPathHash'] as String?,
      backendRequested: json['backendRequested'] as String? ?? 'cpu',
      backendUsed: json['backendUsed'] as String? ?? 'unknown',
      npuPrefillAvailable: json['npuPrefillAvailable'] as bool? ?? false,
      backendFallbackReason: json['backendFallbackReason'] as String?,
      engineCreateLatencyMs: _intFromJson(json['engineCreateLatencyMs']),
      availableMemoryMB: _nullableIntFromJson(json['availableMemoryMB']),
      memoryWarningCount: _intFromJson(json['memoryWarningCount']),
      availableModels: _mapListFromJson(json['availableModels']),
      loadedModelId: (json['loadedModelId'] as String?) ??
          (json['modelId'] as String?) ??
          'gemma-4-e2b',
      loadedModelRole: json['loadedModelRole'] as String? ?? 'daily_fast',
      supportsTools: json['supportsTools'] as bool? ?? false,
      supportsVision: json['supportsVision'] as bool? ?? false,
      supportsAudio: json['supportsAudio'] as bool? ?? false,
      supportsStreaming: json['supportsStreaming'] as bool? ?? false,
      maxContextWindow: _intFromJson(json['maxContextWindow']),
      safeContextWindow: _intFromJson(json['safeContextWindow']),
      localOnlyEnforced: json['localOnlyEnforced'] as bool? ?? true,
      cloudFallbackEnabled: json['cloudFallbackEnabled'] as bool? ?? false,
      lastModelSwitchReason: json['lastModelSwitchReason'] as String?,
      lastNativeRuntimeAbort: json['lastNativeRuntimeAbort'] as String?,
    );
  }
}

abstract class LocalModelRuntime {
  Future<LocalModelRuntimeStatus> getRuntimeStatus();

  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile});

  Future<LocalModelResponse> generate(LocalModelRequest request);

  Future<Map<String, dynamic>> getAvailableBackends();

  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId);
}

extension LocalModelRuntimePreparation on LocalModelRuntime {
  Future<LocalModelRuntimeStatus> loadLocalModel({String? profile}) {
    return loadBundledModel(profile: profile);
  }
}

class MethodChannelLocalModelRuntime implements LocalModelRuntime {
  MethodChannelLocalModelRuntime({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('com.gutguard/litert_lm_legacy');

  final MethodChannel _channel;
  Future<LocalModelRuntimeStatus>? _loadInFlight;
  LocalModelRuntimeStatus? _lastKnownStatus;
  static const LocalModelRuntimeStatus _missingBridgeStatus =
      LocalModelRuntimeStatus(
    status: 'unavailable',
    runtimeName: 'litert-lm-ios-gemma4',
    backendStyle: 'litert-lm',
    modelId: 'gemma-4-e2b-litert-lm',
    quantization: 'int4_litert_lm_bundle',
    expectedModelFilename: 'Models/litert-lm/gemma-4-E2B-it',
    isBackendLinked: false,
    isBundledModelPresent: false,
    isModelLoaded: false,
    reason: 'Legacy native runtime bridge is not available on this platform.',
    backendRequested: 'litert-lm',
    backendUsed: 'unavailable',
  );

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'getRuntimeStatus',
      );
      final status = LocalModelRuntimeStatus.fromJson(raw ?? const {});
      // Keep cache in sync: a fresh status query is ground truth.
      _lastKnownStatus = status;
      return status;
    } on MissingPluginException {
      return _missingBridgeStatus;
    }
  }

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) async {
    // Fast-path: if a concurrent load is already in flight, share its result.
    final existingLoad = _loadInFlight;
    if (existingLoad != null) {
      return existingLoad;
    }

    // Fast-path: if the model is already loaded, skip the platform-channel
    // round-trip entirely.  Sequential callers (local_agent_service,
    // gemma_task_service, home_screen, guidance_service) each invoke this
    // independently after the first load completes; without this guard they
    // each trigger a full _loadBundledModel() on the Swift serial queue, which
    // — even with Swift's own idempotency guard — adds unnecessary queue hops
    // and defeats the early-exit log signal.
    final cached = _lastKnownStatus;
    if (cached != null && cached.isModelLoaded) {
      return cached;
    }

    final load = _invokeLoadBundledModel(profile: profile);
    _loadInFlight = load;
    try {
      final result = await load;
      // Cache the result so sequential callers see the loaded state.
      // Clear on failed load so the next attempt re-checks.
      _lastKnownStatus = result.isModelLoaded ? result : null;
      return result;
    } finally {
      if (identical(_loadInFlight, load)) {
        _loadInFlight = null;
      }
    }
  }

  Future<LocalModelRuntimeStatus> _invokeLoadBundledModel({
    String? profile,
  }) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'loadBundledModel',
        profile == null ? null : {'profile': profile},
      );
      return LocalModelRuntimeStatus.fromJson(raw ?? const {});
    } on MissingPluginException {
      return _missingBridgeStatus;
    }
  }

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'generate',
        request.toJson(),
      );
      return LocalModelResponse.fromJson(raw ?? const {});
    } on MissingPluginException {
      return const LocalModelResponse(
        status: 'unavailable',
        outputText:
            'Gemma 4 E2B native runtime is unavailable on this platform.',
        runtimeName: 'litert-lm-ios-gemma4',
        reason: 'native_bridge_unavailable',
        taskType: 'unknown',
        backendRequested: 'litert-lm',
        backendUsed: 'unavailable',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'getAvailableBackends',
      );
      return raw ?? const {};
    } on MissingPluginException {
      return const {};
    }
  }

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'setPreferredBackend',
        backendId == null ? null : {'backendId': backendId},
      );
      return LocalModelRuntimeStatus.fromJson(raw ?? const {});
    } on MissingPluginException {
      return _missingBridgeStatus;
    }
  }
}

class UnavailableGemmaRuntime implements LocalModelRuntime {
  const UnavailableGemmaRuntime();

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    return const LocalModelRuntimeStatus(
      status: 'unavailable',
      runtimeName: 'litert-lm-ios-gemma4-unavailable',
      backendStyle: 'litert-lm',
      modelId: 'gemma-4-e2b-litert-lm',
      quantization: 'int4_litert_lm_bundle',
      expectedModelFilename: 'Models/litert-lm/gemma-4-E2B-it',
      isBackendLinked: false,
      isBundledModelPresent: false,
      isModelLoaded: false,
      reason: 'Gemma 4 LiteRT-LM runtime is not connected in this build.',
      backendRequested: 'litert-lm',
      backendUsed: 'unavailable',
    );
  }

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) {
    return getRuntimeStatus();
  }

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    return const LocalModelResponse(
      status: 'unavailable',
      outputText: 'Gemma 4 LiteRT-LM runtime is not connected in this build.',
      runtimeName: 'litert-lm-ios-gemma4-unavailable',
      reason: 'runtime_not_connected',
      taskType: 'unknown',
      backendRequested: 'litert-lm',
      backendUsed: 'unavailable',
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) {
    return getRuntimeStatus();
  }
}

int _intFromJson(Object? value) {
  return _nullableIntFromJson(value) ?? 0;
}

int? _nullableIntFromJson(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}

double? _nullableDoubleFromJson(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

List<String> _stringListFromJson(Object? value) {
  if (value is! List) return const [];
  return value.map((item) => item.toString()).toList(growable: false);
}

List<Map<String, Object?>> _mapListFromJson(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map(
        (item) =>
            item.map((key, itemValue) => MapEntry(key.toString(), itemValue)),
      )
      .toList(growable: false);
}
