import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test.gutguard/legacy_runtime');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('method channel runtime parses native status and generate responses',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getRuntimeStatus':
          return {
            'status': 'backend_not_linked',
            'runtimeName': 'litert-lm-ios-gemma4',
            'backendStyle': 'litert-lm',
            'modelId': 'gemma-4-e2b',
            'quantization': 'int4_litert_lm_bundle',
            'expectedModelFilename': 'Models/litert-lm/gemma-4-E2B-it',
            'isBackendLinked': false,
            'isBundledModelPresent': true,
            'isModelLoaded': false,
            'reason': 'Backend is not linked.',
            'contextWindow': 1024,
            'batchSize': 8,
            'gpuLayers': 0,
            'defaultMaxTokens': 96,
            'generationTimeoutSeconds': 30,
            'activeRuntimeProfile': 'phone_balanced',
            'bundledModelFileSizeBytes': 1234,
            'loadedModelPathHash': 'abc123',
            'backendRequested': 'cpu',
            'backendUsed': 'unknown',
            'npuPrefillAvailable': false,
            'backendFallbackReason': 'cpu_default_until_gpu_validated',
            'engineCreateLatencyMs': 320,
            'availableMemoryMB': 3376,
            'memoryWarningCount': 2,
          };
        case 'loadBundledModel':
          expect(call.arguments, {'profile': 'phone_safe'});
          return {
            'status': 'ready',
            'runtimeName': 'litert-lm-ios-gemma4',
            'backendStyle': 'litert-lm',
            'modelId': 'gemma-4-e2b',
            'quantization': 'int4_litert_lm_bundle',
            'expectedModelFilename': 'Models/litert-lm/gemma-4-E2B-it',
            'isBackendLinked': true,
            'isBundledModelPresent': true,
            'isModelLoaded': true,
            'reason': 'ok',
            'contextWindow': 512,
            'batchSize': 8,
            'gpuLayers': 0,
            'defaultMaxTokens': 64,
            'generationTimeoutSeconds': 30,
            'activeRuntimeProfile': 'phone_safe',
            'backendRequested': 'cpu',
            'backendUsed': 'cpu',
            'npuPrefillAvailable': true,
            'backendFallbackReason': 'cpu_default_until_gpu_validated',
            'engineCreateLatencyMs': 120,
          };
        case 'generate':
          return {
            'status': 'unavailable',
            'outputText': '',
            'runtimeName': 'litert-lm-ios-gemma4',
            'reason': 'backend_not_linked',
            'fallbackReason': 'backend_not_linked',
            'promptCharCount': 240,
            'estimatedPromptTokens': 60,
            'promptTokenCountNative': 58,
            'promptBudget': 448,
            'generationLimit': 64,
            'generationLatencyMs': 120,
            'nativeDecodeRc': 1,
            'failureStage': 'decode_failed_prompt_rc_1',
            'activeRuntimeProfile': 'phone_safe',
            'rawOutputCharCount': 42,
            'cleanedOutputCharCount': 0,
            'outputQualityStatus': 'rejected',
            'outputQualityReason': 'control_token_output',
            'promptTemplateVersion': 'gemma4_system_user_model_v2',
            'sanitizerVersion': 'native_generated_text_v1',
            'rawOutputHash': 'feedface',
            'generatedTokenCount': 12,
            'prefillTps': 18.5,
            'decodeTps': 7.25,
            'ramUsageMb': 2110.4,
            'totalTokenCount': 70,
            'stopReason': 'control_loop_detected',
            'samplerProfile': 'greedy',
            'chatTemplateSource': 'manual_gemma4',
            'taskType': 'quick_readiness',
            'backendRequested': 'cpu',
            'backendUsed': 'cpu',
            'backendFallbackReason': 'cpu_default_until_gpu_validated',
            'engineCreateLatencyMs': 425,
            'qualitySignals': ['control_token_output', 'prompt_echo'],
            'rawAlphaRatio': 0.12,
            'cleanedAlphaRatio': 0.0,
            'rawSymbolRatio': 0.42,
            'cleanedSymbolRatio': 0.88,
            'qualityLengthBucket': 'short',
            'rawAccepted': false,
            'cleanedAccepted': false,
            'modelIdUsed': 'gemma-4-e2b-litert-lm',
            'modelLoadLatencyMs': 425,
            'memoryWarningCount': 2,
            'thermalState': 'fair',
            'availableMemoryMbBeforeLoad': 3376,
            'timeToFirstTokenMs': 240,
          };
      }
      return null;
    });

    final runtime = MethodChannelLocalModelRuntime(channel: channel);
    final status = await runtime.getRuntimeStatus();
    final loaded = await runtime.loadBundledModel(profile: 'phone_safe');
    final response = await runtime.generate(
      const LocalModelRequest(
        systemPrompt: 'System',
        userPrompt: 'Why is my risk higher?',
        groundedContext: {'risk': 42},
      ),
    );

    expect(status.runtimeName, 'litert-lm-ios-gemma4');
    expect(status.isBundledModelPresent, isTrue);
    expect(status.isBackendLinked, isFalse);
    expect(status.contextWindow, 1024);
    expect(status.activeRuntimeProfile, 'phone_balanced');
    expect(status.backendRequested, 'cpu');
    expect(status.backendUsed, 'unknown');
    expect(status.npuPrefillAvailable, isFalse);
    expect(status.backendFallbackReason, 'cpu_default_until_gpu_validated');
    expect(status.engineCreateLatencyMs, 320);
    expect(status.availableMemoryMB, 3376);
    expect(status.memoryWarningCount, 2);
    expect(loaded.isModelLoaded, isTrue);
    expect(loaded.activeRuntimeProfile, 'phone_safe');
    expect(loaded.backendRequested, 'cpu');
    expect(loaded.backendUsed, 'cpu');
    expect(loaded.npuPrefillAvailable, isTrue);
    expect(loaded.backendFallbackReason, 'cpu_default_until_gpu_validated');
    expect(response.status, 'unavailable');
    expect(response.reason, 'backend_not_linked');
    expect(response.fallbackReason, 'backend_not_linked');
    expect(response.estimatedPromptTokens, 60);
    expect(response.promptBudget, 448);
    expect(response.generationLatencyMs, 120);
    expect(response.nativeDecodeRc, 1);
    expect(response.failureStage, 'decode_failed_prompt_rc_1');
    expect(response.rawOutputCharCount, 42);
    expect(response.cleanedOutputCharCount, 0);
    expect(response.outputQualityStatus, 'rejected');
    expect(response.outputQualityReason, 'control_token_output');
    expect(response.promptTemplateVersion, 'gemma4_system_user_model_v2');
    expect(response.sanitizerVersion, 'native_generated_text_v1');
    expect(response.rawOutputHash, 'feedface');
    expect(response.generatedTokenCount, 12);
    expect(response.prefillTokenCount, 58);
    expect(response.decodeTokenCount, 12);
    expect(response.prefillTps, 18.5);
    expect(response.decodeTps, 7.25);
    expect(response.ramUsageMb, 2110.4);
    expect(response.totalTokenCount, 70);
    expect(response.stopReason, 'control_loop_detected');
    expect(response.samplerProfile, 'greedy');
    expect(response.chatTemplateSource, 'manual_gemma4');
    expect(response.taskType, 'quick_readiness');
    expect(response.backendRequested, 'cpu');
    expect(response.backendUsed, 'cpu');
    expect(response.backendFallbackReason, 'cpu_default_until_gpu_validated');
    expect(response.engineCreateLatencyMs, 425);
    expect(response.qualitySignals, contains('control_token_output'));
    expect(response.rawAlphaRatio, 0.12);
    expect(response.cleanedSymbolRatio, 0.88);
    expect(response.qualityLengthBucket, 'short');
    expect(response.rawAccepted, isFalse);
    expect(response.cleanedAccepted, isFalse);
    expect(response.modelIdUsed, 'gemma-4-e2b-litert-lm');
    expect(response.modelLoadLatencyMs, 425);
    expect(response.memoryWarningCount, 2);
    expect(response.thermalState, 'fair');
    expect(response.availableMemoryMbBeforeLoad, 3376);
    expect(response.timeToFirstTokenMs, 240);
  });

  test('method channel runtime falls back cleanly when native bridge is absent',
      () async {
    final runtime = MethodChannelLocalModelRuntime(channel: channel);
    final status = await runtime.getRuntimeStatus();

    expect(status.status, 'unavailable');
    expect(status.reason, contains('Legacy native runtime bridge'));
  });

  test('method channel runtime coalesces concurrent load calls', () async {
    var nativeLoadCalls = 0;
    final completer = Completer<Map<String, Object?>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'loadBundledModel') return null;
      nativeLoadCalls += 1;
      return completer.future;
    });

    final runtime = MethodChannelLocalModelRuntime(channel: channel);
    final first = runtime.loadBundledModel(profile: 'phone_balanced');
    final second = runtime.loadBundledModel(profile: 'phone_balanced');

    await Future<void>.delayed(Duration.zero);
    expect(nativeLoadCalls, 1);

    completer.complete({
      'status': 'ready',
      'runtimeName': 'litert-lm-ios-gemma4',
      'backendStyle': 'litert-lm',
      'modelId': 'gemma-4-e2b-litert-lm',
      'quantization': 'int4_litert_lm_bundle',
      'expectedModelFilename': 'Models/litert-lm/gemma-4-E2B-it',
      'isBackendLinked': true,
      'isBundledModelPresent': true,
      'isModelLoaded': true,
      'reason': 'loaded',
      'activeRuntimeProfile': 'phone_balanced',
      'backendRequested': 'litert-lm',
      'backendUsed': 'litert-lm',
    });

    final results = await Future.wait([first, second]);

    expect(results.first.isModelLoaded, isTrue);
    expect(results.last.isModelLoaded, isTrue);
    expect(nativeLoadCalls, 1);
  });
}
