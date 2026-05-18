// flutter_litert_lm_runtime.dart
// Gemma Flares — LocalModelRuntime backed by the flutter_litert_lm pub package.
//
// Replaces the custom MethodChannel bridge (LiteRtLmMethodChannelRuntime). The
// package owns the iOS native layer including the LiteRTLM xcframework and the
// GemmaModelConstraintProvider dylib; this adapter just translates between the
// app's LocalModelRuntime contract and the package's LiteLmEngine API.
//
// Status fields:
//   isBundledModelPresent — derived from a real File.exists() check against
//     the install path owned by LiteRtLmModelDownloadService. The native side
//     never sees the file until we hand it the path, so a file-system probe is
//     the authoritative source.
//   isBackendLinked — true when an engine has been successfully constructed at
//     least once in this process. The xcframework is statically linked, so
//     this flips to true as soon as LiteLmEngine.create returns a handle.
//   isModelLoaded — true while an engine handle is held open.

import 'dart:async';
import 'dart:io';

import 'package:flutter_litert_lm/flutter_litert_lm.dart';

import 'litert_lm_download_service.dart';
import 'local_model_runtime.dart';
import 'local_model_token_broker.dart';

const _kRuntimeName = 'litert-lm-ios-gemma4';
const _kBackendStyle = 'litert-lm';
const _kModelId = 'gemma-4-e2b-litert';
const _kQuantization = 'litert-lm-e2b';
const _kExpectedFile = 'model.litertlm';

class FlutterLitertLmRuntime implements LocalModelRuntime {
  FlutterLitertLmRuntime({
    LiteRtLmModelDownloadService? downloadService,
    LiteRtLmArtifact artifact = LiteRtLmModelDownloadService.defaultArtifact,
  })  : _download = downloadService ?? LiteRtLmModelDownloadService(),
        _artifact = artifact;

  final LiteRtLmModelDownloadService _download;
  final LiteRtLmArtifact _artifact;

