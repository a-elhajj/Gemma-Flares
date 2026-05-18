@Tags(['slow'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/app_services.dart';
import 'package:gemma_flares/core/contracts/health_bridge_contracts.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/rag_corpus_service.dart';
import 'package:gemma_flares/core/services/litert_lm_download_service.dart';
import 'package:gemma_flares/core/services/health_sync_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/profile_service.dart';
import 'package:gemma_flares/core/services/rag_memory_service.dart';
import 'package:gemma_flares/core/services/setup_state_service.dart';
import 'package:gemma_flares/features/home/setup_wizard_dialog.dart';

import '../helpers/autonomous_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    AppServices.resetToDefaults();
  });

  testWidgets('profile phase blocks continuation until diagnosis is saved', (
    tester,
  ) async {
    AppServices.configureForTesting(
      localModelRuntimeOverride: TestLocalModelRuntime.loaded(),
      liteRtLmDownloadServiceOverride: _FakeLiteRtLmDownloadService(),
    );
    AppServices.profileService = _MemoryProfileService();
    AppServices.setupStateService = _MemorySetupStateService();
    AppServices.healthSyncService = _WidgetHealthSyncService();
    await _pumpWizard(tester);

    await _tapText(tester, 'Save and validate');
    await _pumpUntilFound(tester, find.text('Profile needs a diagnosis'));

    expect(find.text('Profile needs a diagnosis'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    final continueButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Continue'),
    );
    expect(continueButton.onPressed, isNull);
  });

  testWidgets('wizard starts Gemma model download in the background on open',
      (tester) async {
    final downloadService = _FakeLiteRtLmDownloadService(installed: false);
    AppServices.configureForTesting(
      localModelRuntimeOverride: TestLocalModelRuntime(
        status: const LocalModelRuntimeStatus(
          status: 'not_loaded',
          runtimeName: 'litert-lm-ios-gemma4',
          backendStyle: 'litert-lm',
          modelId: 'gemma-4-e2b-litert-lm',
          quantization: 'int4_litert_lm_bundle',
          expectedModelFilename: 'Models/litert-lm/gemma-4-E2B-it',
          isBackendLinked: true,
          isBundledModelPresent: false,
          isModelLoaded: false,
          reason: 'not_loaded',
          activeRuntimeProfile: 'phone_balanced',
          backendRequested: 'cpu',
          backendUsed: 'litert-lm',
          localOnlyEnforced: true,
        ),
        loadStatus: const LocalModelRuntimeStatus(
          status: 'loaded',
          runtimeName: 'litert-lm-ios-gemma4',
          backendStyle: 'litert-lm',
          modelId: 'gemma-4-e2b-litert-lm',
          quantization: 'int4_litert_lm_bundle',
          expectedModelFilename: 'Models/litert-lm/gemma-4-E2B-it',
          isBackendLinked: true,
          isBundledModelPresent: false,
          isModelLoaded: false,
          reason: 'not_loaded',
          activeRuntimeProfile: 'phone_balanced',
          backendRequested: 'cpu',
          backendUsed: 'litert-lm',
          localOnlyEnforced: true,
        ),
      ),
      liteRtLmDownloadServiceOverride: downloadService,
    );
    AppServices.profileService = _MemoryProfileService();
    AppServices.setupStateService = _MemorySetupStateService();
    AppServices.healthSyncService = _WidgetHealthSyncService();

    await _pumpWizard(tester);
    await _pumpUntil(tester, () => downloadService.downloadCalls == 1);
    await _pumpUntil(tester, () => downloadService.installed);

    expect(downloadService.downloadCalls, 1);
    expect(downloadService.installedArtifact,
        LiteRtLmModelDownloadService.defaultArtifact);
    expect(find.textContaining('Gemma 4'), findsWidgets);
  });

  testWidgets('wizard validates profile, Gemma probe, and Health backfill', (
    tester,
  ) async {
    final runtime = TestLocalModelRuntime.loaded();
    AppServices.configureForTesting(
      localModelRuntimeOverride: runtime,
      liteRtLmDownloadServiceOverride: _FakeLiteRtLmDownloadService(),
    );
    final repository = _MemoryWearableSampleRepository();
    final profileService = _MemoryProfileService();
    final setupStateService = _MemorySetupStateService();
    final healthSyncService = _WidgetHealthSyncService(
      result: HealthSyncRunResult(
        startedAt: DateTime.utc(2026, 4, 20, 10),
        endedAt: DateTime.utc(2026, 4, 20, 10, 1),
        metricResults: HealthSyncService.tier1Metrics
            .map(
              (metric) => MetricSyncResult(
                metricType: metric,
                status: 'success',
                fetched: 3,
                inserted: 3,
                updated: 0,
                ignored: 0,
                invalid: 0,
                touchedDates: const ['2026-04-20'],
              ),
            )
            .toList(growable: false),
      ),
    );
    AppServices.wearableSampleRepository = repository;
    AppServices.profileService = profileService;
    AppServices.setupStateService = setupStateService;
    AppServices.healthSyncService = healthSyncService;
    await _pumpWizard(tester);

    await _chooseDropdown(tester, 'Diagnosis', 'Crohn\'s disease');
    await _chooseDropdown(tester, 'Sex', 'Male');
    await tester.enterText(find.widgetWithText(TextField, 'Age'), '36');
    await tester.enterText(find.widgetWithText(TextField, 'Height'), '180');
    await _tapText(tester, 'lbs');
    await tester.enterText(find.widgetWithText(TextField, 'Weight'), '180');
    await tester.enterText(
      find.widgetWithText(TextField, 'Diagnosis year'),
      '2018',
    );

    await _tapText(tester, 'Save and validate');
    await _pumpUntilFound(tester, find.text('Profile saved and validated'));

    expect(find.text('Profile saved and validated'), findsOneWidget);
    await _tapText(tester, 'Continue');
    await _pumpUntilFound(tester, find.text('Open Health access'));

    await _tapText(tester, 'Open Health access');
    await _pumpUntilFound(tester, find.text('Health access validated'));

    expect(
      healthSyncService.authorizationRequests.single.length,
      greaterThanOrEqualTo(40),
    );
    expect(
      healthSyncService.backfillRequests.single,
      containsAll(HealthSyncService.tier1Metrics),
    );
    expect(find.text('Health access validated'), findsOneWidget);

    await _tapText(tester, 'Continue to Gemma 4');
    await _pumpUntilFound(tester, find.text('Downloading Gemma 4...'));
    await _pumpUntil(
      tester,
      () => runtime.loadProfiles.isNotEmpty,
    );
    await _pumpUntil(
      tester,
      () => runtime.generateRequests.isNotEmpty,
    );
    await _pumpUntilFound(
      tester,
      find.text('Gemma 4 loaded and generated text'),
    );

    expect(runtime.loadProfiles, contains('phone_balanced'));
    expect(runtime.generateRequests.first.requestId, 'setup_model_probe');
    expect(runtime.generateRequests, hasLength(1));
    expect(
      runtime.generateRequests.first.systemPrompt,
      'You are GutGuard. Validate that local inference works. Do not mention medical advice.',
    );
    expect(
      runtime.generateRequests.first.userPrompt,
      'Reply in one short sentence that GutGuard is ready.',
    );
    expect(find.text('Gemma 4 loaded and generated text'), findsOneWidget);

    final profile = await profileService.loadProfile();
    expect(profile.diseaseType, 'CD');
    expect(profile.weightUnitPreference, 'lb');
    expect(profile.weightKg, closeTo(81.6, 0.2));
    expect(profile.bmi, closeTo(25.2, 0.2));

    final setupStatus = await setupStateService.loadStatus();
    expect(setupStatus.completed, isTrue);
    expect(setupStatus.hasValidatedProfile, isTrue);
    expect(setupStatus.hasValidatedModel, isTrue);
    expect(setupStatus.healthEnabled, isTrue);
    expect(setupStatus.healthImportedSamples, greaterThan(0));
  });

  testWidgets('wizard restores saved profile and phase validation', (
    tester,
  ) async {
    const savedProfile = UserProfile(
      dateOfBirth: '1990-07-01',
      biologicalSex: 'male',
      heightCm: 180,
      weightKg: 81,
      diseaseType: 'CD',
      diagnosisYear: 2018,
      deviceType: 'Apple Watch',
      watchSeries: 'Series 9',
      medications: [MedicationEntry(name: 'Biologic agents')],
      otherConditions: ['asthma', 'smoking_status:never'],
    );
    final savedStatus = SetupStatus(
      completed: true,
      completedAt: DateTime.utc(2026, 4, 20, 10),
      profileValidatedAt: DateTime.utc(2026, 4, 20, 10),
      modelValidatedAt: DateTime.utc(2026, 4, 20, 10),
      healthValidatedAt: DateTime.utc(2026, 4, 20, 10),
      healthEnabled: true,
      healthImportedSamples: 24,
      modelRuntimeProfile: 'phone_balanced',
      modelBackend: 'litert-lm',
    );
    AppServices.configureForTesting(
      localModelRuntimeOverride: TestLocalModelRuntime.loaded(),
      liteRtLmDownloadServiceOverride: _FakeLiteRtLmDownloadService(),
    );
    final profileService = _MemoryProfileService(savedProfile);
    final setupStateService = _MemorySetupStateService(savedStatus);
    AppServices.profileService = profileService;
    AppServices.setupStateService = setupStateService;
    AppServices.healthSyncService = _WidgetHealthSyncService();

    await _pumpWizard(tester);
    await _pumpUntilFound(tester, find.text('Profile saved and validated'));

    expect(find.text('Crohn\'s disease'), findsOneWidget);
    expect(find.text('Profile saved and validated'), findsOneWidget);

    await _tapText(tester, 'Continue');
    await _pumpUntilFound(tester, find.text('Health access validated'));
    await _tapText(tester, 'Continue to Gemma 4');
    await _pumpUntilFound(
      tester,
      find.text('Gemma 4 loaded and generated text'),
    );

    expect(find.text('Gemma 4 loaded and generated text'), findsOneWidget);
  });

  testWidgets('wizard does not trust stale saved setup phases', (tester) async {
    const savedProfile = UserProfile(
      dateOfBirth: '1990-07-01',
      diseaseType: 'CD',
      biologicalSex: 'male',
    );
    final savedStatus = SetupStatus(
      completed: true,
      completedAt: DateTime.utc(2026, 4, 20, 10),
      profileValidatedAt: DateTime.utc(2026, 4, 20, 10),
      modelValidatedAt: DateTime.utc(2026, 4, 20, 10),
      healthValidatedAt: DateTime.utc(2026, 4, 20, 10),
      healthEnabled: true,
      modelRuntimeProfile: 'phone_balanced',
      modelBackend: 'litert-lm',
      schemaVersion: SetupStatus.currentSchemaVersion - 1,
    );
    AppServices.configureForTesting(
      localModelRuntimeOverride: TestLocalModelRuntime.loaded(),
      liteRtLmDownloadServiceOverride: _FakeLiteRtLmDownloadService(),
    );
    final profileService = _MemoryProfileService(savedProfile);
    final setupStateService = _MemorySetupStateService(savedStatus);
    AppServices.profileService = profileService;
    AppServices.setupStateService = setupStateService;
    AppServices.healthSyncService = _WidgetHealthSyncService();

    await _pumpWizard(tester);
    await _pumpUntilFound(tester, find.text('Profile needs re-validation'));

    expect(find.text('Profile needs re-validation'), findsOneWidget);
    expect(find.text('Gemma 4 loaded and generated text'), findsNothing);
    expect(find.text('Done'), findsNothing);
  });

  testWidgets('wizard ignores saved model validation when model is absent', (
    tester,
  ) async {
    const savedProfile = UserProfile(
      dateOfBirth: '1990-07-01',
      diseaseType: 'CD',
      biologicalSex: 'male',
    );
    final savedStatus = SetupStatus(
      completed: true,
      completedAt: DateTime.utc(2026, 4, 20, 10),
      profileValidatedAt: DateTime.utc(2026, 4, 20, 10),
      modelValidatedAt: DateTime.utc(2026, 4, 20, 10),
      healthValidatedAt: DateTime.utc(2026, 4, 20, 10),
      healthEnabled: true,
      modelRuntimeProfile: 'phone_balanced',
      modelBackend: 'litert-lm',
    );
    AppServices.configureForTesting(
      localModelRuntimeOverride: TestLocalModelRuntime(
        status: const LocalModelRuntimeStatus(
          status: 'model_missing',
          runtimeName: 'litert-lm-ios-gemma4',
          backendStyle: 'litert-lm',
          modelId: 'gemma-4-e2b-litert-lm',
          quantization: 'int4_litert_lm_bundle',
          expectedModelFilename: 'Models/litert-lm/gemma-4-E2B-it',
          isBackendLinked: true,
          isBundledModelPresent: false,
          isModelLoaded: false,
          reason: 'model_missing',
          activeRuntimeProfile: 'phone_balanced',
          backendUsed: 'litert-lm',
        ),
        loadStatus: const LocalModelRuntimeStatus(
          status: 'model_missing',
          runtimeName: 'litert-lm-ios-gemma4',
          backendStyle: 'litert-lm',
          modelId: 'gemma-4-e2b-litert-lm',
          quantization: 'int4_litert_lm_bundle',
          expectedModelFilename: 'Models/litert-lm/gemma-4-E2B-it',
          isBackendLinked: true,
          isBundledModelPresent: false,
          isModelLoaded: false,
          reason: 'model_missing',
          activeRuntimeProfile: 'phone_balanced',
          backendUsed: 'litert-lm',
        ),
      ),
      liteRtLmDownloadServiceOverride:
          _FakeLiteRtLmDownloadService(installed: false),
    );
    final profileService = _MemoryProfileService(savedProfile);
    final setupStateService = _MemorySetupStateService(savedStatus);
    AppServices.profileService = profileService;
    AppServices.setupStateService = setupStateService;
    AppServices.healthSyncService = _WidgetHealthSyncService();

    await _pumpWizard(tester);
    await _pumpUntilFound(tester, find.text('Gemma 4 needs repair'));

    expect(find.text('Gemma 4 loaded and generated text'), findsNothing);
    expect(find.text('Done'), findsNothing);
  });

  testWidgets('continue without Health completes setup in degraded mode', (
    tester,
  ) async {
    AppServices.configureForTesting(
      localModelRuntimeOverride: TestLocalModelRuntime.loaded(),
      liteRtLmDownloadServiceOverride: _FakeLiteRtLmDownloadService(),
    );
    final setupStateService = _MemorySetupStateService();
    AppServices.profileService = _MemoryProfileService();
    AppServices.setupStateService = setupStateService;
    AppServices.healthSyncService = _WidgetHealthSyncService(
      authorizationStatus: 'denied',
    );
    await _pumpWizard(tester);

    await _chooseDropdown(tester, 'Diagnosis', 'Crohn\'s disease');
    await _tapText(tester, 'Save and validate');
    await _pumpUntilFound(tester, find.text('Profile saved and validated'));
    await _tapText(tester, 'Continue');
    await _pumpUntilFound(tester, find.text('Open Health access'));
    await _tapText(tester, 'Open Health access');
    await _pumpUntilFound(tester, find.text('Health access was not completed'));
    await _tapText(tester, 'Continue without Health');
    await _pumpUntilFound(
      tester,
      find.text('Gemma 4 loaded and generated text'),
    );

    final setupStatus = await setupStateService.loadStatus();
    expect(setupStatus.completed, isTrue);
    expect(setupStatus.healthEnabled, isFalse);
  });

  // -- BUG-013: Setup wizard double-tap regression suite ---------------------

  testWidgets('BUG-013: wizard closes on single Done tap after full flow', (
    tester,
  ) async {
    final repository = _MemoryWearableSampleRepository(database: AppDatabase());
    final runtime = TestLocalModelRuntime.loaded();
    AppServices.configureForTesting(
      repositoryOverride: repository,
      localModelRuntimeOverride: runtime,
      liteRtLmDownloadServiceOverride: _FakeLiteRtLmDownloadService(),
    );
    AppServices.profileService = _MemoryProfileService();
    AppServices.setupStateService = _MemorySetupStateService();
    final ragMemoryService = _RecordingRagMemoryService();
    AppServices.ragMemoryService = ragMemoryService;
    AppServices.healthSyncService = _WidgetHealthSyncService(
      result: HealthSyncRunResult(
        startedAt: DateTime.utc(2026, 5, 1, 9),
        endedAt: DateTime.utc(2026, 5, 1, 9, 1),
        metricResults: HealthSyncService.tier1Metrics
            .map(
              (metric) => MetricSyncResult(
                metricType: metric,
                status: 'success',
                fetched: 2,
                inserted: 2,
                updated: 0,
                ignored: 0,
                invalid: 0,
                touchedDates: const ['2026-05-01'],
              ),
            )
            .toList(growable: false),
      ),
    );

    await _pumpWizard(tester, asRoute: true);

    // Step 1 - Profile
    await _chooseDropdown(tester, 'Diagnosis', 'Crohn\'s disease');
    await _tapText(tester, 'Save and validate');
    await _pumpUntilFound(tester, find.text('Profile saved and validated'));
    await _tapText(tester, 'Continue');

    // Step 2 - Health
    await _pumpUntilFound(tester, find.text('Open Health access'));
    await _tapText(tester, 'Open Health access');
    await _pumpUntilFound(tester, find.text('Health access validated'));
    await _tapText(tester, 'Continue to Gemma 4');

    // Step 3 - Model
    await _pumpUntilFound(
      tester,
      find.text('Gemma 4 loaded and generated text'),
    );

    // Done button should be enabled and wizard should close in a single tap.
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();

    expect(
      find.byType(SetupWizardDialog),
      findsNothing,
      reason: 'BUG-013: wizard must close after a single Done tap',
    );
  });

  testWidgets('BUG-013: setup uses one smoke probe before Done is enabled', (
    tester,
  ) async {
    final repository = _MemoryWearableSampleRepository(database: AppDatabase());
    final runtime = TestLocalModelRuntime.loaded();
    AppServices.configureForTesting(
      repositoryOverride: repository,
      localModelRuntimeOverride: runtime,
      liteRtLmDownloadServiceOverride: _FakeLiteRtLmDownloadService(),
    );
    AppServices.profileService = _MemoryProfileService();
    AppServices.setupStateService = _MemorySetupStateService();
    AppServices.ragMemoryService = _RecordingRagMemoryService();
    AppServices.healthSyncService = _WidgetHealthSyncService(
      result: HealthSyncRunResult(
        startedAt: DateTime.utc(2026, 5, 1, 9),
        endedAt: DateTime.utc(2026, 5, 1, 9, 1),
        metricResults: HealthSyncService.tier1Metrics
            .map(
              (metric) => MetricSyncResult(
                metricType: metric,
                status: 'success',
                fetched: 1,
                inserted: 1,
                updated: 0,
                ignored: 0,
                invalid: 0,
                touchedDates: const ['2026-05-01'],
              ),
            )
            .toList(growable: false),
      ),
    );

    await _pumpWizard(tester);

    await _chooseDropdown(tester, 'Diagnosis', 'Crohn\'s disease');
    await _tapText(tester, 'Save and validate');
    await _pumpUntilFound(tester, find.text('Profile saved and validated'));
    await _tapText(tester, 'Continue');
    await _pumpUntilFound(tester, find.text('Open Health access'));
    await _tapText(tester, 'Open Health access');
    await _pumpUntilFound(tester, find.text('Health access validated'));
    await _tapText(tester, 'Continue to Gemma 4');
    await _pumpUntilFound(
      tester,
      find.text('Gemma 4 loaded and generated text'),
    );

    final requestIds =
        runtime.generateRequests.map((r) => r.requestId).toList();
    expect(
        requestIds,
        [
          'setup_model_probe',
        ],
        reason: 'setup should run exactly one inference smoke test');
  });

  testWidgets('BUG-013: profile RAG anchor written after validation', (
    tester,
  ) async {
    final repository = _MemoryWearableSampleRepository(database: AppDatabase());
    AppServices.configureForTesting(
      repositoryOverride: repository,
      localModelRuntimeOverride: TestLocalModelRuntime.loaded(),
      liteRtLmDownloadServiceOverride: _FakeLiteRtLmDownloadService(),
    );
    AppServices.profileService = _MemoryProfileService();
    AppServices.setupStateService = _MemorySetupStateService();
    final ragMemoryService = _RecordingRagMemoryService();
    AppServices.ragMemoryService = ragMemoryService;
    AppServices.healthSyncService = _WidgetHealthSyncService();

    await _pumpWizard(tester);
    await _chooseDropdown(tester, 'Diagnosis', 'Crohn\'s disease');
    await _tapText(tester, 'Save and validate');
    await _pumpUntilFound(tester, find.text('Profile saved and validated'));

    // Allow the unawaited RAG write to flush.
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      ragMemoryService.transactionIds,
      contains(RagMemoryService.setupProfileTransactionId),
      reason: 'BUG-013: profile RAG anchor must be requested after validation',
    );
    final profileWrite =
        ragMemoryService.writes[RagMemoryService.setupProfileTransactionId];
    expect(
      profileWrite,
      isNotNull,
      reason: 'profile anchor write should be recorded for inspection',
    );
    expect(
      profileWrite!.text,
      contains('"profile"'),
      reason: 'profile payload must be embedded as structured JSON',
    );
    expect(
      profileWrite.text,
      contains('"date_of_birth":null'),
      reason: 'unfilled profile keys must stay explicit null in RAG payload',
    );
    expect(
      profileWrite.text,
      contains('"biological_sex":null'),
      reason: 'all profile keys should be present even when unset',
    );
    expect(
      profileWrite.text,
      contains('"medications":['),
      reason:
          'medication schema must always be present for later GI summary use',
    );
  });

  testWidgets('setup profile validation is non-blocking when RAG write fails', (
    tester,
  ) async {
    final repository = _MemoryWearableSampleRepository(database: AppDatabase());
    AppServices.configureForTesting(
      repositoryOverride: repository,
      localModelRuntimeOverride: TestLocalModelRuntime.loaded(),
      liteRtLmDownloadServiceOverride: _FakeLiteRtLmDownloadService(),
    );
    AppServices.profileService = _MemoryProfileService();
    AppServices.setupStateService = _MemorySetupStateService();
    AppServices.ragMemoryService = _FailingRagMemoryService();
    AppServices.healthSyncService = _WidgetHealthSyncService();

    await _pumpWizard(tester);
    await _chooseDropdown(tester, 'Diagnosis', 'Crohn\'s disease');
    await _tapText(tester, 'Save and validate');
    await _pumpUntilFound(tester, find.text('Profile saved and validated'));

    expect(
      find.text('Profile saved and validated'),
      findsOneWidget,
      reason: 'best-effort RAG anchor failure must not block setup phase',
    );
  });

  testWidgets('BUG-013: health RAG anchor written after health sync', (
    tester,
  ) async {
    final repository = _MemoryWearableSampleRepository(database: AppDatabase());
    AppServices.configureForTesting(
      repositoryOverride: repository,
      localModelRuntimeOverride: TestLocalModelRuntime.loaded(),
      liteRtLmDownloadServiceOverride: _FakeLiteRtLmDownloadService(),
    );
    AppServices.profileService = _MemoryProfileService();
    AppServices.setupStateService = _MemorySetupStateService();
    final ragMemoryService = _RecordingRagMemoryService();
    AppServices.ragMemoryService = ragMemoryService;
    AppServices.healthSyncService = _WidgetHealthSyncService(
      result: HealthSyncRunResult(
        startedAt: DateTime.utc(2026, 5, 1, 9),
        endedAt: DateTime.utc(2026, 5, 1, 9, 1),
        metricResults: HealthSyncService.tier1Metrics
            .map(
              (m) => MetricSyncResult(
                metricType: m,
                status: 'success',
                fetched: 5,
                inserted: 5,
                updated: 0,
                ignored: 0,
                invalid: 0,
                touchedDates: const ['2026-05-01'],
              ),
            )
            .toList(growable: false),
      ),
    );

    await _pumpWizard(tester);
    await _chooseDropdown(tester, 'Diagnosis', 'Crohn\'s disease');
    await _tapText(tester, 'Save and validate');
    await _pumpUntilFound(tester, find.text('Profile saved and validated'));
    await _tapText(tester, 'Continue');
    await _pumpUntilFound(tester, find.text('Open Health access'));
    await _tapText(tester, 'Open Health access');
    await _pumpUntilFound(tester, find.text('Health access validated'));

    await tester.pump(const Duration(milliseconds: 500));

    expect(
      ragMemoryService.transactionIds,
      contains(RagMemoryService.setupHealthTransactionId),
      reason: 'BUG-013: health RAG anchor must be requested after health sync',
    );
  });

  testWidgets('BUG-013: health RAG anchor written after skip', (tester) async {
    final repository = _MemoryWearableSampleRepository(database: AppDatabase());
    AppServices.configureForTesting(
      repositoryOverride: repository,
      localModelRuntimeOverride: TestLocalModelRuntime.loaded(),
      liteRtLmDownloadServiceOverride: _FakeLiteRtLmDownloadService(),
    );
    AppServices.profileService = _MemoryProfileService();
    AppServices.setupStateService = _MemorySetupStateService();
    final ragMemoryService = _RecordingRagMemoryService();
    AppServices.ragMemoryService = ragMemoryService;
    AppServices.healthSyncService = _WidgetHealthSyncService(
      authorizationStatus: 'denied',
    );

    await _pumpWizard(tester);
    await _chooseDropdown(tester, 'Diagnosis', 'Crohn\'s disease');
    await _tapText(tester, 'Save and validate');
    await _pumpUntilFound(tester, find.text('Profile saved and validated'));
    await _tapText(tester, 'Continue');
    await _pumpUntilFound(tester, find.text('Open Health access'));
    await _tapText(tester, 'Open Health access');
    await _pumpUntilFound(tester, find.text('Health access was not completed'));
    await _tapText(tester, 'Continue without Health');

    await tester.pump(const Duration(milliseconds: 500));

    expect(
      ragMemoryService.transactionIds,
      contains(RagMemoryService.setupHealthTransactionId),
      reason:
          'BUG-013: health RAG anchor must be written even when health is skipped',
    );
    final anchor =
        ragMemoryService.writes[RagMemoryService.setupHealthTransactionId]!;
    expect(
      anchor.chunkId,
      isNotEmpty,
      reason: 'skipped anchor must have a chunk ID',
    );
    // The sourceType for a skipped health anchor must encode the setup phase.
    expect(
      anchor.sourceType,
      equals('setup'),
      reason: 'health anchor sourceType must be "setup"',
    );
    expect(
      anchor.sourceId,
      equals('apple_health'),
      reason: 'health anchor sourceId must be "apple_health"',
    );
  });

  testWidgets('BUG-013: double Done tap is idempotent and does not crash', (
    tester,
  ) async {
    AppServices.configureForTesting(
      localModelRuntimeOverride: TestLocalModelRuntime.loaded(),
      liteRtLmDownloadServiceOverride: _FakeLiteRtLmDownloadService(),
    );
    AppServices.profileService = _MemoryProfileService();
    AppServices.setupStateService = _MemorySetupStateService();
    AppServices.ragMemoryService = _RecordingRagMemoryService();
    AppServices.healthSyncService = _WidgetHealthSyncService(
      authorizationStatus: 'denied',
    );

    await _pumpWizard(tester, asRoute: true);
    await _chooseDropdown(tester, 'Diagnosis', 'Crohn\'s disease');
    await _tapText(tester, 'Save and validate');
    await _pumpUntilFound(tester, find.text('Profile saved and validated'));
    await _tapText(tester, 'Continue');
    await _pumpUntilFound(tester, find.text('Open Health access'));
    await _tapText(tester, 'Open Health access');
    await _pumpUntilFound(tester, find.text('Health access was not completed'));
    await _tapText(tester, 'Continue without Health');
    await _pumpUntilFound(
      tester,
      find.text('Gemma 4 loaded and generated text'),
    );

    // First tap closes wizard (navigates back).
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();
    expect(
      find.byType(SetupWizardDialog),
      findsNothing,
      reason: 'wizard must close after first Done tap',
    );

    // Second settle after removal should stay clean.
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.takeException(),
      isNull,
      reason: 'BUG-013: second tap must not throw an exception',
    );
  });
}

