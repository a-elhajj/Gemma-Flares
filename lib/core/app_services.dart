import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';

import 'database/app_database.dart';
import 'database/wearable_sample_repository.dart';
import 'services/cosinor_service.dart';
import 'services/flutter_litert_lm_runtime.dart';
import 'services/litert_lm_download_service.dart';
import 'services/rag_corpus_service.dart';
import 'services/context_attribution_service.dart';
import 'services/daily_summary_service.dart';
import 'services/dashboard_snapshot_service.dart';
import 'services/diagnostic_log_service.dart';
import 'services/encryption_service.dart';
import 'services/evaluation_service.dart';
import 'services/experiment_service.dart';
import 'services/expanded_healthkit_import_service.dart';
import 'services/flare_label_service.dart';
import 'services/food_logging_service.dart';
import 'services/food_entry.dart';
import 'services/analytics_refresh_service.dart';
import 'services/app_readiness_service.dart';
import 'services/background_job_service.dart';
import 'services/background_orchestration_service.dart';
import 'services/gemma_task_service.dart';
import 'services/gemma_audit_service.dart';
import 'services/gemma_router_service.dart';
import 'services/gemma_tool_dispatch_service.dart';
import 'services/guidance_service.dart';
import 'services/grounded_evidence_service.dart';
import 'services/health_refresh_coordinator.dart';
import 'services/health_rag_sync_service.dart';
import 'services/health_sync_service.dart';
import 'services/hierarchical_summary_service.dart';
import 'services/lab_logging_service.dart';
import 'services/lab_normalization_service.dart';
import 'services/lab_report_ocr_service.dart';
import 'services/lab_risk_contribution_service.dart';
import 'services/local_agent_service.dart';
import 'services/local_data_controls_service.dart';
import 'services/local_model_runtime.dart';
import 'services/logistic_risk_service.dart';
import 'services/medication_logging_service.dart';
import 'services/memory_assembler_service.dart';
import 'services/memory_controls_service.dart';
import 'services/metric_capability_service.dart';
import 'services/method_channel_health_bridge.dart';
import 'services/model_validation_service.dart';
import 'services/notification_scheduler_service.dart';
import 'services/doctor_summary_pdf_service.dart';
import 'services/pinned_fact_service.dart';
import 'services/photo_intake_service.dart';
import 'services/profile_service.dart';
import 'services/proactive_open_service.dart';
import 'services/prompt_injection_guard_service.dart';
import 'services/model_readiness_service.dart';
import 'services/red_flag_classifier_service.dart';
import 'services/risk_engine_service.dart';
import 'services/runtime_benchmark_service.dart';
import 'services/runtime_telemetry_service.dart';
import 'services/embedding_service.dart';
import 'services/litert_embedding_service.dart';
import 'services/rag_index_service.dart';
import 'services/rag_memory_service.dart';
import 'services/rag_query_service.dart';
import 'services/rag_store.dart';
import 'services/score_stability_gate.dart';
import 'services/setup_state_service.dart';
import 'services/symptom_logging_service.dart';
import 'services/symptom_parser_service.dart';
import 'services/symptom_taxonomy_service.dart';
import 'services/system_status_service.dart';
import 'services/token_budget_service.dart';
import 'services/tool_audit_service.dart';
import 'services/vector_index_service.dart';
import 'services/wearable_normalization_service.dart';

class AppServices {
  // ── Dependency-injection container ────────────────────────────────────────
  static final _di = GetIt.instance;
  static bool _configured = false;

  /// Reactive model-load state. Lives outside GetIt so it persists across
  /// _configure() re-calls and is always safe to read before setup completes.
  static final modelReadiness = ModelReadinessService();

  /// Register or replace a singleton in the DI container (idempotent).
  static void _reg<T extends Object>(T instance) {
    if (_di.isRegistered<T>()) _di.unregister<T>();
    _di.registerSingleton<T>(instance);
  }

  // ── GetIt-managed services (swappable via configureForTesting) ─────────────
  static AppDatabase get database => _di<AppDatabase>();
  static MethodChannelHealthBridge get healthBridge =>
      _di<MethodChannelHealthBridge>();
  static WearableSampleRepository get wearableSampleRepository =>
      _di<WearableSampleRepository>();
  // Test-only setter.
  static set wearableSampleRepository(WearableSampleRepository value) =>
      _reg<WearableSampleRepository>(value);
  static ProfileService get profileService => _di<ProfileService>();
  // Test-only setter.
  static set profileService(ProfileService value) =>
      _reg<ProfileService>(value);
  static FlareLabelService get flareLabelService => _di<FlareLabelService>();
  static LocalModelRuntime get localModelRuntime => _di<LocalModelRuntime>();
  // Test-only setter.
  static set localModelRuntime(LocalModelRuntime value) =>
      _reg<LocalModelRuntime>(value);
  static LiteRtLmModelDownloadService get liteRtLmDownloadService =>
      _di<LiteRtLmModelDownloadService>();