  LiteLmEngine? _engine;
  bool _engineEverCreated = false;
  Future<LocalModelRuntimeStatus>? _loadInFlight;
  String? _modelPathLoaded;

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    final modelPath = await _resolveModelPath();
    final modelPresent = modelPath != null;
    final loaded = _engine != null;
    return _buildStatus(
      status: loaded
          ? 'ready'
          : modelPresent
              ? 'idle'
              : 'awaiting_download',
      isBackendLinked: _engineEverCreated,
      isBundledModelPresent: modelPresent,
      isModelLoaded: loaded,
      reason: loaded
          ? 'Engine loaded.'
          : modelPresent
              ? 'Model installed; engine not loaded.'
              : 'Model file not installed.',
    );
  }

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) {
    final existing = _loadInFlight;
    if (existing != null) return existing;

    final future = _doLoad();
    _loadInFlight = future;
    return future.whenComplete(() {
      if (identical(_loadInFlight, future)) _loadInFlight = null;
    });
  }

  Future<LocalModelRuntimeStatus> _doLoad() async {
    final modelPath = await _resolveModelPath();
    if (modelPath == null) {
      return _buildStatus(
        status: 'unavailable',
        isBackendLinked: _engineEverCreated,
        isBundledModelPresent: false,
        isModelLoaded: false,
        reason: 'Model file not installed at expected path.',
      );
    }

    if (_engine != null && _modelPathLoaded == modelPath) {
      return _buildStatus(
        status: 'ready',
        isBackendLinked: true,
        isBundledModelPresent: true,
        isModelLoaded: true,
        reason: 'Engine already loaded.',
      );
    }

    try {
      final engine = await LiteLmEngine.create(
        LiteLmEngineConfig(
          modelPath: modelPath,
          backend: LiteLmBackend.cpu,
        ),
      );
      _engine = engine;
      _modelPathLoaded = modelPath;
      _engineEverCreated = true;
      return _buildStatus(
        status: 'ready',
        isBackendLinked: true,
        isBundledModelPresent: true,
        isModelLoaded: true,
        reason: 'Engine loaded.',
      );
    } catch (e) {
      return _buildStatus(
        status: 'unavailable',
        isBackendLinked: _engineEverCreated,
        isBundledModelPresent: true,
        isModelLoaded: false,
        reason: 'LiteLmEngine.create failed: $e',
      );
    }
  }

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    if (_engine == null) {
      final loadStatus = await loadBundledModel();
      if (!loadStatus.isModelLoaded) {
        return _errorResponse(
          reason: 'engine_not_loaded',
          message: loadStatus.reason,
          taskType: request.taskType,
        );
      }
    }
    final engine = _engine!;

    LiteLmConversation? conversation;
    final started = DateTime.now();
    var ttftMs = 0;
    var firstChunkSeen = false;
    final outputBuffer = StringBuffer();
    final requestId = request.requestId;
    var previousText = '';

    if (requestId != null) {
      LocalModelTokenBroker.instance.openProducer(requestId);
    }

    try {
      conversation = await engine.createConversation(
        LiteLmConversationConfig(systemInstruction: request.systemPrompt),
      );

      await for (final message
          in conversation.sendMessageStream(request.userPrompt)) {
        // LiteLmConversation.sendMessageStream emits the cumulative text on
        // each event, not just the new tokens. Diff against previousText to
        // extract the delta so token-broker subscribers see incremental chunks
        // rather than ever-growing duplicates.
        final fullText = message.text;
        final delta = fullText.length > previousText.length &&
                fullText.startsWith(previousText)
            ? fullText.substring(previousText.length)
            : fullText;
        previousText = fullText;

        if (!firstChunkSeen && delta.isNotEmpty) {
          ttftMs = DateTime.now().difference(started).inMilliseconds;
          firstChunkSeen = true;
        }
        outputBuffer.write(delta);

        if (requestId != null && delta.isNotEmpty) {
          LocalModelTokenBroker.instance.pushToken(requestId, delta);
        }
      }

      final elapsedMs = DateTime.now().difference(started).inMilliseconds;
      final finalText = outputBuffer.toString();
      if (requestId != null) {
        LocalModelTokenBroker.instance.pushComplete(requestId, finalText);
      }
      return LocalModelResponse(
        status: 'success',
        outputText: finalText,
        runtimeName: _kRuntimeName,
        taskType: request.taskType,
        backendRequested: 'cpu',
        backendUsed: 'cpu',
        modelIdUsed: 'gemma-4-e2b',
        engineUsed: 'litert-lm',
        generationLatencyMs: elapsedMs,
        timeToFirstTokenMs: ttftMs,
        localOnlyVerified: true,
      );
    } catch (e) {
      if (requestId != null) {
        LocalModelTokenBroker.instance.pushError(requestId, e);
      }
      return _errorResponse(
        reason: 'generation_failed',
        message: 'LiteLm streaming failed: $e',
        taskType: request.taskType,
      );
    } finally {
      try {
        await conversation?.dispose();
      } catch (_) {
        // Best-effort cleanup.
      }
    }
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {
        'backends': ['cpu'],
        'selected': 'cpu',
        'note':
            'flutter_litert_lm v0.3 iOS path uses CPU; GPU/NPU not exposed.',
      };

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) =>
      getRuntimeStatus();

  Future<String?> _resolveModelPath() async {
    final dir = await _download.revisionDirectory(_artifact);
    final modelFile = File('${dir.path}/$_kExpectedFile');
    if (!await modelFile.exists()) return null;
    if (await modelFile.length() < _artifact.minimumBytes) return null;
    return modelFile.path;
  }

  LocalModelRuntimeStatus _buildStatus({
    required String status,
    required bool isBackendLinked,
    required bool isBundledModelPresent,
    required bool isModelLoaded,
    required String reason,
  }) {
    return LocalModelRuntimeStatus(
      status: status,
      runtimeName: _kRuntimeName,
      backendStyle: _kBackendStyle,
      modelId: _kModelId,
      quantization: _kQuantization,
      expectedModelFilename: _kExpectedFile,
      isBackendLinked: isBackendLinked,
      isBundledModelPresent: isBundledModelPresent,
      isModelLoaded: isModelLoaded,
      reason: reason,
      backendRequested: 'cpu',
      backendUsed: isModelLoaded ? 'cpu' : 'unavailable',
      supportsStreaming: true,
      localOnlyEnforced: true,
      cloudFallbackEnabled: false,
    );
  }

  LocalModelResponse _errorResponse({
    required String reason,
    required String message,
    required String taskType,
  }) {
    return LocalModelResponse(
      status: 'error',
      outputText: message,
      runtimeName: _kRuntimeName,
      reason: reason,
      taskType: taskType,
      backendRequested: 'cpu',
      backendUsed: 'unavailable',
      engineUsed: 'litert-lm',
      localOnlyVerified: true,
    );
  }
}
