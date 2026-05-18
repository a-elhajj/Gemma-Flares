@Tags(['slow'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/gemma_router_service.dart';
import 'package:gemma_flares/core/services/gemma_tool_dispatch_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/local_model_token_stream.dart';
import 'package:gemma_flares/core/services/system_status_service.dart';
import 'package:gemma_flares/core/services/tool_schemas.dart';

import '../helpers/autonomous_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'router loads local model and preserves task routing metadata',
    () async {
      final runtime = TestLocalModelRuntime.notLoaded(
        responses: const [
          LocalModelResponse(
            status: 'success',
            outputText: 'Risk explanation ready.',
            runtimeName: 'litert-lm-ios-gemma4',
            backendUsed: 'litert-lm',
          ),
        ],
      );
      final router = GemmaRouterService(
        runtime: runtime,
        systemStatusService: const UnavailableSystemStatusService(),
        tokenSubscribeOverride: (_) =>
            Stream.value(LocalModelTokenEvent.complete(text: 'done')),
      );

      final text = await router.sendChat(
        'Explain the current score.',
        taskType: 'explain_risk',
        systemPrompt: 'Use deterministic risk payloads only.',
        groundedContext: const {'risk_score': 0.42},
      ).join();

      expect(text, 'Risk explanation ready.');
      expect(runtime.loadProfiles, contains('phone_balanced'));
      expect(runtime.generateRequests.single.taskType, 'explain_risk');
      expect(runtime.generateRequests.single.modelRole, 'daily_fast');
      expect(runtime.generateRequests.single.maxTokens, 400);
    },
  );

  test('tool block includes every registered strict schema', () {
    final service = GemmaToolDispatchService(
      router: GemmaRouterService(
        runtime: TestLocalModelRuntime.loaded(),
        systemStatusService: const UnavailableSystemStatusService(),
      ),
    );
    final block = service.buildToolBlock();

    for (final schema in kAllToolSchemas) {
      expect(block, contains('"${schema['name']}"'));
    }
    expect(kAllToolSchemas.length, 17);
  });

  test('tool dispatch parses fenced JSON and calls validated handler',
      () async {
    final runtime = TestLocalModelRuntime.loaded(
      responses: const [
        LocalModelResponse(
          status: 'success',
          outputText:
              '```json\n{"name":"log_bm","arguments":{"count":1,"bristol_score":6,"blood":false}}\n```',
          runtimeName: 'litert-lm-ios-gemma4',
          backendUsed: 'litert-lm',
        ),
      ],
    );
    final service = GemmaToolDispatchService(
      router: GemmaRouterService(
        runtime: runtime,
        systemStatusService: const UnavailableSystemStatusService(),
      ),
    );
    Object? handled;
    service.registerHandler('log_bm', (args) async {
      handled = args;
      return {'saved': true};
    });

    final result = await service.sendAndDispatch(
      userMessage: 'I had one loose bowel movement.',
      assembledContext: 'local context',
      restrictToTools: const ['log_bm'],
    );

    expect(result, isNotNull);
    expect(result!.toolName, 'log_bm');
    expect(result.usedFallback, isFalse);
    expect(result.handlerResult, {'saved': true});
    expect(handled, containsPair('bristol_score', 6));
  });

  test('tool dispatch retries strict-schema violations before success',
      () async {
    final runtime = TestLocalModelRuntime.loaded(
      responses: const [
        LocalModelResponse(
          status: 'success',
          outputText:
              '{"name":"log_symptom","arguments":{"symptom_canonical_id":"abdominal_pain","severity":6,"surprise":"nope"}}',
          runtimeName: 'litert-lm-ios-gemma4',
          backendUsed: 'litert-lm',
        ),
        LocalModelResponse(
          status: 'success',
          outputText:
              '{"name":"log_symptom","arguments":{"symptom_canonical_id":"abdominal_pain","severity":6,"raw_text":"cramps"}}',
          runtimeName: 'litert-lm-ios-gemma4',
          backendUsed: 'litert-lm',
        ),
      ],
    );
    final service = GemmaToolDispatchService(
      router: GemmaRouterService(
        runtime: runtime,
        systemStatusService: const UnavailableSystemStatusService(),
      ),
    );
    service.registerHandler('log_symptom', (args) async => {'saved': args});

    final result = await service.sendAndDispatch(
      userMessage: 'Cramps are a six.',
      assembledContext: 'local context',
      restrictToTools: const ['log_symptom'],
    );

    expect(result, isNotNull);
    expect(result!.attemptCount, 2);
    expect(result.arguments, isNot(contains('surprise')));
    expect(runtime.generateRequests, hasLength(2));
  });
}