  /// Initialises all services with production defaults (no encryption key).
  /// Useful in tests that don't need a Keychain round-trip.
  static void setup() => _configure(
        databaseOverride: AppDatabase(),
        repositoryOverride: null,
        profileServiceOverride: null,
        flareLabelServiceOverride: null,
        healthBridgeOverride: MethodChannelHealthBridge(),
        localModelRuntimeOverride: FlutterLitertLmRuntime(),
        liteRtLmDownloadServiceOverride: null,
        appReadinessServiceOverride: null,
        setupStateServiceOverride: null,
        localAgentServiceOverride: null,
        dashboardSnapshotServiceOverride: null,
        pinnedFactServiceOverride: null,
        toolAuditServiceOverride: null,
        memoryControlsServiceOverride: null,
        healthSyncServiceOverride: null,
        labRiskContributionServiceOverride: null,
        scoreStabilityGateOverride: null,
      );

  /// Must be called once during app boot (before any DB access) to wire the
  /// encryption key sourced from the iOS Keychain.
  static Future<void> bootstrapEncryption() async {
    final key = await EncryptionService.getMasterKey();
    _configure(
      databaseOverride: AppDatabase(encryptionKey: key),
      repositoryOverride: null,
      profileServiceOverride: null,
      flareLabelServiceOverride: null,
      healthBridgeOverride: MethodChannelHealthBridge(),
      localModelRuntimeOverride: FlutterLitertLmRuntime(),
      liteRtLmDownloadServiceOverride: null,
      appReadinessServiceOverride: null,
      setupStateServiceOverride: null,
      localAgentServiceOverride: null,
      dashboardSnapshotServiceOverride: null,
      pinnedFactServiceOverride: null,
      toolAuditServiceOverride: null,
      memoryControlsServiceOverride: null,
      healthSyncServiceOverride: null,
      labRiskContributionServiceOverride: null,
      scoreStabilityGateOverride: null,
    );
  }

  static SystemStatusService get systemStatusService =>
      _di<SystemStatusService>();
  static const wearableNormalizationService = WearableNormalizationService();
  static DailySummaryService get dailySummaryService =>
      _di<DailySummaryService>();
  // Paper replication services — initialized before riskEngineService so DI ordering is clear
  static CosinorService get cosinorService => _di<CosinorService>();
  static LogisticRiskService get logisticRiskService =>
      _di<LogisticRiskService>();
  static EvaluationService get evaluationService => _di<EvaluationService>();
  static ContextAttributionService get contextAttributionService =>
      _di<ContextAttributionService>();
  static MetricCapabilityService get metricCapabilityService =>
      _di<MetricCapabilityService>();
  static ModelValidationService get modelValidationService =>
      _di<ModelValidationService>();
  static ExperimentService get experimentService => _di<ExperimentService>();
  static DiagnosticLogService get diagnosticLogService =>
      _di<DiagnosticLogService>();
  static const labNormalizationService = LabNormalizationService();
  static LabRiskContributionService get labRiskContributionService =>
      _di<LabRiskContributionService>();
  // Test-only setter.
  static set labRiskContributionService(LabRiskContributionService value) =>
      _reg<LabRiskContributionService>(value);
  static ScoreStabilityGate get scoreStabilityGate => _di<ScoreStabilityGate>();
  // Test-only setter.
  static set scoreStabilityGate(ScoreStabilityGate value) =>
      _reg<ScoreStabilityGate>(value);
  static SetupStateService get setupStateService => _di<SetupStateService>();
  // Test-only setter: replaces the DI-registered SetupStateService with a fake.
  // Must be called after configureForTesting and before the widget under test pumps.
  static set setupStateService(SetupStateService value) =>
      _reg<SetupStateService>(value);
  static RiskEngineService get riskEngineService => _di<RiskEngineService>();
  static AnalyticsRefreshService get analyticsRefreshService =>
      _di<AnalyticsRefreshService>();
  static const symptomParserService = SymptomParserService();
  static SymptomTaxonomyService get symptomTaxonomyService =>
      _di<SymptomTaxonomyService>();
  static RagCorpusService get ragCorpusService => _di<RagCorpusService>();

