// Regression: BUG-052
//
// TestFlight crash on iPhone17,3 / iOS 26.3.1 — EXC_BAD_ACCESS inside a
// native runtime worker pthread during the first foreground generation call.
// The native runtime now refuses generation gracefully when the device is
// in a state correlated with the crash (thermal-critical, jetsam headroom
// below the per-profile floor). These tests pin the Dart-side contract for
// the error codes the iOS layer emits, so a future drift in
// `LocalModelResponse` parsing does not silently swallow the guard signal.
//
// We intentionally do NOT mock the native runtime itself — the focus here is
// that the Dart runtime cleanly surfaces the new short codes without crashing,
// throwing, or losing the diagnostic detail QA needs.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test.gutguard/legacy_runtime');

  Map<Object?, Object?> unavailableWith({
    required String code,
    required String reason,
  }) {
    return <Object?, Object?>{
      'status': 'unavailable',
      'outputText': '',
      'runtimeName': 'litert-lm-ios-gemma4',
      'reason': reason,
      'fallbackReason': code,
      'failureStage': code,
      'activeRuntimeProfile': 'phone_balanced',
      'backendRequested': 'litert-lm',
      'backendUsed': 'litert-lm',
      'engineCreateLatencyMs': 0,
      'promptCharCount': 32,
      'estimatedPromptTokens': 8,
      'promptTokenCountNative': 8,
      'promptBudget': 4096,
      'generationLimit': 320,
      'generationLatencyMs': 0,
      'taskType': 'chat',
      'outputQualityStatus': 'rejected',
      'promptTemplateVersion': 'gemma4_local_runtime_v2',
      'sanitizerVersion': 'native_generated_text_v1',
      'rawOutputCharCount': 0,
      'cleanedOutputCharCount': 0,
      'memoryWarningCount': 0,
      'thermalState': 'critical',
      'timeToFirstTokenMs': 0,
    };
  }

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
      'BUG-052: runtime_thermal_critical surfaces as fallbackReason without throwing',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'generate') {
        return unavailableWith(
          code: 'runtime_thermal_critical',
          reason:
              'Your iPhone is too warm right now — the on-device model is paused for a moment. Try again in a few seconds.',
        );
      }
      return null;
    });

    final runtime = MethodChannelLocalModelRuntime(channel: channel);
    final response = await runtime.generate(
      const LocalModelRequest(
        systemPrompt: 'sys',
        userPrompt: 'hi',
        groundedContext: <String, Object?>{},
        taskType: 'chat',
      ),
    );

    expect(response.status, 'unavailable');
    expect(response.fallbackReason, 'runtime_thermal_critical');
    expect(response.failureStage, 'runtime_thermal_critical');
    // The user message MUST be patient-safe (no raw runtime error, no
    // mention of pthreads / EXC_BAD_ACCESS / jetsam).
    expect(response.reason, isNotNull);
    expect(response.reason, isNot(contains('EXC_BAD_ACCESS')));
    expect(response.reason, isNot(contains('jetsam')));
    expect(response.reason, isNot(contains('pthread')));
  });

  test(
    'BUG-052: runtime_headroom_below_floor surfaces as fallbackReason without throwing',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'generate') {
          return unavailableWith(
            code: 'runtime_headroom_below_floor',
            reason:
                "There isn't enough free memory right now for an on-device answer. Close a couple of apps and try again.",
          );
        }
        return null;
      });

      final runtime = MethodChannelLocalModelRuntime(channel: channel);
      final response = await runtime.generate(
        const LocalModelRequest(
          systemPrompt: 'sys',
          userPrompt: 'hi',
          groundedContext: <String, Object?>{},
          taskType: 'chat',
        ),
      );

      expect(response.status, 'unavailable');
      expect(response.fallbackReason, 'runtime_headroom_below_floor');
      expect(response.failureStage, 'runtime_headroom_below_floor');
      expect(response.reason, isNotNull);
      expect(response.reason, isNot(contains('EXC_BAD_ACCESS')));
    },
  );

  test(
      'BUG-052: lastNativeRuntimeAbort propagates through runtime status without breaking parse',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getRuntimeStatus') {
        return <Object?, Object?>{
          'status': 'ready',
          'runtimeName': 'litert-lm-ios-gemma4',
          'backendStyle': 'litert-lm',
          'modelId': 'gemma-4-e2b',
          'quantization': 'int4_litert_lm_bundle',
          'expectedModelFilename': 'Models/litert-lm/gemma-4-E2B-it',
          'isBackendLinked': true,
          'isBundledModelPresent': true,
          'isModelLoaded': true,
          'reason':
              'Gemma 4 is loaded locally through LiteRT-LM. On-device responses are available.',
          'contextWindow': 4096,
          'batchSize': 4,
          'gpuLayers': 0,
          'defaultMaxTokens': 320,
          'generationTimeoutSeconds': 30,
          'activeRuntimeProfile': 'phone_balanced',
          'backendRequested': 'litert-lm',
          'backendUsed': 'litert-lm',
          'npuPrefillAvailable': false,
          'engineCreateLatencyMs': 320,
          'availableMemoryMB': 1200,
          'memoryWarningCount': 0,
          // BUG-052: this is the new field the iOS layer exposes when a
          // pre-generate guard recently fired. Dart must not choke on it.
          'lastNativeRuntimeAbort': 'runtime_headroom_below_floor',
        };
      }
      return null;
    });

    final runtime = MethodChannelLocalModelRuntime(channel: channel);
    final status = await runtime.getRuntimeStatus();
    // The status parse must succeed and include the extra diagnostic field
    // verbatim so QA telemetry can route on it.
    expect(status.status, 'ready');
    expect(status.lastNativeRuntimeAbort, 'runtime_headroom_below_floor');
  });
}
