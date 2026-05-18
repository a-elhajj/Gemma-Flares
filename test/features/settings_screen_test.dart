import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/app_services.dart';
import 'package:gemma_flares/core/contracts/health_bridge_contracts.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/method_channel_health_bridge.dart';
import 'package:gemma_flares/core/theme/theme_mode_controller.dart';
import 'package:gemma_flares/features/settings/settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeLocalModelRuntime runtime;

  setUp(() {
    runtime = _FakeLocalModelRuntime(
      status: const LocalModelRuntimeStatus(
        status: 'loaded',
        runtimeName: 'litert-lm-ios-gemma4',
        backendStyle: 'litert-lm',
        modelId: 'gemma-4-e2b',
        quantization: 'int4_litert_lm_bundle',
        expectedModelFilename: 'Models/litert-lm/gemma-4-E2B-it',
        isBackendLinked: true,
        isBundledModelPresent: true,
        isModelLoaded: true,
        reason: 'Ready.',
        backendRequested: 'cpu',
        backendUsed: 'cpu',
        contextWindow: 4096,
        batchSize: 256,
        generationTimeoutSeconds: 45,
        activeRuntimeProfile: 'phone_balanced',
      ),
      response: const LocalModelResponse(
        status: 'success',
        outputText: 'OK Gemma ready.',
        runtimeName: 'litert-lm-ios-gemma4',
        outputQualityStatus: 'accepted',
        generationLatencyMs: 123,
        activeRuntimeProfile: 'phone_balanced',
        backendRequested: 'cpu',
        backendUsed: 'cpu',
      ),
    );

    AppServices.configureForTesting(
      localModelRuntimeOverride: runtime,
      healthBridgeOverride: _FakeHealthBridge(),
    );
  });

  tearDown(() {
    AppServices.resetToDefaults();
  });

  Widget buildHarness() {
    return ThemeModeControllerScope(
      controller: ThemeModeController(),
      child: MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(body: SettingsScreen()),
      ),
    );
  }

  testWidgets('quick model test accepts punctuation in the readiness reply', (
    tester,
  ) async {
    await tester.pumpWidget(buildHarness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('App settings'));
    await tester.pumpAndSettle();

    final quickTestButton = find.text('Run quick model test');
    await tester.ensureVisible(quickTestButton);
    await tester.pumpAndSettle();
    await tester.tap(quickTestButton, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(runtime.generateCallCount, 1);
  });

  testWidgets('settings root keeps simplified three-entry IA', (tester) async {
    await tester.pumpWidget(buildHarness());
    await tester.pumpAndSettle();

    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Dark mode'), findsOneWidget);
    expect(find.text('My profile'), findsOneWidget);
    expect(find.text('Privacy and safety'), findsOneWidget);
    expect(find.text('App settings'), findsOneWidget);
    expect(find.text('My health records'), findsNothing);
  });

  testWidgets('settings root dark mode toggle updates the switch state', (
    tester,
  ) async {
    await tester.pumpWidget(buildHarness());
    await tester.pumpAndSettle();

    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );

    await tester.tap(find.text('Dark mode'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
  });
}

class _FakeHealthBridge extends MethodChannelHealthBridge {
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
      requestedAt: DateTime.utc(2026, 4, 16),
    );
  }
}

class _FakeLocalModelRuntime implements LocalModelRuntime {
  _FakeLocalModelRuntime({required this.status, required this.response});

  final LocalModelRuntimeStatus status;
  final LocalModelResponse response;
  int generateCallCount = 0;

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    generateCallCount += 1;
    return response;
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async => status;

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) async {
    return status;
  }

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) async {
    return status;
  }
}
