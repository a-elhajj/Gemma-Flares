import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/app/app.dart';
import 'package:gemma_flares/core/app_services.dart';
import 'package:gemma_flares/core/services/app_readiness_service.dart';
import 'package:gemma_flares/core/services/litert_lm_download_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/profile_service.dart';
import 'package:gemma_flares/core/services/setup_state_service.dart';
import 'package:gemma_flares/features/home/home_screen.dart';
import 'package:gemma_flares/features/home/setup_wizard_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppReadinessService originalReadinessService;
  late _FakeAppReadinessService fakeReadinessService;
  late _FakeLocalModelRuntime fakeLocalModelRuntime;
  late _FakeLegacyDownloadService fakeDownloadService;

  setUp(() {
    fakeLocalModelRuntime = _FakeLocalModelRuntime();
    fakeDownloadService = _FakeLegacyDownloadService();
    AppServices.configureForTesting(
      localModelRuntimeOverride: fakeLocalModelRuntime,
      liteRtLmDownloadServiceOverride: fakeDownloadService,
    );
    AppServices.profileService = _FakeProfileService();
    originalReadinessService = AppServices.appReadinessService;
    fakeReadinessService = _FakeAppReadinessService();
    AppServices.appReadinessService = fakeReadinessService;
    AppServices.setupStateService = _FakeSetupStateService(
      SetupStatus(
        completed: true,
        profileValidatedAt: DateTime.utc(2026, 4, 20, 10),
        modelValidatedAt: DateTime.utc(2026, 4, 20, 10),
        healthValidatedAt: DateTime.utc(2026, 4, 20, 10),
        healthEnabled: false,
      ),
    );
  });

  tearDown(() {
    AppServices.appReadinessService = originalReadinessService;
    AppServices.resetToDefaults();
  });

  testWidgets('app shell triggers open-ready refresh on launch and resume', (
    tester,
  ) async {
    await tester.pumpWidget(const GemmaFlaresApp());
    await tester.pump();

    expect(fakeReadinessService.reasons, contains('app_launch'));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(fakeReadinessService.reasons, contains('app_resumed'));
  });

  test('auto warm-load is disabled outside release builds', () {
    expect(shouldAutoWarmInstalledModelOnLaunch(isReleaseMode: false), isFalse);
    expect(shouldAutoWarmInstalledModelOnLaunch(isReleaseMode: true), isTrue);
  });

  testWidgets(
    'completed setup does not auto-warm model on non-release launch',
    (tester) async {
      await tester.pumpWidget(const GemmaFlaresApp());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(fakeLocalModelRuntime.loadCalls, 0);
      expect(find.byType(SetupWizardDialog), findsNothing);
    },
  );

  testWidgets('incomplete setup does not silently warm model', (tester) async {
    AppServices.setupStateService = _FakeSetupStateService(
      const SetupStatus(completed: false),
    );

    await tester.pumpWidget(const GemmaFlaresApp());
    await tester.pump();

    expect(fakeLocalModelRuntime.loadCalls, 0);
    expect(find.byType(SetupWizardDialog), findsOneWidget);
  });

  testWidgets(
      'completed setup checks sandbox model without auto-warming on non-release app reopen',
      (tester) async {
    fakeLocalModelRuntime.isBundledModelPresent = false;
    fakeDownloadService.installed = true;
    AppServices.setupStateService = _FakeSetupStateService(
      SetupStatus(
        completed: true,
        profileValidatedAt: DateTime.utc(2026, 4, 20, 10),
        modelValidatedAt: DateTime.utc(2026, 4, 20, 10),
        healthValidatedAt: DateTime.utc(2026, 4, 20, 10),
        healthEnabled: false,
      ),
    );

    await tester.pumpWidget(const GemmaFlaresApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
        fakeDownloadService.hasInstalledArtifactCalls, greaterThanOrEqualTo(1));
    expect(fakeDownloadService.downloadCalls, 0);
    expect(fakeLocalModelRuntime.loadCalls, 0);
    expect(find.byType(SetupWizardDialog), findsNothing);
  });

  testWidgets('completed setup reopens wizard when model artifacts are missing',
      (tester) async {
    fakeLocalModelRuntime.isBundledModelPresent = false;
    fakeDownloadService.installed = false;
    AppServices.setupStateService = _FakeSetupStateService(
      SetupStatus(
        completed: true,
        profileValidatedAt: DateTime.utc(2026, 4, 20, 10),
        modelValidatedAt: DateTime.utc(2026, 4, 20, 10),
        healthValidatedAt: DateTime.utc(2026, 4, 20, 10),
        healthEnabled: false,
      ),
    );

    await tester.pumpWidget(const GemmaFlaresApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
        fakeDownloadService.hasInstalledArtifactCalls, greaterThanOrEqualTo(1));
    expect(fakeDownloadService.downloadCalls, greaterThanOrEqualTo(1));
    expect(find.byType(SetupWizardDialog), findsOneWidget);
  });

  testWidgets(
      'completed setup never auto-opens wizard from HomeScreen on '
      'transient model-check failure', (tester) async {
    // Simulate: app.dart._checkSetup() sees isBundledModelPresent=true (no
    // wizard), but HomeScreen's own check sees isBundledModelPresent=false AND
    // installed=false.  Before the fix HomeScreen would auto-open a second
    // wizard, corrupting DB state and causing the wizard to reopen on every
    // subsequent launch.
    AppServices.localModelRuntime = _TransientlyFailingRuntime();
    fakeDownloadService.installed = false;
    AppServices.setupStateService = _FakeSetupStateService(
      SetupStatus(
        completed: true,
        profileValidatedAt: DateTime.utc(2026, 4, 20, 10),
        modelValidatedAt: DateTime.utc(2026, 4, 20, 10),
        healthValidatedAt: DateTime.utc(2026, 4, 20, 10),
        healthEnabled: false,
      ),
    );

    await tester.pumpWidget(const GemmaFlaresApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // HomeScreen must be visible (app.dart said no wizard needed).
    expect(find.byType(HomeScreen), findsOneWidget);
    // Despite HomeScreen's own check returning setupComplete=false (because
    // isBundledModelPresent flipped to false), NO wizard must auto-open.
    expect(find.byType(SetupWizardDialog), findsNothing);
  });

  testWidgets('stale completed setup schema reopens wizard on launch', (
    tester,
  ) async {
    AppServices.setupStateService = _FakeSetupStateService(
      SetupStatus(
        completed: true,
        profileValidatedAt: DateTime.utc(2026, 4, 20, 10),
        modelValidatedAt: DateTime.utc(2026, 4, 20, 10),
        healthValidatedAt: DateTime.utc(2026, 4, 20, 10),
        healthEnabled: false,
        schemaVersion: SetupStatus.currentSchemaVersion - 1,
      ),
    );

    await tester.pumpWidget(const GemmaFlaresApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(SetupWizardDialog), findsOneWidget);
  });
}