  static RagMemoryService get ragMemoryService => _di<RagMemoryService>();
  // Test-only setter: replaces the DI-registered RagMemoryService with a fake.
  static set ragMemoryService(RagMemoryService value) =>
      _reg<RagMemoryService>(value);
  static GemmaRouterService get gemmaRouterService => _di<GemmaRouterService>();
  static PinnedFactService get pinnedFactService => _di<PinnedFactService>();
  // Test-only setter.
  static set pinnedFactService(PinnedFactService value) =>
      _reg<PinnedFactService>(value);
  static VectorIndexService get vectorIndexService => _di<VectorIndexService>();
  static EmbeddingService get embeddingService => _di<EmbeddingService>();
  static VectorStore get vectorStore => _di<VectorStore>();
  static RagIndexService get ragIndexService => _di<RagIndexService>();
  static RagQueryService get ragQueryService => _di<RagQueryService>();
  // Test-only setter: swap out the embedding/store/index/query triple.
  static set ragIndexService(RagIndexService value) =>
      _reg<RagIndexService>(value);
  static set ragQueryService(RagQueryService value) =>
      _reg<RagQueryService>(value);
  static TokenBudgetService get tokenBudgetService => _di<TokenBudgetService>();
  static MemoryAssemblerService get memoryAssemblerService =>
      _di<MemoryAssemblerService>();
  static HierarchicalSummaryService get hierarchicalSummaryService =>
      _di<HierarchicalSummaryService>();
  static PromptInjectionGuardService get promptInjectionGuardService =>
      _di<PromptInjectionGuardService>();
  static RedFlagClassifierService get redFlagClassifierService =>
      _di<RedFlagClassifierService>();
  static ToolAuditService get toolAuditService => _di<ToolAuditService>();
  // Test-only setter.
  static set toolAuditService(ToolAuditService value) =>
      _reg<ToolAuditService>(value);
  static MemoryControlsService get memoryControlsService =>
      _di<MemoryControlsService>();
  // Test-only setter.
  static set memoryControlsService(MemoryControlsService value) =>
      _reg<MemoryControlsService>(value);
  static NotificationSchedulerService get notificationSchedulerService =>
      _di<NotificationSchedulerService>();
  static ProactiveOpenService get proactiveOpenService =>
      _di<ProactiveOpenService>();
  static BackgroundJobService get backgroundJobService =>
      _di<BackgroundJobService>();
  static BackgroundOrchestrationService get backgroundOrchestrationService =>
      _di<BackgroundOrchestrationService>();
  static GemmaToolDispatchService get gemmaToolDispatchService =>
      _di<GemmaToolDispatchService>();
  static GemmaTaskService get gemmaTaskService => _di<GemmaTaskService>();
  static MedicationLoggingService get medicationLoggingService =>
      _di<MedicationLoggingService>();
  static FoodLoggingService get foodLoggingService => _di<FoodLoggingService>();
  static DoctorSummaryPdfService get doctorSummaryPdfService =>
      _di<DoctorSummaryPdfService>();
  static GemmaAuditService get gemmaAuditService => _di<GemmaAuditService>();
  static GroundedEvidenceService get groundedEvidenceService =>
      _di<GroundedEvidenceService>();
  static LabReportOcrService get labReportOcrService =>
      _di<LabReportOcrService>();
  static PhotoIntakeService get photoIntakeService => _di<PhotoIntakeService>();
  static LabLoggingService get labLoggingService => _di<LabLoggingService>();
  static LocalAgentService get localAgentService => _di<LocalAgentService>();
  // Test-only setter.
  static set localAgentService(LocalAgentService value) =>
      _reg<LocalAgentService>(value);
  static LocalDataControlsService get localDataControlsService =>
      _di<LocalDataControlsService>();
  static RuntimeBenchmarkService get runtimeBenchmarkService =>
      _di<RuntimeBenchmarkService>();
  static RuntimeTelemetryService get runtimeTelemetryService =>
      _di<RuntimeTelemetryService>();
  static SymptomLoggingService get symptomLoggingService =>
      _di<SymptomLoggingService>();
  static DashboardSnapshotService get dashboardSnapshotService =>
      _di<DashboardSnapshotService>();
  // Test-only setter.
  static set dashboardSnapshotService(DashboardSnapshotService value) =>
      _reg<DashboardSnapshotService>(value);
  static HealthSyncService get healthSyncService => _di<HealthSyncService>();
  // Test-only setter: replaces the DI-registered HealthSyncService with a fake.
  static set healthSyncService(HealthSyncService value) =>
      _reg<HealthSyncService>(value);
  static HealthRagSyncService get healthRagSyncService =>
      _di<HealthRagSyncService>();
  static GuidanceService get guidanceService => _di<GuidanceService>();
  static HealthRefreshCoordinator get healthRefreshCoordinator =>
      _di<HealthRefreshCoordinator>();
  static AppReadinessService get appReadinessService =>
      _di<AppReadinessService>();
  // Test-only setter.
  static set appReadinessService(AppReadinessService value) =>
      _reg<AppReadinessService>(value);
  static ExpandedHealthKitImportService get expandedHealthKitImportService =>
      _di<ExpandedHealthKitImportService>();

