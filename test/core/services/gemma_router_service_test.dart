import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/gemma_router_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/local_model_token_stream.dart';
import 'package:gemma_flares/core/services/system_status_service.dart';

/// Returns a stream that closes immediately with no events, simulating the
/// case where no real EventChannel is available (unit-test environment).
Stream<LocalModelTokenEvent> _emptyTokenStream(String _) =>
    const Stream.empty();

void main() {
  test('router surfaces native model failure details to the user', () async {
    final router = GemmaRouterService(
      runtime: _FailingRuntime(),
      systemStatusService: const UnavailableSystemStatusService(),
      tokenSubscribeOverride: _emptyTokenStream,
    );

    final text = await router.sendChat(
      'How am I doing?',
      systemPrompt: 'You are Gemma Flares.',
      groundedContext: const {},
    ).join();

    expect(text, contains('Gemma 4 could not generate a response'));
    expect(text, contains('model_not_loaded'));
    expect(text, contains('Backend: litert-lm'));
    expect(text,
        isNot(contains('[Could not generate a response. Please try again.]')));
  });

  test('router refuses generation when available memory is critical', () async {
    final runtime = _SuccessfulRuntime();
    final router = GemmaRouterService(
      runtime: runtime,
      systemStatusService: const _FixedSystemStatusService(
        availableMemoryBytes: 300 * 1024 * 1024,
      ),
      tokenSubscribeOverride: _emptyTokenStream,
    );

    final text = await router
        .sendChat('Can we talk?', systemPrompt: 'You are Gemma Flares.')
        .join();

    expect(text, contains('memory pressure too high'));
    expect(runtime.loadedProfiles, isEmpty);
    expect(runtime.generateCount, 0);
  });

  test(
    'router uses caller system prompt for chat and drops tool schemas',
    () async {
      final runtime = _SuccessfulRuntime();
      final router = GemmaRouterService(
        runtime: runtime,
        systemStatusService: const UnavailableSystemStatusService(),
        tokenSubscribeOverride: _emptyTokenStream,
      );

      final text = await router.sendChat(
        'hi',
        systemPrompt: List.filled(1200, 'long system prompt').join(' '),
        groundedContext: {
          'current_date': '2026-05-05T10:00:00Z',
          'recent_visible_messages': List.generate(
            20,
            (index) => {
              'role': 'assistant',
              'text': 'message $index ${List.filled(80, 'word').join(' ')}',
            },
          ),
          'ignored_large_blob': List.filled(1000, 'drop me').join(' '),
        },
        toolSchemas: const [
          {'name': 'log_symptom'},
        ],
      ).join();

      expect(text, 'ok');
      expect(runtime.lastRequest, isNotNull);
      // Caller's system prompt is passed through (capped at 1800 chars).
      expect(runtime.lastRequest!.systemPrompt.length, lessThan(2000));
      expect(runtime.lastRequest!.systemPrompt, contains('long system prompt'));
      expect(runtime.lastRequest!.toolSchemas, isEmpty);
      expect(
        runtime.lastRequest!.groundedContext.keys,
        isNot(contains('ignored_large_blob')),
      );
      expect(runtime.lastRequest!.contextPolicy, 'chat_compact');
    },
  );

  test(
    'router sends proactive opening prompt when status is unavailable',
    () async {
      final runtime = _SuccessfulRuntime();
      final router = GemmaRouterService(
        runtime: runtime,
        systemStatusService: const _ThrowingSystemStatusService(),
        tokenSubscribeOverride: _emptyTokenStream,
      );

      final text = await router.sendChat(
        'Start this app session.',
        taskType: 'proactive_open',
        groundedContext: const {'recent_checkins': []},
      ).join();

      expect(text, 'ok');
      expect(runtime.loadedProfiles, ['phone_balanced']);
      expect(runtime.lastRequest, isNotNull);
      expect(runtime.lastRequest!.taskType, 'proactive_open');
      expect(runtime.lastRequest!.maxTokens, 300);
    },
  );
}

class _FixedSystemStatusService implements SystemStatusService {
  const _FixedSystemStatusService({this.availableMemoryBytes});

  final int? availableMemoryBytes;

  @override
  Future<SystemStatusSnapshot> getStatus() async {
    return SystemStatusSnapshot(
      lowPowerModeEnabled: false,
      thermalState: 'nominal',
      backgroundRefreshStatus: 'available',
      availableMemoryBytes: availableMemoryBytes,
    );
  }
}

class _ThrowingSystemStatusService implements SystemStatusService {
  const _ThrowingSystemStatusService();

  @override
  Future<SystemStatusSnapshot> getStatus() async {
    throw StateError('status unavailable');
  }
}

class _SuccessfulRuntime implements LocalModelRuntime {
  final loadedProfiles = <String?>[];
  int generateCount = 0;
  LocalModelRequest? lastRequest;

  // Starts unloaded — mirrors the real runtime before the first loadBundledModel
  // call. This lets _ensureModelLoaded tests assert the correct profile was used.
  bool _loaded = false;

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    generateCount++;
    lastRequest = request;
    return const LocalModelResponse(
      status: 'success',
      outputText: 'ok',
      runtimeName: 'fake-runtime',
      backendUsed: 'litert-lm',
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    return LocalModelRuntimeStatus(
      status: _loaded ? 'ready' : 'idle',
      runtimeName: 'fake-runtime',
      backendStyle: 'litert-lm',
      modelId: 'gemma-4-e2b-litert-lm',
      quantization: 'int4_litert_lm_bundle',
      expectedModelFilename: 'Models/litert-lm/gemma-4-E2B-it',
      isBackendLinked: true,
      isBundledModelPresent: true,
      isModelLoaded: _loaded,
      reason: _loaded ? 'loaded' : 'not_loaded',
      backendUsed: 'litert-lm',
    );
  }

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) async {
    loadedProfiles.add(profile);
    _loaded = true;
    return LocalModelRuntimeStatus(
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
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) async {
    return getRuntimeStatus();
  }
}

class _FailingRuntime implements LocalModelRuntime {
  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    return const LocalModelResponse(
      status: 'unavailable',
      outputText: '',
      runtimeName: 'fake-runtime',
      reason: 'Model is not loaded for daily_fast.',
      fallbackReason: 'model_not_loaded',
      failureStage: 'model_not_loaded',
      backendUsed: 'litert-lm',
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    return const LocalModelRuntimeStatus(
      status: 'not_loaded',
      runtimeName: 'fake-runtime',
      backendStyle: 'litert-lm',
      modelId: 'gemma-4-e2b-litert-lm',
      quantization: 'int4_litert_lm_bundle',
      expectedModelFilename: 'Models/litert-lm/gemma-4-E2B-it',
      isBackendLinked: true,
      isBundledModelPresent: true,
      isModelLoaded: false,
      reason: 'not_loaded',
      backendUsed: 'litert-lm',
    );
  }

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) async {
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
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) async {
    return getRuntimeStatus();
  }
}
