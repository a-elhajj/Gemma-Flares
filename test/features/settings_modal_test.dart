import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/app_services.dart';
import 'package:gemma_flares/core/contracts/health_bridge_contracts.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/memory_controls_service.dart';
import 'package:gemma_flares/core/services/method_channel_health_bridge.dart';
import 'package:gemma_flares/core/services/pinned_fact_service.dart';
import 'package:gemma_flares/core/services/tool_audit_service.dart';
import 'package:gemma_flares/features/settings/settings_modal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeHealthBridge healthBridge;

  setUp(() {
    healthBridge = _FakeHealthBridge();
    AppServices.configureForTesting(
      healthBridgeOverride: healthBridge,
      localModelRuntimeOverride: const _FakeLocalModelRuntime(),
    );
    AppServices.pinnedFactService = _FakePinnedFactService();
    AppServices.toolAuditService = _FakeToolAuditService();
    AppServices.memoryControlsService = _FakeMemoryControlsService();
  });

  tearDown(() {
    AppServices.resetToDefaults();
  });

  testWidgets(
    'requesting Health access refreshes settings without setState crash',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: const SettingsModal(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      final manageButton = find.widgetWithText(TextButton, 'Manage');
      if (manageButton.evaluate().isNotEmpty) {
        await tester.tap(manageButton.first);
        await _pumpUntil(
          tester,
          () => healthBridge.authorizationRequests == 1,
          maxPumps: 60,
        );
        expect(healthBridge.authorizationRequests, 1);
      }

      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  int maxPumps = 300,
}) async {
  for (var index = 0; index < maxPumps; index++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (predicate()) return;
  }
  throw TestFailure('Timed out waiting for settings modal condition.');
}

class _FakePinnedFactService extends PinnedFactService {
  _FakePinnedFactService() : super(database: AppServices.database);

  @override
  Future<PinnedFact?> load() async => null;
}

class _FakeToolAuditService extends ToolAuditService {
  _FakeToolAuditService() : super(database: AppServices.database);

  @override
  Future<List<Map<String, Object?>>> latest({int limit = 50}) async => const [];
}

class _FakeMemoryControlsService extends MemoryControlsService {
  _FakeMemoryControlsService() : super(database: AppServices.database);

  @override
  Future<List<Map<String, Object?>>> pendingDeletes({int limit = 100}) async {
    return const [];
  }
}

class _FakeHealthBridge extends MethodChannelHealthBridge {
  int authorizationRequests = 0;

  @override
  Future<AuthorizationStatusResponse> getAuthorizationStatus(
    AuthorizationStatusRequest request,
  ) async {
    return AuthorizationStatusResponse(
      healthDataAvailable: true,
      typeStatuses: {
        for (final metric in request.requestedTypes)
          metric: HealthAuthorizationState.authorized,
      },
      requestedAt: DateTime.utc(2026, 5, 5, 12),
    );
  }

  @override
  Future<RequestAuthorizationResponse> requestAuthorization(
    List<HealthMetricType> readTypes,
  ) async {
    authorizationRequests += 1;
    return RequestAuthorizationResponse(
      status: 'success',
      grantedTypes: readTypes,
      notGrantedTypes: const [],
      requestedAt: DateTime.utc(2026, 5, 5, 12),
    );
  }
}

class _FakeLocalModelRuntime implements LocalModelRuntime {
  const _FakeLocalModelRuntime();

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    return const LocalModelResponse(
      status: 'success',
      outputText: 'ok',
      runtimeName: 'litert-lm-ios-gemma4',
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    return const LocalModelRuntimeStatus(
      status: 'ready',
      runtimeName: 'litert-lm-ios-gemma4',
      backendStyle: 'litert-lm',
      modelId: 'gemma-4-e2b-litert-lm',
      quantization: 'int4_litert_lm_bundle',
      expectedModelFilename: 'Models/litert-lm/gemma-4-E2B-it',
      isBackendLinked: true,
      isBundledModelPresent: true,
      isModelLoaded: true,
      reason: 'loaded',
      activeRuntimeProfile: 'phone_balanced',
      backendRequested: 'litert-lm',
      backendUsed: 'litert-lm',
    );
  }

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) {
    return getRuntimeStatus();
  }

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) {
    return getRuntimeStatus();
  }
}