  /// Clears setup state and user profile so the setup wizard runs again on
  /// the next cold launch. Safe to call in any non-release build.
  ///
  /// Called automatically at boot when the `GEMMA_FLARES_DEV_RESET` dart-define
  /// is true (e.g. `flutter run --dart-define=GEMMA_FLARES_DEV_RESET=true`).
  /// Can also be triggered from the UI via Settings → Reset Setup.
  static Future<void> resetSetupForDevelopment() async {
    await setupStateService.clearStatus();
    await profileService.clearProfile();
  }

  static void configureForTesting({
    AppDatabase? databaseOverride,
    WearableSampleRepository? repositoryOverride,
    ProfileService? profileServiceOverride,
    FlareLabelService? flareLabelServiceOverride,
    MethodChannelHealthBridge? healthBridgeOverride,
    LocalModelRuntime? localModelRuntimeOverride,
    LiteRtLmModelDownloadService? liteRtLmDownloadServiceOverride,
    AppReadinessService? appReadinessServiceOverride,
    SetupStateService? setupStateServiceOverride,
    LocalAgentService? localAgentServiceOverride,
    DashboardSnapshotService? dashboardSnapshotServiceOverride,
    PinnedFactService? pinnedFactServiceOverride,
    ToolAuditService? toolAuditServiceOverride,
    MemoryControlsService? memoryControlsServiceOverride,
    HealthSyncService? healthSyncServiceOverride,
    LabRiskContributionService? labRiskContributionServiceOverride,
    ScoreStabilityGate? scoreStabilityGateOverride,
  }) {
    _configure(
      databaseOverride: databaseOverride ?? AppDatabase(),
      repositoryOverride: repositoryOverride,
      profileServiceOverride: profileServiceOverride,
      flareLabelServiceOverride: flareLabelServiceOverride,
      healthBridgeOverride: healthBridgeOverride ?? MethodChannelHealthBridge(),
      localModelRuntimeOverride:
          localModelRuntimeOverride ?? const UnavailableGemmaRuntime(),
      liteRtLmDownloadServiceOverride: liteRtLmDownloadServiceOverride,
      appReadinessServiceOverride: appReadinessServiceOverride,
      setupStateServiceOverride: setupStateServiceOverride,
      localAgentServiceOverride: localAgentServiceOverride,
      dashboardSnapshotServiceOverride: dashboardSnapshotServiceOverride,
      pinnedFactServiceOverride: pinnedFactServiceOverride,
      toolAuditServiceOverride: toolAuditServiceOverride,
      memoryControlsServiceOverride: memoryControlsServiceOverride,
      healthSyncServiceOverride: healthSyncServiceOverride,
      labRiskContributionServiceOverride: labRiskContributionServiceOverride,
      scoreStabilityGateOverride: scoreStabilityGateOverride,
    );
  }

  static void resetToDefaults() {
    _configure(
      databaseOverride: AppDatabase(),
      repositoryOverride: null,
      profileServiceOverride: null,
      flareLabelServiceOverride: null,
      healthBridgeOverride: MethodChannelHealthBridge(),
      localModelRuntimeOverride: FlutterLitertLmRuntime(),
      liteRtLmDownloadServiceOverride: null,
      appReadinessServiceOverride: null,
      setupStateServiceOverride: null,
      localAgentServiceOverride: null,
      dashboardSnapshotServiceOverride: null,
      pinnedFactServiceOverride: null,
      toolAuditServiceOverride: null,
      memoryControlsServiceOverride: null,
      healthSyncServiceOverride: null,
      labRiskContributionServiceOverride: null,
      scoreStabilityGateOverride: null,
    );
  }

