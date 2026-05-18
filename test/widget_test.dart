import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/app/app.dart';
import 'package:gemma_flares/core/app_services.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/app_readiness_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/profile_service.dart';
import 'package:gemma_flares/core/services/setup_state_service.dart';

void main() {
  late AppReadinessService originalReadinessService;

  setUp(() {
    AppServices.configureForTesting(
      localModelRuntimeOverride: const _ReadyRuntime(),
    );
    AppServices.profileService = _FakeProfileService(
      AppServices.wearableSampleRepository,
    );
    originalReadinessService = AppServices.appReadinessService;
    AppServices.appReadinessService = _ImmediateReadinessService();
    AppServices.setupStateService = _FakeSetupStateService(
      SetupStatus(
        completed: true,
        completedAt: DateTime.utc(2026, 4, 18, 12),
        profileValidatedAt: DateTime.utc(2026, 4, 18, 12),
        modelValidatedAt: DateTime.utc(2026, 4, 18, 12),
        healthValidatedAt: DateTime.utc(2026, 4, 18, 12),
      ),
    );
  });

  tearDown(() {
    AppServices.appReadinessService = originalReadinessService;
    AppServices.resetToDefaults();
  });

  testWidgets('app shell exposes v2 single-screen home', (tester) async {
    await tester.pumpWidget(const GemmaFlaresApp());
    await tester.pump();

    expect(find.text("How's your gut today?"), findsOneWidget);
    expect(find.text('Start a check-in'), findsWidgets);
    expect(find.text('Log a symptom'), findsWidgets);
    expect(find.text('Scan a lab photo'), findsWidgets);
    expect(find.byTooltip('Settings'), findsOneWidget);
  });
}

class _FakeProfileService extends ProfileService {
  _FakeProfileService(WearableSampleRepository repository)
      : super(repository: repository);

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

class _ImmediateReadinessService extends AppReadinessService {
  _ImmediateReadinessService()
      : super(
          healthRefreshCoordinator: AppServices.healthRefreshCoordinator,
          repository: AppServices.wearableSampleRepository,
          fastPathTimeout: Duration.zero,
        );

  @override
  Future<void> refreshForOpen({required String reason}) async {
    state.value = AppReadinessState(
      phase: 'ready',
      isRefreshing: false,
      reason: reason,
      lastCompletedAt: DateTime.utc(2026, 4, 18, 12),
    );
  }
}

class _ReadyRuntime implements LocalModelRuntime {
  const _ReadyRuntime();

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    return const LocalModelResponse(
      status: 'success',
      outputText: 'Ready.',
      runtimeName: 'test',
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    return const LocalModelRuntimeStatus(
      status: 'loaded',
      runtimeName: 'test',
      backendStyle: 'litert-lm',
      modelId: 'gemma-4-e2b',
      quantization: 'q4',
      expectedModelFilename: 'Models/litert-lm/gemma-4-E2B-it',
      isBackendLinked: true,
      isBundledModelPresent: true,
      isModelLoaded: true,
      reason: 'test',
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
