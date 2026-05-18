import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/app_services.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/profile_service.dart';
import 'package:gemma_flares/core/services/setup_state_service.dart';
import 'package:gemma_flares/features/home/home_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppServices.resetToDefaults();
    AppServices.configureForTesting(
      localModelRuntimeOverride: _FakeLocalModelRuntime(),
      repositoryOverride: _TestWearableSampleRepository(),
      profileServiceOverride: _ImmediateProfileService(),
      setupStateServiceOverride: _NeverReadySetupStateService(),
    );
  });

  tearDown(() {
    AppServices.resetToDefaults();
  });

  testWidgets('BUG-076 invalid check-in input re-ask includes cancel hint', (
    tester,
  ) async {
    await _pumpHomeScreen(tester);

    await _sendMessage(tester, 'start a check in');
    await _pumpUntilText(tester, 'You: start a check in');
    await _pumpUntilText(
      tester,
      'How\'s your belly pain or cramping right now?',
    );

    await _sendMessage(tester, 'not sure');
    await _pumpUntilText(tester, 'I didn\'t catch that.');

    expect(_textContaining('I didn\'t catch that.'), findsWidgets);
    expect(_textContaining('Say "cancel" to stop.'), findsWidgets);
  });

  testWidgets('BUG-076 each check-in question includes cancel hint', (
    tester,
  ) async {
    await _pumpHomeScreen(tester);

    await _sendMessage(tester, 'daily check in');
    await _pumpUntilText(tester, 'You: daily check in');
    await _pumpUntilText(
      tester,
      'How\'s your belly pain or cramping right now?',
    );
    expect(
      _assistantMessageWithQuestionHasHint(
        tester: tester,
        question: 'How\'s your belly pain or cramping right now?',
        hint: 'Say "cancel" to stop.',
      ),
      isTrue,
      reason: 'Initial check-in question must include the cancel hint.',
    );

    await _sendMessage(tester, '1');
    await _pumpUntilText(
      tester,
      'Compared to your normal, how many extra bathroom trips today?',
    );
    expect(
      _assistantMessageWithQuestionHasHint(
        tester: tester,
        question:
            'Compared to your normal, how many extra bathroom trips today?',
        hint: 'Say "cancel" to stop.',
      ),
      isTrue,
      reason: 'Follow-up check-in question must include the same cancel hint.',
    );
  });

  testWidgets('BUG-076 accented cancel exits HomeScreen check-in flow', (
    tester,
  ) async {
    await _pumpHomeScreen(tester);

    await _sendMessage(tester, 'start check in');
    await _pumpUntilText(tester, 'You: start check in');
    await _pumpUntilText(
      tester,
      'How\'s your belly pain or cramping right now?',
    );

    await _sendMessage(tester, 'cancé');
    await _pumpUntilText(tester, 'Check-in cancelled. Nothing was saved.');

    expect(
      _textContaining('Check-in cancelled. Nothing was saved.'),
      findsWidgets,
    );
  });

  testWidgets('Home header shows compact disease badge from profile', (
    tester,
  ) async {
    AppServices.configureForTesting(
      localModelRuntimeOverride: _FakeLocalModelRuntime(),
      repositoryOverride: _TestWearableSampleRepository(),
      profileServiceOverride: _DiseaseProfileService('UC'),
      setupStateServiceOverride: _NeverReadySetupStateService(),
    );

    await _pumpHomeScreen(tester);
    await _pumpUntilText(tester, 'Colitis');

    expect(_textContaining('Colitis'), findsWidgets);
  });
}

Future<void> _pumpHomeScreen(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: const HomeScreen(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _sendMessage(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  final sendIcon = find.byIcon(Icons.arrow_upward_rounded);
  if (sendIcon.evaluate().isNotEmpty) {
    await tester.tap(sendIcon.first);
  } else {
    await tester.testTextInput.receiveAction(TextInputAction.send);
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> _pumpUntilText(
  WidgetTester tester,
  String text, {
  int maxPumps = 120,
}) async {
  final finder = _textContaining(text);
  for (var index = 0; index < maxPumps; index++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  throw TestFailure(
    'Timed out waiting for text containing "$text". '
    'Visible snapshot: ${_visibleTextSnapshot(tester)}',
  );
}

String _visibleTextSnapshot(WidgetTester tester) {
  final parts = <String>[];

  for (final element in find.byType(Semantics).evaluate()) {
    final widget = element.widget;
    if (widget is Semantics) {
      final label = widget.properties.label;
      if (label != null && label.trim().isNotEmpty) {
        parts.add(label.trim());
      }
    }
  }

  for (final widget in tester.widgetList<Text>(find.byType(Text))) {
    final text = widget.data ?? widget.textSpan?.toPlainText();
    if (text != null && text.trim().isNotEmpty) {
      parts.add(text.trim());
    }
  }

  return parts.toSet().join(' | ');
}

bool _assistantMessageWithQuestionHasHint({
  required WidgetTester tester,
  required String question,
  required String hint,
}) {
  for (final element in find.byType(Semantics).evaluate()) {
    final widget = element.widget;
    if (widget is! Semantics) continue;
    final label = widget.properties.label;
    if (label == null || !label.startsWith('Gemma Flares:')) continue;
    if (label.contains(question) && label.contains(hint)) {
      return true;
    }
  }
  return false;
}

Finder _textContaining(String text) {
  return find.byWidgetPredicate((widget) {
    if (widget is Semantics) {
      final label = widget.properties.label;
      if (label != null && label.contains(text)) {
        return true;
      }
    }
    if (widget is! Text) {
      return false;
    }
    final data = widget.data ?? widget.textSpan?.toPlainText();
    return data?.contains(text) ?? false;
  }, description: 'Text containing $text');
}

class _TestWearableSampleRepository extends WearableSampleRepository {
  _TestWearableSampleRepository() : super(database: AppDatabase());

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
      outputText: 'ok',
      runtimeName: 'litert-lm-ios-gemma4',
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    return const LocalModelRuntimeStatus(
      status: 'unloaded',
      runtimeName: 'litert-lm-ios-gemma4',
      backendStyle: 'litert-lm',
      modelId: 'gemma-4-e2b',
      quantization: 'int4_litert_lm_bundle',
      expectedModelFilename: 'Models/litert-lm/gemma-4-E2B-it',
      isBackendLinked: true,
      isBundledModelPresent: false,
      isModelLoaded: false,
      reason: 'Model not loaded for widget test.',
      backendRequested: 'cpu',
      backendUsed: 'cpu',
      contextWindow: 4096,
      batchSize: 256,
      generationTimeoutSeconds: 45,
      activeRuntimeProfile: 'phone_balanced',
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

class _NeverReadySetupStateService extends SetupStateService {
  _NeverReadySetupStateService()
      : super(repository: _TestWearableSampleRepository());

  @override
  Future<SetupStatus> loadStatus() async => SetupStatus.empty;
}

class _ImmediateProfileService extends ProfileService {
  _ImmediateProfileService()
      : super(repository: _TestWearableSampleRepository());

  @override
  Future<UserProfile> loadProfile() async => UserProfile.empty;
}

class _DiseaseProfileService extends ProfileService {
  _DiseaseProfileService(this.diseaseType)
      : super(repository: _TestWearableSampleRepository());

  final String diseaseType;

  @override
  Future<UserProfile> loadProfile() async {
    return UserProfile(diseaseType: diseaseType);
  }
}