  static void _configure({
    required AppDatabase databaseOverride,
    required WearableSampleRepository? repositoryOverride,
    required ProfileService? profileServiceOverride,
    required FlareLabelService? flareLabelServiceOverride,
    required MethodChannelHealthBridge healthBridgeOverride,
    required LocalModelRuntime localModelRuntimeOverride,
    required LiteRtLmModelDownloadService? liteRtLmDownloadServiceOverride,
    required AppReadinessService? appReadinessServiceOverride,
    required SetupStateService? setupStateServiceOverride,
    required LocalAgentService? localAgentServiceOverride,
    required DashboardSnapshotService? dashboardSnapshotServiceOverride,
    required PinnedFactService? pinnedFactServiceOverride,
    required ToolAuditService? toolAuditServiceOverride,
    required MemoryControlsService? memoryControlsServiceOverride,
    required HealthSyncService? healthSyncServiceOverride,
    required LabRiskContributionService? labRiskContributionServiceOverride,
    required ScoreStabilityGate? scoreStabilityGateOverride,
  }) {
    if (_configured) healthRefreshCoordinator.stop();
    _reg<AppDatabase>(databaseOverride);
    _reg<MethodChannelHealthBridge>(healthBridgeOverride);
    _reg<SystemStatusService>(MethodChannelSystemStatusService());
    _reg<WearableSampleRepository>(
      repositoryOverride ?? WearableSampleRepository(database: database),
    );
    _reg<DailySummaryService>(
      DailySummaryService(repository: wearableSampleRepository),
    );
    _reg<CosinorService>(CosinorService(repository: wearableSampleRepository));
    _reg<FlareLabelService>(
      flareLabelServiceOverride ??
          FlareLabelService(repository: wearableSampleRepository),
    );
    _reg<LogisticRiskService>(
      LogisticRiskService(repository: wearableSampleRepository),
    );
    _reg<EvaluationService>(
      EvaluationService(repository: wearableSampleRepository),
    );
    _reg<ContextAttributionService>(
      ContextAttributionService(repository: wearableSampleRepository),
    );
    _reg<MetricCapabilityService>(
      MetricCapabilityService(
        repository: wearableSampleRepository,
        normalizationService: wearableNormalizationService,
      ),
    );
    _reg<ModelValidationService>(
      ModelValidationService(repository: wearableSampleRepository),
    );
    _reg<ExperimentService>(
      ExperimentService(repository: wearableSampleRepository),
    );
    _reg<DiagnosticLogService>(
      DiagnosticLogService(repository: wearableSampleRepository),
    );
    _reg<RuntimeTelemetryService>(
      RuntimeTelemetryService(repository: wearableSampleRepository),
    );
    _reg<ProfileService>(
      profileServiceOverride ??
          ProfileService(repository: wearableSampleRepository),
    );
    _reg<SetupStateService>(
      setupStateServiceOverride ??
          SetupStateService(repository: wearableSampleRepository),
    );
    _reg<LabRiskContributionService>(
      labRiskContributionServiceOverride ??
          LabRiskContributionService(
            normalizationService: labNormalizationService,
          ),
    );
    _reg<ScoreStabilityGate>(
      scoreStabilityGateOverride ??
          ScoreStabilityGate(
            repository: wearableSampleRepository,
            diagnosticLogService: diagnosticLogService,
          ),
    );
    _reg<RiskEngineService>(
      RiskEngineService(
        repository: wearableSampleRepository,
        logisticRiskService: logisticRiskService,
        profileService: profileService,
        contextAttributionService: contextAttributionService,
        labRiskContributionService: labRiskContributionService,
        labNormalizationService: labNormalizationService,
        scoreStabilityGate: scoreStabilityGate,
        diagnosticLogService: diagnosticLogService,
      ),
    );
    _reg<AnalyticsRefreshService>(
      AnalyticsRefreshService(
        repository: wearableSampleRepository,
        dailySummaryService: dailySummaryService,
        flareLabelService: flareLabelService,
        cosinorService: cosinorService,
        riskEngineService: riskEngineService,
        diagnosticLogService: diagnosticLogService,
      ),
    );
    _reg<SymptomTaxonomyService>(SymptomTaxonomyService());
    _reg<LiteRtLmModelDownloadService>(
        liteRtLmDownloadServiceOverride ?? LiteRtLmModelDownloadService());
    _reg<RagCorpusService>(RagCorpusService());
    _reg<LocalModelRuntime>(localModelRuntimeOverride);
    _reg<RagMemoryService>(RagMemoryService(
      repository: wearableSampleRepository,
      corpusService: ragCorpusService,
      runtime: localModelRuntime,
    ));
    _reg<GemmaRouterService>(GemmaRouterService(
      runtime: localModelRuntime,
      systemStatusService: systemStatusService,
      diagnosticLogService: diagnosticLogService,
    ));
    _reg<PinnedFactService>(
      pinnedFactServiceOverride ?? PinnedFactService(database: database),
    );
    _reg<VectorIndexService>(VectorIndexService());
    // Embedding + vector store + unified RAG write/read services.
    // Production: LiteRtEmbeddingService (native TFLite when present with a
    // deterministic fallback) plus DurableVectorStore. This is intentionally
    // independent of the removed native local_model bridge so RAG writes
    // stay durable even when native ANN is unavailable.
    _reg<EmbeddingService>(LiteRtEmbeddingService(
      allowDeterministicFallback: !kReleaseMode,
    ));
    _reg<VectorStore>(DurableVectorStore());
    _reg<RagIndexService>(
        RagIndexService(embedding: embeddingService, store: vectorStore));
    _reg<RagQueryService>(
        RagQueryService(embedding: embeddingService, store: vectorStore));
    _reg<TokenBudgetService>(TokenBudgetService());
    _reg<MemoryAssemblerService>(MemoryAssemblerService(
      ragQueryService: ragQueryService,
      pinnedFacts: pinnedFactService,
      tokenBudget: tokenBudgetService,
    ));
    _reg<HierarchicalSummaryService>(HierarchicalSummaryService(
      database: database,
      router: gemmaRouterService,
      vectorIndex: vectorIndexService,
      ragCorpus: ragCorpusService,
    ));
    _reg<PromptInjectionGuardService>(PromptInjectionGuardService(
      diagnosticLogService: diagnosticLogService,
    ));
    _reg<RedFlagClassifierService>(RedFlagClassifierService(
      diagnosticLogService: diagnosticLogService,
    ));
    _reg<ToolAuditService>(
        toolAuditServiceOverride ?? ToolAuditService(database: database));
    _reg<MemoryControlsService>(memoryControlsServiceOverride ??
        MemoryControlsService(
          database: database,
          diagnosticLogService: diagnosticLogService,
        ));
    _reg<NotificationSchedulerService>(NotificationSchedulerService(
      database: database,
      diagnosticLogService: diagnosticLogService,
    ));
    _reg<ProactiveOpenService>(ProactiveOpenService(
      database: database,
      diagnosticLogService: diagnosticLogService,
    ));
    _reg<BackgroundJobService>(BackgroundJobService(
      database: database,
      diagnosticLogService: diagnosticLogService,
    ));
    _reg<BackgroundOrchestrationService>(BackgroundOrchestrationService(
      backgroundJobs: backgroundJobService,
      summaries: hierarchicalSummaryService,
      proactiveOpen: proactiveOpenService,
    ));
    _reg<GemmaToolDispatchService>(GemmaToolDispatchService(
      router: gemmaRouterService,
      auditService: toolAuditService,
    ));
    _reg<GemmaTaskService>(GemmaTaskService(
      repository: wearableSampleRepository,
      runtime: localModelRuntime,
      diagnosticLogService: diagnosticLogService,
    ));
    _reg<MedicationLoggingService>(MedicationLoggingService(
      repository: wearableSampleRepository,
      profileService: profileService,
      riskEngineService: riskEngineService,
      analyticsRefreshService: analyticsRefreshService,
      ragIndexService: ragIndexService,
      ragMemoryService: ragMemoryService,
    ));
    _reg<FoodLoggingService>(FoodLoggingService(
      repository: wearableSampleRepository,
      ragIndexService: ragIndexService,
      ragMemoryService: ragMemoryService,
    ));
    _reg<DoctorSummaryPdfService>(DoctorSummaryPdfService());
    _reg<GemmaAuditService>(
      GemmaAuditService(repository: wearableSampleRepository),
    );
    _reg<GroundedEvidenceService>(
      GroundedEvidenceService(
        repository: wearableSampleRepository,
        profileService: profileService,
      ),
    );
    _reg<LabReportOcrService>(LabReportOcrService());
    _reg<PhotoIntakeService>(PhotoIntakeService(
      ocrService: labReportOcrService,
      runtime: localModelRuntime,
    ));
    _reg<LabLoggingService>(LabLoggingService(
      repository: wearableSampleRepository,
      analyticsRefreshService: analyticsRefreshService,
      ragIndexService: ragIndexService,
      ragMemoryService: ragMemoryService,
      gemmaTaskService: gemmaTaskService,
      toolAuditService: toolAuditService,
    ));
    _registerToolHandlers();
    _reg<LocalAgentService>(localAgentServiceOverride ??
        LocalAgentService(
          repository: wearableSampleRepository,
          runtime: localModelRuntime,
          ragQueryService: ragQueryService,
          ragCorpusService: ragCorpusService,
          profileService: profileService,
          diagnosticLogService: diagnosticLogService,
          gemmaTaskService: gemmaTaskService,
          runtimeTelemetryService: runtimeTelemetryService,
        ));
    _reg<LocalDataControlsService>(LocalDataControlsService(
      repository: wearableSampleRepository,
      runtime: localModelRuntime,
      ragMemoryService: ragMemoryService,
      earlyWarningSnapshotLoader: () async {
        final snapshot = await dashboardSnapshotService.loadDashboardSnapshot();
        return {
          'generated_at': DateTime.now().toUtc().toIso8601String(),
          'outlook': snapshot.earlyWarningOutlook
              .map((item) => {
                    'horizon_days': item.horizonDays,
                    'label': item.label,
                    'probability': item.probability,
                    'training_samples': item.trainingSamples,
                    'is_learning': item.isLearning,
                  })
              .toList(growable: false),
        };
      },
    ));
    _reg<RuntimeBenchmarkService>(RuntimeBenchmarkService(
      runtime: localModelRuntime,
      diagnosticLogService: diagnosticLogService,
      runtimeTelemetryService: runtimeTelemetryService,
    ));
    _reg<SymptomLoggingService>(SymptomLoggingService(
      repository: wearableSampleRepository,
      parser: symptomParserService,
      taxonomyService: symptomTaxonomyService,
      ragIndexService: ragIndexService,
      ragMemoryService: ragMemoryService,
      gemmaTaskService: gemmaTaskService,
      riskEngineService: riskEngineService,
      analyticsRefreshService: analyticsRefreshService,
    ));
    _reg<DashboardSnapshotService>(dashboardSnapshotServiceOverride ??
        DashboardSnapshotService(
          repository: wearableSampleRepository,
        ));
    _reg<HealthSyncService>(healthSyncServiceOverride ??
        HealthSyncService(
          bridge: healthBridge,
          normalizationService: wearableNormalizationService,
          repository: wearableSampleRepository,
          dailySummaryService: dailySummaryService,
          cosinorService: cosinorService,
          riskEngineService: riskEngineService,
          diagnosticLogService: diagnosticLogService,
        ));
    _reg<HealthRagSyncService>(HealthRagSyncService(
      repository: wearableSampleRepository,
      ragMemoryService: ragMemoryService,
      ragIndexService: ragIndexService,
    ));
    _reg<GuidanceService>(GuidanceService(
      repository: wearableSampleRepository,
      runtime: localModelRuntime,
      profileService: profileService,
      diagnosticLogService: diagnosticLogService,
    ));
    _reg<HealthRefreshCoordinator>(HealthRefreshCoordinator(
      healthSyncService: healthSyncService,
      guidanceService: guidanceService,
      systemStatusService: systemStatusService,
      healthRagSyncService: healthRagSyncService,
      diagnosticLogService: diagnosticLogService,
      authorizationCheckOverride: () =>
          healthSyncService.hasAuthorizedHealthAccess(),
    ));
    _reg<AppReadinessService>(appReadinessServiceOverride ??
        AppReadinessService(
          healthRefreshCoordinator: healthRefreshCoordinator,
          repository: wearableSampleRepository,
          diagnosticLogService: diagnosticLogService,
          shouldRefreshForOpen: () =>
              healthSyncService.hasAuthorizedHealthAccess(),
        ));
    _reg<ExpandedHealthKitImportService>(
      ExpandedHealthKitImportService(healthSync: healthSyncService),
    );
    _configured = true;
  }

