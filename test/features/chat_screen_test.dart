import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/app_services.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/setup_state_service.dart';
import 'package:gemma_flares/features/chat/chat_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    AppServices.resetToDefaults();
    AppServices.configureForTesting(
      localModelRuntimeOverride: _FakeLocalModelRuntime(),
      repositoryOverride: _FakeWearableSampleRepository(),
      setupStateServiceOverride: _FakeSetupStateService(
        SetupStatus(
          completed: true,
          profileValidatedAt: DateTime.utc(2026, 5, 1),
          modelValidatedAt: DateTime.utc(2026, 5, 1),
          healthValidatedAt: DateTime.utc(2026, 5, 1),
        ),
      ),
    );
  });

  tearDown(() {
    AppServices.resetToDefaults();
  });

  testWidgets('chat uses empty-state suggestions and sends starter prompt', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(body: ChatScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Try asking:'), findsOneWidget);
    expect(find.text('Daily check-in'), findsWidgets);
    expect(find.text('Log symptom'), findsWidgets);

    await tester.tap(find.text('Daily check-in').first);
    await tester.pump();
    await _pumpUntilVisible(tester, _textContaining('Start a daily check-in.'));

    expect(find.text('Try asking:'), findsNothing);
    expect(_textContaining('Start a daily check-in.'), findsOneWidget);

    // Chat send schedules a delayed safety timeout; advance fake time so
    // no timer remains pending at test teardown.
    await tester.pump(const Duration(seconds: 80));
    await tester.pumpAndSettle();
  });

  testWidgets('chat header shows on-device only after setup model validation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(body: ChatScreen()),
      ),
    );
    await tester.pump();
    await _pumpUntilVisible(tester, find.text('Gemma 4 · on-device'));

    expect(find.text('Gemma 4 · on-device'), findsOneWidget);
    expect(find.text('Waiting for Gemma 4…'), findsNothing);
  });

  testWidgets(
    'chat header shows waiting when runtime is loaded but setup is not validated',
    (tester) async {
      AppServices.configureForTesting(
        localModelRuntimeOverride: _FakeLocalModelRuntime(),
        repositoryOverride: _FakeWearableSampleRepository(),
        setupStateServiceOverride: _FakeSetupStateService(SetupStatus.empty),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(body: ChatScreen()),
        ),
      );
      await tester.pump();
      await _pumpUntilVisible(tester, find.text('Waiting for Gemma 4…'));

      expect(find.text('Waiting for Gemma 4…'), findsOneWidget);
      expect(find.text('Gemma 4 · on-device'), findsNothing);
    },
  );
}

Finder _textContaining(String text) {
  return find.byWidgetPredicate((widget) {
    if (widget is! Text) {
      return false;
    }
    final data = widget.data ?? widget.textSpan?.toPlainText();
    return data?.contains(text) ?? false;
  }, description: 'Text containing $text');
}

Future<void> _pumpUntilVisible(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 150,
}) async {
  for (var index = 0; index < maxPumps; index++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  throw TestFailure('Timed out waiting for expected widget: $finder');
}

class _FakeWearableSampleRepository extends WearableSampleRepository {
  _FakeWearableSampleRepository() : super(database: AppDatabase());

  @override
  Future<List<ConversationRecord>> getRecentConversations({int? limit}) async {
    return const [];
  }
}

class _FakeLocalModelRuntime implements LocalModelRuntime {
  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    return const LocalModelResponse(
      status: 'success',
      outputText: 'OK',
      runtimeName: 'litert-lm-ios-gemma4',
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    return const LocalModelRuntimeStatus(
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

class _FakeSetupStateService extends SetupStateService {
  _FakeSetupStateService(this.status)
      : super(repository: _FakeWearableSampleRepository());

  final SetupStatus status;

  @override
  Future<SetupStatus> loadStatus() async => status;
}