class _FakeProfileService extends ProfileService {
  _FakeProfileService()
      : super(repository: AppServices.wearableSampleRepository);

  @override
  Future<UserProfile> loadProfile() async {
    return const UserProfile(diseaseType: 'CD');
  }
}

class _FakeSetupStateService extends SetupStateService {
  _FakeSetupStateService(this.status)
      : super(repository: AppServices.wearableSampleRepository);

  final SetupStatus status;

  @override
  Future<SetupStatus> loadStatus() async => status;
}

class _FakeLegacyDownloadService extends LiteRtLmModelDownloadService {
  bool installed = true;
  int hasInstalledArtifactCalls = 0;
  int downloadCalls = 0;

  @override
  Future<bool> hasInstalledArtifact(
      [LiteRtLmArtifact artifact =
          LiteRtLmModelDownloadService.defaultArtifact]) async {
    hasInstalledArtifactCalls += 1;
    return installed;
  }

  @override
  Future<LiteRtLmDownloadResult> downloadRequired({
    void Function(LiteRtLmDownloadProgress progress)? onProgress,
    LiteRtLmArtifact artifact = LiteRtLmModelDownloadService.defaultArtifact,
  }) async {
    downloadCalls += 1;
    installed = true;
    final installDirectory = await Directory.systemTemp.createTemp('litert-lm');
    final modelFile = File('${installDirectory.path}/model.litertlm');
    await modelFile.writeAsString('test model');
    return LiteRtLmDownloadResult(
      artifact: artifact,
      modelFile: modelFile,
      installDirectory: installDirectory,
    );
  }
}