class _FakeLiteRtLmDownloadService extends LiteRtLmModelDownloadService {
  _FakeLiteRtLmDownloadService({this.installed = true});

  bool installed;
  int downloadCalls = 0;
  int hasInstalledArtifactCalls = 0;
  int resetCalls = 0;
  LiteRtLmArtifact? installedArtifact;

  LiteRtLmDownloadResult _resultFor(LiteRtLmArtifact artifact) {
    final installDirectory = Directory(
      '${Directory.systemTemp.path}/litert-lm-test/${artifact.id}',
    );
    final modelFile = File('${installDirectory.path}/model.litertlm');
    return LiteRtLmDownloadResult(
      artifact: artifact,
      modelFile: modelFile,
      installDirectory: installDirectory,
    );
  }

  @override
  Future<bool> hasInstalledArtifact(
      [LiteRtLmArtifact artifact =
          LiteRtLmModelDownloadService.defaultArtifact]) async {
    hasInstalledArtifactCalls += 1;
    return installed;
  }

  @override
  Future<LiteRtLmDownloadResult> downloadRequired({
    void Function(LiteRtLmDownloadProgress)? onProgress,
    LiteRtLmArtifact artifact = LiteRtLmModelDownloadService.defaultArtifact,
  }) async {
    downloadCalls += 1;
    if (installed) {
      installedArtifact = artifact;
      onProgress?.call(LiteRtLmDownloadProgress(
        artifact: artifact,
        phase: 'already_installed',
        receivedBytes: 100,
        totalBytes: 100,
      ));
      return _resultFor(artifact);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    onProgress?.call(LiteRtLmDownloadProgress(
      artifact: artifact,
      phase: 'downloading',
      receivedBytes: 75,
      totalBytes: 100,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    onProgress?.call(LiteRtLmDownloadProgress(
      artifact: artifact,
      phase: 'ready',
    ));
    installed = true;
    installedArtifact = artifact;
    return _resultFor(artifact);
  }

  @override
  Future<void> resetArtifact(
      [LiteRtLmArtifact artifact =
          LiteRtLmModelDownloadService.defaultArtifact]) async {
    resetCalls += 1;
    installed = false;
  }
}

Future<void> _pumpWizard(WidgetTester tester, {bool asRoute = false}) async {
  if (asRoute) {
    // Push wizard as a named route so Navigator.pop() actually removes it.
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        initialRoute: '/host',
        routes: {
          '/host': (_) => Scaffold(
                body: Builder(
                  builder: (ctx) => TextButton(
                    onPressed: () => Navigator.of(ctx).pushNamed('/wizard'),
                    child: const Text('open'),
                  ),
                ),
              ),
          '/wizard': (_) => Scaffold(body: SetupWizardDialog()),
        },
      ),
    );
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  } else {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(body: SetupWizardDialog()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _chooseDropdown(
  WidgetTester tester,
  String label,
  String value,
) async {
  await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text(value).last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _tapText(WidgetTester tester, String text) async {
  final finder = _buttonFinder(text);
  tester.testTextInput.hide();
  await tester.pump();
  await tester.scrollUntilVisible(
    finder,
    240,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(finder);
  await tester.pump();
}

Finder _buttonFinder(String text) {
  for (final finder in [
    find.widgetWithText(FilledButton, text),
    find.widgetWithText(OutlinedButton, text),
    find.widgetWithText(TextButton, text),
    find.widgetWithText(ElevatedButton, text),
  ]) {
    if (finder.evaluate().isNotEmpty) return finder.last;
  }
  return find.text(text).last;
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 120,
}) async {
  for (var i = 0; i < maxPumps; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  final visibleTexts = tester
      .widgetList<Text>(find.byType(Text))
      .map((widget) => widget.data?.trim())
      .whereType<String>()
      .where((text) => text.isNotEmpty)
      .take(30)
      .toList(growable: false);
  throw TestFailure(
    'Timed out waiting for $finder. Visible text snapshot: ${visibleTexts.join(' | ')}',
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  int maxPumps = 120,
}) async {
  for (var i = 0; i < maxPumps; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (predicate()) return;
  }
  final visibleTexts = tester
      .widgetList<Text>(find.byType(Text))
      .map((widget) => widget.data?.trim())
      .whereType<String>()
      .where((text) => text.isNotEmpty)
      .take(30)
      .toList(growable: false);
  throw TestFailure(
    'Timed out waiting for setup wizard condition. Visible text snapshot: ${visibleTexts.join(' | ')}',
  );
}

class _MemoryWearableSampleRepository extends WearableSampleRepository {
  _MemoryWearableSampleRepository({AppDatabase? database})
      : super(database: database ?? AppServices.database);

  @override
  Future<SyncStateRecord?> getSyncState(String sourceName) async {
    return SyncStateRecord(
      sourceName: sourceName,
      lastSyncAt: DateTime.utc(2026, 4, 20, 10),
      lastBackfillStart: DateTime.utc(2026, 3, 21, 10),
      lastBackfillEnd: DateTime.utc(2026, 4, 20, 10),
      updatedAt: DateTime.utc(2026, 4, 20, 10),
    );
  }
}

class _MemoryProfileService extends ProfileService {
  _MemoryProfileService([UserProfile initialProfile = UserProfile.empty])
      : _profile = initialProfile,
        super(repository: AppServices.wearableSampleRepository);

  UserProfile _profile;

  @override
  Future<UserProfile> loadProfile() async => _profile;

  @override
  Future<void> saveProfile(UserProfile profile) async {
    _profile = profile;
  }

  @override
  Future<UserProfileCovariates> getCovariates() async {
    return UserProfileCovariates(
      age: _profile.ageAt(DateTime.utc(2026, 4, 20)),
      sexMale: _profile.biologicalSex == 'male'
          ? true
          : _profile.biologicalSex == null
              ? null
              : false,
      bmi: _profile.bmi,
      diseaseCd: _profile.diseaseType == 'CD'
          ? true
          : _profile.diseaseType == null
              ? null
              : false,
    );
  }
}

class _WidgetHealthSyncService extends HealthSyncService {
  _WidgetHealthSyncService({
    HealthSyncRunResult? result,
    this.authorizationStatus = 'success',
  })  : result = result ??
            HealthSyncRunResult(
              startedAt: DateTime.utc(2026, 4, 20, 10),
              endedAt: DateTime.utc(2026, 4, 20, 10, 1),
              metricResults: const [],
            ),
        super(
          bridge: AppServices.healthBridge,
          normalizationService: AppServices.wearableNormalizationService,
          repository: AppServices.wearableSampleRepository,
          dailySummaryService: AppServices.dailySummaryService,
          cosinorService: AppServices.cosinorService,
          riskEngineService: AppServices.riskEngineService,
        );

  final HealthSyncRunResult result;
  final String authorizationStatus;
  final List<List<HealthMetricType>> authorizationRequests = [];
  final List<List<HealthMetricType>> backfillRequests = [];

  @override
  Future<RequestAuthorizationResponse> requestAuthorization({
    List<HealthMetricType> metrics = HealthSyncService.tier1Metrics,
  }) async {
    authorizationRequests.add(metrics);
    return RequestAuthorizationResponse(
      status: authorizationStatus,
      grantedTypes: authorizationStatus == 'success' ? metrics : const [],
      notGrantedTypes: authorizationStatus == 'success' ? const [] : metrics,
      requestedAt: DateTime.utc(2026, 4, 20, 10),
    );
  }

  @override
  Future<AuthorizationStatusResponse> getAuthorizationStatus({
    List<HealthMetricType> metrics = HealthSyncService.tier1Metrics,
  }) async {
    return AuthorizationStatusResponse(
      healthDataAvailable: true,
      typeStatuses: {
        for (final metric in metrics)
          metric: HealthAuthorizationState.authorized,
      },
      requestedAt: DateTime.utc(2026, 4, 20, 10),
    );
  }

  @override
  Future<HealthSyncRunResult> runInitialBackfill({
    List<HealthMetricType> metrics = HealthSyncService.tier1Metrics,
    DateTime? now,
    Duration lookback = const Duration(days: 30),
  }) async {
    backfillRequests.add(metrics);
    return result;
  }
}

class _MemorySetupStateService extends SetupStateService {
  _MemorySetupStateService([this.status = SetupStatus.empty])
      : super(repository: AppServices.wearableSampleRepository);

  SetupStatus status;

  @override
  Future<SetupStatus> loadStatus() async => status;

  @override
  Future<void> saveStatus(SetupStatus status) async {
    this.status = status;
  }

  @override
  Future<SetupStatus> markProfileValidated() async {
    status = status.copyWith(profileValidatedAt: DateTime.utc(2026, 4, 20, 10));
    return status;
  }

  @override
  Future<SetupStatus> markModelValidated({
    String? runtimeProfile,
    String? backend,
  }) async {
    status = status.copyWith(
      modelValidatedAt: DateTime.utc(2026, 4, 20, 10),
      modelRuntimeProfile: runtimeProfile,
      modelBackend: backend,
    );
    return status;
  }

  @override
  Future<SetupStatus> completeWithHealth({
    required int importedSamples,
    DateTime? lastBackfillAt,
  }) async {
    status = status.copyWith(
      completed: true,
      completedAt: DateTime.utc(2026, 4, 20, 10),
      healthValidatedAt: DateTime.utc(2026, 4, 20, 10),
      healthEnabled: true,
      healthImportedSamples: importedSamples,
      healthLastBackfillAt: lastBackfillAt,
    );
    return status;
  }

  @override
  Future<SetupStatus> completeWithoutHealth() async {
    status = status.copyWith(
      completed: true,
      completedAt: DateTime.utc(2026, 4, 20, 10),
      healthValidatedAt: DateTime.utc(2026, 4, 20, 10),
      healthEnabled: false,
      healthImportedSamples: 0,
    );
    return status;
  }
}

/// Test-only RagMemoryService that records requested anchors without touching
/// native runtime or sqflite. The widget tests only need to prove the setup flow
/// requests the idempotent anchors at the right time.
class _RecordingRagMemoryService extends RagMemoryService {
  _RecordingRagMemoryService()
      : super(
          repository: _MemoryWearableSampleRepository(database: AppDatabase()),
          corpusService: RagCorpusService(),
          runtime: const UnavailableGemmaRuntime(),
        );

  final Map<String, _RecordedRagWrite> writes = {};
  Iterable<String> get transactionIds => writes.keys;

  @override
  Future<RagWriteResult> writeAndVerify({
    required String transactionId,
    required String sourceType,
    required String sourceId,
    required String text,
    Map<String, Object?> metadata = const {},
  }) async {
    final chunkId = transactionId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    writes[transactionId] = _RecordedRagWrite(
      transactionId: transactionId,
      sourceType: sourceType,
      sourceId: sourceId,
      chunkId: chunkId,
      text: text,
      metadata: metadata,
    );
    return RagWriteResult(
      transactionId: transactionId,
      chunkId: chunkId,
      status: RagMemoryStatus.pending,
      verified: false,
      message: 'test-stub: corpus write skipped',
    );
  }
}

class _RecordedRagWrite {
  const _RecordedRagWrite({
    required this.transactionId,
    required this.sourceType,
    required this.sourceId,
    required this.chunkId,
    required this.text,
    required this.metadata,
  });

  final String transactionId;
  final String sourceType;
  final String sourceId;
  final String chunkId;
  final String text;
  final Map<String, Object?> metadata;
}

class _FailingRagMemoryService extends RagMemoryService {
  _FailingRagMemoryService()
      : super(
          repository: _MemoryWearableSampleRepository(database: AppDatabase()),
          corpusService: RagCorpusService(),
          runtime: const UnavailableGemmaRuntime(),
        );

  @override
  Future<RagWriteResult> writeAndVerify({
    required String transactionId,
    required String sourceType,
    required String sourceId,
    required String text,
    Map<String, Object?> metadata = const {},
  }) {
    throw StateError('test write failure');
  }
}