  static Future<void> validateCriticalStartupChain() async {
    final checks = <String, bool>{
      'database': _di.isRegistered<AppDatabase>(),
      'embedding_service': _di.isRegistered<EmbeddingService>(),
      'vector_store': _di.isRegistered<VectorStore>(),
      'rag_index': _di.isRegistered<RagIndexService>(),
      'rag_query': _di.isRegistered<RagQueryService>(),
      'local_agent': _di.isRegistered<LocalAgentService>(),
    };
    final missing = checks.entries
        .where((entry) => !entry.value)
        .map((entry) => entry.key)
        .toList(growable: false);
    if (missing.isNotEmpty) {
      final error = StateError('Missing critical startup services: $missing');
      await diagnosticLogService.error(
        'critical_startup_chain_invalid',
        category: DiagnosticLogService.categoryApp,
        message: 'Critical local AI/RAG service registration failed.',
        error: error,
        metadata: {'missing': missing},
      );
      throw error;
    }
    final embedding = embeddingService;
    await diagnosticLogService.info(
      'critical_startup_chain_validated',
      category: DiagnosticLogService.categoryApp,
      message: 'Critical local AI/RAG service chain is registered.',
      metadata: {
        'embedding_provider': embedding.providerName,
        'embedding_fallback_active': embedding.isDeterministicFallbackActive,
        'vector_store': vectorStore.runtimeType.toString(),
      },
    );
  }

