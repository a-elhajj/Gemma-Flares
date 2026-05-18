import 'dart:convert';

import '../database/wearable_sample_repository.dart';
import 'local_model_runtime.dart';
import 'profile_service.dart';
import 'rag_memory_service.dart';

class LocalDataExportBundle {
  const LocalDataExportBundle({required this.payload});

  final Map<String, Object?> payload;

  String toPrettyJson() {
    return const JsonEncoder.withIndent('  ').convert(payload);
  }
}

class LocalDataControlsService {
  LocalDataControlsService({
    required WearableSampleRepository repository,
    required LocalModelRuntime runtime,
    RagMemoryService? ragMemoryService,
    Future<Map<String, Object?>?> Function()? earlyWarningSnapshotLoader,
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _runtime = runtime,
        _ragMemoryService = ragMemoryService,
        _earlyWarningSnapshotLoader = earlyWarningSnapshotLoader,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final WearableSampleRepository _repository;
  final LocalModelRuntime _runtime;
  final RagMemoryService? _ragMemoryService;
  final Future<Map<String, Object?>?> Function()? _earlyWarningSnapshotLoader;
  final DateTime Function() _nowProvider;

  Future<LocalDataExportBundle> buildExportBundle() async {
    final runtimeStatus = await _runtime.getRuntimeStatus();
    final syncState = await _repository.getSyncState('apple_health');
    final latestBaseline = await _repository.getLatestBaselineSnapshot();
    final latestSummary = await _repository.getLatestDailySummary();
    final latestScore = await _repository.getLatestUserFacingFlareRiskScore();
    final profile = await _repository.getAppSettingMap(
      ProfileService.profileKey,
    );
    final evaluationResults = await _repository.getAppSettingJson(
      'eval_results_json',
    );
    final baselines = await _repository.getBaselineSnapshots();
    final summaries = await _repository.getDailySummaries();
    final features = await _repository.getDailyFeatures();
    final scores = await _repository.getFlareRiskScores();
    final symptoms = await _repository.getRecentSymptoms(limit: null);
    final conversations = await _repository.getRecentConversations(limit: null);
    final labs = await _repository.getLabValues();
    final procedures = await _repository.getEndoscopyRecords();
    final checkIns = await _repository.getPro2Surveys();
    final labels = await _repository.getAllFlareLabels();
    final cosinorFeatures = await _repository.getCosinorFeatures();
    final logisticStates = await _repository.getAllLogisticModelStates();
    final experimentAssignments = await _repository.getExperimentAssignments();
    final experimentEvents = await _repository.getExperimentEvents();
    final diagnosticLogs = await _repository.getDiagnosticLogs();
    final contextWindows = await _repository.getContextWindows();
    final dailyContextFeatures = await _repository.getDailyContextFeatures();
    final metricRegistry = await _repository.getHealthKitMetricRegistry();
    final clinicalImports = await _repository.getClinicalRecordImports();
    final validationRuns = await _repository.getValidationRuns();
    final validationMetrics = await _repository.getValidationMetrics();
    final gemmaTaskRuns = await _repository.getGemmaTaskRuns();
    final gemmaExtractionReviews =
        await _repository.getGemmaExtractionReviews();
    final doctorSummaries = await _repository.getDoctorSummaries();
    final ragTransactions = await _repository.getRagMemoryTransactions();
    Map<String, Object?>? ragMemoryExport;
    try {
      ragMemoryExport = _ragMemoryService == null
          ? null
          : (await _ragMemoryService.exportRagContents()).payload;
    } catch (error) {
      ragMemoryExport = {'status': 'unavailable', 'reason': error.toString()};
    }
    Map<String, Object?>? earlyWarningSnapshot;
    try {
      earlyWarningSnapshot = await _earlyWarningSnapshotLoader?.call();
    } catch (_) {
      earlyWarningSnapshot = {
        'status': 'unavailable',
        'reason': 'early_warning_snapshot_loader_failed',
      };
    }

    return LocalDataExportBundle(
      payload: {
        'exported_at': _nowProvider().toUtc().toIso8601String(),
        'product': 'gemma_flares',
        'export_scope': 'local_diagnostics_and_friend_testing_audit',
        'privacy_note':
            'Local export only. This can include sensitive health and chat data. Gemma Flares does not diagnose a flare or recommend medication changes.',
        'runtime_status': {
          'status': runtimeStatus.status,
          'runtime_name': runtimeStatus.runtimeName,
          'backend_style': runtimeStatus.backendStyle,
          'expected_model_filename': runtimeStatus.expectedModelFilename,
          'is_backend_linked': runtimeStatus.isBackendLinked,
          'is_bundled_model_present': runtimeStatus.isBundledModelPresent,
          'is_model_loaded': runtimeStatus.isModelLoaded,
          'reason': runtimeStatus.reason,
        },
        'latest_summary':
            latestSummary == null ? null : _summaryToJson(latestSummary),
        'latest_baseline':
            latestBaseline == null ? null : _baselineToJson(latestBaseline),
        'latest_score': latestScore == null ? null : _scoreToJson(latestScore),
        'early_warning_outlook': earlyWarningSnapshot,
        'sync_state': syncState == null ? null : _syncStateToJson(syncState),
        'profile': profile,
        'evaluation_results': evaluationResults,
        'baseline_snapshots':
            baselines.map(_baselineToJson).toList(growable: false),
        'daily_summaries':
            summaries.map(_summaryToJson).toList(growable: false),
        'daily_features':
            features.map(_dailyFeatureToJson).toList(growable: false),
        'flare_risk_scores': scores.map(_scoreToJson).toList(growable: false),
        'lab_values': labs.map(_labToJson).toList(growable: false),
        'endoscopy_records':
            procedures.map(_endoscopyToJson).toList(growable: false),
        'pro2_surveys': checkIns.map(_pro2ToJson).toList(growable: false),
        'flare_labels': labels.map(_flareLabelToJson).toList(growable: false),
        'cosinor_features':
            cosinorFeatures.map(_cosinorToJson).toList(growable: false),
        'logistic_model_states':
            logisticStates.map(_logisticStateToJson).toList(growable: false),
        'experiment_assignments': experimentAssignments
            .map(_experimentAssignmentToJson)
            .toList(growable: false),
        'experiment_events': experimentEvents
            .map(_experimentEventToJson)
            .toList(growable: false),
        'diagnostic_logs':
            diagnosticLogs.map(_diagnosticLogToJson).toList(growable: false),
        'context_windows':
            contextWindows.map(_contextWindowToJson).toList(growable: false),
        'daily_context_features': dailyContextFeatures
            .map(_dailyContextFeatureToJson)
            .toList(growable: false),
        'healthkit_metric_registry':
            metricRegistry.map(_metricRegistryToJson).toList(growable: false),
        'clinical_record_imports':
            clinicalImports.map(_clinicalImportToJson).toList(growable: false),
        'model_validation_runs':
            validationRuns.map(_validationRunToJson).toList(growable: false),
        'model_validation_metrics': validationMetrics
            .map(_validationMetricToJson)
            .toList(growable: false),
        'gemma_task_runs':
            gemmaTaskRuns.map(_gemmaTaskRunToJson).toList(growable: false),
        'gemma_extraction_reviews': gemmaExtractionReviews
            .map(_gemmaExtractionReviewToJson)
            .toList(growable: false),
        'doctor_summaries':
            doctorSummaries.map(_doctorSummaryToJson).toList(growable: false),
        'rag_memory': ragMemoryExport,
        'rag_memory_transactions': ragTransactions
            .map(_ragMemoryTransactionToJson)
            .toList(growable: false),
        'symptoms': symptoms.map(_symptomToJson).toList(growable: false),
        'conversations':
            conversations.map(_conversationToJson).toList(growable: false),
      },
    );
  }

  Future<void> clearLocalData() {
    return _repository.clearLocalUserData();
  }

  Future<void> clearRagMemory() async {
    final service = _ragMemoryService;
    if (service != null) {
      await service.deleteAllRagContents();
    } else {
      await _repository.markAllRagMemoryTransactionsDeleted();
    }
  }

  Map<String, Object?> _summaryToJson(DailySummaryRecord record) {
    return {
      'date_local': record.dateLocal,
      'summary_json': record.summaryJson,
      'sync_quality_score': record.syncQualityScore,
      'recomputed_at': record.recomputedAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _ragMemoryTransactionToJson(
    RagMemoryTransactionRecord record,
  ) =>
      {
        'transaction_id': record.transactionId,
        'source_type': record.sourceType,
        'source_id': record.sourceId,
        'chunk_id': record.chunkId,
        'status': record.status,
        'text_hash': record.textHash,
        'created_at': record.createdAt.toUtc().toIso8601String(),
        'indexed_at': record.indexedAt?.toUtc().toIso8601String(),
        'verified_at': record.verifiedAt?.toUtc().toIso8601String(),
        'retry_count': record.retryCount,
        'last_error': record.lastError,
      };

  Map<String, Object?> _baselineToJson(BaselineSnapshotRecord record) {
    return {
      'snapshot_date_local': record.snapshotDateLocal,
      'readiness_state': record.readinessState,
      'baseline_json': record.baselineJson,
      'valid_days': record.validDays,
      'created_at': record.createdAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _scoreToJson(FlareRiskScoreRecord record) {
    return {
      'date_local': record.dateLocal,
      'risk_score': record.riskScore,
      'risk_band': record.riskBand,
      'confidence_score': record.confidenceScore,
      'contribution_json': record.contributionJson,
      'feature_snapshot_json': record.featureSnapshotJson,
      'model_version': record.modelVersion,
      'created_at': record.createdAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _dailyFeatureToJson(DailyFeatureRecord record) {
    return {
      'feature_date_local': record.featureDateLocal,
      'feature_json': record.featureJson,
      'missingness_json': record.missingnessJson,
      'recomputed_at': record.recomputedAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _syncStateToJson(SyncStateRecord record) {
    return {
      'source_name': record.sourceName,
      'last_sync_at': record.lastSyncAt?.toUtc().toIso8601String(),
      'last_backfill_start':
          record.lastBackfillStart?.toUtc().toIso8601String(),
      'last_backfill_end': record.lastBackfillEnd?.toUtc().toIso8601String(),
      'sync_cursor_json': record.syncCursorJson,
      'last_error': record.lastError,
      'updated_at': record.updatedAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _labToJson(LabValueRecord record) {
    return {
      'id': record.id,
      'drawn_date': record.drawnDate,
      'lab_type': record.labType,
      'value_numeric': record.valueNumeric,
      'unit': record.unit,
      'reference_high': record.referenceHigh,
      'lab_name': record.labName,
      'ordering_provider': record.orderingProvider,
      'notes': record.notes,
      'created_at': record.createdAt.toUtc().toIso8601String(),
      'updated_at': record.updatedAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _endoscopyToJson(EndoscopyRecord record) {
    return {
      'id': record.id,
      'procedure_date': record.procedureDate,
      'procedure_type': record.procedureType,
      'mayo_endoscopic_score': record.mayoEndoscopicScore,
      'ses_cd_score': record.sesCdScore,
      'rutgeerts_score': record.rutgeertsScore,
      'findings_text': record.findingsText,
      'biopsies_taken': record.biopsiesTaken,
      'biopsy_result': record.biopsyResult,
      'provider': record.provider,
      'notes': record.notes,
      'created_at': record.createdAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _pro2ToJson(Pro2SurveyRecord record) {
    return {
      'id': record.id,
      'survey_date': record.surveyDate,
      'disease_type': record.diseaseType,
      'cd_abdominal_pain': record.cdAbdominalPain,
      'cd_stool_frequency': record.cdStoolFrequency,
      'uc_rectal_bleeding': record.ucRectalBleeding,
      'uc_stool_frequency': record.ucStoolFrequency,
      'pro2_score': record.pro2Score,
      'is_flare': record.isFlare,
      'score_version': record.scoreVersion,
      'notes': record.notes,
      'created_at': record.createdAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _flareLabelToJson(FlareLabelRecord record) {
    return {
      'label_date': record.labelDate,
      'inflammatory_flare': record.inflammatoryFlare,
      'symptomatic_flare': record.symptomaticFlare,
      'clinical_flare': record.clinicalFlare,
      'combined_flare': record.combinedFlare,
      'label_source': record.labelSource,
      'confidence': record.confidence,
      'recomputed_at': record.recomputedAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _cosinorToJson(CosinorFeatureRecord record) {
    return {
      'feature_date': record.featureDate,
      'mesor': record.mesor,
      'amplitude': record.amplitude,
      'acrophase_rad': record.acrophaseRad,
      'peak_time_hours': record.peakTimeHours,
      'r_squared': record.rSquared,
      'sample_count': record.sampleCount,
      'time_span_hours': record.timeSpanHours,
      'fit_valid': record.fitValid,
      'recomputed_at': record.recomputedAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _logisticStateToJson(LogisticModelStateRecord record) {
    return {
      'model_key': record.modelKey,
      'horizon_days': record.horizonDays,
      'flare_type': record.flareType,
      'coefficients_json': record.coefficientsJson,
      'intercept': record.intercept,
      'training_samples': record.trainingSamples,
      'last_auc': record.lastAuc,
      'last_f1': record.lastF1,
      'updated_at': record.updatedAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _gemmaTaskRunToJson(GemmaTaskRunRecord record) {
    return {
      'id': record.id,
      'task_type': record.taskType,
      'prompt_version': record.promptVersion,
      'schema_version': record.schemaVersion,
      'model_id': record.modelId,
      'runtime_name': record.runtimeName,
      'status': record.status,
      'used_model_output': record.usedModelOutput,
      'validation_status': record.validationStatus,
      'validation_errors_json': record.validationErrorsJson,
      'input_summary_json': record.inputSummaryJson,
      'output_summary_json': record.outputSummaryJson,
      'output_hash': record.outputHash,
      'latency_ms': record.latencyMs,
      'created_at': record.createdAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _gemmaExtractionReviewToJson(
    GemmaExtractionReviewRecord record,
  ) {
    return {
      'id': record.id,
      'task_run_id': record.taskRunId,
      'review_type': record.reviewType,
      'source_kind': record.sourceKind,
      'source_hash': record.sourceHash,
      'extracted_json': record.extractedJson,
      'user_confirmed_json': record.userConfirmedJson,
      'review_status': record.reviewStatus,
      'created_at': record.createdAt.toUtc().toIso8601String(),
      'confirmed_at': record.confirmedAt?.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _doctorSummaryToJson(DoctorSummaryRecord record) {
    return {
      'id': record.id,
      'task_run_id': record.taskRunId,
      'summary_range_days': record.summaryRangeDays,
      'summary_text': record.summaryText,
      'context_summary_json': record.contextSummaryJson,
      'created_at': record.createdAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _experimentAssignmentToJson(
    ExperimentAssignmentRecord record,
  ) {
    return {
      'experiment_key': record.experimentKey,
      'variant': record.variant,
      'assigned_at': record.assignedAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _experimentEventToJson(ExperimentEventRecord record) {
    return {
      'id': record.id,
      'event_name': record.eventName,
      'experiment_key': record.experimentKey,
      'variant': record.variant,
      'session_id': record.sessionId,
      'metadata_json': record.metadataJson,
      'created_at': record.createdAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _diagnosticLogToJson(DiagnosticLogRecord record) {
    return {
      'id': record.id,
      'created_at': record.createdAt.toUtc().toIso8601String(),
      'session_id': record.sessionId,
      'level': record.level,
      'category': record.category,
      'event_name': record.eventName,
      'message': record.message,
      'metadata_json': record.metadataJson,
      'source': record.source,
    };
  }

  Map<String, Object?> _contextWindowToJson(ContextWindowRecord record) {
    return {
      'id': record.id,
      'date_local': record.dateLocal,
      'start_time_utc': record.startTimeUtc.toUtc().toIso8601String(),
      'end_time_utc': record.endTimeUtc.toUtc().toIso8601String(),
      'context_type': record.contextType,
      'source': record.source,
      'confidence': record.confidence,
      'metadata_json': record.metadataJson,
      'created_at': record.createdAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _dailyContextFeatureToJson(
    DailyContextFeatureRecord record,
  ) {
    return {
      'date_local': record.dateLocal,
      'feature_json': record.featureJson,
      'quality_json': record.qualityJson,
      'recomputed_at': record.recomputedAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _metricRegistryToJson(
    HealthKitMetricRegistryRecord record,
  ) {
    return {
      'metric_key': record.metricKey,
      'healthkit_identifier': record.healthkitIdentifier,
      'normalized_metric_name': record.normalizedMetricName,
      'metric_family': record.metricFamily,
      'availability': record.availability,
      'permission_status': record.permissionStatus,
      'last_successful_import_at':
          record.lastSuccessfulImportAt?.toUtc().toIso8601String(),
      'last_error_kind': record.lastErrorKind,
      'required_for_core_score': record.requiredForCoreScore,
      'used_for_context_only': record.usedForContextOnly,
      'updated_at': record.updatedAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _clinicalImportToJson(
    ClinicalRecordImportRecord record,
  ) {
    return {
      'id': record.id,
      'record_type': record.recordType,
      'source': record.source,
      'effective_date': record.effectiveDate,
      'fhir_resource_type': record.fhirResourceType,
      'fhir_id': record.fhirId,
      'extracted_json': record.extractedJson,
      'import_status': record.importStatus,
      'created_at': record.createdAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _validationRunToJson(ModelValidationRunRecord record) {
    return {
      'id': record.id,
      'run_key': record.runKey,
      'started_at': record.startedAt.toUtc().toIso8601String(),
      'completed_at': record.completedAt?.toUtc().toIso8601String(),
      'status': record.status,
      'dataset_summary_json': record.datasetSummaryJson,
      'notes': record.notes,
    };
  }

  Map<String, Object?> _validationMetricToJson(
    ModelValidationMetricRecord record,
  ) {
    return {
      'id': record.id,
      'run_key': record.runKey,
      'model_version': record.modelVersion,
      'label_type': record.labelType,
      'horizon_days': record.horizonDays,
      'metric_name': record.metricName,
      'metric_value': record.metricValue,
      'metadata_json': record.metadataJson,
      'created_at': record.createdAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _symptomToJson(SymptomRecord record) {
    return {
      'id': record.id,
      'logged_at': record.loggedAt.toUtc().toIso8601String(),
      'symptom_type': record.symptomType,
      'severity': record.severity,
      'duration_minutes': record.durationMinutes,
      'meal_relation': record.mealRelation,
      'notes': record.notes,
      'source_transcript': record.sourceTranscript,
      'extraction_method': record.extractionMethod,
      'extraction_confidence': record.extractionConfidence,
      'created_at': record.createdAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _conversationToJson(ConversationRecord record) {
    return {
      'id': record.id,
      'created_at': record.createdAt.toUtc().toIso8601String(),
      'user_message': record.userMessage,
      'assistant_message': record.assistantMessage,
      'tool_trace_json': record.toolTraceJson,
      'grounded_summary_json': record.groundedSummaryJson,
    };
  }
}
