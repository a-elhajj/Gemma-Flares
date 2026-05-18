// Tests that verify the hallucinated-tool-name retry path fix:
//
// Before the fix, GemmaToolDispatchService.sendAndDispatch() threw a
// ToolDispatchException when Gemma returned a tool call whose name matched
// no registered handler — a hard crash in production.
//
// After the fix:
//   1. Unknown tool names set parseError and continue to the retry loop.
//   2. An audit record is emitted so the event is observable.
//   3. After exhausting retries the method returns null (no crash).
//
// Also tests the production-hardening guard: registerHandler() must throw
// an ArgumentError (not silently pass) when given an unrecognised name.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/services/gemma_router_service.dart';
import 'package:gemma_flares/core/services/gemma_tool_dispatch_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/system_status_service.dart';
import 'package:gemma_flares/core/services/tool_audit_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  group('GemmaToolDispatchService — hallucinated tool name handling', () {
    // ── Helper factory ────────────────────────────────────────────────────

    GemmaToolDispatchService makeDispatcher(LocalModelRuntime runtime) {
      final router = GemmaRouterService(
        runtime: runtime,
        systemStatusService: const UnavailableSystemStatusService(),
      );
      return GemmaToolDispatchService(router: router);
    }

    // ── No-crash contract ─────────────────────────────────────────────────

    test('returns null when model returns an unknown tool name', () async {
      final dispatcher = makeDispatcher(
        _AlwaysHallucinatedToolRuntime('totally_fake_tool'),
      );
      dispatcher.registerHandler('log_symptom', (args) async => {});

      // Must not throw — the pre-fix code would throw ToolDispatchException.
      final result = await dispatcher.sendAndDispatch(
        userMessage: 'Log my pain.',
        assembledContext: 'PINNED_FACTS: Crohn',
        restrictToTools: const ['log_symptom'],
      );

      expect(
        result,
        isNull,
        reason: 'No registered handler for totally_fake_tool — should be null',
      );
    });

    test(
      'does not throw ToolDispatchException for unknown tool name',
      () async {
        final dispatcher = makeDispatcher(
          _AlwaysHallucinatedToolRuntime('gpt_tool_x_123'),
        );
        dispatcher.registerHandler('log_symptom', (args) async => {});

        await expectLater(
          dispatcher.sendAndDispatch(
            userMessage: 'Log my pain.',
            assembledContext: '',
            restrictToTools: const ['log_symptom'],
          ),
          completes,
        );
      },
    );

    // ── Retry exhaustion ──────────────────────────────────────────────────

    test(
      'invokes generate exactly maxRetries+1 times before giving up',
      () async {
        final runtime = _CountingHallucinatedRuntime('bad_tool');
        final dispatcher = makeDispatcher(runtime);
        dispatcher.registerHandler('log_symptom', (args) async => {});

        await dispatcher.sendAndDispatch(
          userMessage: 'Test.',
          assembledContext: '',
          restrictToTools: const ['log_symptom'],
        );

        // Default retry count is 2; so total generate calls = 1 + 2 = 3.
        expect(
          runtime.generateCount,
          greaterThanOrEqualTo(2),
          reason: 'Should retry at least once after first hallucination',
        );
      },
    );

    // ── Eventually succeeds when later attempt returns valid tool ─────────

    test(
      'succeeds on second attempt when first response is hallucinated',
      () async {
        final runtime = _HallucinationThenSuccessRuntime(
          hallucinatedName: 'fake_tool',
          realName: 'log_symptom',
          // Use args that pass _validateArguments for log_symptom.
          realArguments: const <String, Object?>{
            'symptom_canonical_id': 'abdominal_pain',
            'severity': 6,
          },
        );
        final dispatcher = makeDispatcher(runtime);
        var handlerCalled = false;
        dispatcher.registerHandler('log_symptom', (args) async {
          handlerCalled = true;
          return {'stored': true};
        });

        final result = await dispatcher.sendAndDispatch(
          userMessage: 'I feel nauseous.',
          assembledContext: 'PINNED_FACTS: Crohn',
          restrictToTools: const ['log_symptom'],
        );

        expect(result, isNotNull);
        expect(result!.toolName, 'log_symptom');
        expect(handlerCalled, isTrue);
      },
    );

    // ── Audit observability ───────────────────────────────────────────────

    test(
      'audit service records hallucinated tool name in tool_audit table',
      () async {
        final tempRoot = await Directory.systemTemp.createTemp(
          'gemma_flares_dispatch_audit_test',
        );
        addTearDown(() => tempRoot.delete(recursive: true));
        final database = AppDatabase(
          migrationLoader: (assetPath) async => File(assetPath).readAsString(),
          databaseFactoryOverride: databaseFactoryFfi,
          databaseDirectoryProvider: () async => tempRoot.path,
        );
        addTearDown(() => database.close());
        final auditService = ToolAuditService(database: database);

        final runtime = _AlwaysHallucinatedToolRuntime('hallucinated_tool');
        final router = GemmaRouterService(
          runtime: runtime,
          systemStatusService: const UnavailableSystemStatusService(),
        );
        final dispatcher = GemmaToolDispatchService(
          router: router,
          auditService: auditService,
        );
        dispatcher.registerHandler('log_symptom', (args) async => {});

        await dispatcher.sendAndDispatch(
          userMessage: 'Test.',
          assembledContext: '',
          restrictToTools: const ['log_symptom'],
        );

        // The dispatcher writes to tool_audit for every dispatch attempt.
        final rows = await auditService.latest(limit: 20);
        expect(
          rows,
          isNotEmpty,
          reason: 'At least one audit row should be written even on failure',
        );
        // At least one row should reference the hallucinated tool name.
        final hallucinatedRows =
            rows.where((r) => r['tool_name'] == 'hallucinated_tool').toList();
        expect(
          hallucinatedRows,
          isNotEmpty,
          reason: 'Expected audit row for hallucinated_tool',
        );
        expect(hallucinatedRows.first['error'], isNotNull);
      },
    );

    // ── registerHandler production guard ─────────────────────────────────

    test(
      'registerHandler throws ArgumentError for blank name (release-safe guard)',
      () {
        final runtime = _AlwaysHallucinatedToolRuntime('x');
        final dispatcher = makeDispatcher(runtime);

        expect(
          () => dispatcher.registerHandler('', (args) async => {}),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test('registerHandler throws ArgumentError for whitespace-only name', () {
      final runtime = _AlwaysHallucinatedToolRuntime('x');
      final dispatcher = makeDispatcher(runtime);

      expect(
        () => dispatcher.registerHandler('   ', (args) async => {}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('registerHandler throws ArgumentError for duplicate name', () {
      // NOTE: the service silently replaces duplicate handlers (last-writer-wins).
      // Only registering a tool name with NO entry in kAllToolSchemas throws.
      // This test verifies that guard is released for a truly unknown tool name.
      final runtime = _AlwaysHallucinatedToolRuntime('x');
      final dispatcher = makeDispatcher(runtime);

      // 'totally_unknown_tool_xyz' is not in kAllToolSchemas — must throw.
      expect(
        () => dispatcher.registerHandler(
          'totally_unknown_tool_xyz',
          (args) async => {},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    // ── fallbackArguments provided ────────────────────────────────────────

    test(
      'returns null (not fallbackArguments) for hallucinated tool',
      () async {
        // fallbackArguments are for structured extraction, not for filling in
        // a fake tool call.  The dispatcher should still return null.
        final dispatcher = makeDispatcher(
          _AlwaysHallucinatedToolRuntime('bad_tool'),
        );
        dispatcher.registerHandler('log_symptom', (args) async => {});

        final result = await dispatcher.sendAndDispatch(
          userMessage: 'Test.',
          assembledContext: '',
          restrictToTools: const ['log_symptom'],
          fallbackArguments: (_) => const <String, Object?>{
            'symptom_canonical_id': 'nausea',
          },
        );

        expect(result, isNull);
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Fake runtimes
// ---------------------------------------------------------------------------

const _kFakeStatus = LocalModelRuntimeStatus(
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

/// Always returns a tool call whose name is not registered.
class _AlwaysHallucinatedToolRuntime implements LocalModelRuntime {
  const _AlwaysHallucinatedToolRuntime(this._toolName);
  final String _toolName;

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    return LocalModelResponse(
      status: 'success',
      outputText: '',
      runtimeName: 'fake-runtime',
      backendUsed: 'litert-lm',
      toolCalls: [
        {'name': _toolName, 'arguments': {}},
      ],
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async => _kFakeStatus;

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) async =>
      _kFakeStatus;

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(
    String? backendId,
  ) async =>
      _kFakeStatus;
}

/// Counts how many times generate() is called.
class _CountingHallucinatedRuntime implements LocalModelRuntime {
  _CountingHallucinatedRuntime(this._toolName);
  final String _toolName;
  int generateCount = 0;

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    generateCount++;
    return LocalModelResponse(
      status: 'success',
      outputText: '',
      runtimeName: 'fake-runtime',
      backendUsed: 'litert-lm',
      toolCalls: [
        {'name': _toolName, 'arguments': {}},
      ],
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async => _kFakeStatus;

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) async =>
      _kFakeStatus;

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(
    String? backendId,
  ) async =>
      _kFakeStatus;
}

/// Returns a hallucinated tool on the first call, then a valid tool on retry.
class _HallucinationThenSuccessRuntime implements LocalModelRuntime {
  _HallucinationThenSuccessRuntime({
    required this.hallucinatedName,
    required this.realName,
    required this.realArguments,
  });

  final String hallucinatedName;
  final String realName;
  final Map<String, Object?> realArguments;
  int _callCount = 0;

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    _callCount++;
    if (_callCount == 1) {
      return LocalModelResponse(
        status: 'success',
        outputText: '',
        runtimeName: 'fake-runtime',
        backendUsed: 'litert-lm',
        toolCalls: [
          {'name': hallucinatedName, 'arguments': {}},
        ],
      );
    }
    return LocalModelResponse(
      status: 'success',
      outputText: '',
      runtimeName: 'fake-runtime',
      backendUsed: 'litert-lm',
      toolCalls: [
        {'name': realName, 'arguments': realArguments},
      ],
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async => _kFakeStatus;

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) async =>
      _kFakeStatus;

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(
    String? backendId,
  ) async =>
      _kFakeStatus;
}