  static bool _registerToolHandlers() {
    gemmaToolDispatchService.registerHandler('ingest_lab_panel', (args) async {
      final candidates = _labCandidatesFromToolArgs(args);
      final source = args['source']?.toString() ?? 'tool_dispatch';
      final confirmed = args['confirmed'] == true ||
          args['user_confirmed'] == true ||
          source.contains('confirmed');
      if (!confirmed) {
        final auditId = await toolAuditService.record(
          toolName: 'ingest_lab_panel',
          args: {
            'source': source,
            'candidate_count': candidates.length,
            'requires_confirmation': true,
          },
          result: {
            'status': 'pending_review',
            'candidate_count': candidates.length,
            'lab_types': candidates.map((lab) => lab.labType).toList(),
            'message': 'Labs detected but not saved until user confirmation.',
          },
          latencyMs: 0,
          modelRole: 'chat_tool_pending_review',
          promptVersion: GemmaTaskService.labPromptVersion,
          validated: true,
        );
        return {
          'status': 'pending_review',
          'saved_count': 0,
          'candidate_count': candidates.length,
          'lab_types': candidates.map((lab) => lab.labType).toList(),
          'requires_confirmation': true,
          'tool_audit_id': auditId,
        };
      }
      final result = await labLoggingService.saveCandidates(
        candidates: candidates,
        source: source,
      );
      return {
        'status': 'saved',
        'saved_count': result.savedLabs.length,
        'lab_ids': result.savedLabs.map((lab) => lab.id).toList(),
        'lab_types': result.savedLabs.map((lab) => lab.labType).toList(),
        'rag_indexed_by_lab_id': result.ragIndexedByLabId,
        'analytics_refresh_status': result.analyticsRefreshStatus,
        'tool_audit_id': result.toolAuditId,
      };
    });
    gemmaToolDispatchService.registerHandler('log_meal', (args) async {
      final entry = _foodEntryFromToolArgs(args);
      final result = await foodLoggingService.saveFoodEntry(entry);
      return {
        'status': 'saved',
        'food_id': result.savedEntry.id,
        'food_name': result.savedEntry.foodName,
        'meal_type': result.savedEntry.mealType,
        'trigger_suspected': result.savedEntry.triggerSuspected,
        'rag_indexed': result.ragIndexed,
        'rag_status': result.ragStatus,
        'rag_transaction_id': result.ragTransactionId,
        'rag_verified': result.ragVerified,
      };
    });
    return true;
  }