class _FakeAppReadinessService extends AppReadinessService {
  _FakeAppReadinessService()
      : super(
          healthRefreshCoordinator: AppServices.healthRefreshCoordinator,
          repository: AppServices.wearableSampleRepository,
        );

  final List<String> reasons = <String>[];

  @override
  Future<void> refreshForOpen({required String reason}) async {
    reasons.add(reason);
    state.value = AppReadinessState(
      phase: 'ready',
      isRefreshing: false,
      reason: reason,
      lastCompletedAt: DateTime.utc(2026, 4, 18, 12),
    );
  }
}

class _FakeLocalModelRuntime implements LocalModelRuntime {
  int loadCalls = 0;
  bool isBundledModelPresent = true;

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    return const LocalModelResponse(
      status: 'success',
      outputText: '',
      runtimeName: 'fake-runtime',
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async {
    return const {};
  }

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    return LocalModelRuntimeStatus(
      status: 'unavailable',
      runtimeName: 'fake-runtime',
      backendStyle: 'fake',
      modelId: 'fake-model',
      quantization: 'none',
      expectedModelFilename: 'fake.bin',
      isBackendLinked: true,
      isBundledModelPresent: isBundledModelPresent,
      isModelLoaded: false,
      reason: 'not_loaded',
    );
  }

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) async {
    loadCalls += 1;
    return const LocalModelRuntimeStatus(
      status: 'success',
      runtimeName: 'fake-runtime',
      backendStyle: 'fake',
      modelId: 'fake-model',
      quantization: 'none',
      expectedModelFilename: 'fake.bin',
      isBackendLinked: true,
      isBundledModelPresent: true,
      isModelLoaded: true,
      reason: 'loaded',
    );
  }

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) async {
    return const LocalModelRuntimeStatus(
      status: 'success',
      runtimeName: 'fake-runtime',
      backendStyle: 'fake',
      modelId: 'fake-model',
      quantization: 'none',
      expectedModelFilename: 'fake.bin',
      isBackendLinked: true,
      isBundledModelPresent: true,
      isModelLoaded: false,
      reason: 'unchanged',
    );
  }
}

/// A runtime that returns [isBundledModelPresent: true] on the first
/// [getRuntimeStatus] call (seen by app.dart._checkSetup) and then
/// [isBundledModelPresent: false] on every subsequent call (seen by
/// HomeScreen._checkModelReadyInternal). This reproduces the transient
/// file-system check inconsistency that caused the wizard to reopen
/// on every subsequent cold launch before the fix.
class _TransientlyFailingRuntime extends _FakeLocalModelRuntime {
  int _statusCalls = 0;

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    _statusCalls += 1;
    final isBundledModelPresent = _statusCalls <= 1;
    return LocalModelRuntimeStatus(
      status: 'unavailable',
      runtimeName: 'fake-runtime',
      backendStyle: 'fake',
      modelId: 'fake-model',
      quantization: 'none',
      expectedModelFilename: 'fake.bin',
      isBackendLinked: true,
      isBundledModelPresent: isBundledModelPresent,
      isModelLoaded: false,
      reason: 'not_loaded',
    );
  }
}
