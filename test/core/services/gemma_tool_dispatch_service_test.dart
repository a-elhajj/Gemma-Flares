import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/gemma_router_service.dart';
import 'package:gemma_flares/core/services/gemma_tool_dispatch_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/system_status_service.dart';

void main() {
  test(
    'dispatch prefers native tool calls and forwards strict schemas',
    () async {
      final runtime = _ToolCallRuntime();
      final router = GemmaRouterService(
        runtime: runtime,
        systemStatusService: const UnavailableSystemStatusService(),
      );
      final dispatcher = GemmaToolDispatchService(router: router);

      dispatcher.registerHandler('log_symptom', (args) async {
        return {'stored': true, 'symptom': args['symptom_canonical_id']};
      });

      final result = await dispatcher.sendAndDispatch(
        userMessage: 'My abdominal pain is a 6.',
        assembledContext: 'PINNED_FACTS: Crohn disease',
        restrictToTools: const ['log_symptom'],
      );

      expect(result, isNotNull);
      expect(result!.toolName, 'log_symptom');
      expect(result.arguments['symptom_canonical_id'], 'abdominal_pain');
      expect(result.handlerResult, {
        'stored': true,
        'symptom': 'abdominal_pain',
      });
      expect(runtime.lastRequest, isNotNull);
      expect(runtime.lastRequest!.toolSchemas, hasLength(1));
      expect(runtime.lastRequest!.toolSchemas.single['name'], 'log_symptom');
    },
  );
}

class _ToolCallRuntime implements LocalModelRuntime {
  LocalModelRequest? lastRequest;

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    lastRequest = request;
    return const LocalModelResponse(
      status: 'success',
      outputText: 'free text should be ignored when native tool calls exist',
      runtimeName: 'fake-runtime',
      backendUsed: 'litert-lm',
      toolCalls: [
        {
          'name': 'log_symptom',
          'arguments': {
            'symptom_canonical_id': 'abdominal_pain',
            'severity': 6,
          },
        },
      ],
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    return const LocalModelRuntimeStatus(
      status: 'ready',
      runtimeName: 'fake-runtime',
      backendStyle: 'litert-lm',
      modelId: 'gemma-4-e2b-litert-lm',
      quantization: 'int4_litert_lm_bundle',
      expectedModelFilename: 'Models/litert-lm/gemma-4-E2B-it',
      isBackendLinked: true,
      isBundledModelPresent: true,
      isModelLoaded: true,
      reason: 'loaded',
      backendUsed: 'litert-lm',
    );
  }

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) async {
    return getRuntimeStatus();
  }

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) async {
    return getRuntimeStatus();
  }
}