  static FoodEntry _foodEntryFromToolArgs(Map<String, Object?> args) {
    final description = _stringArg(args, 'description') ??
        _stringArg(args, 'food_name') ??
        _stringArg(args, 'meal') ??
        '';
    final immediateResponse = _stringArg(args, 'immediate_gi_response');
    final loggedAt = _parseToolDateTime(_stringArg(args, 'logged_at'));
    final mealType = _stringArg(args, 'meal_type');
    final triggerSuspected = _boolArg(args, 'trigger_suspected') ??
        (immediateResponse?.trim().isNotEmpty ?? false);
    return FoodEntry(
      loggedAt: loggedAt,
      foodName: description,
      description: description,
      mealType: mealType,
      notes: immediateResponse == null
          ? null
          : 'Immediate GI response: $immediateResponse',
      triggerSuspected: triggerSuspected,
      source: 'gemma_tool_log_meal',
    );
  }

  static String? _stringArg(Map<String, Object?> args, String key) {
    final value = args[key]?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  static bool? _boolArg(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value is bool) return value;
    if (value is String) {
      final lower = value.trim().toLowerCase();
      if (lower == 'true' || lower == 'yes') return true;
      if (lower == 'false' || lower == 'no') return false;
    }
    return null;
  }

  static DateTime _parseToolDateTime(String? raw) {
    if (raw == null) return DateTime.now().toUtc();
    return DateTime.tryParse(raw)?.toUtc() ?? DateTime.now().toUtc();
  }

  static List<GemmaLabCandidate> _labCandidatesFromToolArgs(
    Map<String, Object?> args,
  ) {
    final results = args['results'];
    if (results is! List) return const [];
    return results.whereType<Map>().map((raw) {
      final item = Map<String, Object?>.from(raw);
      return GemmaLabCandidate(
        labType: item['analyte_canonical_id']?.toString() ?? 'unknown',
        valueNumeric: (item['value_numeric'] as num?)?.toDouble() ?? 0,
        unit: item['unit']?.toString() ?? '',
        drawnDate: item['drawn_date']?.toString() ?? '',
        referenceHigh: (item['reference_high'] as num?)?.toDouble(),
        labName: item['lab_name']?.toString(),
        abnormalFlag: item['abnormal_flag'] == null
            ? null
            : item['abnormal_flag'].toString().toLowerCase() == 'true',
        confidence: (item['confidence'] as num?)?.toDouble() ?? 0.7,
        sourceTextSnippet: 'ingest_lab_panel tool call',
      );
    }).toList(growable: false);
  }
}
