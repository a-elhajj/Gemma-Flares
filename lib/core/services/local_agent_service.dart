// =============================================================================
// GEMMA 4 HACKATHON — Chat Orchestrator & Intent Router
// =============================================================================
// [LocalAgentService] is the single entry point for every user chat message.
//
// The core design: deterministic code routes, Gemma explains.
//   1. _classifyIntent() maps the user message to one of 17 intent contracts
//      (risk_question, symptom_log_followup, wearable_data_question, etc.)
//      using keyword rules + session state — no model call needed for routing.
//   2. _groundingForIntent() assembles a compact JSON payload (score, symptoms,
//      wearable aggregates, date anchors) for that specific intent — Gemma only
//      sees data relevant to the question.
//   3. buildSystemPrompt() selects the right Gemma 4 prompt from the registry
//      (see prompt_templates.dart) and enforces format rules per intent.
//   4. The LiteRT-LM Gemma 4 E2B model generates a grounded reply.
//   5. _applySafetyEnvelope() appends the safety footer and validates output.
//   6. If Gemma is unavailable, _deterministic*() fallbacks return factual text.
//
// Key safety invariants:
//   - Gemma never computes the risk score (that is risk_engine_service.dart).
//   - Gemma never saves data; all writes require user confirmation.
//   - Urgent symptoms always trigger urgent_safety intent — Gemma is bypassed.
// =============================================================================

import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import '../database/wearable_sample_repository.dart';
import 'rag_corpus_service.dart';
import 'rag_query_service.dart';
import 'rag_text_formatter.dart';
import 'wearable_aggregation_service.dart';
import 'diagnostic_log_service.dart';
import 'gemma_task_service.dart';
import 'ibd_checkin_service.dart';
import 'input_validation_service.dart';
import 'lab_reference_catalog.dart';
import 'llm_output_validator_service.dart';
import 'local_model_runtime.dart';
import 'logistic_risk_service.dart';
import 'medication_logging_service.dart';
import 'profile_service.dart';
import 'prompt_templates.dart' as prompts;
import 'runtime_telemetry_service.dart';
import 'security_hardening_service.dart';
import 'symptom_parser_service.dart';
import 'text_normalization_service.dart';

class LocalAgentReply {
  const LocalAgentReply({
    required this.status,
    required this.message,
    required this.runtimeName,
    required this.toolTraceJson,
    required this.groundedSummaryJson,
    this.pendingAction,
  });

  final String status;
  final String message;
  final String runtimeName;
  final Map<String, Object?> toolTraceJson;
  final Map<String, Object?> groundedSummaryJson;
  final ChatPendingAction? pendingAction;
}

class ChatPendingAction {
  const ChatPendingAction({
    required this.type,
    required this.payloadJson,
    this.reviewId,
    this.confidence,
  });

  final String type;
  final int? reviewId;
  final Map<String, Object?> payloadJson;
  final double? confidence;
}

enum _DataRichness { none, sparse, rich }

class _RagContextBuildResult {
  const _RagContextBuildResult({
    required this.snippets,
    required this.expectedSourceTypes,
    required this.providedSourceTypes,
    required this.duplicateCountRemoved,
    required this.realChunkCount,
    required this.structuredFallbackCount,
  });

  final List<Map<String, Object?>> snippets;
  final Set<String> expectedSourceTypes;
  final Set<String> providedSourceTypes;
  final int duplicateCountRemoved;
  final int realChunkCount;
  final int structuredFallbackCount;

  bool get realRagUsed => realChunkCount > 0;
  bool get fallbackUsed => structuredFallbackCount > 0;
}

enum _ChatTaskContract {
  healthSummary,
  // forecastWatchlist: forward-looking early warning signals and action items.
  // Grounded on early_warning_outlook + HRV trend + check-in trajectory.
  // Deliberately separate from healthSummary so "What should I watch?" and
  // "Check my flare risk" produce distinct, non-overlapping outputs.
  forecastWatchlist,
  memoryLedger,
  labRecall,
  // labGemmaExplain: bypasses the deterministic _latestLabsSummary() fast path
  // so Gemma 4 receives the saved lab rows as grounding and explains them in
  // clinical Gemma Flares voice. Same grounding as labRecall; different routing.
  labGemmaExplain,
  symptomList,
  startCheckIn,
  appleWatchReview,
  ragRecall,
  doctorSummary,
  ibdKnowledge,
  safety,
  general,
  // New starter prompt contracts
  medicationNote,
  foodTrigger,
  hrvTrend,
  activityPattern,
  prepForVisit,
  // symptomExplanation: causal/explanatory questions about specific symptoms
  // ("why am I so bloated", "what causes my migraine"). Grounded on recent
  // symptom logs + RAG IBD knowledge to contextualize the symptom in user's data.
  symptomExplanation,
}

class _ChatToolResult {
  const _ChatToolResult({
    required this.toolName,
    required this.status,
    required this.rowCount,
    required this.sourceTables,
    required this.usedForAnswer,
    this.dataFreshness,
    this.error,
    this.redactedPreview,
    this.evidenceHash,
  });

  final String toolName;
  final String status;
  final int rowCount;
  final List<String> sourceTables;
  final bool usedForAnswer;
  final String? dataFreshness;
  final String? error;
  final String? redactedPreview;
  final String? evidenceHash;

  Map<String, Object?> toJson() => {
        'tool_name': toolName,
        'status': status,
        'row_count': rowCount,
        'source_tables': sourceTables,
        'used_for_answer': usedForAnswer,
        if (dataFreshness != null) 'data_freshness': dataFreshness,
        if (error != null) 'error': error,
        if (redactedPreview != null) 'redacted_preview': redactedPreview,
        if (evidenceHash != null) 'evidence_hash': evidenceHash,
      };
}

class _LatestLabExplainContext {
  const _LatestLabExplainContext({
    required this.lab,
    required this.askedAtUtc,
    this.ragTransactionId,
    this.ragTransactionStatus,
    this.ragTransactionIndexedAt,
    this.ragExtractSnippet,
  });

  final Map<String, Object?> lab;
  final String askedAtUtc;
  final String? ragTransactionId;
  final String? ragTransactionStatus;
  final String? ragTransactionIndexedAt;
  final String? ragExtractSnippet;

  Map<String, Object?> toJson() => {
        'lab': lab,
        'asked_at_utc': askedAtUtc,
        if (ragTransactionId != null) 'rag_transaction_id': ragTransactionId,
        if (ragTransactionStatus != null)
          'rag_transaction_status': ragTransactionStatus,
        if (ragTransactionIndexedAt != null)
          'rag_transaction_indexed_at': ragTransactionIndexedAt,
        if (ragExtractSnippet != null) 'rag_extract_snippet': ragExtractSnippet,
      };
}

class _ChatSessionTurn {
  const _ChatSessionTurn({
    required this.userMessage,
    required this.assistantMessage,
    required this.intent,
  });

  final String userMessage;
  final String assistantMessage;
  final String intent;
}

class _ChatSessionState {
  const _ChatSessionState({
    required this.startedAt,
    required this.lastUsedAt,
    required this.turns,
    required this.rollingSummary,
    required this.awaitingSymptomIntake,
    required this.symptomIntakeClarifierCount,
    required this.symptomIntakeNonHealthCount,
    required this.awaitingGiSummaryDates,
    this.activeRuntimeProfile,
    this.activeTopic,
  });

  final DateTime startedAt;
  final DateTime lastUsedAt;
  final List<_ChatSessionTurn> turns;
  final String rollingSummary;
  final bool awaitingSymptomIntake;
  final int symptomIntakeClarifierCount;
  // Counts consecutive non-health inputs during an active symptom intake session.
  // Triggers progressive rejection messages; resets on session exit or health input.
  final int symptomIntakeNonHealthCount;
  // True when the agent has asked the user for a GI summary date range and
  // is waiting for their reply (typed or spoken).
  final bool awaitingGiSummaryDates;
  final String? activeRuntimeProfile;
  final String? activeTopic;

  _ChatSessionState copyWith({
    DateTime? startedAt,
    DateTime? lastUsedAt,
    List<_ChatSessionTurn>? turns,
    String? rollingSummary,
    bool? awaitingSymptomIntake,
    int? symptomIntakeClarifierCount,
    int? symptomIntakeNonHealthCount,
    bool? awaitingGiSummaryDates,
    String? activeRuntimeProfile,
    String? activeTopic,
  }) {
    return _ChatSessionState(
      startedAt: startedAt ?? this.startedAt,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      turns: turns ?? this.turns,
      rollingSummary: rollingSummary ?? this.rollingSummary,
      awaitingSymptomIntake:
          awaitingSymptomIntake ?? this.awaitingSymptomIntake,
      symptomIntakeClarifierCount:
          symptomIntakeClarifierCount ?? this.symptomIntakeClarifierCount,
      symptomIntakeNonHealthCount:
          symptomIntakeNonHealthCount ?? this.symptomIntakeNonHealthCount,
      awaitingGiSummaryDates:
          awaitingGiSummaryDates ?? this.awaitingGiSummaryDates,
      activeRuntimeProfile: activeRuntimeProfile ?? this.activeRuntimeProfile,
      activeTopic: activeTopic ?? this.activeTopic,
    );
  }
}

class LocalAgentService {
  LocalAgentService({
    required WearableSampleRepository repository,
    required LocalModelRuntime runtime,
    RagQueryService? ragQueryService,
    RagCorpusService? ragCorpusService,
    ProfileService? profileService,
    DiagnosticLogService? diagnosticLogService,
    GemmaTaskService? gemmaTaskService,
    RuntimeTelemetryService? runtimeTelemetryService,
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _runtime = runtime,
        _ragQueryService = ragQueryService,
        _ragCorpusService = ragCorpusService,
        _profileService = profileService,
        _diagnosticLogService = diagnosticLogService,
        _gemmaTaskService = gemmaTaskService,
        _runtimeTelemetryService = runtimeTelemetryService,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final WearableSampleRepository _repository;
  final LocalModelRuntime _runtime;
  final RagCorpusService? _ragCorpusService;
  final RagQueryService? _ragQueryService;
  final ProfileService? _profileService;
  final DiagnosticLogService? _diagnosticLogService;
  final GemmaTaskService? _gemmaTaskService;
  final RuntimeTelemetryService? _runtimeTelemetryService;
  final DateTime Function() _nowProvider;
  late final WearableAggregationService _wearableAgg =
      WearableAggregationService(_repository);
  static const _sessionIdleTimeout = Duration(minutes: 20);
  static const _maxSessionTurns = 6;
  static const _maxSymptomClarifierRetries = 2;
  static const _defaultRagTransactionLimit = 12;
  static const _presetRagTransactionLimit = 128;
  static const _defaultRagSnippetLimit = 3;
  static const _presetRagSnippetLimit = 10;
  // Maximum total rendered chars of DB-sourced history injected into the user
  // prompt.  Each turn is clipped to 160+260=420 chars, so 5000 chars allows
  // up to ~11 full turns before the budget is exhausted (~1250 prompt tokens).
  // This keeps on-device context-window usage bounded regardless of how many
  // turns are stored in the DB.
  static const _kHistoryCharBudget = 5000;
  _ChatSessionState? _sessionState;

  // Tracks which disclaimer keys have already been shown this session so the
  // same generic notice never appears more than once per conversation.
  final Set<String> _deliveredDisclaimers = {};
  final Map<String, String> _labExplainResponseCache = {};
  static const _labExplainCachePromptVersion = 'lab_explain_cache_v1';
  static const _labExplainCacheLocale = 'en-US';
  static const _labExplainCacheAppVersion = 'gemma_flares_local_v1';

  Future<void> resetSession({String reason = 'manual'}) async {
    _sessionState = null;
    _deliveredDisclaimers.clear();
    _labExplainResponseCache.clear();
    await _diagnosticLogService?.info(
      'chat_session_reset',
      category: DiagnosticLogService.categoryChat,
      message: 'Local chat session state was cleared.',
      metadata: {'reason': reason},
    );
  }

  Future<LocalAgentReply> ask(String userMessage) async {
    final now = _nowProvider();

    // ═══════════════════════════════════════════════════════════════════════
    // PRODUCTION HARDENING: Input Validation & Security
    // ═══════════════════════════════════════════════════════════════════════

    // Edge case 135: Empty or whitespace-only input
    if (userMessage.trim().isEmpty) {
      return LocalAgentReply(
        status: 'validation_error',
        message: 'Please enter a message to continue.',
        runtimeName: 'validation',
        toolTraceJson: {'error': 'empty_input'},
        groundedSummaryJson: const {},
      );
    }

    // Edge case 136: Input validation (length, format, control characters)
    final validationResult = InputValidationService.validateChatMessage(
      userMessage,
    );
    String sanitizedMessage = userMessage;

    if (!validationResult.isValid) {
      // Edge case 137: Invalid input - return helpful error
      return LocalAgentReply(
        status: 'validation_error',
        message: validationResult.errors.first,
        runtimeName: 'validation',
        toolTraceJson: {
          'errors': validationResult.errors,
          'warnings': validationResult.warnings,
        },
        groundedSummaryJson: const {},
      );
    }

    // Edge case 138: Input has warnings (truncated, cleaned) - use sanitized version
    if (validationResult.hasWarnings) {
      sanitizedMessage = validationResult.sanitizedValue;
      await _diagnosticLogService?.warning(
        'input_sanitized',
        category: DiagnosticLogService.categoryChat,
        message: 'User input sanitized',
        metadata: {
          'warnings': validationResult.warnings,
          'originalLength': userMessage.length,
          'sanitizedLength': sanitizedMessage.length,
        },
      );
    }

    // Edge case 139: Security validation (PII, prompt injection, content policy)
    final securityResult = SecurityHardeningService.validateInput(
      sanitizedMessage,
    );

    if (securityResult.hasViolations) {
      // Edge case 140: Critical security violation - block input
      final criticalViolations = securityResult.violations
          .where((v) => v.severity == 'critical')
          .toList();

      if (criticalViolations.isNotEmpty) {
        await _diagnosticLogService?.error(
          'security_violation',
          category: DiagnosticLogService.categoryChat,
          message: 'Critical security violation detected',
          metadata: {
            'violations': criticalViolations.map((v) => v.type).toList(),
          },
        );

        return LocalAgentReply(
          status: 'security_violation',
          message: 'For your safety, this message cannot be processed. '
              '${criticalViolations.first.recommendation ?? "Please rephrase and try again."}',
          runtimeName: 'security',
          toolTraceJson: {
            'violations': criticalViolations.map((v) => v.type).toList(),
          },
          groundedSummaryJson: const {},
        );
      }
    }

    // Edge case 141: PII detected - use redacted version
    if (securityResult.wasRedacted) {
      sanitizedMessage = securityResult.sanitizedValue ?? sanitizedMessage;
      await _diagnosticLogService?.warning(
        'pii_redacted',
        category: DiagnosticLogService.categoryChat,
        message: 'PII redacted from input',
        metadata: {'redactedItems': securityResult.redactedItems},
      );
    }

    // Edge case 142: Security warnings (non-blocking) - log for review
    if (securityResult.hasWarnings) {
      await _diagnosticLogService?.warning(
        'security_warnings',
        category: DiagnosticLogService.categoryChat,
        message: 'Security warnings detected',
        metadata: {'warnings': securityResult.warnings},
      );
    }

    // Continue with sanitized, validated, secure input
    final lower = sanitizedMessage.toLowerCase();
    final promptPreset = prompts.presetForUserText(sanitizedMessage);

    // ── Zero-DB fast paths ────────────────────────────────────────────────────
    // These paths return without touching SQLite. Intent classification is
    // purely string-based; session state is already in memory.
    // Order matters: IBD-knowledge check must precede doctor-summary so that
    // "how do I prepare for a Crohn appointment?" routes to education, not export.

    var session = _ensureSession(now);

    // Classify intent before any DB I/O so bare-log and other zero-data paths
    // can return immediately without loading 17 result sets they will ignore.
    final intent = _classifyIntent(lower);

    // BUG: when an intake session is open (GI summary date prompt or symptom
    // intake), an incoming preset chip used to be eaten by the intake's input
    // parser — e.g. tapping "What should I watch?" while awaitingGiSummaryDates
    // was true got interpreted as a date string and re-prompted. Preset chips
    // are explicit navigation intent and must always supersede in-progress
    // intake sessions. Discard the pending intake silently (no save — intake
    // state is in-memory only) so downstream handlers see a clean session.
    if (promptPreset != null &&
        (session.awaitingGiSummaryDates || session.awaitingSymptomIntake)) {
      session = session.copyWith(
        awaitingSymptomIntake: false,
        symptomIntakeClarifierCount: 0,
        awaitingGiSummaryDates: false,
        activeTopic: null,
      );
      _sessionState = session;
    }

    // ── GI Summary date gate ─────────────────────────────────────────────────
    // Fires for ALL GI summary requests — typed, preset, or voice — so the
    // user always picks a date range before generation runs.
    // Also consumes follow-up date replies when awaitingGiSummaryDates is set.
    if (_gemmaTaskService != null &&
        !_isIbdKnowledgeRequest(lower) &&
        !_isDailySummaryRequest(lower)) {
      // Phase 2: user is responding to the date prompt we already sent.
      if (session.awaitingGiSummaryDates) {
        if (_isCancelLike(lower)) {
          return await _giSummaryCancelledReply(
              userMessage: sanitizedMessage, now: now);
        }
        if (_isGiSummaryAllRequest(lower)) {
          return await _doctorSummaryReply(
              userMessage: sanitizedMessage, now: now, allDates: true);
        }
        if (_isGiSummaryDefaultRequest(lower)) {
          return await _doctorSummaryReply(
              userMessage: sanitizedMessage, now: now);
        }
        final parsed = _parseGiDateRange(sanitizedMessage, now);
        if (parsed != null) {
          return await _doctorSummaryReply(
            userMessage: sanitizedMessage,
            now: now,
            startDate: parsed.$1,
            endDate: parsed.$2,
          );
        }
        // Couldn't recognise — re-prompt with format hint.
        return await _giSummaryDateRetryReply(
            userMessage: sanitizedMessage, now: now);
      }

      // Phase 1: new GI summary request (typed or via preset).
      if (_isDoctorSummaryRequest(lower) || intent == 'doctor_summary') {
        // Inline dates? e.g. "I need a GI summary from May 1 to May 15"
        final inlineDates = _parseGiDateRange(sanitizedMessage, now);
        if (inlineDates != null) {
          return await _doctorSummaryReply(
            userMessage: sanitizedMessage,
            now: now,
            startDate: inlineDates.$1,
            endDate: inlineDates.$2,
          );
        }
        // No dates — ask for them.
        return await _giSummaryDatePromptReply(
            userMessage: sanitizedMessage, now: now);
      }
    }

    // BUG-081: If a preset was matched while symptom intake is pending, the
    // user's explicit navigation supersedes the pending intake. Discard the
    // intake silently (no phantom save — nothing was persisted yet, intake
    // state lives only in-memory) so that downstream handlers see a clean
    // session and route to the preset's intent without re-trapping.
    if (promptPreset != null && session.awaitingSymptomIntake) {
      session = session.copyWith(
        awaitingSymptomIntake: false,
        symptomIntakeClarifierCount: 0,
        activeTopic: null,
      );
      _sessionState = session;
    }

    // If the user is in the symptom-intake clarifier loop (awaitingSymptomIntake)
    // and explicitly cancels, exit deterministically instead of falling through
    // to unrelated summaries or LLM paths.
    if (session.awaitingSymptomIntake && _isCancelLike(lower)) {
      const message = 'Cancelled. I did not save anything.';
      final trace = <String, Object?>{
        'agent_intent': 'symptom_intake_cancel',
        'intent_raw': sanitizedMessage,
        'intent_normalized': intent,
        'used_model_output': false,
        'deterministic_fast_path_used': true,
        'chat_path': 'symptom_intake_cancel',
        'asked_at': now.toIso8601String(),
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: sanitizedMessage,
          assistantMessage: message,
          toolTraceJson: trace,
          groundedSummaryJson: const {},
        ),
      );
      _recordSessionTurn(
        userMessage: sanitizedMessage,
        assistantMessage: message,
        intent: 'symptom_log_followup',
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
        activeTopic: 'symptom_intake_cancelled',
        awaitingSymptomIntake: false,
        symptomIntakeClarifierCount: 0,
      );
      return LocalAgentReply(
        status: 'deterministic_symptom_intake_cancelled',
        message: message,
        runtimeName: 'deterministic',
        toolTraceJson: trace,
        groundedSummaryJson: const {},
      );
    }

    // Bare symptom log command ("Log a symptom" with no symptom content):
    // return the intake prompt without any DB context so Gemma never sees
    // recent_symptoms and produces an empathetic preamble instead of the form.
    if (intent == 'symptom_log_followup' && _isBareSymptomLogRequest(lower)) {
      const intakePrompt =
          'Please describe the symptom you are experiencing. Include:\n'
          '• **Symptom:** What is it?\n'
          '• **Frequency:** How often?\n'
          '• **Trigger:** What causes it?\n'
          '• **Duration:** How long does it last?\n\n'
          "I'll build a review card before saving anything.";
      final minimalTrace = <String, Object?>{
        'agent_intent': intent,
        'intent_raw': sanitizedMessage,
        'intent_normalized': intent,
        if (promptPreset != null) 'prompt_preset_id': promptPreset.id,
        if (promptPreset != null) 'prompt_preset_label': promptPreset.label,
        if (promptPreset != null)
          'prompt_preset_contract': promptPreset.taskContract,
        if (promptPreset != null) 'prompt_preset_route': promptPreset.taskRoute,
        'used_model_output': false,
        'deterministic_fast_path_used': true,
        'chat_path': 'bare_symptom_intake_prompt',
        'asked_at': now.toIso8601String(),
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: sanitizedMessage,
          assistantMessage: intakePrompt,
          toolTraceJson: minimalTrace,
          groundedSummaryJson: const {},
        ),
      );
      _recordSessionTurn(
        userMessage: sanitizedMessage,
        assistantMessage: intakePrompt,
        intent: intent,
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
        activeTopic: 'symptom_intake_pending',
        awaitingSymptomIntake: true,
      );
      return LocalAgentReply(
        status: 'deterministic_bare_symptom_intake',
        message: intakePrompt,
        runtimeName: 'deterministic',
        toolTraceJson: minimalTrace,
        groundedSummaryJson: const {},
      );
    }

    // ── Full context load ─────────────────────────────────────────────────────
    // Only reached when none of the zero-DB fast paths apply.

    final todayDate = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';

    final ragTransactionLimit = _ragTransactionLimitFor(
      intent: intent,
      hasPreset: promptPreset != null,
    );

    // Load all context in parallel
    final futures = await Future.wait([
      _repository.getLatestUserFacingFlareRiskScore(), // 0
      _repository.getLatestDailySummary(), // 1
      _repository.getDailySummaries(limit: 7), // 2
      _repository.getRecentSymptoms(limit: 5), // 3
      _repository.getRecentConversations(limit: 20), // 4
      _repository.getCosinorFeature(todayDate), // 5
      _repository.getFlareLabel(todayDate), // 6
      _repository.getRecentPro2Surveys(limit: 7), // 7
      _repository.getLabValues(), // 8
      _repository.getAllLogisticModelStates(), // 9
      _profileService?.getGroundedSummary() ??
          Future.value(const <String, Object?>{}), // 10
      _repository.getEndoscopyRecords(), // 11
      _repository.getDailyFeatureForDate(todayDate), // 12
      _repository.getCosinorFeaturesInRange(
        _offsetDate(todayDate, -7),
        todayDate,
      ), // 13
      _repository.getDailyContextFeatureForDate(todayDate), // 14
      _repository.getRagMemoryTransactions(limit: ragTransactionLimit), // 15
      _repository.getGemmaExtractionReviews(
        reviewType: 'lab_text_extract',
        limit: 3,
      ), // 16
    ]);

    final latestScore = futures[0] as FlareRiskScoreRecord?;
    final latestSummary = futures[1] as DailySummaryRecord?;
    final recentSummaries = futures[2] as List<DailySummaryRecord>;
    final recentSymptoms = futures[3] as List<SymptomRecord>;
    final recentConversations = futures[4] as List<ConversationRecord>;
    final latestCosinor = futures[5] as CosinorFeatureRecord?;
    final latestFlareLabel = futures[6] as FlareLabelRecord?;
    final recentPro2 = futures[7] as List<Pro2SurveyRecord>;
    final allLabs = futures[8] as List<LabValueRecord>;
    final modelStates = futures[9] as List<LogisticModelStateRecord>;
    final profileSummary = futures[10] as Map<String, Object?>;
    final procedures = futures[11] as List<EndoscopyRecord>;
    final todayFeatures = futures[12] as DailyFeatureRecord?;
    final recentCosinor = futures[13] as List<CosinorFeatureRecord>;
    final todayContext = futures[14] as DailyContextFeatureRecord?;
    final ragTransactions = futures[15] as List<RagMemoryTransactionRecord>;
    final recentLabReviews = futures[16] as List<GemmaExtractionReviewRecord>;

    // Best logistic model AUC for context (inflammatory 7d horizon)
    final best7dModel = modelStates
        .where((m) => m.horizonDays == 7 && m.flareType == 'inflammatory')
        .firstOrNull;
    final latestProcedure = procedures.isEmpty ? null : procedures.first;
    final checkInTrend = _buildCheckInTrend(recentPro2);
    final heartRhythmContext = _buildHeartRhythmContext(
      latestCosinor: latestCosinor,
      recentCosinor: recentCosinor,
    );
    final outlook = _buildOutlook(
      modelStates: modelStates,
      todayFeatures: todayFeatures,
    );
    final requestedSummaryWindow = _requestedSummaryWindow(lower);
    final summaryWindowRollups = _buildSummaryWindowRollups(
      todayDate: todayDate,
      dailySummaries: recentSummaries,
      symptoms: recentSymptoms,
      checkIns: recentPro2,
      labs: allLabs,
      procedures: procedures,
      ragTransactions: ragTransactions,
    );

    final groundedSummaryJson = <String, Object?>{
      'latest_score': latestScore == null
          ? null
          : {
              'date_local': latestScore.dateLocal,
              'risk_score': latestScore.riskScore.round(),
              'risk_band': latestScore.riskBand,
              'confidence_score': latestScore.confidenceScore.round(),
              'contributions': latestScore.contributionJson,
            },
      'latest_summary': latestSummary?.summaryJson,
      'recent_daily_summaries': recentSummaries
          .take(14)
          .map(
            (item) => {
              'date_local': item.dateLocal,
              'summary': item.summaryJson,
            },
          )
          .toList(growable: false),
      'context_attribution': todayContext?.featureJson,
      'recent_summary_dates':
          recentSummaries.map((item) => item.dateLocal).toList(growable: false),
      'recent_symptoms': recentSymptoms
          .map(
            (item) => {
              'id': item.id,
              'logged_at': item.loggedAt.toUtc().toIso8601String(),
              'symptom_type': item.symptomType,
              'severity': item.severity,
              'duration_minutes': item.durationMinutes,
              'meal_relation': item.mealRelation,
              'notes': item.notes,
              'source_transcript': item.sourceTranscript,
            },
          )
          .toList(growable: false),
      'recent_conversation_turns': recentConversations
          .map(
            (item) => {
              'created_at': item.createdAt.toUtc().toIso8601String(),
              'user_message': item.userMessage,
              'assistant_message': item.assistantMessage,
            },
          )
          .toList(growable: false),
      // Paper replication context — circadian HRV rhythm (Cosinor model)
      'hrv_circadian_rhythm': heartRhythmContext,
      // Ground-truth flare status from lab + PRO-2
      'flare_label_today': latestFlareLabel == null
          ? 'none'
          : {
              'inflammatory_flare': latestFlareLabel.inflammatoryFlare,
              'symptomatic_flare': latestFlareLabel.symptomaticFlare,
              'clinical_flare': latestFlareLabel.clinicalFlare,
              'combined_flare': latestFlareLabel.combinedFlare,
              'label_source': latestFlareLabel.labelSource,
              'confidence': latestFlareLabel.confidence,
            },
      // Recent PRO-2 clinical scores
      'recent_pro2_surveys': recentPro2
          .map(IbdCheckInService.evidenceForSurvey)
          .toList(growable: false),
      'checkin_trend_7d': checkInTrend,
      'checkin_summary_7d': IbdCheckInService.sevenDaySummary(recentPro2),
      // Lab biomarker results (CRP, ESR, FC)
      'lab_results': allLabs
          .take(5)
          .map(
            (l) => {
              'drawn_date': l.drawnDate,
              'lab_type': l.labType,
              'lab_label': _labDisplayName(l.labType),
              'value': l.valueNumeric,
              'unit': l.unit,
              'lab_name': l.labName,
              'ordering_provider': l.orderingProvider,
              'elevated': l.valueNumeric > (l.referenceHigh ?? double.infinity),
            },
          )
          .toList(growable: false),
      'latest_procedure': latestProcedure == null
          ? null
          : {
              'procedure_date': latestProcedure.procedureDate,
              'procedure_type': latestProcedure.procedureType,
              'summary': _procedureSummary(latestProcedure),
              'provider': latestProcedure.provider,
            },
      'rag_memory_transactions': ragTransactions
          .map(
            (row) => {
              'transaction_id': row.transactionId,
              'source_type': row.sourceType,
              'status': row.status,
              'indexed_at': row.indexedAt?.toUtc().toIso8601String(),
              'verified_at': row.verifiedAt?.toUtc().toIso8601String(),
            },
          )
          .toList(growable: false),
      'recent_lab_reviews': recentLabReviews
          .map(
            (row) => {
              'id': row.id,
              'review_status': row.reviewStatus,
              'created_at': row.createdAt.toUtc().toIso8601String(),
              'candidate_count':
                  ((row.extractedJson['labs'] as List?) ?? const []).length,
            },
          )
          .toList(growable: false),
      'early_warning_outlook': outlook,
      'global_flare_risk': _globalFlareRiskState(
        latestScore: latestScore,
        outlook: outlook,
      ),
      // Logistic model training status
      'logistic_model_status': best7dModel == null
          ? 'not_started'
          : {
              'training_samples': best7dModel.trainingSamples,
              'last_auc': best7dModel.lastAuc?.toStringAsFixed(3),
              'last_f1': best7dModel.lastF1?.toStringAsFixed(3),
              'min_samples_for_predictions':
                  LogisticPrediction.minimumTrainingSamples,
              'ready': best7dModel.trainingSamples >=
                  LogisticPrediction.minimumTrainingSamples,
            },
      'chat_session_summary': session.rollingSummary,
      'user_profile': profileSummary,
      'requested_summary_window': requestedSummaryWindow,
      'summary_window_rollups': summaryWindowRollups,
    };
    // intent and promptPreset are already resolved above (before DB queries).

    // Wearable data questions and PR #11 trend starters need per-metric daily
    // aggregates from SQLite. Without this, HRV/activity starter prompts drift
    // into generic risk prose even though the UI advertises structured tools.
    if (intent == 'wearable_data_question' ||
        intent == 'hrv_trend_analysis' ||
        intent == 'activity_pattern_analysis') {
      final wearableAggregates = await _repository.getWearableMetricAggregates(
        days: 14,
        now: _nowProvider(),
      );
      groundedSummaryJson['wearable_metric_aggregates'] = wearableAggregates;
    }

    // Resolve the task contract from message text, then allow the preset to
    // override when it declares a specific contract that cannot be inferred
    // from message text alone (e.g. 'labGemmaExplain' vs 'labRecall' for the
    // same "lab_question" intent text "Explain my labs").
    var taskContract = _resolveTaskContract(
      lower: lower,
      intent: intent,
      presetContractName: promptPreset?.taskContract,
    );
    if ((intent == 'continuation' || intent == 'followup_expand') &&
        session.activeTopic == 'lab_review') {
      // Keep "explain more" anchored to the current lab explanation thread
      // instead of drifting into a generic continuation response.
      taskContract = _ChatTaskContract.labGemmaExplain;
    }
    if (intent == 'continuation') {
      taskContract = switch (session.activeTopic) {
        'food_trigger_analysis' => _ChatTaskContract.foodTrigger,
        'activity_pattern_analysis' => _ChatTaskContract.activityPattern,
        'hrv_trend_analysis' => _ChatTaskContract.hrvTrend,
        'medication_context' => _ChatTaskContract.medicationNote,
        'visit_preparation' => _ChatTaskContract.prepForVisit,
        _ => taskContract,
      };
    }
    if (intent == 'lab_question' &&
        taskContract == _ChatTaskContract.labRecall &&
        _isLabDetailFollowup(lower) &&
        allLabs.isNotEmpty) {
      taskContract = _ChatTaskContract.labGemmaExplain;
    }
    final latestLabExplainContext =
        taskContract == _ChatTaskContract.labGemmaExplain
            ? await _latestLabExplainContext(
                labs: allLabs,
                ragTransactions: ragTransactions,
              )
            : null;
    if (latestLabExplainContext != null) {
      groundedSummaryJson['latest_lab_explain'] =
          latestLabExplainContext.toJson();
    }
    final groundingIntent = intent == 'continuation'
        ? switch (session.activeTopic) {
            'food_trigger_analysis' => 'food_trigger_analysis',
            'activity_pattern_analysis' => 'activity_pattern_analysis',
            'hrv_trend_analysis' => 'hrv_trend_analysis',
            'medication_context' => 'medication_context',
            'visit_preparation' => 'visit_preparation',
            _ => intent,
          }
        : intent;
    final ragContext = await _buildRagContextSnippets(
      intent: groundingIntent,
      taskContract: taskContract,
      ragTransactions: ragTransactions,
      grounding: groundedSummaryJson,
      hasPreset: promptPreset != null,
      userQuery: userMessage,
    );
    final ragContextSnippets = ragContext.snippets;
    if (ragContextSnippets.isNotEmpty) {
      groundedSummaryJson['rag_context_snippets'] = ragContextSnippets;
    }
    final modelGroundingJson = _groundingForIntent(
      groundingIntent,
      groundedSummaryJson,
    );
    final globalFlareRisk =
        modelGroundingJson['global_flare_risk'] as Map<String, Object?>?;
    final toolTraceJson = <String, Object?>{
      'agent_intent': intent,
      'intent_raw': userMessage,
      'intent_normalized': intent,
      'classifier_reason': _classifierReasonForTrace(
        intent: intent,
        lower: lower,
        session: session,
        taskContract: taskContract,
      ),
      'classifier_priority_order': const [
        'urgent_safety',
        'active_pending_flow',
        'gi_summary_date_followup',
        'confirmed_write_or_review_actions',
        'symptom_logging',
        'medication_context',
        'lab_intake_or_recall',
        'check_in',
        'summary_or_report',
        'personal_data_questions',
        'ibd_education',
        'app_meta',
        'off_topic_redirect',
      ],
      'active_dialog_state': _dialogStateForTrace(session),
      'selected_contract': taskContract.name,
      if (promptPreset != null) 'prompt_preset_id': promptPreset.id,
      if (promptPreset != null) 'prompt_preset_label': promptPreset.label,
      if (promptPreset != null)
        'prompt_preset_contract': promptPreset.taskContract,
      if (promptPreset != null) 'prompt_preset_route': promptPreset.taskRoute,
      'task_contract': taskContract.name,
      'contract_route': _contractRouteName(taskContract),
      'tools_called': _toolsForContract(taskContract, intent),
      'tool_results': _toolResultsForIntent(intent, modelGroundingJson),
      'tool_contract_results': _contractToolResults(
        taskContract,
        modelGroundingJson,
      ).map((result) => result.toJson()).toList(growable: false),
      'structured_sources_used': _structuredSourcesForContract(taskContract),
      'rag_query_required': _ragRequiredForContract(taskContract),
      'rag_query_performed': ragContext.realRagUsed,
      'rag_retrieved_count': ragContext.realChunkCount,
      'rag_context_snippet_count': ragContextSnippets.length,
      'rag_sources_expected': ragContext.expectedSourceTypes.toList()..sort(),
      'rag_sources_provided': ragContext.providedSourceTypes.toList()..sort(),
      'rag_fallback_used': ragContext.fallbackUsed,
      'rag_fallback_source': ragContext.fallbackUsed
          ? (ragContext.realRagUsed
              ? 'rag_plus_structured_db'
              : 'structured_db')
          : 'none',
      'rag_duplicate_count_removed': ragContext.duplicateCountRemoved,
      'user_facing_risk_status': globalFlareRisk?['status'],
      'user_facing_risk_display_text': globalFlareRisk?['display_text'],
      'user_facing_risk_date_local': globalFlareRisk?['date_local'],
      'user_facing_risk_source_table': globalFlareRisk?['source_table'],
      'rag_transaction_ids_used': ragContextSnippets
          .map((row) => row['transaction_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toList(growable: false),
      'rag_write_expected_after_confirmation':
          _ragWriteExpectedAfterConfirmation(taskContract),
      'model_allowed_claims': _allowedClaimsForContract(taskContract),
      'model_forbidden_claims': _forbiddenClaimsForContract(taskContract),
      if (latestLabExplainContext?.ragTransactionId != null)
        'latest_lab_rag_transaction_id':
            latestLabExplainContext!.ragTransactionId,
      'response_grounding_status': 'pending',
      'rejection_reason': null,
      'asked_at': now.toIso8601String(),
    };

    final symptomListReply = intent == 'symptom_question' &&
            taskContract != _ChatTaskContract.ibdKnowledge &&
            _isSymptomListRequest(userMessage.toLowerCase())
        ? _savedSymptomsSummary(recentSymptoms)
        : null;
    if (symptomListReply != null) {
      final message = GemmaFlaresVoicePolicy.polish(
        _applySafetyEnvelope(symptomListReply, userMessage),
        userMessage: userMessage,
      );
      final trace = {
        ...toolTraceJson,
        'used_model_output': false,
        'deterministic_fast_path_used': true,
        'chat_path': 'saved_symptom_list',
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: userMessage,
          assistantMessage: message,
          toolTraceJson: trace,
          groundedSummaryJson: modelGroundingJson,
        ),
      );
      _recordSessionTurn(
        userMessage: userMessage,
        assistantMessage: message,
        intent: intent,
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
        awaitingSymptomIntake: false,
      );
      return LocalAgentReply(
        status: 'deterministic_symptom_list',
        message: message,
        runtimeName: 'deterministic',
        toolTraceJson: trace,
        groundedSummaryJson: modelGroundingJson,
      );
    }

    // NOTE: bare symptom log fast-path is now handled before the DB query block
    // above (zero-DB path). If we reach here, the message has symptom content.

    if (taskContract == _ChatTaskContract.ibdKnowledge) {
      final message = GemmaFlaresVoicePolicy.polish(
        _applySafetyEnvelope(
          _ibdKnowledgeReply(userMessage.toLowerCase()),
          userMessage,
        ),
        userMessage: userMessage,
      );
      final trace = {
        ...toolTraceJson,
        'used_model_output': false,
        'deterministic_fast_path_used': true,
        'chat_path': 'ibd_knowledge',
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: userMessage,
          assistantMessage: message,
          toolTraceJson: trace,
          groundedSummaryJson: modelGroundingJson,
        ),
      );
      _recordSessionTurn(
        userMessage: userMessage,
        assistantMessage: message,
        intent: intent,
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
        awaitingSymptomIntake: false,
      );
      return LocalAgentReply(
        status: 'deterministic_ibd_knowledge',
        message: message,
        runtimeName: 'deterministic',
        toolTraceJson: trace,
        groundedSummaryJson: modelGroundingJson,
      );
    }

    final pendingMedicationAction = intent == 'medication_log'
        ? await _pendingMedicationActionFor(
            userMessage: userMessage,
            loggedAt: now,
          )
        : null;

    var pendingSymptomAction = pendingMedicationAction == null &&
            (_allowsSymptomPendingAction(intent) ||
                session.awaitingSymptomIntake) &&
            !_contractSuppressesSymptomDraft(taskContract)
        ? await _pendingSymptomActionFor(
            userMessage: userMessage,
            loggedAt: now,
            session: session,
          )
        : null;
    final pendingLabAction = pendingSymptomAction == null &&
            pendingMedicationAction == null
        ? await _pendingLabActionFor(userMessage: userMessage, intent: intent)
        : null;
    // Cheap gibberish guard: random keystrokes like "bdyagayauHb" must never
    // be promoted into a symptom action, regardless of which intent-detection
    // branch fires. Discard any pending action the earlier
    // _pendingSymptomActionFor call produced from keysmash, and gate the
    // remaining branches below so they cannot re-promote it. The rejection
    // gate at the symptom-intake clarifier loop further down only runs when
    // pendingSymptomAction is null, so this keeps that rejection flow
    // reachable.
    final looksGibberishEarly = _looksLikeGibberish(userMessage);
    if (looksGibberishEarly) {
      pendingSymptomAction = null;
    }

    if (!looksGibberishEarly &&
        pendingSymptomAction == null &&
        pendingMedicationAction == null &&
        pendingLabAction == null &&
        (lower.contains(',') ||
            lower.contains('|') ||
            lower.contains(';') ||
            lower.contains('//') ||
            lower.contains('+') ||
            intent == 'symptom_log_followup' ||
            intent == 'symptom_question' ||
            intent == 'multi_symptom_log') &&
        (intent == 'symptom_log_followup' ||
            intent == 'symptom_question' ||
            intent == 'multi_symptom_log' ||
            _manualHealthSymptomType(userMessage) != null ||
            SymptomParserService.looksLikeSymptomText(lower))) {
      pendingSymptomAction = _manualSymptomPendingAction(
              sourceText: userMessage, loggedAt: now) ??
          _forcedSymptomPendingAction(sourceText: userMessage, loggedAt: now);
    }
    if (!looksGibberishEarly &&
        pendingSymptomAction == null &&
        pendingMedicationAction == null &&
        pendingLabAction == null &&
        session.awaitingSymptomIntake &&
        (SymptomParserService.looksLikeSymptomText(lower) ||
            _manualHealthSymptomType(userMessage) != null ||
            _containsHealthTerms(lower))) {
      pendingSymptomAction = _manualSymptomPendingAction(
              sourceText: userMessage, loggedAt: now) ??
          _forcedSymptomPendingAction(sourceText: userMessage, loggedAt: now);
    }
    // When we're awaiting symptom intake, stay in the deterministic intake flow
    // unless the user clearly pivoted (greeting, doctor summary, lab question, etc.).
    // Gibberish or under-specified messages should trigger the clarifier loop
    // (with bounded retries) rather than fall through to the LLM.
    final stayInIntake =
        session.awaitingSymptomIntake && !_shouldExitSymptomIntake(lower);
    if (pendingSymptomAction == null &&
        pendingMedicationAction == null &&
        pendingLabAction == null &&
        stayInIntake) {
      // ── Non-health input rejection gate ───────────────────────────────────
      // If the user is in the symptom intake session but typed something that
      // is clearly not a health description, apply progressive rejection instead
      // of routing the gibberish into the clarifier loop (which would eventually
      // force a review card with the non-health text as the symptom note).
      //
      // First pass: cheap deterministic gibberish reject (no model call) so
      // random keystrokes like "bdyagayauHb" never reach the clarifier or the
      // model classifier.
      final looksGibberish = _looksLikeGibberish(userMessage);

      // Second pass: ask Gemma if the input is a health symptom. This catches
      // typos, synonyms, and paraphrases the keyword gate below would miss
      // ("buy groceries", "remind me to call mom", etc.). Skip the call when
      // the cheap gibberish check already rejected — no point asking the model
      // about random characters. Fails open — if the classifier is unavailable
      // or unsure, fall through to the deterministic keyword gate as a safety
      // net.
      var gemmaSaysNonHealth = false;
      final gemmaTaskService = _gemmaTaskService;
      if (!looksGibberish && gemmaTaskService != null) {
        try {
          final classification = await gemmaTaskService.classifyIsHealthSymptom(
              transcript: userMessage);
          gemmaSaysNonHealth =
              classification.usedModelOutput && !classification.isHealthSymptom;
        } catch (_) {
          // Classifier failure is non-fatal — keep the deterministic gate.
        }
      }
      if (looksGibberish ||
          gemmaSaysNonHealth ||
          _isNonHealthSymptomInput(lower)) {
        final nonHealthCount = session.symptomIntakeNonHealthCount + 1;
        if (nonHealthCount > 2) {
          // Two strikes already used — friendly reset, route back to Gemma Flares intro.
          const introMessage =
              "Hi! I'm Gemma Flares — your gut health companion. I help you track "
              'symptoms, check flare risk, and follow your health trends. '
              'Ask me anything about your gut health, or tap one of the quick '
              'actions below to get started.';
          final introTrace = {
            ...toolTraceJson,
            'used_model_output': false,
            'deterministic_fast_path_used': true,
            'chat_path': 'symptom_intake_non_health_reset',
            'non_health_count': nonHealthCount,
          };
          await _repository.insertConversation(
            ConversationRecord(
              createdAt: _nowProvider(),
              userMessage: userMessage,
              assistantMessage: introMessage,
              toolTraceJson: introTrace,
              groundedSummaryJson: modelGroundingJson,
            ),
          );
          _recordSessionTurn(
            userMessage: userMessage,
            assistantMessage: introMessage,
            intent: 'greeting',
            usedModelOutput: false,
            activeRuntimeProfile: session.activeRuntimeProfile,
            activeTopic: null,
            awaitingSymptomIntake: false,
            symptomIntakeClarifierCount: 0,
            symptomIntakeNonHealthCount: 0,
          );
          return LocalAgentReply(
            status: 'deterministic_non_health_reset',
            message: introMessage,
            runtimeName: 'deterministic',
            toolTraceJson: introTrace,
            groundedSummaryJson: modelGroundingJson,
          );
        }
        final rejectionMessage = nonHealthCount == 1
            ? "That doesn't look like a symptom I can log. Try describing how "
                "you're physically feeling — for example, 'stomach pain after "
                "eating' or 'nausea and fatigue since yesterday'. What's "
                'bothering you?'
            : "I can only log physical symptoms — things like pain, bloating, "
                'fatigue, or nausea. One more try: what physical symptom are '
                'you experiencing?';
        final rejectionTrace = {
          ...toolTraceJson,
          'used_model_output': false,
          'deterministic_fast_path_used': true,
          'chat_path': 'symptom_intake_non_health_rejection',
          'non_health_count': nonHealthCount,
        };
        await _repository.insertConversation(
          ConversationRecord(
            createdAt: _nowProvider(),
            userMessage: userMessage,
            assistantMessage: rejectionMessage,
            toolTraceJson: rejectionTrace,
            groundedSummaryJson: modelGroundingJson,
          ),
        );
        _recordSessionTurn(
          userMessage: userMessage,
          assistantMessage: rejectionMessage,
          intent: 'symptom_log_followup',
          usedModelOutput: false,
          activeRuntimeProfile: session.activeRuntimeProfile,
          activeTopic: 'symptom_intake_pending',
          awaitingSymptomIntake: true,
          symptomIntakeClarifierCount: session.symptomIntakeClarifierCount,
          symptomIntakeNonHealthCount: nonHealthCount,
        );
        return LocalAgentReply(
          status: 'deterministic_non_health_rejection',
          message: rejectionMessage,
          runtimeName: 'deterministic',
          toolTraceJson: rejectionTrace,
          groundedSummaryJson: modelGroundingJson,
        );
      }
      // ── End non-health gate ───────────────────────────────────────────────

      final clarifierCount = session.symptomIntakeClarifierCount + 1;
      final sourceText = _symptomNarrativeThread(session, userMessage);
      final slotHints = _symptomSlotHints(sourceText);
      final forcedAction = clarifierCount >= _maxSymptomClarifierRetries
          ? _forcedSymptomPendingAction(sourceText: sourceText, loggedAt: now)
          : null;
      if (forcedAction != null) {
        final symptomCount =
            (forcedAction.payloadJson['symptom_count'] as int?) ?? 1;
        final countLabel = symptomCount > 1
            ? 'I found $symptomCount symptoms to log'
            : 'I can log this as a symptom note';
        final forcedMessage = GemmaFlaresVoicePolicy.polish(
          _applySafetyEnvelope(
            '$countLabel. Review before saving: '
            '${_pendingSymptomSummary(forcedAction.payloadJson)}',
            userMessage,
            intent: 'symptom_log_followup',
          ),
          userMessage: userMessage,
        );
        final forcedTrace = {
          ...toolTraceJson,
          'used_model_output': false,
          'deterministic_fast_path_used': true,
          'chat_path': 'symptom_intake_forced_review',
          'symptom_intake_clarifier_count': clarifierCount,
        };
        await _repository.insertConversation(
          ConversationRecord(
            createdAt: _nowProvider(),
            userMessage: userMessage,
            assistantMessage: forcedMessage,
            toolTraceJson: forcedTrace,
            groundedSummaryJson: modelGroundingJson,
          ),
        );
        _recordSessionTurn(
          userMessage: userMessage,
          assistantMessage: forcedMessage,
          intent: 'symptom_review_pending',
          usedModelOutput: false,
          activeRuntimeProfile: session.activeRuntimeProfile,
          activeTopic: 'symptom_review_pending',
          awaitingSymptomIntake: false,
          symptomIntakeClarifierCount: 0,
        );
        return LocalAgentReply(
          status: 'symptom_review_pending',
          message: forcedMessage,
          runtimeName: 'deterministic',
          toolTraceJson: forcedTrace,
          groundedSummaryJson: modelGroundingJson,
          pendingAction: forcedAction,
        );
      }
      final clarifier =
          'I can log this. Please share ${slotHints.join(', ')} so I can build the review card.';
      final message = GemmaFlaresVoicePolicy.polish(
        _applySafetyEnvelope(
          clarifier,
          userMessage,
          intent: 'symptom_log_followup',
        ),
        userMessage: userMessage,
      );
      final trace = {
        ...toolTraceJson,
        'used_model_output': false,
        'deterministic_fast_path_used': true,
        'chat_path': 'symptom_intake_clarifier',
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: userMessage,
          assistantMessage: message,
          toolTraceJson: trace,
          groundedSummaryJson: modelGroundingJson,
        ),
      );
      _recordSessionTurn(
        userMessage: userMessage,
        assistantMessage: message,
        intent: 'symptom_log_followup',
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
        activeTopic: 'symptom_intake_pending',
        awaitingSymptomIntake: true,
        symptomIntakeClarifierCount: clarifierCount,
      );
      return LocalAgentReply(
        status: 'deterministic_symptom_intake_clarifier',
        message: message,
        runtimeName: 'deterministic',
        toolTraceJson: trace,
        groundedSummaryJson: modelGroundingJson,
      );
    }
    // labGemmaExplain bypasses deterministic summary so Gemma 4 receives the
    // actual lab values as grounding and explains them in clinical Gemma Flares
    // voice.  labRecall and lab_question intent still use the fast path.
    final labSummaryReply = pendingSymptomAction == null &&
            pendingLabAction == null &&
            taskContract != _ChatTaskContract.labGemmaExplain &&
            (intent == 'lab_question' ||
                taskContract == _ChatTaskContract.labRecall) &&
            _isLabExplanationRequest(userMessage.toLowerCase()) &&
            allLabs.isNotEmpty
        ? _latestLabsSummary(
            labs: allLabs,
            ragTransactions: ragTransactions,
            userMessage: userMessage,
          )
        : null;
    final pendingLabReviewReply = pendingSymptomAction == null &&
            pendingLabAction == null &&
            labSummaryReply == null &&
            (intent == 'lab_question' ||
                taskContract == _ChatTaskContract.labRecall ||
                taskContract == _ChatTaskContract.labGemmaExplain) &&
            _isLabExplanationRequest(userMessage.toLowerCase())
        ? _pendingLabReviewRecallReply(recentLabReviews)
        : null;
    final appleWatchReviewReply = pendingSymptomAction == null &&
            pendingLabAction == null &&
            labSummaryReply == null &&
            pendingLabReviewReply == null &&
            taskContract == _ChatTaskContract.appleWatchReview
        ? await _resolvedWearableReply(
            userMessage: userMessage,
            lower: lower,
            todayDate: todayDate,
            recentSummaries: recentSummaries,
            latestScore: latestScore,
            latestSummary: latestSummary,
            todayFeatures: todayFeatures,
            heartRhythmContext: heartRhythmContext,
            earlyWarningOutlook: outlook,
          )
        : null;
    if (pendingLabReviewReply != null) {
      final message = GemmaFlaresVoicePolicy.polish(
        _applySafetyEnvelope(pendingLabReviewReply, userMessage),
        userMessage: userMessage,
      );
      final trace = {
        ...toolTraceJson,
        'used_model_output': false,
        'deterministic_fast_path_used': true,
        'chat_path': 'pending_lab_review_recall',
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: userMessage,
          assistantMessage: message,
          toolTraceJson: trace,
          groundedSummaryJson: modelGroundingJson,
        ),
      );
      _recordSessionTurn(
        userMessage: userMessage,
        assistantMessage: message,
        intent: intent,
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
        awaitingSymptomIntake: false,
      );
      return LocalAgentReply(
        status: 'deterministic_pending_lab_review',
        message: message,
        runtimeName: 'deterministic',
        toolTraceJson: trace,
        groundedSummaryJson: modelGroundingJson,
      );
    }
    if (appleWatchReviewReply != null) {
      final message = GemmaFlaresVoicePolicy.polish(
        _applySafetyEnvelope(appleWatchReviewReply, userMessage),
        userMessage: userMessage,
      );
      final trace = {
        ...toolTraceJson,
        'used_model_output': false,
        'deterministic_fast_path_used': true,
        'chat_path': 'apple_watch_review',
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: userMessage,
          assistantMessage: message,
          toolTraceJson: trace,
          groundedSummaryJson: modelGroundingJson,
        ),
      );
      _recordSessionTurn(
        userMessage: userMessage,
        assistantMessage: message,
        intent: intent,
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
      );
      return LocalAgentReply(
        status: 'deterministic_apple_watch_review',
        message: message,
        runtimeName: 'deterministic',
        toolTraceJson: trace,
        groundedSummaryJson: modelGroundingJson,
      );
    }
    if (labSummaryReply != null) {
      final message = GemmaFlaresVoicePolicy.polish(
        _applySafetyEnvelope(labSummaryReply, userMessage),
        userMessage: userMessage,
      );
      final trace = {
        ...toolTraceJson,
        'used_model_output': false,
        'deterministic_fast_path_used': true,
        'chat_path': 'latest_lab_summary',
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: userMessage,
          assistantMessage: message,
          toolTraceJson: trace,
          groundedSummaryJson: modelGroundingJson,
        ),
      );
      _recordSessionTurn(
        userMessage: userMessage,
        assistantMessage: message,
        intent: intent,
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
      );
      return LocalAgentReply(
        status: 'deterministic_lab_summary',
        message: message,
        runtimeName: 'deterministic',
        toolTraceJson: trace,
        groundedSummaryJson: modelGroundingJson,
      );
    }
    // Lab read-back is a different product action from lab intake/photo scan.
    // If there are no saved labs, answer that truth directly instead of
    // recycling the "paste values or scan" intake copy.
    // Exception: clinical record inputs (OCR text, biopsy reports, stool labs),
    // lab-intake phrases, photo phrases, "I just got labs back"-style phrases,
    // and bare lab-question phrasing without explicit recall keywords all fall
    // through to _deterministicActionReply so the review gate or intake prompt
    // fires instead of the no-data reply.
    if (taskContract == _ChatTaskContract.labRecall &&
        labSummaryReply == null &&
        pendingLabReviewReply == null &&
        pendingLabAction == null &&
        pendingSymptomAction == null &&
        !_isClinicalRecordReviewInput(userMessage.toLowerCase()) &&
        !_isLabIntakePhrase(userMessage.toLowerCase()) &&
        !_looksLikePhotoAttachment(userMessage.toLowerCase()) &&
        _isExplicitLabRecallQuery(userMessage.toLowerCase())) {
      const labNoDataReply = 'No lab results are saved locally yet.';
      final message = GemmaFlaresVoicePolicy.polish(
        _applySafetyEnvelope(labNoDataReply, userMessage),
        userMessage: userMessage,
      );
      final trace = {
        ...toolTraceJson,
        'used_model_output': false,
        'deterministic_fast_path_used': true,
        'chat_path': 'lab_recall_no_data',
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: userMessage,
          assistantMessage: message,
          toolTraceJson: trace,
          groundedSummaryJson: modelGroundingJson,
        ),
      );
      _recordSessionTurn(
        userMessage: userMessage,
        assistantMessage: message,
        intent: intent,
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
      );
      return LocalAgentReply(
        status: 'deterministic_lab_recall_no_data',
        message: message,
        runtimeName: 'deterministic',
        toolTraceJson: trace,
        groundedSummaryJson: modelGroundingJson,
      );
    }
    // ── Memory ledger: real data, not a generic privacy sentence ─────────────
    // Build a structured ledger from actual ragTransactions in scope so the
    // user sees counts, source types, and timestamps instead of boilerplate.
    if (pendingSymptomAction == null &&
        pendingLabAction == null &&
        taskContract == _ChatTaskContract.memoryLedger) {
      // For memory-ledger asks, load a wider window than the default chat
      // context (which is intentionally capped for token/latency reasons).
      final allLedgerRows = await _repository.getRagMemoryTransactions(
        limit: 200,
      );
      final ledgerReply = _buildMemoryLedgerReply(allLedgerRows);
      final message = GemmaFlaresVoicePolicy.polish(
        _applySafetyEnvelope(ledgerReply, userMessage),
        userMessage: userMessage,
      );
      final trace = {
        ...toolTraceJson,
        'used_model_output': false,
        'deterministic_fast_path_used': true,
        'chat_path': 'memory_ledger_real_data',
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: userMessage,
          assistantMessage: message,
          toolTraceJson: trace,
          groundedSummaryJson: modelGroundingJson,
        ),
      );
      _recordSessionTurn(
        userMessage: userMessage,
        assistantMessage: message,
        intent: intent,
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
      );
      return LocalAgentReply(
        status: 'deterministic_memory_ledger',
        message: message,
        runtimeName: 'deterministic',
        toolTraceJson: trace,
        groundedSummaryJson: modelGroundingJson,
      );
    }

    // ── labGemmaExplain: no-labs fast path ────────────────────────────────────
    // When the user taps "Explain my labs" but no labs are saved yet, return a
    // targeted prompt instead of letting Gemma hallucinate an explanation.
    if (taskContract == _ChatTaskContract.labGemmaExplain &&
        pendingSymptomAction == null &&
        pendingLabAction == null &&
        allLabs.isEmpty) {
      const noLabsReply = 'No lab results to explain yet.';
      final message = GemmaFlaresVoicePolicy.polish(
        _applySafetyEnvelope(noLabsReply, userMessage),
        userMessage: userMessage,
      );
      final trace = {
        ...toolTraceJson,
        'used_model_output': false,
        'deterministic_fast_path_used': true,
        'chat_path': 'lab_gemma_explain_no_data',
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: userMessage,
          assistantMessage: message,
          toolTraceJson: trace,
          groundedSummaryJson: modelGroundingJson,
        ),
      );
      _recordSessionTurn(
        userMessage: userMessage,
        assistantMessage: message,
        intent: intent,
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
      );
      return LocalAgentReply(
        status: 'deterministic_lab_explain_no_data',
        message: message,
        runtimeName: 'deterministic',
        toolTraceJson: trace,
        groundedSummaryJson: modelGroundingJson,
      );
    }

    // Bulletproof explain-labs route: always provide a deterministic clinical
    // explanation for saved local labs so repeated "explain my labs" requests
    // never depend on runtime latency/model timeout behavior.
    if (taskContract == _ChatTaskContract.labGemmaExplain &&
        pendingSymptomAction == null &&
        pendingLabAction == null &&
        allLabs.isNotEmpty) {
      final explainCacheKey = _labExplainCacheKey(allLabs);
      final cached = _labExplainResponseCache[explainCacheKey];
      final deterministicExplain = cached ??
          await _deterministicLabExplainReply(
            labs: allLabs,
            ragTransactions: ragTransactions,
          );
      _labExplainResponseCache[explainCacheKey] = deterministicExplain;
      final message = GemmaFlaresVoicePolicy.polish(
        _applySafetyEnvelope(
          deterministicExplain,
          userMessage,
          intent: 'lab_question',
        ),
        userMessage: userMessage,
      );
      final trace = {
        ...toolTraceJson,
        'used_model_output': false,
        'deterministic_fast_path_used': true,
        'chat_path': cached == null
            ? 'lab_gemma_explain_deterministic'
            : 'lab_gemma_explain_cached',
        'lab_explain_cache_hit': cached != null,
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: userMessage,
          assistantMessage: message,
          toolTraceJson: trace,
          groundedSummaryJson: modelGroundingJson,
        ),
      );
      _recordSessionTurn(
        userMessage: userMessage,
        assistantMessage: message,
        intent: 'lab_question',
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
      );
      return LocalAgentReply(
        status: 'deterministic_lab_explain',
        message: message,
        runtimeName: 'deterministic',
        toolTraceJson: trace,
        groundedSummaryJson: modelGroundingJson,
      );
    }

    if (taskContract == _ChatTaskContract.labGemmaExplain &&
        pendingSymptomAction == null &&
        pendingLabAction == null &&
        intent == 'continuation' &&
        allLabs.isNotEmpty) {
      final continuationReply = _latestLabsSummary(
        labs: allLabs,
        ragTransactions: ragTransactions,
        userMessage: 'Explain my labs',
      );
      final message = GemmaFlaresVoicePolicy.polish(
        _applySafetyEnvelope(
          continuationReply,
          userMessage,
          intent: 'lab_question',
        ),
        userMessage: userMessage,
      );
      final trace = {
        ...toolTraceJson,
        'used_model_output': false,
        'deterministic_fast_path_used': true,
        'chat_path': 'lab_explain_continuation',
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: userMessage,
          assistantMessage: message,
          toolTraceJson: trace,
          groundedSummaryJson: modelGroundingJson,
        ),
      );
      _recordSessionTurn(
        userMessage: userMessage,
        assistantMessage: message,
        intent: 'lab_question',
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
      );
      return LocalAgentReply(
        status: 'deterministic_lab_explain_continuation',
        message: message,
        runtimeName: 'deterministic',
        toolTraceJson: trace,
        groundedSummaryJson: modelGroundingJson,
      );
    }

    if (pendingMedicationAction != null) {
      final message = GemmaFlaresVoicePolicy.polish(
        _applySafetyEnvelope(
          'I can log this medication or supplement note. Review before saving: '
          '${_pendingMedicationSummary(pendingMedicationAction.payloadJson)}',
          userMessage,
          intent: intent,
        ),
        userMessage: userMessage,
      );
      final trace = {
        ...toolTraceJson,
        'used_model_output': false,
        'deterministic_fast_path_used': true,
        'pending_action_type': pendingMedicationAction.type,
        'pending_action_extraction_method':
            pendingMedicationAction.payloadJson['extraction_method'],
        'chat_path': 'medication_review_pending',
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: userMessage,
          assistantMessage: message,
          toolTraceJson: trace,
          groundedSummaryJson: modelGroundingJson,
        ),
      );
      _recordSessionTurn(
        userMessage: userMessage,
        assistantMessage: message,
        intent: 'medication_review_pending',
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
        activeTopic: 'medication_review_pending',
        awaitingSymptomIntake: false,
      );
      return LocalAgentReply(
        status: 'medication_review_pending',
        message: message,
        runtimeName: 'deterministic',
        toolTraceJson: trace,
        groundedSummaryJson: modelGroundingJson,
        pendingAction: pendingMedicationAction,
      );
    }

    final deterministicActionReply = _deterministicActionReply(
      userMessage: userMessage,
      intent: intent,
      session: session,
    );
    if (pendingSymptomAction == null &&
        pendingLabAction == null &&
        pendingMedicationAction == null &&
        taskContract != _ChatTaskContract.labGemmaExplain &&
        deterministicActionReply != null) {
      final message = GemmaFlaresVoicePolicy.polish(
        _applySafetyEnvelope(deterministicActionReply, userMessage),
        userMessage: userMessage,
      );
      final trace = {
        ...toolTraceJson,
        'used_model_output': false,
        'deterministic_fast_path_used': true,
        'chat_path': 'action_intake_prompt',
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: userMessage,
          assistantMessage: message,
          toolTraceJson: trace,
          groundedSummaryJson: modelGroundingJson,
        ),
      );
      _recordSessionTurn(
        userMessage: userMessage,
        assistantMessage: message,
        intent: intent,
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
      );
      return LocalAgentReply(
        status: 'deterministic_action_prompt',
        message: message,
        runtimeName: 'deterministic',
        toolTraceJson: trace,
        groundedSummaryJson: modelGroundingJson,
      );
    }
    if (pendingLabAction != null) {
      final message = GemmaFlaresVoicePolicy.polish(
        _applySafetyEnvelope(
          'I found lab values I can save. Review them first: '
          '${_pendingLabSummary(pendingLabAction.payloadJson)}',
          userMessage,
        ),
        userMessage: userMessage,
      );
      final trace = {
        ...toolTraceJson,
        'used_model_output': false,
        'deterministic_fast_path_used': true,
        'pending_action_type': pendingLabAction.type,
        'pending_action_review_id': pendingLabAction.reviewId,
        'chat_path': 'lab_review_pending',
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: userMessage,
          assistantMessage: message,
          toolTraceJson: trace,
          groundedSummaryJson: modelGroundingJson,
        ),
      );
      _recordSessionTurn(
        userMessage: userMessage,
        assistantMessage: message,
        intent: intent,
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
      );
      return LocalAgentReply(
        status: 'lab_review_pending',
        message: message,
        runtimeName: 'deterministic',
        toolTraceJson: trace,
        groundedSummaryJson: modelGroundingJson,
        pendingAction: pendingLabAction,
      );
    }
    if (pendingSymptomAction != null) {
      final safetyNote = _symptomSafetyNote(pendingSymptomAction.payloadJson);
      final symptomCount =
          (pendingSymptomAction.payloadJson['symptom_count'] as int?) ?? 1;
      final countLabel = symptomCount > 1
          ? 'I found $symptomCount symptoms to log'
          : 'I can log this as a symptom note';
      final message = GemmaFlaresVoicePolicy.polish(
        _applySafetyEnvelope(
          '$countLabel. Review before saving: '
          '${_pendingSymptomSummary(pendingSymptomAction.payloadJson)}'
          '${safetyNote == null ? '' : '\n\n$safetyNote'}',
          userMessage,
          intent: intent,
        ),
        userMessage: userMessage,
      );
      final trace = {
        ...toolTraceJson,
        'used_model_output': false,
        'deterministic_fast_path_used': true,
        'pending_action_type': pendingSymptomAction.type,
        'pending_action_review_id': pendingSymptomAction.reviewId,
        'pending_action_extraction_method':
            pendingSymptomAction.payloadJson['extraction_method'],
        'pending_action_safety_flags':
            pendingSymptomAction.payloadJson['safety_flags'],
        'chat_path': 'symptom_review_pending',
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: userMessage,
          assistantMessage: message,
          toolTraceJson: trace,
          groundedSummaryJson: modelGroundingJson,
        ),
      );
      await _diagnosticLogService?.info(
        'chat_symptom_review_created',
        category: DiagnosticLogService.categoryChat,
        message: 'Chat created a review-before-save symptom draft.',
        metadata: {
          'used_model_output': false,
          'pending_action_type': pendingSymptomAction.type,
          'confidence': pendingSymptomAction.confidence,
        },
      );
      _recordSessionTurn(
        userMessage: userMessage,
        assistantMessage: message,
        intent: 'symptom_review_pending',
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
        activeTopic: 'symptom_review_pending',
        awaitingSymptomIntake: false,
        symptomIntakeClarifierCount: 0,
      );
      return LocalAgentReply(
        status: 'symptom_review_pending',
        message: message,
        runtimeName: 'deterministic',
        toolTraceJson: trace,
        groundedSummaryJson: modelGroundingJson,
        pendingAction: pendingSymptomAction,
      );
    }

    // Topic-aware routing: if user is expanding/continuing on a major summary,
    // re-run the summary generator for richer output rather than a plain chat call.
    if ((intent == 'followup_expand' || intent == 'continuation') &&
        session.activeTopic == 'doctor_summary' &&
        _gemmaTaskService != null) {
      final reply = await _doctorSummaryReply(
        userMessage: userMessage,
        now: now,
      );
      // activeTopic already set inside _doctorSummaryReply via _recordSessionTurn
      return reply;
    }

    final starterGroundedReply =
        pendingSymptomAction == null && pendingLabAction == null
            ? _starterPromptGroundedReply(
                taskContract: taskContract,
                grounding: modelGroundingJson,
              )
            : null;
    if (starterGroundedReply != null) {
      final message = GemmaFlaresVoicePolicy.polish(
        _applySafetyEnvelope(
          starterGroundedReply,
          userMessage,
          intent: groundingIntent,
        ),
        userMessage: userMessage,
      );
      final trace = {
        ...toolTraceJson,
        'used_model_output': false,
        'deterministic_fast_path_used': true,
        'chat_path': 'starter_prompt_grounded',
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: userMessage,
          assistantMessage: message,
          toolTraceJson: trace,
          groundedSummaryJson: modelGroundingJson,
        ),
      );
      _recordSessionTurn(
        userMessage: userMessage,
        assistantMessage: message,
        intent: groundingIntent,
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
      );
      return LocalAgentReply(
        status: 'deterministic_starter_prompt',
        message: message,
        runtimeName: 'deterministic',
        toolTraceJson: trace,
        groundedSummaryJson: modelGroundingJson,
      );
    }

    // Change/comparison questions are core data-navigation actions. Keep them
    // deterministic so repeated asks never fall into a model-generated loop
    // telling the user to ask the same question again.
    if (intent == 'followup_compare') {
      final deterministicReply = _changeComparisonReply(
        intent: intent,
        userMessage: userMessage,
        latestScore: latestScore,
        recentSummaries: recentSummaries,
        recentSymptoms: recentSymptoms,
        recentLabs: allLabs,
        checkInTrend: checkInTrend,
        latestProcedure: latestProcedure,
        ragTransactions: ragTransactions,
        contextFeatures: todayContext?.featureJson,
        earlyWarningOutlook: outlook,
      );
      final polished = GemmaFlaresVoicePolicy.polish(
        _applySafetyEnvelope(deterministicReply, userMessage, intent: intent),
        userMessage: userMessage,
      );
      final trace = {
        ...toolTraceJson,
        'deterministic_compare_bypass': true,
        'used_model_output': false,
        'chat_path': 'deterministic_change_comparison',
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: userMessage,
          assistantMessage: polished,
          toolTraceJson: trace,
          groundedSummaryJson: modelGroundingJson,
        ),
      );
      _recordSessionTurn(
        userMessage: userMessage,
        assistantMessage: polished,
        intent: intent,
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
      );
      return LocalAgentReply(
        status: 'deterministic_compare_reply',
        message: polished,
        runtimeName: 'deterministic',
        toolTraceJson: trace,
        groundedSummaryJson: modelGroundingJson,
      );
    }

    // Off-topic, abusive, or accidental fragments should never trigger model
    // generation or expose health scores. Keep the redirect deterministic and
    // data-minimal.
    if (intent == 'out_of_scope') {
      final deterministicReply = _fallbackReply(
        userMessage: userMessage,
        latestScore: latestScore,
        recentSummaries: recentSummaries,
        recentSymptoms: recentSymptoms,
        recentLabs: allLabs,
        checkInTrend: checkInTrend,
        latestProcedure: latestProcedure,
        contextFeatures: todayContext?.featureJson,
        earlyWarningOutlook: outlook,
        ragTransactions: ragTransactions,
      );
      final polished = GemmaFlaresVoicePolicy.polish(
        _applySafetyEnvelope(deterministicReply, userMessage, intent: intent),
        userMessage: userMessage,
      );
      final trace = {
        ...toolTraceJson,
        'deterministic_out_of_scope_bypass': true,
        'used_model_output': false,
        'chat_path': 'deterministic_out_of_scope_redirect',
      };
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: userMessage,
          assistantMessage: polished,
          toolTraceJson: trace,
          groundedSummaryJson: modelGroundingJson,
        ),
      );
      _recordSessionTurn(
        userMessage: userMessage,
        assistantMessage: polished,
        intent: intent,
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
      );
      return LocalAgentReply(
        status: 'deterministic_out_of_scope_reply',
        message: polished,
        runtimeName: 'deterministic',
        toolTraceJson: trace,
        groundedSummaryJson: modelGroundingJson,
      );
    }

    // Risk-score queries are fully answered by deterministic grounded data.
    // Skip Gemma entirely even when no score exists: risk presets are core UX,
    // and a loaded model can otherwise produce generic filler such as
    // "Please provide the text..." instead of the correct data-gap answer.
    if (intent == 'risk_question') {
      final deterministicReply = _fallbackReply(
        userMessage: userMessage,
        latestScore: latestScore,
        recentSummaries: recentSummaries,
        recentSymptoms: recentSymptoms,
        recentLabs: allLabs,
        checkInTrend: checkInTrend,
        latestProcedure: latestProcedure,
        contextFeatures: todayContext?.featureJson,
        earlyWarningOutlook: outlook,
        ragTransactions: ragTransactions,
      );
      final polished = GemmaFlaresVoicePolicy.polish(
        _applySafetyEnvelope(deterministicReply, userMessage, intent: intent),
        userMessage: userMessage,
      );
      toolTraceJson['deterministic_risk_bypass'] = true;
      toolTraceJson['used_model_output'] = false;
      await _repository.insertConversation(
        ConversationRecord(
          createdAt: _nowProvider(),
          userMessage: userMessage,
          assistantMessage: polished,
          toolTraceJson: toolTraceJson,
          groundedSummaryJson: modelGroundingJson,
        ),
      );
      _recordSessionTurn(
        userMessage: userMessage,
        assistantMessage: polished,
        intent: intent,
        usedModelOutput: false,
        activeRuntimeProfile: session.activeRuntimeProfile,
      );
      return LocalAgentReply(
        status: 'deterministic_risk_reply',
        message: polished,
        runtimeName: 'deterministic',
        toolTraceJson: toolTraceJson,
        groundedSummaryJson: groundedSummaryJson,
      );
    }

    var runtimeStatusBeforeGenerate = await _runtime.getRuntimeStatus();
    var runtimeLoadAttempted = false;
    if (!runtimeStatusBeforeGenerate.isModelLoaded &&
        runtimeStatusBeforeGenerate.isBundledModelPresent &&
        runtimeStatusBeforeGenerate.isBackendLinked) {
      runtimeLoadAttempted = true;
      runtimeStatusBeforeGenerate = await _runtime.loadBundledModel(
        profile: _profileForIntent(intent, runtimeStatusBeforeGenerate),
      );
    }
    if (session.activeRuntimeProfile != null &&
        session.activeRuntimeProfile !=
            runtimeStatusBeforeGenerate.activeRuntimeProfile) {
      await resetSession(reason: 'runtime_profile_changed');
      session = _ensureSession(now);
      groundedSummaryJson['chat_session_summary'] = session.rollingSummary;
    }
    toolTraceJson.addAll({
      'runtime_status_before_generate': runtimeStatusBeforeGenerate.status,
      'runtime_loaded_before_generate':
          runtimeStatusBeforeGenerate.isModelLoaded,
      'runtime_reason_before_generate': runtimeStatusBeforeGenerate.reason,
      'runtime_load_attempted': runtimeLoadAttempted,
      'active_runtime_profile':
          runtimeStatusBeforeGenerate.activeRuntimeProfile,
      'runtime_context_window': runtimeStatusBeforeGenerate.contextWindow,
      'runtime_batch_size': runtimeStatusBeforeGenerate.batchSize,
      'runtime_backend_requested': runtimeStatusBeforeGenerate.backendRequested,
      'runtime_backend_used': runtimeStatusBeforeGenerate.backendUsed,
      'runtime_backend_fallback_reason':
          runtimeStatusBeforeGenerate.backendFallbackReason,
      'runtime_engine_create_latency_ms':
          runtimeStatusBeforeGenerate.engineCreateLatencyMs,
    });

    // WS1a: light intents get a minimal grounding (~20-80 tokens) instead of
    // the full ~400-token blob, shaving ~1s TTFT at 300 TPS CPU prefill.
    final runtimeGroundingJson =
        taskContract == _ChatTaskContract.labGemmaExplain
            ? _runtimeGroundingForLatestLabExplain(modelGroundingJson)
            : _isLightIntent(intent)
                ? _lightGroundingForIntent(intent, modelGroundingJson)
                : _runtimeGroundingForModel(modelGroundingJson);
    toolTraceJson['runtime_grounding_keys'] = runtimeGroundingJson.keys.toList(
      growable: false,
    );

    final richness = _dataRichness(runtimeGroundingJson);
    final wantsDetail = taskContract != _ChatTaskContract.labGemmaExplain &&
        (intent == 'followup_expand' ||
            intent == 'followup_compare' ||
            intent == 'confidence_question' ||
            intent == 'daily_summary' ||
            intent == 'week_summary' ||
            intent == 'doctor_summary' ||
            intent == 'general_health_question' ||
            intent == 'lab_question' ||
            intent == 'continuation' ||
            intent == 'forecast_watchlist');
    final promptIntent = taskContract == _ChatTaskContract.labGemmaExplain
        ? 'lab_question'
        : (intent == 'daily_summary' ? 'week_summary' : intent);
    // Extract disease_type for prompt branching (e.g. IBS vs CD/UC glossary
    // and health-agent grounded framing).
    final profileForPrompt =
        groundedSummaryJson['user_profile'] as Map<String, Object?>?;
    final diseaseTypeForPrompt = profileForPrompt?['disease_type'] as String?;

    var systemPrompt = prompts.buildSystemPrompt(
      promptIntent,
      dataRichness: richness.name,
      wantsDetailedAnswer: wantsDetail,
      diseaseType: diseaseTypeForPrompt,
    );
    if (taskContract == _ChatTaskContract.labGemmaExplain) {
      systemPrompt = '$systemPrompt\n\n'
          'Lab explanation mode (strict): Explain the latest saved lab results '
          'from grounded context key "latest_lab_explain" first, then use "labs" '
          'for supporting context. Do not ask the user to paste/upload labs '
          'when labs are present. Do not ask the user to continue for more.';
    }
    final modelRole = _modelRoleForIntent(intent);
    final contextPolicy = _contextPolicyForIntent(intent);
    final modelResponse = await _runtime.generate(
      LocalModelRequest(
        systemPrompt: systemPrompt,
        userPrompt: _buildUserPromptWithHistory(
          userMessage,
          recentConversations,
          session,
          intent,
        ),
        groundedContext: runtimeGroundingJson,
        maxTokens: _chatMaxTokensFor(
          runtimeStatusBeforeGenerate,
          intent,
          grounding: runtimeGroundingJson,
        ),
        temperature: _temperatureFor(intent),
        taskType: 'chat',
        modelRole: modelRole,
        contextPolicy: contextPolicy,
        privacyMode: 'local_only',
      ),
    );

    final sanitizerReport = ChatOutputSanitizer.inspect(
      _stripRuntimeLoadingNotice(modelResponse.outputText),
      userMessage: userMessage,
      intent: intent,
      response: modelResponse,
      grounding: runtimeGroundingJson,
    );
    final cleanedModelOutput = sanitizerReport.cleanedText;
    final llmValidation = LlmOutputValidatorService.scoreResponseQuality(
      output: cleanedModelOutput,
      userInput: userMessage,
      expectedIntent: intent,
    );
    final llmCriticalViolations = llmValidation.violations
        .where((violation) => violation.severity == 'critical')
        .map((violation) => violation.type)
        .toList(growable: false);
    final llmGuard = llmValidation.isValid
        ? null
        : 'llm_validator_${llmCriticalViolations.join("_")}';
    final safeModelOutput = llmValidation.isValid
        ? LlmOutputValidatorService.sanitizeInvalidOutput(
            output: cleanedModelOutput,
            violations: llmValidation.violations,
          )
        : cleanedModelOutput;
    final claimGuard = _inspectUnsupportedClaims(
      cleanedModelOutput,
      toolTraceJson,
      modelGroundingJson,
    );
    final usedModelOutput =
        _isUsableModelResponse(modelResponse, sanitizerReport) &&
            claimGuard == null &&
            llmGuard == null;
    final availableMemoryMbBeforeLoad =
        modelResponse.availableMemoryMbBeforeLoad >= 0
            ? modelResponse.availableMemoryMbBeforeLoad
            : _bytesToMb(runtimeStatusBeforeGenerate.availableMemoryMB);
    final totalTokenCount = modelResponse.totalTokenCount > 0
        ? modelResponse.totalTokenCount
        : modelResponse.prefillTokenCount + modelResponse.decodeTokenCount;
    toolTraceJson.addAll({
      'model_generation_status': modelResponse.status,
      'model_generation_reason': modelResponse.reason,
      'model_fallback_reason': _fallbackReason(modelResponse),
      'prompt_char_count': modelResponse.promptCharCount,
      'estimated_prompt_tokens': modelResponse.estimatedPromptTokens,
      'prompt_token_count_native': modelResponse.promptTokenCountNative,
      'prompt_budget': modelResponse.promptBudget,
      'generation_limit': modelResponse.generationLimit,
      'generation_latency_ms': modelResponse.generationLatencyMs,
      'native_decode_rc': modelResponse.nativeDecodeRc,
      'failure_stage': modelResponse.failureStage,
      'raw_output_char_count': modelResponse.rawOutputCharCount,
      'cleaned_output_char_count': modelResponse.cleanedOutputCharCount,
      'output_quality_status': sanitizerReport.status,
      'output_quality_reason': sanitizerReport.reason,
      'llm_validator_valid': llmValidation.isValid,
      'llm_validator_quality': llmValidation.quality,
      'llm_validator_critical_violations': llmCriticalViolations,
      'llm_validator_violation_count': llmValidation.violations.length,
      'llm_validator_warnings': llmValidation.warnings,
      'native_output_quality_status': modelResponse.outputQualityStatus,
      'native_output_quality_reason': modelResponse.outputQualityReason,
      'prompt_template_version': modelResponse.promptTemplateVersion,
      'sanitizer_version': sanitizerReport.sanitizerVersion,
      'native_sanitizer_version': modelResponse.sanitizerVersion,
      'raw_output_hash': modelResponse.rawOutputHash,
      'generated_token_count': modelResponse.generatedTokenCount,
      'prefill_token_count': modelResponse.prefillTokenCount,
      'decode_token_count': modelResponse.decodeTokenCount,
      'total_token_count': totalTokenCount,
      'prefill_tps': modelResponse.prefillTps,
      'decode_tps': modelResponse.decodeTps,
      'ram_usage_mb': modelResponse.ramUsageMb,
      'time_to_first_token_ms': modelResponse.timeToFirstTokenMs,
      'stop_reason': modelResponse.stopReason,
      'sampler_profile': modelResponse.samplerProfile,
      'chat_template_source': modelResponse.chatTemplateSource,
      'native_task_type': modelResponse.taskType,
      'native_backend_requested': modelResponse.backendRequested,
      'native_backend_used': modelResponse.backendUsed,
      'native_backend_fallback_reason': modelResponse.backendFallbackReason,
      'native_engine_create_latency_ms': modelResponse.engineCreateLatencyMs,
      'native_quality_signals': modelResponse.qualitySignals,
      'native_quality_length_bucket': modelResponse.qualityLengthBucket,
      'native_raw_alpha_ratio': modelResponse.rawAlphaRatio,
      'native_cleaned_alpha_ratio': modelResponse.cleanedAlphaRatio,
      'native_raw_symbol_ratio': modelResponse.rawSymbolRatio,
      'native_cleaned_symbol_ratio': modelResponse.cleanedSymbolRatio,
      'model_role_requested': modelRole,
      'context_policy_requested': contextPolicy,
      'model_role_used': modelResponse.modelRoleUsed,
      'model_id_used': modelResponse.modelIdUsed,
      'engine_used': modelResponse.engineUsed,
      'context_policy_used': modelResponse.contextPolicyUsed,
      'context_window_configured': modelResponse.contextWindowConfigured,
      'prompt_tokens_actual': modelResponse.promptTokensActual,
      'tool_call_parse_status': modelResponse.toolCallParseStatus,
      'tool_calls': modelResponse.toolCalls,
      'local_only_verified': modelResponse.localOnlyVerified,
      'modality_used': modelResponse.modalityUsed,
      'model_load_latency_ms': modelResponse.modelLoadLatencyMs,
      'model_switch_latency_ms': modelResponse.modelSwitchLatencyMs,
      'available_memory_mb_before_load': availableMemoryMbBeforeLoad,
      'memory_warning_count': modelResponse.memoryWarningCount,
      'thermal_state': modelResponse.thermalState,
      'thermal_state_after_generation': modelResponse.thermalState,
      'npu_prefill_available': modelResponse.npuPrefillAvailable,
      'answer_evidence_hash': modelResponse.answerEvidenceHash,
      'used_model_output': usedModelOutput,
      'response_grounding_status': claimGuard == null
          ? (llmGuard == null
              ? (usedModelOutput ? 'grounded' : 'fallback')
              : 'rejected_llm_validator')
          : 'rejected_unsupported_claim',
      'rejection_reason': claimGuard ?? llmGuard,
    });

    final String finalMessage;
    final String finalStatus;
    if (usedModelOutput) {
      var body = _applySafetyEnvelope(
        safeModelOutput,
        userMessage,
        intent: intent,
      );
      body = _appendSymptomLogHint(
        body,
        userMessage: userMessage,
        intent: intent,
      );
      finalMessage = GemmaFlaresVoicePolicy.polish(
        body,
        userMessage: userMessage,
      );
      finalStatus = 'success';
    } else {
      var body = _fallbackReply(
        userMessage: userMessage,
        latestScore: latestScore,
        recentSummaries: recentSummaries,
        recentSymptoms: recentSymptoms,
        recentLabs: allLabs,
        checkInTrend: checkInTrend,
        latestProcedure: latestProcedure,
        contextFeatures: todayContext?.featureJson,
        earlyWarningOutlook: outlook,
        ragTransactions: ragTransactions,
      );
      body = _applySafetyEnvelope(body, userMessage, intent: intent);
      body = _appendSymptomLogHint(
        body,
        userMessage: userMessage,
        intent: intent,
      );
      finalMessage = GemmaFlaresVoicePolicy.polish(
        body,
        userMessage: userMessage,
      );
      finalStatus = modelResponse.status == 'success'
          ? 'fallback_invalid_model_output'
          : modelResponse.status;
    }

    await _repository.insertConversation(
      ConversationRecord(
        createdAt: _nowProvider(),
        userMessage: userMessage,
        assistantMessage: finalMessage,
        toolTraceJson: toolTraceJson,
        groundedSummaryJson: modelGroundingJson,
      ),
    );

    await _diagnosticLogService?.info(
      usedModelOutput
          ? 'chat_model_response'
          : sanitizerReport.status == 'rejected' || llmGuard != null
              ? 'chat_model_output_rejected'
              : 'chat_fallback_response',
      category: DiagnosticLogService.categoryChat,
      message: usedModelOutput
          ? 'Chat response generated by the local model.'
          : 'Chat response used the deterministic fallback.',
      metadata: {
        'reply_status': finalStatus,
        'runtime_name': modelResponse.runtimeName,
        'generation_status': modelResponse.status,
        'runtime_loaded': runtimeStatusBeforeGenerate.isModelLoaded,
        'load_attempted': runtimeLoadAttempted,
        'used_model_output': usedModelOutput,
        'has_snapshot': latestScore != null,
        'recent_record_count': recentSymptoms.length,
        'fallback_reason': _fallbackReason(modelResponse),
        'output_quality_status': sanitizerReport.status,
        'output_quality_reason': sanitizerReport.reason,
        'llm_validator_valid': llmValidation.isValid,
        'llm_validator_quality': llmValidation.quality,
        'llm_validator_critical_violations': llmCriticalViolations,
        'llm_validator_violation_count': llmValidation.violations.length,
        'native_output_quality_status': modelResponse.outputQualityStatus,
        'native_output_quality_reason': modelResponse.outputQualityReason,
        'prompt_template_version': modelResponse.promptTemplateVersion,
        'sanitizer_version': sanitizerReport.sanitizerVersion,
        'raw_output_hash': modelResponse.rawOutputHash,
        'estimated_prompt_tokens': modelResponse.estimatedPromptTokens,
        'prompt_budget': modelResponse.promptBudget,
        'generation_limit': modelResponse.generationLimit,
        'latency_ms': modelResponse.generationLatencyMs,
        'model_id_used': modelResponse.modelIdUsed,
        'active_runtime_profile': modelResponse.activeRuntimeProfile,
        'model_load_latency_ms': modelResponse.modelLoadLatencyMs,
        'time_to_first_token_ms': modelResponse.timeToFirstTokenMs,
        'generation_latency_ms': modelResponse.generationLatencyMs,
        'decode_tps': modelResponse.decodeTps,
        'prefill_tps': modelResponse.prefillTps,
        'prefill_token_count': modelResponse.prefillTokenCount,
        'decode_token_count': modelResponse.decodeTokenCount,
        'total_token_count': totalTokenCount,
        'ram_usage_mb': modelResponse.ramUsageMb,
        'available_memory_mb_before_load': availableMemoryMbBeforeLoad,
        'thermal_state_after_generation': modelResponse.thermalState,
        'npu_prefill_available': modelResponse.npuPrefillAvailable,
        'memory_warning_count': modelResponse.memoryWarningCount,
        'native_decode_rc': modelResponse.nativeDecodeRc,
        'failure_stage': modelResponse.failureStage,
        'backend_requested': modelResponse.backendRequested,
        'backend_used': modelResponse.backendUsed,
        'backend_fallback_reason': modelResponse.backendFallbackReason,
        'engine_create_latency_ms': modelResponse.engineCreateLatencyMs,
      },
    );

    await _runtimeTelemetryService?.recordGenerationComplete(
      response: modelResponse,
      availableMemoryMbBeforeLoad: availableMemoryMbBeforeLoad,
      extraMetadata: {
        'intent': intent,
        'used_model_output': usedModelOutput,
        'response_grounding_status': claimGuard == null
            ? (llmGuard == null
                ? (usedModelOutput ? 'grounded' : 'fallback')
                : 'rejected_llm_validator')
            : 'rejected_unsupported_claim',
        'rejection_reason': claimGuard ?? llmGuard,
      },
    );

    _recordSessionTurn(
      userMessage: userMessage,
      assistantMessage: finalMessage,
      intent: intent,
      usedModelOutput: usedModelOutput,
      activeRuntimeProfile: runtimeStatusBeforeGenerate.activeRuntimeProfile,
    );

    return LocalAgentReply(
      status: finalStatus,
      message: finalMessage,
      runtimeName: modelResponse.runtimeName,
      toolTraceJson: toolTraceJson,
      groundedSummaryJson: modelGroundingJson,
    );
  }

  /// Public entry-point for a date-scoped GI summary requested via the UI date
  /// picker. Bypasses intent routing — the caller has already handled UX.
  Future<LocalAgentReply> generateGiSummary({
    DateTime? startDate,
    DateTime? endDate,
    bool allDates = false,
    String? userMessage,
  }) async {
    final now = _nowProvider();
    final msg = userMessage ??
        (allDates
            ? 'Create a GI summary for all my data.'
            : (startDate != null && endDate != null)
                ? 'Create a GI summary from ${_shortDate(startDate)} to ${_shortDate(endDate)}.'
                : 'Create a GI summary for the last 30 days.');
    return _doctorSummaryReply(
      userMessage: msg,
      now: now,
      startDate: startDate,
      endDate: endDate,
      allDates: allDates,
    );
  }

  Future<LocalAgentReply> _doctorSummaryReply({
    required String userMessage,
    required DateTime now,
    DateTime? startDate,
    DateTime? endDate,
    bool allDates = false,
  }) async {
    final result = await _gemmaTaskService!.createDoctorSummary(
      startDate: startDate,
      endDate: endDate,
      allDates: allDates,
    );
    final toolTraceJson = <String, Object?>{
      'tools_called': [
        'get_doctor_summary_context',
        'create_doctor_summary_context',
        'create_doctor_summary',
      ],
      'asked_at': now.toIso8601String(),
      'gemma_task_run_id': result.taskRunId,
      'doctor_summary_id': result.summaryId,
      'used_model_output': result.usedModelOutput,
      'agent_intent': 'doctor_summary',
      'intent_raw': userMessage,
      'intent_normalized': 'doctor_summary',
      'task_contract': _ChatTaskContract.doctorSummary.name,
      'contract_route': _contractRouteName(_ChatTaskContract.doctorSummary),
      'tool_contract_results': _contractToolResults(
        _ChatTaskContract.doctorSummary,
        result.contextSummaryJson,
      ).map((item) => item.toJson()).toList(growable: false),
      'structured_sources_used': _structuredSourcesForContract(
        _ChatTaskContract.doctorSummary,
      ),
      'rag_query_required': false,
      'rag_query_performed': false,
      'rag_retrieved_count': 0,
      'rag_transaction_ids_used': const <String>[],
      'rag_write_expected_after_confirmation': false,
      'model_allowed_claims': _allowedClaimsForContract(
        _ChatTaskContract.doctorSummary,
      ),
      'model_forbidden_claims': _forbiddenClaimsForContract(
        _ChatTaskContract.doctorSummary,
      ),
      'response_grounding_status': 'grounded',
      'rejection_reason': null,
      'chat_path': 'doctor_summary',
      'summary_range_start': result.contextSummaryJson['range_start'],
      'summary_range_end': result.contextSummaryJson['range_end'],
      'summary_range_days': result.contextSummaryJson['range_days'],
      'summary_all_dates': allDates,
    };
    final groundedSummaryJson = result.contextSummaryJson;
    final message = _applySafetyEnvelope(
      _doctorSummaryChatReply(result.contextSummaryJson, result.summaryText),
      userMessage,
      intent: 'doctor_summary',
    );
    await _repository.insertConversation(
      ConversationRecord(
        createdAt: _nowProvider(),
        userMessage: userMessage,
        assistantMessage: message,
        toolTraceJson: toolTraceJson,
        groundedSummaryJson: groundedSummaryJson,
      ),
    );
    await _diagnosticLogService?.info(
      result.usedModelOutput
          ? 'doctor_summary_model_response'
          : 'doctor_summary_fallback_response',
      category: DiagnosticLogService.categoryChat,
      message: 'Doctor-summary chat flow completed locally.',
      metadata: {
        'used_model_output': result.usedModelOutput,
        'gemma_task_run_id': result.taskRunId,
      },
    );
    _recordSessionTurn(
      userMessage: userMessage,
      assistantMessage: message,
      intent: 'doctor_summary',
      usedModelOutput: result.usedModelOutput,
      activeRuntimeProfile: null,
    );
    return LocalAgentReply(
      status: result.status,
      message: message,
      runtimeName: result.usedModelOutput ? 'litert-lm-ios-gemma4' : 'fallback',
      toolTraceJson: toolTraceJson,
      groundedSummaryJson: groundedSummaryJson,
    );
  }

  String _doctorSummaryChatReply(
    Map<String, Object?> context,
    String summaryText,
  ) {
    final symptoms = context['symptoms'];
    final labs = context['labs'];
    final checkIns = context['check_ins'];
    final latestScore = context['latest_score'];
    final summaryCount = (context['summary_count'] as num?)?.toInt() ?? 0;
    final isSparseContext = latestScore == null &&
        summaryCount == 0 &&
        symptoms is List &&
        symptoms.isEmpty &&
        labs is List &&
        labs.isEmpty &&
        checkIns is List &&
        checkIns.isEmpty;

    if (summaryText.trim().isNotEmpty) {
      return _doctorSummaryDisplayText(summaryText);
    }

    // Fallback: Gemma was unavailable, build a minimal count-based blurb.
    if (isSparseContext) {
      return 'I could not build a GI summary draft yet because there is not enough saved symptom, check-in, or lab data in this window. '
          'Track symptoms, stool counts, bleeding, urgency, and labs before follow-up. '
          'If you currently have visible blood in stool, severe or worsening abdominal pain, fever, dehydration, fainting, or cannot keep liquids down, seek urgent care.';
    }
    final dataLimits = context['data_limits'];
    final parts = <String>[];
    if (symptoms is List && symptoms.isNotEmpty) {
      parts.add(
        '${symptoms.length} symptom item${symptoms.length == 1 ? '' : 's'}',
      );
    }
    if (labs is List && labs.isNotEmpty) {
      parts.add('${labs.length} lab item${labs.length == 1 ? '' : 's'}');
    }
    if (checkIns is List && checkIns.isNotEmpty) {
      parts.add(
        '${checkIns.length} check-in${checkIns.length == 1 ? '' : 's'}',
      );
    }
    final dataText = parts.isEmpty
        ? 'I did not find saved symptoms, labs, or check-ins in the selected window.'
        : 'It includes ${_joinHumanList(parts)} from local data.';
    final limits = dataLimits is List && dataLimits.isNotEmpty
        ? ' Data limits: ${_clip(dataLimits.take(2).join('; '), 180)}.'
        : '';
    final rangeDays = (context['range_days'] as num?)?.toInt() ?? 30;
    final rangeLabel = rangeDays >= 3000 ? 'full-history' : '$rangeDays-day';
    return 'I created a $rangeLabel GI summary draft locally. $dataText$limits You can review it and copy it into notes before a GI visit.';
  }

  String _doctorSummaryDisplayText(String raw) =>
      doctorSummaryDisplayTextForTest(raw);

  _ChatSessionState _ensureSession(DateTime now) {
    final current = _sessionState;
    if (current == null ||
        now.difference(current.lastUsedAt) > _sessionIdleTimeout) {
      _sessionState = _ChatSessionState(
        startedAt: now,
        lastUsedAt: now,
        turns: const [],
        rollingSummary: '',
        awaitingSymptomIntake: false,
        symptomIntakeClarifierCount: 0,
        symptomIntakeNonHealthCount: 0,
        awaitingGiSummaryDates: false,
      );
      _deliveredDisclaimers.clear();
    }
    return _sessionState!;
  }

  void _recordSessionTurn({
    required String userMessage,
    required String assistantMessage,
    required String intent,
    required bool usedModelOutput,
    required String? activeRuntimeProfile,
    String? activeTopic,
    bool? awaitingSymptomIntake,
    int? symptomIntakeClarifierCount,
    int? symptomIntakeNonHealthCount,
    bool? awaitingGiSummaryDates,
  }) {
    final now = _nowProvider();
    final current = _ensureSession(now);
    final safeAssistant = ChatOutputSanitizer.inspect(
      _stripRuntimeLoadingNotice(assistantMessage),
      userMessage: userMessage,
    ).cleanedText;
    final nextTurns = [
      ...current.turns,
      _ChatSessionTurn(
        userMessage: _clip(userMessage, 200),
        assistantMessage: _clip(safeAssistant, 500),
        intent: intent,
      ),
    ];
    final trimmedTurns = nextTurns.length > _maxSessionTurns
        ? nextTurns.sublist(nextTurns.length - _maxSessionTurns)
        : nextTurns;
    // Derive activeTopic: explicit override > intent-based derivation > keep prior
    final resolvedTopic =
        activeTopic ?? _activeTopicForIntent(intent) ?? current.activeTopic;
    final resolvedAwaitingSymptomIntake = awaitingSymptomIntake ??
        switch (intent) {
          'symptom_log_followup' => current.awaitingSymptomIntake,
          'symptom_review_pending' => false,
          'symptom_question' => false,
          'multi_symptom_log' => false,
          'check_in_log' => false,
          'continuation' => current.awaitingSymptomIntake,
          _ => false,
        };
    final resolvedClarifierCount = symptomIntakeClarifierCount ??
        (intent == 'symptom_review_pending'
            ? 0
            : intent == 'symptom_log_followup'
                ? current.symptomIntakeClarifierCount
                : 0);
    // Non-health count resets to 0 whenever the session exits symptom intake.
    // Explicit override takes precedence; otherwise preserve within-intake value.
    final resolvedNonHealthCount = symptomIntakeNonHealthCount ??
        (resolvedAwaitingSymptomIntake
            ? current.symptomIntakeNonHealthCount
            : 0);
    _sessionState = current.copyWith(
      lastUsedAt: now,
      turns: trimmedTurns,
      rollingSummary: _summarizeSession(trimmedTurns),
      awaitingSymptomIntake: resolvedAwaitingSymptomIntake,
      symptomIntakeClarifierCount: resolvedClarifierCount,
      symptomIntakeNonHealthCount: resolvedNonHealthCount,
      awaitingGiSummaryDates: awaitingGiSummaryDates ?? false,
      activeRuntimeProfile: activeRuntimeProfile,
      activeTopic: resolvedTopic,
    );
  }

  String? _activeTopicForIntent(String intent) {
    return switch (intent) {
      'doctor_summary' => 'doctor_summary',
      'daily_summary' => 'daily_summary',
      'week_summary' => 'week_summary',
      'risk_question' => 'risk_briefing',
      'lab_question' => 'lab_review',
      'symptom_question' => 'symptom_review',
      'medication_context' => 'medication_context',
      'food_trigger_analysis' => 'food_trigger_analysis',
      'hrv_trend_analysis' => 'hrv_trend_analysis',
      'activity_pattern_analysis' => 'activity_pattern_analysis',
      'visit_preparation' => 'visit_preparation',
      _ => null,
    };
  }

  String _summarizeSession(List<_ChatSessionTurn> turns) {
    if (turns.isEmpty) return '';
    final topics = turns
        .map((turn) => _plainIntentLabel(turn.intent))
        .toSet()
        .take(3)
        .join(', ');
    final last = turns.last;
    return 'Recent topics: $topics. Latest grounded answer: ${_clip(last.assistantMessage, 300)}';
  }

  String _plainIntentLabel(String intent) {
    return switch (intent) {
      'risk_question' => 'risk changes',
      'confidence_question' => 'score confidence',
      'lab_question' => 'lab context',
      'daily_summary' => 'daily patterns',
      'week_summary' => 'weekly patterns',
      'symptom_question' => 'symptoms',
      'symptom_explanation' => 'symptom explanation',
      'followup_expand' => 'more detail',
      'followup_compare' => 'changes over time',
      'followup_correction' => 'correction',
      'symptom_log_followup' => 'symptom logging',
      'doctor_summary' => 'doctor summary',
      'emotional_support' => 'emotional support',
      'emotional_vent_with_symptoms' => 'emotional support + symptom offer',
      'medication_question' => 'medication question',
      'diet_question' => 'diet question',
      'data_gap_question' => 'data gap',
      'out_of_scope' => 'off-topic',
      'urgent_safety' => 'urgent symptom',
      'greeting' => 'greeting',
      'smalltalk' => 'small talk',
      _ => 'general health question',
    };
  }

  String _dialogStateForTrace(_ChatSessionState session) {
    if (session.awaitingSymptomIntake) return 'symptom_intake_pending';
    if (session.awaitingGiSummaryDates) return 'gi_summary_awaiting_dates';
    return session.activeTopic ?? 'none';
  }

  String _classifierReasonForTrace({
    required String intent,
    required String lower,
    required _ChatSessionState session,
    required _ChatTaskContract taskContract,
  }) {
    if (intent == 'urgent_safety') return 'priority_urgent_safety';
    if (session.awaitingSymptomIntake) return 'priority_active_symptom_intake';
    if (session.awaitingGiSummaryDates) return 'priority_gi_summary_dates';
    if (intent == 'medication_log' || intent == 'symptom_log_followup') {
      return 'priority_confirmed_write_or_review_action';
    }
    if (intent == 'medication_context' || intent == 'medication_question') {
      return 'priority_medication_context_or_boundary';
    }
    if (intent == 'lab_question') return 'priority_lab_intake_or_recall';
    if (intent == 'check_in_log' || _isCheckInStartRequest(lower)) {
      return 'priority_check_in';
    }
    if (intent == 'daily_summary' ||
        intent == 'week_summary' ||
        intent == 'doctor_summary' ||
        taskContract == _ChatTaskContract.doctorSummary) {
      return 'priority_summary_or_report';
    }
    if (intent == 'general_health_question' && _isIbdKnowledgeRequest(lower)) {
      return 'priority_ibd_education';
    }
    if (intent == 'app_meta_question') return 'priority_app_meta';
    if (intent == 'out_of_scope') return 'priority_off_topic_redirect';
    return 'priority_general_router_match';
  }

  // Emotional and general-health intents use a lower temperature to suppress
  // analytical persona drift when grounding context is data-rich.
  static double _temperatureFor(String intent) {
    return switch (intent) {
      'emotional_support' ||
      'emotional_vent_with_symptoms' ||
      'general_health_question' =>
        0.22,
      _ => 0.35,
    };
  }

  int _bytesToMb(int? bytes) {
    if (bytes == null || bytes <= 0) return -1;
    return (bytes / (1024 * 1024)).round();
  }

  String _modelRoleForIntent(String intent) {
    return switch (intent) {
      'doctor_summary' => 'doctor_summary',
      'daily_summary' => 'deep_analysis',
      'week_summary' => 'deep_analysis',
      'followup_compare' => 'deep_analysis',
      'followup_expand' => 'deep_analysis',
      'continuation' => 'deep_analysis',
      'lab_question' => 'deep_analysis',
      _ => 'daily_fast',
    };
  }

  String _contextPolicyForIntent(String intent) {
    return switch (intent) {
      'doctor_summary' => 'large_128k',
      'daily_summary' => 'large_128k',
      'week_summary' => 'large_128k',
      'followup_compare' => 'large_128k',
      'followup_expand' => 'large_128k',
      'continuation' => 'standard',
      'lab_question' => 'standard',
      _ => 'standard',
    };
  }

  String _buildUserPromptWithHistory(
    String userMessage,
    List<ConversationRecord> history,
    _ChatSessionState session,
    String intent,
  ) {
    final buffer = StringBuffer();
    if (session.rollingSummary.isNotEmpty) {
      // Bug-E: instruct Gemma to use this for context only, not quote it back
      buffer.writeln(
        'Session summary (background context — do not repeat or paraphrase this in your reply): '
        '${_clip(session.rollingSummary, 320)}',
      );
      buffer.writeln();
    }
    if (session.activeTopic != null) {
      buffer.writeln('Active topic: ${session.activeTopic}');
      buffer.writeln();
    }
    final sessionTurns = session.turns;
    final safeHistory =
        sessionTurns.isNotEmpty ? sessionTurns : _selectDbHistory(history);
    if (safeHistory.isNotEmpty) {
      buffer.writeln('Recent turns:');
    }
    for (final turn in safeHistory.reversed) {
      buffer.writeln('User: ${_clip(turn.userMessage, 160)}');
      buffer.writeln('Gemma Flares: ${_clip(turn.assistantMessage, 260)}');
    }
    final followUpHint = _followUpHint(intent);
    if (followUpHint != null) {
      buffer.writeln();
      buffer.writeln('Follow-up guidance: $followUpHint');
    }
    if (buffer.isNotEmpty) {
      buffer.writeln();
    }
    buffer.writeln('Current message: ${_clip(userMessage, 320)}');
    return buffer.toString();
  }

  /// Selects, filters, and budget-caps history turns from the DB for injection
  /// into the model user-prompt.
  ///
  /// [history] is ordered **newest-first** (ORDER BY created_at DESC).  The
  /// returned list preserves that order so the caller can call `.reversed` to
  /// emit turns oldest-first, matching natural conversation flow in the prompt.
  ///
  /// Hardening guarantees
  /// ─────────────────────
  /// • [ChatOutputSanitizer.inspect] is called **exactly once** per candidate
  ///   turn (the previous inline `.where`+`.map` chain called it twice).
  /// • Turns with a blank user or assistant message (e.g. from an interrupted
  ///   write) are silently skipped.
  /// • The accumulated rendered char cost is capped at [_kHistoryCharBudget]
  ///   so a large DB cannot inflate the on-device context window.  Newest
  ///   turns are prioritised because we iterate newest-first.
  /// • At most 20 turns are returned regardless of the budget.
  List<_ChatSessionTurn> _selectDbHistory(List<ConversationRecord> history) {
    final result = <_ChatSessionTurn>[];
    var charBudget = _kHistoryCharBudget;
    for (final turn in history) {
      if (result.length >= 20 || charBudget <= 0) break;
      // Skip transactional pending-action saves — not conversational context.
      if (turn.toolTraceJson['pending_action_type'] != null) continue;
      // Skip turns where the model ran but the output was later rejected.
      final usedModel = turn.toolTraceJson['used_model_output'] == true;
      final quality = turn.toolTraceJson['output_quality_status'];
      if (usedModel && quality != null && quality != 'accepted') continue;
      // Skip turns with blank messages (e.g. from an interrupted DB write).
      if (turn.userMessage.trim().isEmpty ||
          turn.assistantMessage.trim().isEmpty) {
        continue;
      }
      // Inspect once; reuse both .status and .cleanedText.
      final inspected = ChatOutputSanitizer.inspect(
        _stripRuntimeLoadingNotice(turn.assistantMessage),
        userMessage: turn.userMessage,
      );
      if (inspected.status != 'accepted') continue;
      // Approximate rendered cost using the same clip bounds as the render
      // loop, avoiding a string allocation just for the budget calculation.
      final cost = turn.userMessage.length.clamp(0, 160) +
          inspected.cleanedText.length.clamp(0, 260);
      charBudget -= cost;
      result.add(
        _ChatSessionTurn(
          userMessage: turn.userMessage,
          assistantMessage: inspected.cleanedText,
          intent: turn.toolTraceJson['agent_intent'] as String? ??
              'general_health_question',
        ),
      );
    }
    return result;
  }

  String? _followUpHint(String intent) {
    return switch (intent) {
      'followup_expand' =>
        'Stay on the same topic as the previous answer and add one layer of grounded detail.',
      'followup_compare' =>
        'Compare today with yesterday or the recent baseline when grounded data allows.',
      'followup_correction' =>
        'The user thinks the last answer was off. Re-check grounded facts and correct the mistake plainly.',
      'symptom_log_followup' =>
        'The user wants to turn a recent symptom description into a draft note for review.',
      _ => null,
    };
  }

  String _fallbackReply({
    required String userMessage,
    required FlareRiskScoreRecord? latestScore,
    List<DailySummaryRecord> recentSummaries = const [],
    required List<SymptomRecord> recentSymptoms,
    List<LabValueRecord> recentLabs = const [],
    Map<String, Object?> checkInTrend = const {},
    EndoscopyRecord? latestProcedure,
    Map<String, Object?>? contextFeatures,
    List<Map<String, Object?>> earlyWarningOutlook = const [],
    List<RagMemoryTransactionRecord> ragTransactions = const [],
  }) {
    final lower = userMessage.toLowerCase();
    final isGreeting = _isGreeting(lower);
    final intent = _classifyIntent(lower);
    // Hoist here so early-return paths (data_gap_question, etc.) can also
    // use the UI-consistent flare display without recomputing.
    final ready7dOutlook = _readyUserFacingRiskPoint(
      latestScore: latestScore,
      outlook: earlyWarningOutlook,
      horizonDays: 7,
    );

    // Handle intents that don't need score data
    if (intent == 'urgent_safety') {
      return 'I can hear that things are really tough right now. Please reach out to your GI doctor or urgent care as soon as you can — they are the best people to help you right now. If it feels like an emergency, do not hesitate to call 911 or go to the ER.';
    }
    if (intent == 'emotional_support') {
      return _applySafetyEnvelope(
        'I hear you — that sounds really hard. Living with this is exhausting, and those feelings make complete sense. '
        'Tell me what\'s going on and I can help log it, or we can look at your recent data together.',
        userMessage,
      );
    }
    if (intent == 'emotional_vent_with_symptoms') {
      return _applySafetyEnvelope(
        'I hear you — that sounds really tough. It\'s okay to have hard days with this. '
        'Tell me what\'s going on and I can build a quick note for your timeline.',
        userMessage,
      );
    }
    if (intent == 'general_health_question') {
      // IBD education answer — use grounded framing. Since Gemma may be
      // unavailable, provide a deterministic bridge that still feels helpful.
      return _applySafetyEnvelope(
        'That\'s a good question. I can share general IBD information, though your GI team is always the best source for your specific situation. '
        'What would you like to know more about?',
        userMessage,
      );
    }
    if (intent == 'out_of_scope') {
      return 'That is a bit outside what I can help with — I am focused on health data and IBD tracking. I can help with symptoms, labs, check-ins, or recent patterns.';
    }
    if (intent == 'medication_question') {
      return _applySafetyEnvelope(
        'Great question, but medication decisions really need to come from your GI doctor — I am not able to give advice there. What I can do is show you symptom timing and patterns that might be useful to discuss at your next appointment.',
        userMessage,
      );
    }
    if (intent == 'diet_question') {
      return _applySafetyEnvelope(
        'Diet is really personal with IBD. I can show you symptom patterns that might line up with meals, but for specific dietary advice, a registered dietitian who knows IBD is your best bet. Want me to look at your recent symptom timing instead?',
        userMessage,
      );
    }
    if (intent == 'data_gap_question') {
      // Safety net: urgent or distress patterns must never silently collapse to
      // an Apple Health sync fallback.
      if (_isUrgentSymptom(lower)) {
        return 'I can hear that things are really tough right now. Please reach out to your GI doctor or urgent care as soon as you can — they are the best people to help you right now. If it feels like an emergency, do not hesitate to call 911 or go to the ER.';
      }
      if (_isEmotionalDistress(lower)) {
        return _applySafetyEnvelope(
          'I hear you — that sounds really hard. Living with this is exhausting, and those feelings make complete sense. '
          'Tell me what\'s going on and I can help log it, or we can look at your recent data together.',
          userMessage,
        );
      }
      if (_saysHealthAlreadySynced(lower) && latestScore != null) {
        final latestTransaction = ragTransactions.isEmpty
            ? null
            : ragTransactions.first.transactionId;
        final transactionText = latestTransaction == null
            ? ''
            : ' Latest memory transaction: $latestTransaction.';
        return _applySafetyEnvelope(
          'You are right — I can see synced health data locally. Your current flare risk is ${_flareRiskDisplay(ready7dOutlook)} (${latestScore.riskBand}).$transactionText Ask me what changed, or send a symptom/lab and I will keep it tied to this local record.',
          userMessage,
        );
      }
      return 'It looks like some data might be missing. Make sure your Apple Watch is syncing with the Health app, and try opening Gemma Flares so it can pull in the latest data. More data means better insights — even a few days of regular syncing makes a difference!';
    }
    final appFeatureReply = _appFeatureReply(lower);
    if (appFeatureReply != null) {
      return _applySafetyEnvelope(appFeatureReply, userMessage);
    }
    if (_isMemoryPrivacyQuestion(lower)) {
      return 'Your Gemma Flares memory is local. New health records are only written after review/confirmation, and you can inspect, export, retry, or delete local memory from Settings.';
    }
    if (intent == 'smalltalk') {
      return 'Of course. I am here when you want to check symptoms, labs, or your latest Gemma Flares pattern.';
    }
    if (intent == 'lab_question' &&
        _isLabExplanationRequest(lower) &&
        recentLabs.isNotEmpty) {
      return _latestLabsSummary(
        labs: recentLabs,
        ragTransactions: ragTransactions,
        userMessage: userMessage,
      );
    }
    final actionReply = _deterministicActionReply(
      userMessage: userMessage,
      intent: intent,
      session: _sessionState ?? _ensureSession(_nowProvider()),
    );
    if (actionReply != null) {
      return _applySafetyEnvelope(actionReply, userMessage);
    }

    if (latestScore == null) {
      if ((intent == 'daily_summary' || intent == 'week_summary') &&
          _hasSummaryGrounding(
            recentSummaries: recentSummaries,
            recentSymptoms: recentSymptoms,
            recentLabs: recentLabs,
            checkInTrend: checkInTrend,
            ragTransactions: ragTransactions,
          )) {
        final summaryReply = _changeComparisonReply(
          intent: intent,
          userMessage: userMessage,
          latestScore: null,
          recentSummaries: recentSummaries,
          recentSymptoms: recentSymptoms,
          recentLabs: recentLabs,
          checkInTrend: checkInTrend,
          latestProcedure: latestProcedure,
          ragTransactions: ragTransactions,
          contextFeatures: contextFeatures,
        );
        return _applySafetyEnvelope(summaryReply, userMessage);
      }
      final message = isGreeting
          ? 'Hi! How are you feeling today? Once you sync your Apple Health data, I can help you understand your Gemma Flares score and track changes over time.'
          : _noDataReplyForIntent(intent);
      return _applySafetyEnvelope(message, userMessage);
    }

    final contributions = latestScore.contributionJson;
    final drivers = _driverContributions(contributions);
    final driverText = drivers.isEmpty
        ? 'no strong signals'
        : drivers.map((driver) => driver.label).join(', ');
    final band = latestScore.riskBand;
    final conf = latestScore.confidenceScore.round();
    final contextReason = (latestScore
            .contributionJson['context_attribution_reason'] as String?) ??
        (contextFeatures?['context_attribution_reason'] as String?);
    final contextText = _plainContextReason(contextReason);
    final bandPhrase = _plainBandPhrase(band);
    // ready7dOutlook is hoisted to top of _fallbackReply — do not redeclare.
    final horizonText = ready7dOutlook == null
        ? ''
        : _riskHorizonInterpretation(latestScore, readyOutlook: ready7dOutlook);

    // Intent-specific fallbacks when LLM is unavailable but data exists.
    // These are last-resort templates — the LLM should handle the real response.
    // Use _flareRiskDisplay (the UI-consistent %) everywhere a score is shown.
    final flareDisplay = _flareRiskDisplay(ready7dOutlook);
    final summary = switch (intent) {
      'greeting' => ready7dOutlook == null
          ? 'Hi! How are you feeling today? I am still building your personal baseline — keep logging check-ins and I can start showing you risk patterns soon.'
          : 'Hi! How are you feeling today? Your 7-day flare risk is $flareDisplay — $bandPhrase. I can dig into what that means or look at recent patterns whenever you are ready.',
      'confidence_question' => _confidenceExplanation(latestScore),
      'risk_question' => ready7dOutlook == null
          ? _learningFlareRiskReply(
              hasSignalIndex: true,
              driverText: driverText,
              contextText: contextText,
            )
          : _readyFlareRiskReply(
              outlook: ready7dOutlook,
              confidence: conf,
              driverText: driverText,
              contextText: contextText,
              horizonText: horizonText,
            ),
      'forecast_watchlist' => ready7dOutlook == null
          ? 'Your 7-day flare-risk estimate is still learning, so I will not call the internal signal index a flare percentage yet. Track these daily: $driverText. If symptoms worsen over 2-3 days, contact your GI team proactively.'
          : 'Based on your current data, here are the signals to keep an eye on: $driverText. Estimated 7-day flare risk is $flareDisplay (${ready7dOutlook['band']}). If any of these signals worsen — more frequent urgency, rising pain, or more disrupted sleep — log a check-in so your trend data stays current. If things escalate over 2-3 days, reach out to your GI team proactively.',
      'followup_expand' || 'continuation' => ready7dOutlook == null
          ? 'Let me pull more context. Main signals: $driverText. $contextText Ask me about a specific signal or say "Create a GI summary" for a full export.'
          : 'Let me pull more context. Your 7-day flare risk is $flareDisplay ($bandPhrase), confidence $conf/100. $horizonText Main signals: $driverText. $contextText Ask me about a specific signal or say "Create a GI summary" for a full export.',
      'followup_compare' => ready7dOutlook == null
          ? 'Ask me "what changed this week" or "how does today compare to last week" and I can pull a side-by-side from your data.'
          : 'Comparing trends: your 7-day flare risk is $flareDisplay ($bandPhrase). Ask me "what changed this week" or "how does today compare to last week" and I can pull a side-by-side from your data.',
      'daily_summary' || 'week_summary' => _changeComparisonReply(
          intent: intent,
          userMessage: userMessage,
          latestScore: latestScore,
          recentSummaries: recentSummaries,
          recentSymptoms: recentSymptoms,
          recentLabs: recentLabs,
          checkInTrend: checkInTrend,
          latestProcedure: latestProcedure,
          ragTransactions: ragTransactions,
          contextFeatures: contextFeatures,
          earlyWarningOutlook: earlyWarningOutlook,
        ),
      'app_meta_question' =>
        'Gemma Flares tracks IBD patterns using your wearable data, symptom logs, labs, and check-ins. I can explain your flare risk, log new symptoms, summarise lab results, and generate GI reports — but I cannot give medical advice or diagnose. Ask me anything specific.',
      'check_in_log' =>
        'Tell me your check-in: belly pain (0–3 scale), stool frequency, any urgency or bleeding, and anything unusual like fatigue, fever, or missed medication. I will show a review card before saving.',
      'multi_symptom_log' ||
      'symptom_log_followup' =>
        'I can log all of that for you. Tell me each symptom with detail — pain level, frequency, and timing — and I will build a review card before saving anything.',
      'symptom_question' => () {
          final count = recentSymptoms.length;
          final word = count == 1 ? 'entry' : 'entries';
          final riskPart = ready7dOutlook == null
              ? ''
              : ' Your 7-day flare risk is $flareDisplay ($bandPhrase).';
          return 'You have $count recent symptom $word in your log.$riskPart Want me to go through the recent logs?';
        }(),
      // When a lab value is present, acknowledge receipt instead of asking user
      // to paste values — the intake prompt is wrong if values are already there.
      'lab_question' => _looksLikeLabValues(lower)
          ? 'I can see lab values in your message. The on-device model is currently unavailable to extract and structure them — try again in a moment, or paste the values in a standard format (e.g., "CRP 18 mg/L") and I\'ll queue them for review.'
          : _labIntakeStartReply(),
      _ => ready7dOutlook == null
          ? 'Main signals in your data: $driverText. $contextText I can look at symptoms, labs, check-ins, or give you a weekly summary — just ask.'
          : 'Your 7-day flare risk is $flareDisplay ($bandPhrase), confidence $conf/100. $horizonText Main signals: $driverText. $contextText I can look at symptoms, labs, check-ins, or give you a weekly summary — just ask.',
    };

    return _applySafetyEnvelope(summary, userMessage);
  }

  bool _hasSummaryGrounding({
    required List<DailySummaryRecord> recentSummaries,
    required List<SymptomRecord> recentSymptoms,
    required List<LabValueRecord> recentLabs,
    required Map<String, Object?> checkInTrend,
    required List<RagMemoryTransactionRecord> ragTransactions,
  }) {
    if (recentSummaries.isNotEmpty ||
        recentSymptoms.isNotEmpty ||
        recentLabs.isNotEmpty) {
      return true;
    }
    final surveys = checkInTrend['surveys'];
    if (surveys is List && surveys.isNotEmpty) return true;
    return ragTransactions.any(
      (tx) => tx.status == 'verified' || tx.status == 'written_to_corpus',
    );
  }

  String _changeComparisonReply({
    required String intent,
    required String userMessage,
    required FlareRiskScoreRecord? latestScore,
    required List<DailySummaryRecord> recentSummaries,
    required List<SymptomRecord> recentSymptoms,
    required List<LabValueRecord> recentLabs,
    required Map<String, Object?> checkInTrend,
    EndoscopyRecord? latestProcedure,
    List<RagMemoryTransactionRecord> ragTransactions = const [],
    Map<String, Object?>? contextFeatures,
    List<Map<String, Object?>> earlyWarningOutlook = const [],
  }) {
    final lower = userMessage.toLowerCase();
    final summaryWindow = _summaryWindowForIntent(intent: intent, lower: lower);
    final todayDate = _dateFromDateTimeUtc(_nowProvider());
    final windowRange = _summaryWindowRange(summaryWindow, todayDate);
    final window = _summaryWindowLabel(summaryWindow);
    final parts = <String>[];

    final summariesInWindow = recentSummaries
        .where(
          (item) => _isDateInRange(
            item.dateLocal,
            startDate: windowRange.startDate,
            endDate: windowRange.endDate,
          ),
        )
        .toList(growable: false);
    final symptomsInWindow = recentSymptoms
        .where(
          (item) => _isDateInRange(
            _dateFromDateTimeUtc(item.loggedAt),
            startDate: windowRange.startDate,
            endDate: windowRange.endDate,
          ),
        )
        .toList(growable: false);
    final checkinsInWindow = (checkInTrend['surveys'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, Object?>.from(row))
        .where(
          (row) => _isDateInRange(
            row['date']?.toString() ?? '',
            startDate: windowRange.startDate,
            endDate: windowRange.endDate,
          ),
        )
        .toList(growable: false);
    final labsInWindow = recentLabs
        .where(
          (item) => _isDateInRange(
            item.drawnDate,
            startDate: windowRange.startDate,
            endDate: windowRange.endDate,
          ),
        )
        .toList(growable: false);
    final proceduresInWindow = latestProcedure != null &&
            _isDateInRange(
              latestProcedure.procedureDate,
              startDate: windowRange.startDate,
              endDate: windowRange.endDate,
            )
        ? [latestProcedure]
        : const <EndoscopyRecord>[];
    final ragInWindow = ragTransactions
        .where(
          (item) => _isDateInRange(
            _dateFromDateTimeUtc(item.createdAt),
            startDate: windowRange.startDate,
            endDate: windowRange.endDate,
          ),
        )
        .toList(growable: false);

    // Only show the score when the outlook model is ready. In learning state the
    // internal signal index exists but is not a calibrated user-facing number —
    // showing it here would contradict the "Learning" reply from risk_question.
    // Use the UI-consistent flare % (_flareRiskDisplay) not the raw signal index.
    final ready7dForCompare = _readyUserFacingRiskPoint(
      latestScore: latestScore,
      outlook: earlyWarningOutlook,
      horizonDays: 7,
    );
    if (latestScore != null && ready7dForCompare != null) {
      final flarePercent = _outlookPercentText(ready7dForCompare);
      // Include the band literal (e.g. "moderate") so downstream consumers and
      // tests can match on it, plus the plain-language phrase for users.
      final bandLiteral = latestScore.riskBand.toLowerCase();
      final bandPhrase = _plainBandPhrase(latestScore.riskBand);
      final confidence = latestScore.confidenceScore.round();
      final drivers = _driverContributions(
        latestScore.contributionJson,
      ).map((driver) => driver.label).take(4).toList(growable: false);
      parts.add(
        drivers.isEmpty
            ? 'Your 7-day flare risk is $flarePercent ($bandLiteral — $bandPhrase), confidence $confidence/100, with no single dominant driver.'
            : 'Your 7-day flare risk is $flarePercent ($bandLiteral — $bandPhrase), confidence $confidence/100; main drivers are ${_joinHumanList(drivers)}.',
      );
    }

    final wearableSummary = _windowWearableSummary(
      window: summaryWindow,
      summariesInWindow: summariesInWindow,
      windowLabel: window,
    );
    if (wearableSummary != null) {
      parts.add(wearableSummary);
    }

    if (checkinsInWindow.isNotEmpty) {
      final count = checkinsInWindow.length;
      final scores = checkinsInWindow
          .map((row) => (row['score'] as num?)?.toDouble())
          .whereType<double>()
          .toList(growable: false);
      final avgScore = scores.isEmpty
          ? null
          : scores.fold<double>(0, (sum, value) => sum + value) / scores.length;
      final flareCount =
          checkinsInWindow.where((row) => row['is_flare'] == true).length;
      final avgPhrase =
          avgScore == null ? '' : ' (average score ${_formatNumber(avgScore)})';
      parts.add(
        flareCount == 0
            ? 'Recent check-ins ($window): $count entries$avgPhrase with no flare flags.'
            : 'Recent check-ins ($window): $count entries$avgPhrase with $flareCount flare-flagged day${flareCount == 1 ? '' : 's'}.',
      );
    }

    if (symptomsInWindow.isNotEmpty) {
      final symptomNames = symptomsInWindow
          .map((symptom) => symptom.symptomType.replaceAll('_', ' '))
          .where((value) => value.trim().isNotEmpty)
          .toSet()
          .take(3)
          .toList(growable: false);
      if (symptomNames.isNotEmpty) {
        parts.add(
          'Recent symptom logs ($window) mention ${_joinHumanList(symptomNames)}.',
        );
      }
    }

    if (labsInWindow.isNotEmpty) {
      final sortedLabs = [...labsInWindow]
        ..sort((left, right) => right.drawnDate.compareTo(left.drawnDate));
      final latestLab = sortedLabs.first;
      final labName = _labDisplayName(latestLab.labType);
      final value = _formatNumber(latestLab.valueNumeric);
      final unit = latestLab.unit.trim().isEmpty ? '' : ' ${latestLab.unit}';
      parts.add(
        'Latest saved lab ($window): $labName $value$unit on ${latestLab.drawnDate}.',
      );
    }

    if (proceduresInWindow.isNotEmpty) {
      parts.add(
        'Latest procedure note: ${_procedureSummary(proceduresInWindow.first)}.',
      );
    }

    if (ragInWindow.isNotEmpty) {
      final localMemorySources = ragInWindow
          .where(
            (tx) => tx.status == 'verified' || tx.status == 'written_to_corpus',
          )
          .map((tx) => tx.sourceType)
          .toSet()
          .toList(growable: false);
      if (localMemorySources.isNotEmpty) {
        parts.add(
          'Other saved entries in local memory include ${_joinHumanList(localMemorySources)}.',
        );
      }
    }

    final contextReason =
        (contextFeatures?['context_attribution_reason'] as String?);
    final contextText = _plainContextReason(contextReason);
    if (contextText.isNotEmpty) parts.add(contextText);

    if (parts.isEmpty) {
      return 'I do not have enough local history for $window yet. Add a check-in, symptom log, lab, or a few days of synced wearable data and I can summarize what changed.';
    }

    if (intent == 'followup_compare') {
      final compareWindow = switch (summaryWindow) {
        'daily' => 'today',
        'monthly' => 'this month',
        _ => 'this week',
      };
      return 'Here is what changed $compareWindow: ${parts.join(' ')}';
    }

    return 'Here is your $window summary up to now: ${parts.join(' ')}';
  }

  ({String startDate, String endDate}) _summaryWindowRange(
    String summaryWindow,
    String endDate,
  ) {
    final startDate = switch (summaryWindow) {
      'daily' => endDate,
      'monthly' => _offsetDate(endDate, -29),
      _ => _offsetDate(endDate, -6),
    };
    return (startDate: startDate, endDate: endDate);
  }

  String _summaryWindowLabel(String summaryWindow) {
    return switch (summaryWindow) {
      'daily' => 'today so far',
      'monthly' => 'last 30 days',
      _ => 'last 7 days',
    };
  }

  String _requestedSummaryWindow(String lower) {
    final normalized = _normalizeIntentText(lower);
    if (normalized.contains('month') || normalized.contains('monthly')) {
      return 'monthly';
    }
    if (normalized.contains('daily summary') ||
        normalized.contains('today summary') ||
        normalized.contains('summary for today') ||
        normalized.contains('summarize today') ||
        normalized.contains('day summary') ||
        normalized.contains('daily') ||
        normalized.contains('today')) {
      return 'daily';
    }
    if (normalized.contains('week') || normalized.contains('weekly')) {
      return 'weekly';
    }
    return 'weekly';
  }

  String _summaryWindowForIntent({
    required String intent,
    required String lower,
  }) {
    final requested = _requestedSummaryWindow(lower);
    // Keep explicit monthly phrasing as the top override for both summary intents.
    if (requested == 'monthly') return requested;
    if (intent == 'daily_summary') return 'daily';
    if (intent == 'week_summary') return 'weekly';
    return requested;
  }

  String _resolveSummaryIntent(String normalizedLower) {
    final wantsDaily = _isDailySummaryRequest(normalizedLower);
    final wantsWeekly = _isWeeklySummaryRequest(normalizedLower);
    if (wantsDaily && wantsWeekly) {
      final explicitDaily = normalizedLower.contains('daily summary') ||
          normalizedLower.contains('today summary') ||
          normalizedLower.contains('day summary');
      final explicitWeekly = normalizedLower.contains('weekly summary') ||
          normalizedLower.contains('week summary') ||
          normalizedLower.contains('weekly recap');
      if (explicitDaily && !explicitWeekly) return 'daily_summary';
      if (explicitWeekly && !explicitDaily) return 'week_summary';
      final dailySummaryIndex = normalizedLower.indexOf('daily summary');
      final weeklySummaryIndex = normalizedLower.indexOf('weekly summary');
      if (dailySummaryIndex >= 0 && weeklySummaryIndex >= 0) {
        return dailySummaryIndex <= weeklySummaryIndex
            ? 'daily_summary'
            : 'week_summary';
      }
      return 'week_summary';
    }
    if (wantsDaily) return 'daily_summary';
    return 'week_summary';
  }

  bool _isDateInRange(
    String date, {
    required String startDate,
    required String endDate,
  }) {
    if (date.length != 10) return false;
    return date.compareTo(startDate) >= 0 && date.compareTo(endDate) <= 0;
  }

  String _dateFromDateTimeUtc(DateTime dateTime) {
    final utc = dateTime.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')}';
  }

  String? _windowWearableSummary({
    required String window,
    required List<DailySummaryRecord> summariesInWindow,
    required String windowLabel,
  }) {
    if (summariesInWindow.isEmpty) return null;
    final byDateDesc = [...summariesInWindow]
      ..sort((left, right) => right.dateLocal.compareTo(left.dateLocal));
    if (window == 'daily') {
      final snippets = _dailySummarySnippets(byDateDesc.first.summaryJson);
      if (snippets.isEmpty) return null;
      return 'Apple Health summary ($windowLabel): ${_joinHumanList(snippets)}.';
    }

    final steps = byDateDesc
        .map(
          (item) => (item.summaryJson['step_count_total'] as num?)?.toDouble(),
        )
        .whereType<double>()
        .toList(growable: false);
    final sleep = byDateDesc
        .map(
          (item) =>
              (item.summaryJson['sleep_total_minutes'] as num?)?.toDouble(),
        )
        .whereType<double>()
        .toList(growable: false);
    final restingHr = byDateDesc
        .map(
          (item) => (item.summaryJson['resting_hr_mean'] as num?)?.toDouble(),
        )
        .whereType<double>()
        .toList(growable: false);
    final hrv = byDateDesc
        .map((item) => (item.summaryJson['hrv_sdnn_mean'] as num?)?.toDouble())
        .whereType<double>()
        .toList(growable: false);

    final parts = <String>[];
    if (steps.isNotEmpty) {
      final total = steps.fold<double>(0, (sum, value) => sum + value);
      final average = total / steps.length;
      parts.add(
        '${total.round()} steps total (${_formatNumber(average)} per day)',
      );
    }
    if (sleep.isNotEmpty) {
      final average =
          sleep.fold<double>(0, (sum, value) => sum + value) / sleep.length;
      parts.add('sleep ${_formatNumber(average)} min/day');
    }
    if (restingHr.isNotEmpty) {
      final average = restingHr.fold<double>(0, (sum, value) => sum + value) /
          restingHr.length;
      parts.add('resting heart rate ${_formatNumber(average)} bpm');
    }
    if (hrv.isNotEmpty) {
      final average =
          hrv.fold<double>(0, (sum, value) => sum + value) / hrv.length;
      parts.add('HRV ${_formatNumber(average)} ms');
    }
    if (parts.isEmpty) return null;
    return 'Apple Health summary ($windowLabel): ${_joinHumanList(parts)}.';
  }

  Map<String, Object?> _buildSummaryWindowRollups({
    required String todayDate,
    required List<DailySummaryRecord> dailySummaries,
    required List<SymptomRecord> symptoms,
    required List<Pro2SurveyRecord> checkIns,
    required List<LabValueRecord> labs,
    required List<EndoscopyRecord> procedures,
    required List<RagMemoryTransactionRecord> ragTransactions,
  }) {
    Map<String, Object?> rollupForWindow(String window) {
      final range = _summaryWindowRange(window, todayDate);
      final summariesInWindow = dailySummaries
          .where(
            (item) => _isDateInRange(
              item.dateLocal,
              startDate: range.startDate,
              endDate: range.endDate,
            ),
          )
          .toList(growable: false);
      final symptomsInWindow = symptoms
          .where(
            (item) => _isDateInRange(
              _dateFromDateTimeUtc(item.loggedAt),
              startDate: range.startDate,
              endDate: range.endDate,
            ),
          )
          .toList(growable: false);
      final checkInsInWindow = checkIns
          .where(
            (item) => _isDateInRange(
              item.surveyDate,
              startDate: range.startDate,
              endDate: range.endDate,
            ),
          )
          .toList(growable: false);
      final labsInWindow = labs
          .where(
            (item) => _isDateInRange(
              item.drawnDate,
              startDate: range.startDate,
              endDate: range.endDate,
            ),
          )
          .toList(growable: false);
      final proceduresInWindow = procedures
          .where(
            (item) => _isDateInRange(
              item.procedureDate,
              startDate: range.startDate,
              endDate: range.endDate,
            ),
          )
          .toList(growable: false);
      final ragInWindow = ragTransactions
          .where(
            (item) => _isDateInRange(
              _dateFromDateTimeUtc(item.createdAt),
              startDate: range.startDate,
              endDate: range.endDate,
            ),
          )
          .toList(growable: false);

      final steps = summariesInWindow
          .map(
            (item) =>
                (item.summaryJson['step_count_total'] as num?)?.toDouble(),
          )
          .whereType<double>()
          .toList(growable: false);
      final sleep = summariesInWindow
          .map(
            (item) =>
                (item.summaryJson['sleep_total_minutes'] as num?)?.toDouble(),
          )
          .whereType<double>()
          .toList(growable: false);
      final restingHr = summariesInWindow
          .map(
            (item) => (item.summaryJson['resting_hr_mean'] as num?)?.toDouble(),
          )
          .whereType<double>()
          .toList(growable: false);
      final hrv = summariesInWindow
          .map(
            (item) => (item.summaryJson['hrv_sdnn_mean'] as num?)?.toDouble(),
          )
          .whereType<double>()
          .toList(growable: false);

      final rollup = <String, Object?>{
        'window_label': _summaryWindowLabel(window),
        'start_date': range.startDate,
        'end_date': range.endDate,
        'symptom_count': symptomsInWindow.length,
        'checkin_count': checkInsInWindow.length,
        'lab_count': labsInWindow.length,
        'procedure_count': proceduresInWindow.length,
        'rag_transaction_count': ragInWindow.length,
      };

      final wearable = <String, Object?>{};
      if (steps.isNotEmpty) {
        final total = steps.fold<double>(0, (sum, value) => sum + value);
        wearable['step_count_total'] = total.round();
        wearable['step_count_daily_avg'] = double.parse(
          (total / steps.length).toStringAsFixed(1),
        );
      }
      if (sleep.isNotEmpty) {
        final avg =
            sleep.fold<double>(0, (sum, value) => sum + value) / sleep.length;
        wearable['sleep_minutes_daily_avg'] = double.parse(
          avg.toStringAsFixed(1),
        );
      }
      if (restingHr.isNotEmpty) {
        final avg = restingHr.fold<double>(0, (sum, value) => sum + value) /
            restingHr.length;
        wearable['resting_hr_mean'] = double.parse(avg.toStringAsFixed(1));
      }
      if (hrv.isNotEmpty) {
        final avg =
            hrv.fold<double>(0, (sum, value) => sum + value) / hrv.length;
        wearable['hrv_sdnn_mean'] = double.parse(avg.toStringAsFixed(1));
      }
      if (wearable.isNotEmpty) {
        rollup['wearable'] = wearable;
      }

      if (symptomsInWindow.isNotEmpty) {
        rollup['symptom_types'] = symptomsInWindow
            .map((item) => item.symptomType)
            .toSet()
            .take(6)
            .toList(growable: false);
      }
      if (labsInWindow.isNotEmpty) {
        final latestLab = [...labsInWindow]
          ..sort((left, right) => right.drawnDate.compareTo(left.drawnDate));
        final latest = latestLab.first;
        rollup['latest_lab'] = {
          'drawn_date': latest.drawnDate,
          'lab_type': latest.labType,
          'value_numeric': latest.valueNumeric,
          'unit': latest.unit,
        };
      }

      return rollup;
    }

    return {
      'daily': rollupForWindow('daily'),
      'weekly': rollupForWindow('weekly'),
      'monthly': rollupForWindow('monthly'),
    };
  }

  List<String> _dailySummarySnippets(Map<String, Object?> summary) {
    final snippets = <String>[];
    final steps = summary['step_count_total'];
    final sleep = summary['sleep_total_minutes'];
    final rhr = summary['resting_hr_mean'];
    final hrv = summary['hrv_sdnn_mean'];
    if (steps is num) snippets.add('${steps.round()} steps');
    if (sleep is num) snippets.add('${sleep.round()} min sleep');
    if (rhr is num) {
      snippets.add('resting heart rate ${_formatNumber(rhr.toDouble())} bpm');
    }
    if (hrv is num) snippets.add('HRV ${_formatNumber(hrv.toDouble())} ms');
    return snippets;
  }

  String _joinHumanList(List<String> values) {
    if (values.isEmpty) return '';
    if (values.length == 1) return values.single;
    if (values.length == 2) return '${values[0]} and ${values[1]}';
    return '${values.take(values.length - 1).join(', ')}, and ${values.last}';
  }

  String _formatNumber(double value) {
    return value == value.roundToDouble()
        ? value.round().toString()
        : value.toStringAsFixed(1);
  }

  /// Short, intent-aware reply when no health data is synced.
  String _noDataReplyForIntent(String intent) {
    return switch (intent) {
      'risk_question' ||
      'confidence_question' =>
        "I don't have a score yet — sync your Apple Health data and I can show you where things stand.",
      'daily_summary' =>
        "I can generate a daily summary once local entries are available in symptoms, check-ins, labs, or synced daily summaries. I do not have enough local entries for today yet.",
      'week_summary' =>
        "I can generate a daily or weekly summary once local entries are available in symptoms, check-ins, labs, or synced daily summaries. I do not have enough local entries for that window yet.",
      'forecast_watchlist' =>
        'I do not have enough local data to generate a personalized watchlist yet. Until more signals sync, track these daily: bowel movement frequency and urgency, abdominal pain trend, sleep disruption, and hydration tolerance. If any signal worsens for 2-3 days, contact your GI team early.',
      // lab_question: if values are present but model unavailable, don't show
      // the intake prompt — acknowledge values and explain fallback.
      'lab_question' =>
        'No saved local labs yet. To add results, paste values here (e.g., "CRP 18 mg/L") and I\'ll extract them into a review card before saving.',
      'symptom_question' =>
        "I don't see any symptom logs yet. Tell me how you're feeling and I'll build a review card before saving anything.",
      'symptom_log_followup' ||
      'multi_symptom_log' ||
      'check_in_log' =>
        "Tell me your symptom — severity, timing, and any other details — and I'll build a review card before saving anything.",
      'smalltalk' =>
        'Of course. I am here when you want to check symptoms, labs, or your latest Gemma Flares pattern.',
      _ =>
        "I don't have enough data yet to answer that. Try syncing Apple Health data — once that's in, I can help.",
    };
  }

  bool _saysHealthAlreadySynced(String lower) {
    return (lower.contains('already synced') ||
            lower.contains('is synced') ||
            lower.contains('data synced')) &&
        (lower.contains('health') || lower.contains('watch'));
  }

  String _labIntakeStartReply() {
    return 'Paste the values here or use the attach/scan button (camera button) to scan the report or upload a lab photo. I will extract key values into a review card before anything is saved. I can track CRP, ESR, fecal calprotectin, CBC markers, albumin, ferritin, B12, vitamin D, liver enzymes, kidney markers, electrolytes, TSH, and stool studies.';
  }

  /// Returns true when the message is clearly a lab-intake request (log/add/
  /// enter/record/save a lab or result), not a recall or read-back query.
  /// These phrases must bypass the labRecall no-data short-circuit and reach
  /// the deterministic intake-prompt path instead.
  bool _isLabIntakePhrase(String lower) {
    // "I just got labs back" style — arriving/intake phrasing
    if ((lower.contains('got') || lower.contains('just got')) &&
        (lower.contains('lab') || lower.contains('result'))) {
      return true;
    }
    // "scan a lab photo", "send a photo", "attach a photo" style
    if ((lower.contains('scan') ||
            lower.contains('send') ||
            lower.contains('attach')) &&
        lower.contains('photo')) {
      return true;
    }
    const intakeVerbs = ['log', 'add', 'enter', 'record', 'save', 'input'];
    const labNouns = [
      'lab',
      'labs',
      'result',
      'results',
      'test',
      'value',
      'values',
    ];
    for (final verb in intakeVerbs) {
      for (final noun in labNouns) {
        if (lower.contains(verb) && lower.contains(noun)) return true;
      }
    }
    return false;
  }

  /// Returns true only for explicit "show/share/see my labs" recall queries
  /// that should get the no-data short-circuit reply when no labs are saved.
  /// All other lab-question intents (intake, "I got labs back", "what were
  /// my results?", etc.) fall through to the deterministic intake prompt.
  bool _isExplicitLabRecallQuery(String lower) {
    return lower.startsWith('show') ||
        lower.startsWith('share') ||
        lower.startsWith('see my lab') ||
        lower.startsWith('view my lab') ||
        lower.startsWith('pull up my lab') ||
        lower.startsWith('display my lab') ||
        lower.startsWith('list my lab') ||
        lower.startsWith('get my lab') ||
        (lower.contains('my lab') &&
            lower.contains('result') &&
            !lower.contains('what'));
  }

  String? _starterPromptGroundedReply({
    required _ChatTaskContract taskContract,
    required Map<String, Object?> grounding,
  }) {
    final symptoms = (grounding['recent_symptoms'] as List?) ?? const [];
    final labs = (grounding['lab_results'] as List?) ?? const [];
    final checkins = (grounding['recent_pro2_surveys'] as List?) ?? const [];
    final wearable =
        (grounding['wearable_metric_aggregates'] as List?) ?? const [];
    final snippets = (grounding['rag_context_snippets'] as List?) ?? const [];
    final profile = grounding['user_profile'];

    switch (taskContract) {
      case _ChatTaskContract.foodTrigger:
        if (symptoms.isEmpty && snippets.isEmpty) {
          return 'I do not have enough saved symptom or meal-timing notes to find food-trigger patterns yet. Log symptoms with timing like "after lunch," "after coffee," or "after dairy," and I can compare what repeats.';
        }
        if (symptoms.isEmpty && snippets.isNotEmpty) {
          return 'Food-trigger pattern check: I found ${snippets.length} local saved memory note${snippets.length == 1 ? '' : 's'} about symptoms, meals, check-ins, or intake timing. This can show repeated timing patterns, but it cannot prove a food caused symptoms. Useful next logs: what you ate, when symptoms started, duration, and whether it repeated on another day.';
        }
        final mealLinked = symptoms.where((item) {
          final map = item is Map ? item : const {};
          final meal = map['meal_relation']?.toString().trim() ?? '';
          final notes = map['notes']?.toString().toLowerCase() ?? '';
          return meal.isNotEmpty ||
              notes.contains('food') ||
              notes.contains('meal') ||
              notes.contains('after eating') ||
              notes.contains('coffee') ||
              notes.contains('dairy') ||
              notes.contains('gluten');
        }).length;
        return 'Food-trigger pattern check: I found ${symptoms.length} recent symptom note${symptoms.length == 1 ? '' : 's'}, with $mealLinked mentioning food, meals, or timing. This can show timing patterns, but it cannot prove a food caused symptoms. Useful next logs: what you ate, when symptoms started, duration, and whether it repeated on another day.';
      case _ChatTaskContract.activityPattern:
        if (wearable.isEmpty && snippets.isEmpty) {
          return 'I do not have enough recent activity summaries to show an activity pattern yet. Once Apple Health syncs steps or activity minutes for a few days, I can compare your recent movement against your usual baseline and nearby symptom logs.';
        }
        if (wearable.isEmpty && snippets.isNotEmpty) {
          return 'Activity pattern check: I found ${snippets.length} local saved memory note${snippets.length == 1 ? '' : 's'} that can support a movement-and-symptom review. I will keep this as pattern review, not a flare diagnosis.';
        }
        return 'Activity pattern check: I can see ${wearable.length} recent wearable aggregate row${wearable.length == 1 ? '' : 's'}. I am looking at steps, exercise or activity minutes, and nearby symptom notes. Use this as a pattern review, not a flare diagnosis.';
      case _ChatTaskContract.hrvTrend:
        if (wearable.isEmpty &&
            grounding['hrv_circadian_rhythm'] == null &&
            snippets.isEmpty) {
          return 'I do not have enough recent HRV summaries to show a trend yet. Once Apple Health syncs HRV for a few days, I can compare recent values with your baseline.';
        }
        if (wearable.isEmpty && snippets.isNotEmpty) {
          return 'HRV trend check: I found ${snippets.length} local saved memory note${snippets.length == 1 ? '' : 's'} that can support a trend review. HRV is noisy day to day, so I look for repeated shifts alongside sleep, activity, and symptoms.';
        }
        return 'HRV trend check: I can see ${wearable.length} recent wearable aggregate row${wearable.length == 1 ? '' : 's'}${grounding['hrv_circadian_rhythm'] == null ? '' : ' plus rhythm baseline context'}. HRV is noisy day to day, so I look for repeated shifts alongside sleep, activity, and symptoms.';
      case _ChatTaskContract.medicationNote:
        final hasProfile = profile != null;
        if (!hasProfile && snippets.isEmpty) {
          return 'I do not have a saved medication note to review yet. You can log the medication name, dose if you choose, schedule, and what changed. I will not suggest dose changes; medication decisions belong with your GI team.';
        }
        if (!hasProfile && snippets.isNotEmpty) {
          return 'Medication context: I found ${snippets.length} local saved memory note${snippets.length == 1 ? '' : 's'} that can support a medication-timing review. I will keep this to tracking context only, not dosing advice or medication changes.';
        }
        return 'Medication context: I can use your saved profile or medication notes and nearby symptoms to summarize what is documented. I will keep this to tracking context only, not dosing advice or medication changes.';
      case _ChatTaskContract.prepForVisit:
        final parts = <String>[
          '${symptoms.length} symptom note${symptoms.length == 1 ? '' : 's'}',
          '${labs.length} lab result${labs.length == 1 ? '' : 's'}',
          '${checkins.length} check-in${checkins.length == 1 ? '' : 's'}',
          if (snippets.isNotEmpty)
            '${snippets.length} local memory note${snippets.length == 1 ? '' : 's'}',
        ];
        return 'Visit prep snapshot: I found ${parts.join(', ')}. Bring up what changed, what is repeating, any bleeding or urgency, recent labs, current medications, and the top 2-3 questions you want answered. If you want the full doctor-ready export, ask for "Create a GI summary."';
      default:
        return null;
    }
  }

  /// Builds a real memory ledger response from actual RAG transaction records.
  /// Groups by source_type, shows counts, most-recent index date, and a
  /// status breakdown that distinguishes user-confirmed writes from query
  /// verification state.
  String _buildMemoryLedgerReply(
    List<RagMemoryTransactionRecord> ragTransactions,
  ) {
    if (ragTransactions.isEmpty) {
      return 'No memory transactions yet. Lab results and symptoms are only '
          'indexed into local Gemma Flares memory after you explicitly confirm '
          'them. Once saved, they appear here. Open Settings → Data controls '
          'to export or delete any stored items.';
    }

    // Group by source_type for the breakdown line.
    final countByType = <String, int>{};
    for (final tx in ragTransactions) {
      countByType[tx.sourceType] = (countByType[tx.sourceType] ?? 0) + 1;
    }
    final typeBreakdown = countByType.entries
        .map((e) => '${e.value} ${_ledgerSourceLabel(e.key)}')
        .join(', ');

    const confirmedStatuses = <String>{
      'verified',
      'written_to_corpus',
      'loaded_in_rag',
    };
    final confirmed = ragTransactions
        .where((tx) => confirmedStatuses.contains(tx.status))
        .length;
    final queryVerified =
        ragTransactions.where((tx) => tx.verifiedAt != null).length;
    final awaitingRuntimeVerification = ragTransactions
        .where(
          (tx) =>
              tx.status == 'written_to_corpus' || tx.status == 'loaded_in_rag',
        )
        .length;
    final queued = ragTransactions.where((tx) => tx.status == 'pending').length;
    final failed = ragTransactions.where((tx) => tx.status == 'failed').length;

    // Most recent indexed timestamp.
    final mostRecentIndexed = ragTransactions
        .map((tx) => tx.indexedAt)
        .whereType<DateTime>()
        .fold<DateTime?>(null, (latest, dt) {
      if (latest == null) return dt;
      return dt.isAfter(latest) ? dt : latest;
    });
    final indexedText = mostRecentIndexed == null
        ? ''
        : ' Last indexed ${_ledgerDateLabel(mostRecentIndexed)}.';

    final statusParts = <String>[
      '$confirmed confirmed writes',
      '$queryVerified query-verified',
      '$awaitingRuntimeVerification awaiting runtime verification',
      '$queued queued',
      '$failed failed',
    ];

    return 'Local memory ledger: ${ragTransactions.length} '
        'entr${ragTransactions.length == 1 ? 'y' : 'ies'} — $typeBreakdown.'
        ' ${statusParts.join(', ')}.$indexedText '
        'User-confirmed health entries are only written after your approval. '
        'Open Settings → Data controls to export or delete stored items.';
  }

  String _ledgerSourceLabel(String sourceType) {
    return switch (sourceType) {
      'lab_value' ||
      'lab' =>
        'lab result${sourceType == 'lab_value' ? 's' : ''}',
      'symptom' => 'symptom logs',
      'intake_event' => 'intake events',
      'check_in' || 'pro2_survey' => 'check-ins',
      'conversation' => 'conversation summaries',
      'apple_health_sync' => 'Apple Health sync batches',
      'flare_risk_score' => 'flare risk snapshots',
      'setup' => 'setup anchors',
      _ => sourceType.replaceAll('_', ' '),
    };
  }

  String _ledgerDateLabel(DateTime dt) {
    final now = _nowProvider();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}';
  }

  bool _isLabExplanationRequest(String lower) {
    if (_looksLikeLabValues(lower)) return false;
    if (_isLabDetailFollowup(lower)) return true;
    final asksForSavedLabs = lower.contains('explain my lab') ||
        lower.contains('summarize my lab') ||
        lower.contains('summary of my lab') ||
        lower.contains('explain the lab') ||
        lower.contains('explain these lab') ||
        lower.contains('latest lab') ||
        lower.contains('last lab') ||
        lower.contains('recent lab') ||
        lower.contains('lab result') ||
        lower.contains('blood work result') ||
        lower.contains('what do my lab') ||
        lower.contains('what did my lab') ||
        lower.contains('what was my last');
    final asksForSpecificLab = lower.contains('last crp') ||
        lower.contains('my crp') ||
        lower.contains('my esr') ||
        lower.contains('calprotectin') ||
        lower.contains('ferritin') ||
        lower.contains('hemoglobin') ||
        lower.contains('albumin') ||
        lower.contains('platelet') ||
        lower.contains('wbc') ||
        lower.contains('vitamin');
    final asksForMeaning = lower.contains('mean') ||
        lower.contains('explain') ||
        lower.contains('summarize') ||
        lower.contains('show') ||
        lower.contains('tell me');
    return asksForSavedLabs || (asksForSpecificLab && asksForMeaning);
  }

  bool _isLabDetailFollowup(String lower) {
    final asksForMoreDetail = lower.contains('more detail') ||
        lower.contains('more context') ||
        lower.contains('more info') ||
        lower.contains('more information') ||
        lower.contains('explain more') ||
        lower.contains('go deeper') ||
        lower.contains('elaborate');
    final asksAboutLabs = lower.contains('lab') ||
        lower.contains('bloodwork') ||
        lower.contains('blood work') ||
        lower.contains('result');
    final inLabThread = _sessionState?.activeTopic == 'lab_review';
    return asksForMoreDetail && (asksAboutLabs || inLabThread);
  }

  String _latestLabsSummary({
    required List<LabValueRecord> labs,
    required List<RagMemoryTransactionRecord> ragTransactions,
    required String userMessage,
  }) {
    final lower = userMessage.toLowerCase();
    final matchingLabs = _requestedLabTypes(lower);
    final selected = (matchingLabs.isEmpty
            ? labs
            : labs.where((lab) => matchingLabs.contains(lab.labType)))
        .take(6)
        .toList(growable: false);
    if (selected.isEmpty) {
      return 'I can see saved labs locally, but not the specific lab you asked about. Ask for a summary of all latest labs, or add that result from a report.';
    }
    final latestDate = selected.first.drawnDate;
    final labLines = selected.map(_labSummaryLine).join(' ');
    return 'Your latest labs from $latestDate: $labLines Say "Explain my labs" and I\'ll walk through what each value means for you.';
  }

  Future<String> _deterministicLabExplainReply({
    required List<LabValueRecord> labs,
    required List<RagMemoryTransactionRecord> ragTransactions,
  }) async {
    if (labs.isEmpty) {
      return 'No saved local labs are available yet. Paste values or scan a lab report and I can explain them after review.';
    }
    final selected = labs.take(4).toList(growable: false);
    final unknownLabs = selected
        .where((lab) => !_isKnownLabTypeForDeterministicMeaning(lab.labType))
        .toList(growable: false);
    final unknownEnrichment = unknownLabs.isEmpty
        ? const <String, String>{}
        : await _gemmaUnknownLabEnrichment(labs: unknownLabs);
    final lines = <String>[];
    for (final lab in selected) {
      final type = _labDisplayName(lab.labType);
      final value = _formatLabNumber(lab.valueNumeric);
      final unit = lab.unit.trim().isEmpty ? '' : ' ${lab.unit}';
      final referenceHigh = lab.referenceHigh;
      final elevated =
          referenceHigh != null && lab.valueNumeric > referenceHigh;
      final rangeText = referenceHigh == null
          ? 'Reference high is not available in this local record.'
          : elevated
              ? 'This is above the reference high of ${_formatLabNumber(referenceHigh)}${unit.isEmpty ? '' : unit}.'
              : 'This is not above the reference high of ${_formatLabNumber(referenceHigh)}${unit.isEmpty ? '' : unit}.';
      final unknownHint = unknownEnrichment[lab.labType.toLowerCase()];
      final whatItMeansToYou = elevated
          ? 'For you right now, this can fit with higher inflammation activity and is worth discussing with your GI team in context with symptoms.'
          : 'For you right now, this does not look elevated by this local reference alone and can be trended over time with symptoms.';
      final meaning = _labClinicalMeaning(type);
      final enrichedMeaning =
          unknownHint == null ? meaning : '$meaning $unknownHint';
      lines.add(
        '- **$type:** $value$unit on ${lab.drawnDate}.\n'
        '  - What it is: $enrichedMeaning\n'
        '  - Interpretation: $rangeText\n'
        '  - What this may mean for you: $whatItMeansToYou',
      );
    }
    final verifiedLabMemoryCount = ragTransactions
        .where(
          (tx) =>
              tx.sourceType == 'lab_value' &&
              (tx.status == 'verified' || tx.status == 'written_to_corpus'),
        )
        .length;
    final memoryText = verifiedLabMemoryCount > 0
        ? ' These values are also indexed in local Gemma Flares memory.'
        : '';
    return 'Here are your latest saved labs from ${selected.first.drawnDate}.\n\n'
        '${lines.join('\n\n')}\n\n'
        '**What to ask your GI team next:** Which value should be rechecked first, what timing is best for repeat testing, and how should these numbers be interpreted with your current symptoms?\n\n'
        '${memoryText.trim()} This is tracking guidance, not a diagnosis.';
  }

  bool _isKnownLabTypeForDeterministicMeaning(String labType) {
    return findLabReference(labType) != null;
  }

  Future<Map<String, String>> _gemmaUnknownLabEnrichment({
    required List<LabValueRecord> labs,
  }) async {
    if (labs.isEmpty) return const {};
    try {
      final response = await _runtime.generate(
        LocalModelRequest(
          systemPrompt:
              'You are Gemma 4 in Gemma Flares. Return JSON only. Do not diagnose. For each lab row, give one plain sentence that explains what the lab generally measures for IBD monitoring. If unknown, say "clinical significance depends on full clinical context".',
          userPrompt:
              'Return exactly {"items":[{"lab_type":"...","meaning":"..."}]} for these labs: ${jsonEncode(labs.map((l) => {
                    'lab_type': l.labType,
                    'lab_name': l.labName,
                    'unit': l.unit
                  }).toList(growable: false))}',
          groundedContext: const {'task': 'unknown_lab_explain'},
          maxTokens: 140,
          temperature: 0.0,
          taskType: 'lab_text_extract',
          modelRole: 'structured_extraction',
          contextPolicy: 'compact',
          privacyMode: 'local_only',
        ),
      );
      if (response.status != 'success' || response.outputText.trim().isEmpty) {
        return const {};
      }
      final parsed = _decodeJsonObject(response.outputText);
      final rawItems = parsed?['items'];
      if (rawItems is! List) return const {};
      final out = <String, String>{};
      for (final item in rawItems.whereType<Map>()) {
        final map = Map<String, Object?>.from(item);
        final type = map['lab_type']?.toString().toLowerCase().trim();
        final meaning = map['meaning']?.toString().trim();
        if (type == null ||
            type.isEmpty ||
            meaning == null ||
            meaning.isEmpty) {
          continue;
        }
        out[type] = _clip(meaning, 140);
      }
      if (out.isNotEmpty) {
        await _diagnosticLogService?.info(
          'unknown_lab_meaning_enriched',
          category: DiagnosticLogService.categoryChat,
          message:
              'Gemma enriched unknown lab meaning for deterministic explain path.',
          metadata: {'lab_types': out.keys.toList(growable: false)},
        );
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  String _labExplainCacheKey(List<LabValueRecord> labs) {
    final selected = labs.take(8).map((lab) {
      return [
        lab.drawnDate,
        lab.labType,
        lab.valueNumeric.toStringAsFixed(4),
        lab.unit,
        (lab.referenceHigh ?? -1).toStringAsFixed(4),
      ].join('|');
    }).join('||');
    final rawKey = [
      _labExplainCachePromptVersion,
      _labExplainCacheLocale,
      _labExplainCacheAppVersion,
      selected,
    ].join('::');
    return sha256.convert(utf8.encode(rawKey)).toString();
  }

  String _labClinicalMeaning(String labType) {
    final ref = findLabReference(labType);
    if (ref == null) {
      return 'This provides additional context for IBD monitoring.';
    }
    return '${ref.whatItMeasures} ${ref.ibdUse}';
  }

  String? _pendingLabReviewRecallReply(
    List<GemmaExtractionReviewRecord> recentLabReviews,
  ) {
    final pending = recentLabReviews.where((review) {
      return review.reviewStatus == 'pending_user_confirm' &&
          review.extractedJson['labs'] is List &&
          (review.extractedJson['labs'] as List).isNotEmpty;
    }).toList(growable: false);
    if (pending.isEmpty) return null;
    final latest = pending.first;
    final labs = (latest.extractedJson['labs'] as List)
        .whereType<Map>()
        .take(4)
        .map((raw) => Map<String, Object?>.from(raw))
        .map((lab) {
      final type = _labDisplayName(lab['lab_type']?.toString() ?? 'lab');
      final value = lab['value_numeric'];
      final unit = lab['unit']?.toString() ?? '';
      final date = lab['drawn_date']?.toString();
      return '$type $value $unit${date == null ? '' : ' from $date'}';
    }).join('; ');
    return 'I found lab values from your recent scan, but they are still waiting for your confirmation and are not saved yet: $labs. Reply "confirm" on the review card to save these values, then ask me to explain your labs and I will use the saved local records.';
  }

  Set<String> _requestedLabTypes(String lower) {
    final types = <String>{};
    if (lower.contains('crp') || lower.contains('c-reactive')) {
      types.add('crp');
    }
    if (lower.contains('esr') || lower.contains('sed rate')) {
      types.add('esr');
    }
    if (lower.contains('calprotectin')) types.add('fecal_calprotectin');
    if (lower.contains('ferritin')) types.add('ferritin');
    if (lower.contains('hemoglobin')) types.add('hemoglobin');
    if (lower.contains('albumin')) types.add('albumin');
    if (lower.contains('platelet')) types.add('platelet');
    if (lower.contains('wbc') || lower.contains('white blood')) {
      types.add('wbc');
    }
    if (lower.contains('vitamin d')) types.add('vitamin_d');
    if (lower.contains('b12') || lower.contains('vitamin b12')) {
      types.add('vitamin_b12');
    }
    return types;
  }

  String _labSummaryLine(LabValueRecord lab) {
    final elevated = lab.referenceHigh != null &&
        lab.valueNumeric > (lab.referenceHigh ?? double.infinity);
    final referenceText = lab.referenceHigh == null
        ? ''
        : elevated
            ? ', above reference high ${_formatLabNumber(lab.referenceHigh!)}'
            : ', not above reference high ${_formatLabNumber(lab.referenceHigh!)}';
    return '${_labDisplayName(lab.labType)} ${_formatLabNumber(lab.valueNumeric)} ${lab.unit} on ${lab.drawnDate}$referenceText.';
  }

  String _formatLabNumber(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(1);
  }

  Map<String, Object?>? _decodeJsonObject(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    if (start == -1 || end <= start) return null;
    try {
      return Map<String, Object?>.from(
        jsonDecode(trimmed.substring(start, end + 1)) as Map,
      );
    } catch (_) {
      return null;
    }
  }

  String? _deterministicActionReply({
    required String userMessage,
    required String intent,
    required _ChatSessionState session,
  }) {
    final lower = userMessage.toLowerCase();
    final appFeatureReply = _appFeatureReply(lower);
    if (appFeatureReply != null) {
      return appFeatureReply;
    }
    if (_looksLikePhotoAttachment(lower)) {
      return 'I see the photo handoff. I need the lab import screen to OCR the image first, then I can show the extracted fields for review before saving. Tap the attachment button and choose Scan lab report, or paste the OCR text here if you already have it.';
    }
    if (_isCheckInStartRequest(lower)) {
      return 'Let\'s do a quick check-in.\n\nTell me:\n- Pain (0–3)\n- Bathroom trips today\n- Any urgency or bleeding\n- Fatigue, fever, or missed meds\n\nI\'ll build a review card before saving anything. Say **cancel** or **quit** at any time to stop.';
    }
    // Memory ledger is handled before _deterministicActionReply with real
    // ragTransaction data; this branch is intentionally unreachable but kept
    // as a safety net for call sites outside the main ask() path.
    if (_isMemoryLedgerRequest(lower)) return null;
    if (_isSymptomListRequest(lower)) {
      return 'I can summarize your saved symptom timeline. Ask "show recent symptoms" or open Health > Symptoms for the full local list; if you just logged one in chat, confirm the review card first so it is actually saved.';
    }
    if (intent == 'medication_log') {
      return 'Tell me the medication, vitamin, or supplement name, plus dose or timing if you want. I will build a review card before anything is saved.';
    }
    if (_isRagRecallRequest(lower)) {
      return 'I can search local Gemma Flares memory for that, but this build only exposes the transaction ledger in chat. Open memory details for full retrieved chunks. I will not claim a remembered fact unless a local RAG query returns matching evidence.';
    }
    if (intent == 'lab_question' && _isClinicalRecordReviewInput(lower)) {
      return 'This looks like a clinical report or procedure record. Review the text before saving anything: ${_clip(userMessage, 700)} Nothing is saved until you confirm, edit, or cancel.';
    }
    if (intent == 'lab_question' && !_looksLikeLabValues(lower)) {
      return _labIntakeStartReply();
    }
    return null;
  }

  String _plainContextReason(String? reason) {
    return switch (reason) {
      'looks_workout_related' =>
        'Recent activity explains some of the heart-rate change, so I would read this with caution.',
      'looks_meal_timed' =>
        'Some of the change lines up with meal or intake timing, so it may be digestion-related.',
      'multiple_signals_agree' =>
        'Several independent signals changed together, so the pattern is less likely to be just one noisy metric.',
      'symptoms_changed_even_with_quiet_heart_rate' =>
        'Your heart-rate signal is quiet, but other signals changed, so the app is watching for a possible missed signal.',
      'heart_rhythm_data_harder_to_interpret' =>
        'Heart rhythm data may be harder to interpret today.',
      _ => 'No single context fully explains the pattern today.',
    };
  }

  String _confidenceExplanation(FlareRiskScoreRecord latestScore) {
    final conf = latestScore.confidenceScore.round();
    final contributions = latestScore.contributionJson;
    final rawComponents = contributions['confidence_components'];
    final rawInputs = contributions['confidence_inputs'];
    final components =
        rawComponents is Map ? Map<String, Object?>.from(rawComponents) : null;
    final inputs =
        rawInputs is Map ? Map<String, Object?>.from(rawInputs) : null;
    if (components == null || inputs == null) {
      return 'Your confidence score is $conf/100, which tells you how much the app trusts today\'s risk estimate.\n\n'
          'Think of it like a weather forecast — the more data and history the app has, the more reliable the prediction. '
          'Right now, confidence is ${_confLevel(conf)} because the app is still learning your patterns.';
    }
    final available =
        (inputs['available_metric_families'] as num?)?.round() ?? 0;
    final stale = inputs['stale_sync'] == true;

    final reasons = <String>[];
    final baselineVal = (components['baseline_maturity'] as num?)?.round() ?? 0;
    if (baselineVal < 20) {
      reasons.add(
        'the app is still early in learning your personal baseline — it needs a few more weeks of data',
      );
    } else if (baselineVal < 40) {
      reasons.add(
        'your baseline is building but not fully established yet — more daily data will strengthen it',
      );
    }

    final coverage = (components['data_coverage'] as num?)?.round() ?? 0;
    if (coverage < 15) {
      reasons.add(
        'only $available out of 5 possible data sources (like Apple Watch, check-ins, labs) are connected',
      );
    }

    if (stale) {
      reasons.add(
        'some of your health data has not synced recently, so the picture may be slightly outdated',
      );
    }

    final checkinQ = (components['checkin_quality'] as num?)?.round() ?? 0;
    if (checkinQ < 5) {
      reasons.add(
        'more frequent daily check-ins would give the app a clearer picture of how you are feeling',
      );
    }

    final reasonText = reasons.isEmpty
        ? 'Overall the data looks solid — confidence should stay high as long as you keep syncing.'
        : 'Here\'s why confidence is ${_confLevel(conf)} right now:\n${reasons.map((r) => '• $r').join('\n')}';

    return 'Your confidence score is $conf/100, which means the app is ${_confLevel(conf)} in today\'s risk estimate.\n\n'
        'Think of confidence like a weather forecast — the more history and data the app has, the more it can trust the prediction.\n\n'
        '$reasonText';
  }

  String _confLevel(int conf) {
    if (conf >= 70) return 'fairly confident';
    if (conf >= 40) return 'moderately confident';
    return 'not very confident yet';
  }

  bool _isUsableModelResponse(
    LocalModelResponse response,
    ChatOutputSanitizerReport sanitizerReport,
  ) {
    if (sanitizerReport.cleanedText.isEmpty) {
      return false;
    }
    if (response.status != 'success') {
      return false;
    }
    if (response.outputQualityStatus == 'rejected') {
      return false;
    }
    return sanitizerReport.status == 'accepted';
  }

  String _profileForIntent(String intent, LocalModelRuntimeStatus status) {
    if (_contextPolicyForIntent(intent) == 'large_128k') {
      return 'phone_large';
    }
    if (_contextPolicyForIntent(intent) == 'standard') {
      return 'phone_standard';
    }
    final current = status.activeRuntimeProfile;
    if (current == 'phone_safe' ||
        current == 'phone_standard' ||
        current == 'phone_large' ||
        current == 'phone_balanced') {
      return current;
    }
    return 'phone_balanced';
  }

  int _chatMaxTokensFor(
    LocalModelRuntimeStatus status,
    String intent, {
    Map<String, Object?>? grounding,
  }) {
    // Structured / redirect intents — keep tight regardless of profile
    if (intent == 'urgent_safety') return 128;
    if (intent == 'out_of_scope') return 96;
    if (intent == 'smalltalk') return 96;
    if (intent == 'medication_question' || intent == 'diet_question') {
      return 192;
    }

    // Compute data richness — fewer tokens when there's less to talk about
    final dataRichness = _dataRichness(grounding);

    final baseTokens = switch (status.activeRuntimeProfile) {
      'phone_safe' => _safeProfileTokens(intent),
      'phone_standard' => _standardProfileTokens(intent),
      'phone_large' => _largeProfileTokens(intent),
      _ => _safeProfileTokens(intent),
    };

    // Scale tokens by data richness — no data means short response
    if (dataRichness == _DataRichness.none) {
      return (baseTokens * 0.4).round().clamp(64, 128);
    }
    if (dataRichness == _DataRichness.sparse) {
      return (baseTokens * 0.6).round();
    }
    return baseTokens;
  }

  int _safeProfileTokens(String intent) => switch (intent) {
        // WS1b: tighter caps for one-sentence intents
        'greeting' => 64,
        'smalltalk' => 48,
        'urgent_safety' => 72,
        'out_of_scope' => 56,
        'emotional_support' || 'emotional_vent_with_symptoms' => 192,
        'data_gap_question' => 192,
        'app_meta_question' => 192,
        'continuation' => 192,
        _ => 220,
      };

  int _standardProfileTokens(String intent) => switch (intent) {
        // WS1b: tighter caps for one-sentence intents
        'greeting' => 64,
        'smalltalk' => 48,
        'urgent_safety' => 72,
        'out_of_scope' => 56,
        'emotional_support' || 'emotional_vent_with_symptoms' => 256,
        'data_gap_question' => 256,
        'app_meta_question' => 256,
        'continuation' => 384,
        'forecast_watchlist' => 384,
        'risk_question' => 512,
        'symptom_question' => 512,
        'check_in_log' => 512,
        'multi_symptom_log' => 512,
        'general_health_question' => 512,
        'wearable_data_question' => 256,
        'followup_correction' => 512,
        'confidence_question' => 640,
        'daily_summary' => 700,
        'week_summary' => 768,
        'followup_expand' => 768,
        'followup_compare' => 768,
        'lab_question' => 640,
        'doctor_summary' => 1024,
        _ => 384,
      };

  int _largeProfileTokens(String intent) => switch (intent) {
        // WS1b: tighter caps for one-sentence intents
        'greeting' => 64,
        'smalltalk' => 48,
        'urgent_safety' => 72,
        'out_of_scope' => 56,
        'app_meta_question' => 256,
        'continuation' => 512,
        'forecast_watchlist' => 512,
        'risk_question' => 640,
        'symptom_question' => 768,
        'check_in_log' => 640,
        'general_health_question' => 640,
        'wearable_data_question' => 384,
        'daily_summary' => 900,
        'week_summary' => 1024,
        'followup_expand' => 1024,
        'followup_compare' => 1024,
        'lab_question' => 900,
        'doctor_summary' => 1500,
        _ => 512,
      };

  /// Assess how much grounding data is available to shape response length.
  _DataRichness _dataRichness(Map<String, Object?>? grounding) {
    if (grounding == null) return _DataRichness.none;
    var signals = 0;
    if (grounding['score'] != null) signals++;
    final latestSummary = grounding['latest_summary'];
    if (latestSummary is Map && latestSummary.isNotEmpty) signals++;
    final wearableDays = grounding['wearable_daily_summaries'];
    if (wearableDays is List && wearableDays.isNotEmpty) signals++;
    final symptoms = grounding['symptoms'];
    if (symptoms is List && symptoms.isNotEmpty) signals++;
    final labs = grounding['labs'];
    if (labs is List && labs.isNotEmpty) signals++;
    final checkins = grounding['checkins'];
    if (checkins is List && checkins.isNotEmpty) signals++;
    final outlook = grounding['outlook'];
    if (outlook is List && outlook.isNotEmpty) signals++;
    final ragSnippets = grounding['rag_context_snippets'];
    if (ragSnippets is List && ragSnippets.isNotEmpty) signals++;
    if (signals == 0) return _DataRichness.none;
    if (signals <= 2) return _DataRichness.sparse;
    return _DataRichness.rich;
  }

  String _fallbackReason(LocalModelResponse response) {
    final reason = response.fallbackReason ??
        response.outputQualityReason ??
        response.failureStage ??
        response.reason ??
        response.status;
    return _clip(reason, 160);
  }

  Future<ChatPendingAction?> _pendingLabActionFor({
    required String userMessage,
    required String intent,
  }) async {
    if (intent != 'lab_question') return null;
    final gemmaTaskService = _gemmaTaskService;
    if (gemmaTaskService == null) return null;
    if (!_looksLikeLabValues(userMessage.toLowerCase())) return null;
    final extraction = await gemmaTaskService.extractLabsFromText(
      reportText: userMessage,
    );
    if (extraction.candidates.isEmpty) return null;
    final payload = <String, Object?>{
      'source_text': _clip(userMessage, 1200),
      'candidate_labs': extraction.candidates
          .map((candidate) => candidate.toJson())
          .toList(growable: false),
      'candidate_count': extraction.candidates.length,
      'validation_errors': extraction.validationErrors,
      'extraction_status': extraction.status,
      'used_model_output': extraction.usedModelOutput,
      'requires_confirmation': true,
    };
    return ChatPendingAction(
      type: 'lab_review',
      reviewId: extraction.reviewId,
      payloadJson: payload,
      confidence: extraction.candidates
              .map((candidate) => candidate.confidence)
              .fold<double>(0, math.max) /
          1.0,
    );
  }

  bool _looksLikeLabValues(String lower) {
    if (!_isLabQuestion(lower)) return false;
    // A number must be present, but NOT only as part of a temporal expression
    // like 'in the past 30 days' or 'last 7 days'. Strip those first so we
    // don't confuse them with actual numeric lab results.
    final withoutTemporals = lower
        .replaceAll(
          RegExp(
            r'\b(past|last|next|previous|prior|over the|within)\s+\d+\s+(day|week|month|year)s?\b',
          ),
          '',
        )
        .replaceAll(RegExp(r'\b\d+\s+(day|week|month|year)s?\s+ago\b'), '');
    if (!RegExp(r'\b\d+(?:\.\d+)?\b').hasMatch(withoutTemporals)) return false;
    return _mentionsAnyLabAnalyte(lower) ||
        lower.contains('mg/') ||
        lower.contains('g/dl') ||
        lower.contains('u/l') ||
        lower.contains('iu/l') ||
        lower.contains('mmol/l') ||
        lower.contains('miu/l') ||
        lower.contains('ml/min') ||
        lower.contains('%') ||
        lower.contains('mm/h') ||
        lower.contains('ug/g') ||
        lower.contains('µg/g') ||
        lower.contains('ng/ml') ||
        lower.contains('pg/ml') ||
        lower.contains('x10') ||
        lower.contains('k/ul') ||
        lower.contains('10^') ||
        lower.contains('crp') ||
        lower.contains('esr') ||
        lower.contains('calprotectin') ||
        lower.contains('hemoglobin') ||
        lower.contains('wbc') ||
        lower.contains('albumin') ||
        lower.contains('ferritin') ||
        lower.contains('b12') ||
        lower.contains('vitamin d');
  }

  String _pendingLabSummary(Map<String, Object?> payload) {
    final candidates = payload['candidate_labs'];
    if (candidates is! List || candidates.isEmpty) {
      return 'No lab values were extracted. Nothing is saved until you confirm.';
    }
    final parts = candidates.take(6).map((raw) {
      final item = raw is Map ? Map<String, Object?>.from(raw) : const {};
      final type = item['lab_type'] ?? 'lab';
      final value = item['value_numeric'] ?? '?';
      final unit = item['unit'] ?? '';
      final date = item['drawn_date'] ?? 'unknown date';
      return '$type $value $unit on $date'.trim();
    }).toList(growable: false);
    final extra = candidates.length > parts.length
        ? ' and ${candidates.length - parts.length} more'
        : '';
    return '${parts.join('; ')}$extra. Nothing is saved until you confirm.';
  }

  Future<ChatPendingAction?> _pendingMedicationActionFor({
    required String userMessage,
    required DateTime loggedAt,
  }) async {
    final draft = await MedicationLoggingService(
      repository: _repository,
      profileService:
          _profileService ?? ProfileService(repository: _repository),
      nowProvider: () => loggedAt.toUtc(),
    ).buildDraftFromText(transcript: userMessage, loggedAt: loggedAt);
    if (draft.requiresClarification || draft.medicationName.trim().isEmpty) {
      return null;
    }
    return ChatPendingAction(
      type: 'medication_review',
      payloadJson: {
        'event_type': draft.eventType,
        'medication_name': draft.medicationName,
        'dose': draft.dose,
        'schedule': draft.schedule,
        'notes': draft.notes,
        'source_text': draft.sourceTranscript,
        'logged_at': draft.loggedAt.toUtc().toIso8601String(),
        'confidence': draft.confidence,
        'requires_confirmation': true,
        'extraction_method': 'deterministic_medication_review',
      },
      confidence: draft.confidence,
    );
  }

  String _pendingMedicationSummary(Map<String, Object?> payload) {
    final eventType = payload['event_type']?.toString() ?? 'medication_taken';
    final medicationName = payload['medication_name']?.toString().trim() ?? '';
    final dose = payload['dose']?.toString().trim() ?? '';
    final schedule = payload['schedule']?.toString().trim() ?? '';
    final verb = eventType == 'medication_skipped' ? 'missed/skipped' : 'taken';
    final details = <String>[
      if (medicationName.isNotEmpty) medicationName,
      if (dose.isNotEmpty) dose,
      if (schedule.isNotEmpty) schedule,
    ];
    final label =
        details.isEmpty ? 'medication or supplement' : details.join(', ');
    return '$label marked as $verb. Nothing is saved until you confirm.';
  }

  String _savedSymptomsSummary(List<SymptomRecord> symptoms) {
    if (symptoms.isEmpty) {
      return 'I do not see saved symptom notes yet. If you described one in chat, confirm the review card first so it gets written to your local timeline.';
    }
    final lines = symptoms.take(8).map((symptom) {
      final date = symptom.loggedAt.toLocal().toString().split('.').first;
      final severity =
          symptom.severity == null ? '' : ', severity ${symptom.severity}/10';
      final duration = symptom.durationMinutes == null
          ? ''
          : ', ${symptom.durationMinutes} min';
      return '${symptom.symptomType} on $date$severity$duration';
    }).join('; ');
    final extra = symptoms.length > 8 ? ' and ${symptoms.length - 8} more' : '';
    return 'Saved symptoms: $lines$extra.';
  }

  Future<ChatPendingAction?> _pendingSymptomActionFor({
    required String userMessage,
    required DateTime loggedAt,
    required _ChatSessionState session,
  }) async {
    final lower = userMessage.toLowerCase();
    var sourceText = userMessage.trim();
    final explicitLogRequest = _isExplicitSymptomLogRequest(lower);
    if (_isQuestionLike(lower) && !explicitLogRequest) return null;
    // Symptom continuation: after a recent symptom_review_pending turn, a
    // follow-up that adds trigger/frequency/timing details should fold into a
    // new pending action rather than fall through to the LLM. Examples:
    //   "its all because of gluten. happens 5 times this morning"
    //   "started after coffee, 3 episodes today"
    final isSymptomContinuation =
        (session.activeTopic == 'symptom_review_pending' ||
                session.activeTopic == 'symptom_intake_pending') &&
            _containsSymptomContinuationSignals(lower);
    if (!_looksLikeSymptomNarrative(lower)) {
      if (!explicitLogRequest) {
        // In an active symptom-intake thread, retain health-related follow-up
        // text even when it does not match a known symptom lexicon term yet.
        final hasHealthText = _containsHealthTerms(lower);
        final inIntakeThread = session.awaitingSymptomIntake && hasHealthText;
        if (!hasHealthText &&
            !inIntakeThread &&
            !isSymptomContinuation &&
            !session.awaitingSymptomIntake) {
          return null;
        }
      }
      final priorNarrative = _latestSymptomNarrativeFromSession(session);
      sourceText =
          priorNarrative != null ? '$priorNarrative\n$sourceText' : sourceText;
    } else {
      sourceText = _symptomNarrativeThread(session, userMessage);
    }

    if (_containsSymptomContinuationSignals(lower) ||
        sourceText.contains(',')) {
      final forced = _forcedSymptomPendingAction(
        sourceText: sourceText,
        loggedAt: loggedAt,
      );
      if (forced != null) return forced;
    }

    final deterministicDraft = const SymptomParserService()
        .parse(transcript: sourceText, loggedAt: loggedAt)
        .structuredSymptom;
    final gemmaTaskService = _gemmaTaskService;
    if (gemmaTaskService != null) {
      final extraction = await gemmaTaskService.extractSymptom(
        transcript: sourceText,
        loggedAt: loggedAt,
        deterministicDraft: deterministicDraft,
      );
      final action = _pendingSymptomActionFromExtraction(
        extraction,
        sourceText: sourceText,
      );
      final augmented = _augmentSymptomActionFromDeterministicMentions(
        action,
        sourceText: sourceText,
      );
      final count = (augmented.payloadJson['symptom_count'] as num?)?.toInt() ??
          ((augmented.payloadJson['all_symptoms'] as List?)?.length ?? 0);
      if (count <= 0) {
        if (explicitLogRequest || _containsHealthTerms(sourceText)) {
          return _forcedSymptomPendingAction(
            sourceText: sourceText,
            loggedAt: loggedAt,
          );
        }
        return null;
      }
      return augmented;
    }

    if (!SymptomParserService.looksLikeSymptomText(lower) &&
        !SymptomParserService.looksLikeSymptomText(sourceText)) {
      if (explicitLogRequest && _containsHealthTerms(sourceText)) {
        return _forcedSymptomPendingAction(
          sourceText: sourceText,
          loggedAt: loggedAt,
        );
      }
      if (session.awaitingSymptomIntake && _containsHealthTerms(sourceText)) {
        return _forcedSymptomPendingAction(
          sourceText: sourceText,
          loggedAt: loggedAt,
        );
      }
      return null;
    }
    final severityMatch = RegExp(
      r'\b([1-9]|10)\s*(?:/10|out of 10)?\b',
    ).firstMatch(sourceText.toLowerCase());
    final severity = severityMatch == null
        ? null
        : int.tryParse(severityMatch.group(1) ?? '');
    final sourceLower = sourceText.toLowerCase();
    final lexiconMatch = SymptomParserService.matchSymptom(sourceLower);
    final resolvedSymptomType = switch (lexiconMatch?.symptomType) {
      'blood' => 'bleeding',
      'diarrhea' || 'urgency' => 'stool_frequency',
      'pain' || 'cramping' => 'abdominal_pain',
      final matched? => matched,
      null => deterministicDraft.symptomType,
    };
    final safetyFlags = deterministicDraft.safetyFlags;
    final uncertaintyNotes = deterministicDraft.uncertaintyNotes;
    final deterministicMentions = _filterOverlappingSymptomMentions(
      sourceText.toLowerCase(),
      SymptomParserService.matchAllSymptoms(sourceText.toLowerCase()),
    );
    final primaryIsNegated = _isNegatedSymptomMention(
      sourceLower,
      resolvedSymptomType,
    );
    final allSymptoms = <Map<String, Object?>>[];
    final existingTypes = <String>{};
    final canonicalPrimaryType = _canonicalSymptomType(resolvedSymptomType);
    if (!primaryIsNegated && canonicalPrimaryType != 'other') {
      allSymptoms.add({
        'symptom_type': canonicalPrimaryType,
        'severity': severity,
        'duration_minutes': deterministicDraft.durationMinutes,
        'meal_relation': deterministicDraft.mealRelation,
        'notes': _clip(sourceText, 280),
        'user_facing_description': deterministicDraft.userFacingDescription,
      });
      existingTypes.add(canonicalPrimaryType);
    }
    for (final mention in deterministicMentions) {
      final canonicalType = _canonicalSymptomType(mention.symptomType);
      if (canonicalType == 'other' || existingTypes.contains(canonicalType)) {
        continue;
      }
      allSymptoms.add({
        'symptom_type': canonicalType,
        'severity': null,
        'duration_minutes': deterministicDraft.durationMinutes,
        'meal_relation': deterministicDraft.mealRelation,
        'notes': _clip(sourceText, 280),
        'user_facing_description': _humanSymptomLabel(canonicalType),
      });
      existingTypes.add(canonicalType);
    }
    final scopedSymptoms = _preferSpecificSymptomPayloads(
      sourceText,
      _filterOverlappingSymptomPayloads(sourceText, allSymptoms),
    );
    allSymptoms
      ..clear()
      ..addAll(scopedSymptoms);
    if (allSymptoms.isEmpty) {
      if (explicitLogRequest || _containsHealthTerms(sourceText)) {
        return _forcedSymptomPendingAction(
          sourceText: sourceText,
          loggedAt: loggedAt,
        );
      }
      return null;
    }
    final primarySymptomType =
        allSymptoms.first['symptom_type']?.toString() ?? resolvedSymptomType;
    final primarySymptomSeverity = allSymptoms.first['severity'] as int?;
    final primaryDurationMinutes =
        allSymptoms.first['duration_minutes'] as int?;
    final primaryMealRelation = allSymptoms.first['meal_relation'] as String?;
    final payload = <String, Object?>{
      'symptom_type': primarySymptomType,
      'analytics_category': primarySymptomType,
      'severity': primarySymptomSeverity,
      'duration_minutes': primaryDurationMinutes,
      'meal_relation': primaryMealRelation ??
          (sourceLower.contains('after dinner') ||
                  sourceLower.contains('after lunch') ||
                  sourceLower.contains('after breakfast') ||
                  sourceLower.contains('after eating')
              ? 'after_meal'
              : null),
      'bleeding':
          sourceLower.contains('bleed') || sourceLower.contains('blood'),
      'fatigue':
          sourceLower.contains('fatigue') || sourceLower.contains('tired'),
      'urgency':
          sourceLower.contains('urgent') || sourceLower.contains('urgency'),
      'medication_skipped': sourceLower.contains('skipped med') ||
          sourceLower.contains('missed med'),
      'source_text': _clip(sourceText, 280),
      'user_facing_description': deterministicDraft.userFacingDescription,
      'uncertainty_notes': uncertaintyNotes,
      'safety_flags': safetyFlags,
      'lexicon_match_type': lexiconMatch?.matchType,
      'lexicon_matched_text': lexiconMatch?.matchedText,
      'extraction_method': 'deterministic_chat_review',
      'requires_confirmation': true,
      'all_symptoms': allSymptoms,
      'symptom_count': allSymptoms.length,
    };
    return ChatPendingAction(
      type: 'symptom_review',
      payloadJson: payload,
      confidence: deterministicDraft.extractionConfidence,
    );
  }

  ChatPendingAction _augmentSymptomActionFromDeterministicMentions(
    ChatPendingAction action, {
    required String sourceText,
  }) {
    final mentions = _filterOverlappingSymptomMentions(
      sourceText,
      SymptomParserService.matchAllSymptoms(sourceText),
    );
    if (mentions.isEmpty) return action;
    final payload = Map<String, Object?>.from(action.payloadJson);
    final existingRaw = payload['all_symptoms'];
    final all = <Map<String, Object?>>[];
    if (existingRaw is List) {
      for (final item in existingRaw.whereType<Map>()) {
        all.add(Map<String, Object?>.from(item));
      }
    }
    if (all.isEmpty) {
      all.add({
        'symptom_type': payload['symptom_type'],
        'severity': payload['severity'],
        'duration_minutes': payload['duration_minutes'],
        'meal_relation': payload['meal_relation'],
        'notes': payload['source_text'],
        'user_facing_description': payload['user_facing_description'],
      });
    }
    final filteredExisting = _filterOverlappingSymptomPayloads(sourceText, all);
    if (filteredExisting.length != all.length) {
      all
        ..clear()
        ..addAll(filteredExisting);
    }
    final existingTypes = all
        .map(
          (item) =>
              _canonicalSymptomType(item['symptom_type']?.toString() ?? ''),
        )
        .where((type) => type.isNotEmpty)
        .toSet();
    for (final mention in mentions) {
      final canonicalType = _canonicalSymptomType(mention.symptomType);
      if (existingTypes.contains(canonicalType)) continue;
      all.add({
        'symptom_type': canonicalType,
        'severity': null,
        'duration_minutes': null,
        'meal_relation': null,
        'notes': _clip(sourceText, 280),
        'user_facing_description': _humanSymptomLabel(canonicalType),
      });
      existingTypes.add(canonicalType);
    }
    if (all.length <= 1) {
      payload['all_symptoms'] = all;
      payload['symptom_count'] = all.length;
      return ChatPendingAction(
        type: action.type,
        payloadJson: payload,
        confidence: action.confidence,
        reviewId: action.reviewId,
      );
    }
    payload['all_symptoms'] = all;
    payload['symptom_count'] = all.length;
    payload['user_facing_description'] = all
        .map((s) => _humanSymptomLabel(s['symptom_type']?.toString() ?? ''))
        .where((s) => s.isNotEmpty)
        .join(' and ');
    return ChatPendingAction(
      type: action.type,
      payloadJson: payload,
      confidence: action.confidence,
      reviewId: action.reviewId,
    );
  }

  List<SymptomLexiconMatch> _filterOverlappingSymptomMentions(
    String sourceText,
    List<SymptomLexiconMatch> mentions,
  ) {
    final nonNegated = _filterNegatedSymptomMentions(sourceText, mentions);
    if (nonNegated.length <= 1) return nonNegated;

    final lower = sourceText.toLowerCase();
    final hasJointPain = nonNegated.any((m) => m.symptomType == 'joint_pain');
    if (hasJointPain) {
      final hasAbdominalCue = lower.contains('abdominal') ||
          lower.contains('abdomen') ||
          lower.contains('belly') ||
          lower.contains('stomach');
      if (!hasAbdominalCue) {
        return nonNegated
            .where(
              (m) =>
                  m.symptomType != 'pain' && m.symptomType != 'abdominal_pain',
            )
            .toList(growable: false);
      }
    }

    final hasBleeding = nonNegated.any(
      (m) =>
          m.symptomType == 'blood' ||
          m.symptomType == 'bleeding' ||
          m.symptomType == 'rectal_bleeding',
    );
    if (!hasBleeding) return nonNegated;
    final hasIndependentFrequencyCue = RegExp(
      r'\b(diarrhea|loose|watery|urgent|urgency|bathroom|bowel movements?|bm|bms|poop(?:ed|ing)?\s+\d+|\d+\s*(?:times|x))\b',
      caseSensitive: false,
    ).hasMatch(lower);
    final onlyBloodyStoolPhrase = RegExp(
      r'\b(bloody|blood(?:y)?|bleeding|rectal bleeding)\s+stools?\b|\bstools?\s+(?:with\s+)?blood\b',
      caseSensitive: false,
    ).hasMatch(lower);
    if (!onlyBloodyStoolPhrase || hasIndependentFrequencyCue) {
      return nonNegated;
    }
    return nonNegated
        .where(
          (m) =>
              m.symptomType != 'diarrhea' &&
              m.symptomType != 'stool_frequency' &&
              m.symptomType != 'frequency',
        )
        .toList(growable: false);
  }

  List<SymptomLexiconMatch> _filterNegatedSymptomMentions(
    String sourceText,
    List<SymptomLexiconMatch> mentions,
  ) {
    final lower = sourceText.toLowerCase();
    return mentions
        .where((m) => !_isNegatedSymptomMention(lower, m.symptomType))
        .toList(growable: false);
  }

  bool _isNegatedSymptomMention(String lower, String symptomType) {
    final aliases = switch (symptomType) {
      'pain' || 'abdominal_pain' => const ['pain', 'abdominal pain'],
      'cramping' => const ['cramping', 'cramps'],
      'bleeding' || 'blood' || 'rectal_bleeding' => const ['bleeding', 'blood'],
      'nausea' => const ['nausea', 'nauseous'],
      'fatigue' => const ['fatigue', 'tired'],
      'diarrhea' || 'stool_frequency' || 'frequency' => const [
          'diarrhea',
          'loose stool',
          'bowel movement'
        ],
      'urgency' => const ['urgency', 'urgent'],
      'bloating' => const ['bloating', 'bloated'],
      'joint_pain' => const ['joint pain', 'joints hurt'],
      _ => <String>[symptomType.replaceAll('_', ' ')],
    };

    for (final alias in aliases) {
      final escaped = RegExp.escape(alias);
      final negatedPrefix = RegExp(
        '\\b(?:no|not|without|never|denies?|denied|none|pain[- ]?free)\\s+(?:\\w+\\s+){0,2}$escaped\\b',
        caseSensitive: false,
      );
      if (negatedPrefix.hasMatch(lower)) return true;

      final resolvedPattern = RegExp(
        '\\b$escaped\\b\\s+(?:is|was|are|were)?\\s*(?:not|gone|resolved|better now)\\b',
        caseSensitive: false,
      );
      if (resolvedPattern.hasMatch(lower)) return true;
    }
    return false;
  }

  List<Map<String, Object?>> _filterOverlappingSymptomPayloads(
    String sourceText,
    List<Map<String, Object?>> symptoms,
  ) {
    if (symptoms.isEmpty) return symptoms;
    final mentions = symptoms
        .map(
          (item) => SymptomLexiconMatch(
            symptomType: item['symptom_type']?.toString() ?? '',
            confidence: 1,
            matchedText: item['symptom_type']?.toString() ?? '',
            matchType: 'payload',
          ),
        )
        .where((item) => item.symptomType.isNotEmpty)
        .toList(growable: false);
    if (mentions.isEmpty) return symptoms;
    final filtered = _filterOverlappingSymptomMentions(
      sourceText,
      mentions,
    ).map((item) => item.symptomType).toSet();
    if (filtered.length == mentions.length &&
        filtered.containsAll(mentions.map((m) => m.symptomType))) {
      return symptoms;
    }
    return symptoms
        .where((item) => filtered.contains(item['symptom_type']?.toString()))
        .toList(growable: false);
  }

  List<Map<String, Object?>> _preferSpecificSymptomPayloads(
    String sourceText,
    List<Map<String, Object?>> symptoms,
  ) {
    if (symptoms.length <= 1) return symptoms;
    final lower = sourceText.toLowerCase();
    final types = symptoms
        .map((item) => item['symptom_type']?.toString() ?? '')
        .where((type) => type.isNotEmpty)
        .toSet();
    final shouldDropAbdominalPain = types.contains('abdominal_pain') &&
        ((types.contains('mouth_sores') && lower.contains('mouth')) ||
            (types.contains('joint_pain') && lower.contains('joint')) ||
            (types.contains('back_pain') && lower.contains('back')));
    if (!shouldDropAbdominalPain) return symptoms;
    return symptoms
        .where((item) => item['symptom_type']?.toString() != 'abdominal_pain')
        .toList(growable: false);
  }

  bool _allowsSymptomPendingAction(String intent) {
    return intent == 'symptom_question' ||
        intent == 'symptom_log_followup' ||
        intent == 'multi_symptom_log' ||
        intent == 'check_in_log' ||
        intent == 'general_health_question' ||
        intent == 'urgent_safety';
  }

  ChatPendingAction _pendingSymptomActionFromExtraction(
    GemmaSymptomExtractionResult extraction, {
    required String sourceText,
  }) {
    final primarySymptom = extraction.structuredSymptom;
    final allSymptoms = extraction.allSymptoms;
    final canonicalPrimaryType = _canonicalSymptomType(
      primarySymptom.symptomType,
    );
    final canonicalAllSymptoms = <Map<String, Object?>>[];
    final seenTypes = <String>{};
    for (final symptom in allSymptoms) {
      final canonicalType = _canonicalSymptomType(symptom.symptomType);
      if (seenTypes.contains(canonicalType)) continue;
      canonicalAllSymptoms.add({
        'symptom_type': canonicalType,
        'severity': symptom.severity1To10,
        'duration_minutes': symptom.durationMinutes,
        'meal_relation': symptom.mealRelation,
        'notes': symptom.notes,
        'user_facing_description': _humanSymptomLabel(canonicalType),
      });
      seenTypes.add(canonicalType);
    }

    // Build a combined label for multi-symptom review cards
    final combinedLabel = canonicalAllSymptoms.length > 1
        ? canonicalAllSymptoms
            .map(
              (s) => _humanSymptomLabel(s['symptom_type']?.toString() ?? ''),
            )
            .join(' and ')
        : primarySymptom.userFacingDescription;
    final scopedCanonicalSymptoms = _preferSpecificSymptomPayloads(
      sourceText,
      _filterOverlappingSymptomPayloads(sourceText, canonicalAllSymptoms),
    );
    final scopedPrimaryType =
        scopedCanonicalSymptoms.firstOrNull?['symptom_type']?.toString() ??
            canonicalPrimaryType;

    final payload = <String, Object?>{
      'symptom_type': scopedPrimaryType,
      'analytics_category': scopedPrimaryType,
      'severity': primarySymptom.severity1To10,
      'duration_minutes': primarySymptom.durationMinutes,
      'meal_relation': primarySymptom.mealRelation,
      'source_text': _clip(sourceText, 280),
      'user_facing_description': combinedLabel,
      'uncertainty_notes': primarySymptom.uncertaintyNotes,
      'safety_flags': primarySymptom.safetyFlags,
      'intake_events': extraction.intakeEvents
          .map((event) => event.toJson())
          .toList(growable: false),
      'extraction_method': extraction.extractionMethod,
      'requires_confirmation': true,
      // Include all extracted symptoms for multi-save on confirm.
      // 'notes' = raw Gemma extraction notes (frequency, trigger, user's own words).
      // 'user_facing_description' = preformatted label used as fallback display text.
      'all_symptoms': scopedCanonicalSymptoms,
      'symptom_count': scopedCanonicalSymptoms.length,
    };
    return ChatPendingAction(
      type: 'symptom_review',
      reviewId: extraction.reviewId,
      payloadJson: payload,
      confidence: primarySymptom.extractionConfidence,
    );
  }

  String _canonicalSymptomType(String symptomType) {
    return switch (symptomType) {
      'blood' || 'rectal_bleeding' => 'bleeding',
      'diarrhea' || 'frequency' => 'stool_frequency',
      'pain' || 'cramping' => 'abdominal_pain',
      _ => symptomType,
    };
  }

  String? _manualHealthSymptomType(String text) {
    final lower = _normalizeIntentText(text).toLowerCase();
    if (lower.contains('bloody stool') ||
        lower.contains('blood in stool') ||
        lower.contains('rectal bleeding') ||
        lower.contains('blood when wiping')) {
      return 'bleeding';
    }
    if (lower.contains('diarrhea') ||
        lower.contains('diarreha') ||
        lower.contains('loose stool') ||
        lower.contains('the runs') ||
        lower.contains('shit') ||
        lower.contains('poop')) {
      return 'stool_frequency';
    }
    if (lower.contains('bloated') ||
        lower.contains('bloating') ||
        lower.contains('bloateed')) {
      return 'bloating';
    }
    if (lower.contains('cramping') || lower.contains('cramps')) {
      return 'abdominal_pain';
    }
    if (lower.contains('fever') || lower.contains('chills')) {
      return 'fever';
    }
    if (lower.contains('tired') ||
        lower.contains('fatigue') ||
        lower.contains('exhausted')) {
      return 'fatigue';
    }
    if (lower.contains('migraine') ||
        lower.contains('headache') ||
        lower.contains('head ache')) {
      return 'headache_migraine';
    }
    if (lower.contains('dizzy') || lower.contains('lightheaded')) {
      return 'dizziness';
    }
    if (lower.contains('joint pain') || lower.contains('joint')) {
      return 'joint_pain';
    }
    if (lower.contains('mouth sore') ||
        lower.contains('mouth ulcer') ||
        lower.contains('canker')) {
      return 'mouth_sores';
    }
    if (lower.contains('eye redness') || lower.contains('red eye')) {
      return 'eye';
    }
    if (lower.contains('rash') || lower.contains('skin')) {
      return 'skin';
    }
    if (lower.contains('urinary urgency') || lower.contains('urinary')) {
      return 'urinary_urgency';
    }
    if (lower.contains('urgent bathroom') || lower.contains('urgency')) {
      return 'urgency';
    }
    if (lower.contains('back pain')) return 'back_pain';
    if (lower.contains('appetite')) return 'appetite_loss';
    if (lower.contains('dehydrated') || lower.contains('dehydration')) {
      return 'dehydration';
    }
    if (lower.contains('budesonide') ||
        lower.contains('started') && lower.contains('med') ||
        lower.contains('skipped') && lower.contains('med')) {
      return 'other_health_symptom';
    }
    if (lower.contains('cough') ||
        lower.contains('congestion') ||
        lower.contains('sore throat') ||
        lower.contains('shortness of breath')) {
      return 'other_health_symptom';
    }
    return null;
  }

  String _humanSymptomLabel(String symptomType) {
    return switch (symptomType) {
      'pain' || 'abdominal_pain' => 'abdominal pain',
      'diarrhea' ||
      'stool_frequency' ||
      'frequency' =>
        'Frequency / Increased Bowel Movements',
      'blood' || 'bleeding' || 'rectal_bleeding' => 'rectal bleeding',
      'mucus_stool' => 'mucus or pus in stool',
      'urgency' => 'urgency',
      'nausea' => 'nausea',
      'bloating' => 'bloating',
      'fatigue' => 'fatigue',
      'cramping' || 'cramps' => 'cramping',
      'fever' => 'fever',
      'night_sweats' => 'night sweats',
      'constipation' => 'constipation',
      'fecal_incontinence' => 'bowel leakage',
      'weight_loss' => 'weight loss',
      'appetite_loss' => 'appetite loss',
      'fistula' => 'fistula or drainage',
      'joint_pain' => 'joint pain',
      'skin' => 'skin symptoms',
      'eye' => 'eye symptoms',
      'anal_fissure' => 'anal fissure pain',
      'obstruction' => 'obstructive symptoms',
      'vomiting' => 'vomiting',
      'dehydration' => 'dehydration symptoms',
      'malnutrition' => 'malnutrition symptoms',
      'dizziness' => 'dizziness or lightheadedness',
      'back_pain' => 'back pain',
      'urinary_urgency' => 'urinary urgency',
      'mouth_sores' => 'mouth sores',
      'headache_migraine' || 'headache' || 'migraine' => 'headache / migraine',
      'other_health_symptom' => 'other health symptom',
      _ => symptomType.replaceAll('_', ' '),
    };
  }

  bool _isBareSymptomLogRequest(String lower) {
    final normalized = lower
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return normalized == 'log symptom' ||
        normalized == 'log a symptom' ||
        normalized == 'record symptom' ||
        normalized == 'record a symptom' ||
        normalized == 'save symptom' ||
        normalized == 'save a symptom' ||
        normalized == 'i want to log a symptom' ||
        normalized == 'i have symptoms to log' ||
        normalized == 'i have a symptom to log' ||
        normalized == 'log symptoms';
  }

  bool _isExplicitSymptomLogRequest(String lower) {
    return lower.contains('save that') ||
        lower.contains('save this') ||
        lower.contains('log that') ||
        lower.contains('log that please') ||
        lower.contains('log this') ||
        lower.contains('log both') ||
        lower.contains('capture both') ||
        lower.contains('track both') ||
        lower.contains('logging that') ||
        lower.contains('logging this') ||
        lower.contains('track that') ||
        lower.contains('track this') ||
        lower.contains('note that') ||
        lower.contains('can you log both') ||
        lower.contains('can you capture both') ||
        lower.contains('can you track that') ||
        lower.contains('can you track this') ||
        lower.contains('log symptom') ||
        lower.contains('log a symptom') ||
        lower.contains('symptoms to log') ||
        lower.contains('symptom to log') ||
        lower.contains('log symptoms') ||
        lower.contains('record symptom') ||
        lower.contains('record a symptom') ||
        lower.contains('save symptom') ||
        lower.contains('save that symptom') ||
        lower.contains('record that symptom') ||
        lower.contains('save this symptom');
  }

  bool _isFoodLifestyleUpdate(String lower) {
    final hasFoodContext = lower.contains('food') ||
        lower.contains('diet') ||
        lower.contains('meal') ||
        lower.contains('coffee') ||
        lower.contains('alcohol') ||
        lower.contains('spicy') ||
        lower.contains('beans') ||
        lower.contains('salad') ||
        lower.contains('dairy') ||
        lower.contains('gluten') ||
        lower.contains('low-residue') ||
        lower.contains('low residue') ||
        lower.contains('liquid diet') ||
        lower.contains('scd');
    if (!hasFoodContext) return false;

    final hasTrackingOrOutcome = lower.contains('log') ||
        lower.contains('logging') ||
        lower.contains('track') ||
        lower.contains('record') ||
        lower.contains('note that') ||
        lower.contains('trigger') ||
        lower.contains('related') ||
        lower.contains('felt better') ||
        lower.contains('felt much better') ||
        lower.contains('feel better') ||
        lower.contains('feeling better') ||
        lower.contains('felt worse') ||
        lower.contains('feeling worse') ||
        lower.contains('felt okay') ||
        lower.contains('felt ok') ||
        lower.contains('felt good') ||
        lower.contains('stomach is wrecked') ||
        lower.contains('gut is wrecked') ||
        lower.contains('stomach wrecked') ||
        lower.contains('bad idea') ||
        lower.contains('spiked') ||
        lower.contains('still having') ||
        lower.contains('flare') ||
        // Outcome language: "had X and Y happened"
        (lower.contains('and') &&
            (lower.contains('cramp') ||
                lower.contains('pain') ||
                lower.contains('bloat') ||
                lower.contains('nausea') ||
                lower.contains('diarrhea') ||
                lower.contains('urgency')));
    return hasTrackingOrOutcome;
  }

  bool _isCheckInStartRequest(String lower) {
    final normalized = lower
        .replaceAll(RegExp(r'[^a-z\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.contains('score') ||
        normalized.contains('how did i do') ||
        normalized.contains('how am i doing') ||
        normalized.contains('what is my')) {
      return false;
    }
    return normalized == 'start a check in' ||
        normalized.contains('start a check in') ||
        normalized == 'start check in' ||
        normalized.contains('start check in') ||
        normalized == 'daily check in' ||
        normalized.contains('daily check in') ||
        normalized.contains('daily ibd check') ||
        normalized == 'start daily check in' ||
        normalized.contains('start daily check in') ||
        normalized == 'check in' ||
        normalized.contains(' check in');
  }

  bool _isMemoryLedgerRequest(String lower) {
    return lower.contains('memory ledger') ||
        lower.contains('access rag') ||
        lower.contains('rag ledger') ||
        lower.contains('show memory') ||
        lower.contains('what did you save') ||
        lower.contains('saved locally') ||
        lower.contains('what is in memory') ||
        lower.contains('in memory now') ||
        lower.contains('saved in memory') ||
        lower.contains('what is saved in memory') ||
        lower.contains("what's in memory");
  }

  bool _isSymptomListRequest(String lower) {
    return (lower.contains('print') ||
            lower.contains('show') ||
            lower.contains('list') ||
            lower.contains('all') ||
            lower.contains('what') ||
            lower.contains('did i log')) &&
        (lower.contains('symptom') || lower.contains('symotom'));
  }

  bool _looksLikePhotoAttachment(String lower) {
    return lower.contains('[photo attached:') ||
        lower.contains('[image attached:') ||
        lower.contains('photo attached') ||
        lower.contains('image_picker_') ||
        lower.contains("it's a photo") ||
        lower.contains('it s a photo') ||
        lower.contains('lab result is a photo') ||
        lower.contains('lab is a photo');
  }

  bool _looksLikeSymptomNarrative(String lower) {
    return SymptomParserService.looksLikeSymptomText(lower);
  }

  int? _symptomIntakeStartTurnIndex(_ChatSessionState session) {
    if (session.turns.isEmpty) return null;
    for (var i = session.turns.length - 1; i >= 0; i--) {
      final turn = session.turns[i];
      final normalizedUser = _normalizeIntentText(turn.userMessage).trim();
      final looksLikeBareStart = _isBareSymptomLogRequest(normalizedUser);
      final looksLikePrompt = turn.intent == 'symptom_log_followup' &&
          turn.assistantMessage.toLowerCase().contains('describe the symptom');
      if (looksLikeBareStart || looksLikePrompt) {
        return i;
      }
    }
    return null;
  }

  String? _latestSymptomNarrativeFromSession(_ChatSessionState session) {
    final intakeStart = session.awaitingSymptomIntake
        ? _symptomIntakeStartTurnIndex(session)
        : null;
    for (var i = session.turns.length - 1; i >= 0; i--) {
      if (intakeStart != null && i <= intakeStart) break;
      final turn = session.turns[i];
      if (_looksLikeSymptomNarrative(turn.userMessage.toLowerCase())) {
        return turn.userMessage;
      }
    }
    return null;
  }

  String _symptomNarrativeThread(
    _ChatSessionState session,
    String currentMessage,
  ) {
    // Only stitch prior turns when we are actively inside a symptom intake
    // session.  Outside an active intake session, stitching arbitrary prior
    // turns that happen to look like symptom narratives causes RAG/session
    // contamination: symptoms from previous unrelated turns (e.g., an
    // education question that mentioned blood) get injected into the current
    // review card as if the user reported them now.  (BUG-053)
    //
    // Inside an active intake session (awaitingSymptomIntake == true), the
    // multi-turn stitch is intentional: "log a symptom" → "cramping" → "7/10"
    // should be parsed as a single coherent extraction context.
    if (!session.awaitingSymptomIntake) {
      return _clip(currentMessage.trim(), 600);
    }
    final pieces = <String>[];
    final intakeStart = _symptomIntakeStartTurnIndex(session);
    final intakeTurns = intakeStart == null
        ? session.turns
        : session.turns.sublist(intakeStart + 1);
    // Only stitch within the current intake thread. A user may have mentioned
    // prior symptoms in earlier turns (or earlier drafts they later canceled);
    // those MUST NOT leak into a new intake session (BUG-053).
    //
    // Cap the stitch to a small window for performance and prompt compactness.
    for (final turn in intakeTurns.reversed.take(6).toList().reversed) {
      final lower = turn.userMessage.toLowerCase().trim();
      // Skip question turns — they are information requests, not symptom logs.
      // A question turn that happens to contain 'all day' (e.g. 'did it hurt
      // all day?') must not be stitched into the extraction transcript.
      if (_isQuestionLike(lower)) continue;
      if (_looksLikeSymptomNarrative(lower) ||
          lower.contains('gluten') ||
          lower.contains('all day') ||
          lower.contains('times a day')) {
        pieces.add(turn.userMessage.trim());
      }
    }
    pieces.add(currentMessage.trim());
    return _clip(pieces.where((piece) => piece.isNotEmpty).join('. '), 600);
  }

  bool _isQuestionLike(String lower) {
    return lower.trim().endsWith('?') ||
        lower.startsWith('what ') ||
        lower.startsWith('why ') ||
        lower.startsWith('how ') ||
        lower.startsWith('can ') ||
        lower.startsWith('do ') ||
        lower.startsWith('does ') ||
        lower.contains('tell me') ||
        lower.contains('summarize') ||
        lower.contains('explain');
  }

  String _pendingSymptomSummary(Map<String, Object?> payload) {
    final rawAll = payload['all_symptoms'];
    final isSingle = rawAll is! List || rawAll.length <= 1;

    if (isSingle) {
      // Single symptom — surface every extracted field so the user can verify
      // before confirming. Use dot-separated format for scannability.
      final firstSymptom =
          (rawAll is List && rawAll.isNotEmpty) ? (rawAll.first as Map?) : null;

      // Prefer the formatted label from user_facing_description; fall back to type
      final symptomLabel =
          (firstSymptom?['user_facing_description'] as String?)?.isNotEmpty ==
                  true
              ? firstSymptom!['user_facing_description'] as String
              : payload['user_facing_description'] as String? ??
                  _humanSymptomLabel(payload['symptom_type']?.toString() ?? '');

      final parts = <String>[symptomLabel];
      final labelLower = symptomLabel.toLowerCase();

      final sev = firstSymptom?['severity'] ?? payload['severity'];
      if (sev != null) parts.add('severity $sev/10');

      final dur =
          firstSymptom?['duration_minutes'] ?? payload['duration_minutes'];
      if (dur is num && dur > 0) {
        final durationText = _humanizeDuration(dur.toInt());
        final labelAlreadyMentionsDuration =
            labelLower.contains(' for ') || labelLower.contains(durationText);
        if (!labelAlreadyMentionsDuration) {
          parts.add('duration $durationText');
        }
      }

      final meal = firstSymptom?['meal_relation'] ?? payload['meal_relation'];
      if (meal != null && meal.toString().isNotEmpty) {
        parts.add('timing $meal');
      }

      // Raw notes carry frequency, trigger, and the user's own words.
      // Always show these so the user can catch extraction errors before saving.
      final rawNotes =
          firstSymptom?['notes'] as String? ?? payload['notes'] as String?;
      if (rawNotes != null && rawNotes.trim().isNotEmpty) {
        parts.add('details: ${rawNotes.trim()}');
      }

      final flags = payload['safety_flags'];
      if (flags is List && flags.contains('bleeding_reported')) {
        parts.add('bleeding reported');
      }

      return '${parts.join(' · ')}. Nothing is saved until you confirm.';
    }

    // Multi-symptom path — Oxford-comma label, no per-symptom detail expansion
    final labels = rawAll
        .whereType<Map>()
        .map((s) => _humanSymptomLabel(s['symptom_type']?.toString() ?? ''))
        .where((l) => l.isNotEmpty)
        .toList(growable: false);
    final String combinedLabel;
    if (labels.length == 2) {
      combinedLabel = '${labels[0]} and ${labels[1]}';
    } else if (labels.length >= 3) {
      final init = labels.take(labels.length - 1).join(', ');
      combinedLabel = '$init, and ${labels.last}';
    } else {
      combinedLabel =
          payload['user_facing_description'] as String? ?? 'symptom';
    }
    return '$combinedLabel. Nothing is saved until you confirm.';
  }

  List<String> _symptomSlotHints(String sourceText) {
    final lower = sourceText.toLowerCase();
    final hasSymptom = SymptomParserService.matchSymptom(lower) != null;
    final hasFrequency = RegExp(
      r'\b(?:daily|every day|every morning|often|usually|sometimes|x\s*\d+|\d+\s*(?:x|times?)|once|twice|\d+\s*(?:per|a)\s*(?:day|morning|night|week))\b',
    ).hasMatch(lower);
    final hasTrigger = RegExp(
      r'\b(?:after|before|because of|trigger|from|due to)\b',
    ).hasMatch(lower);
    final hasDuration = RegExp(
      r'\b(?:\d+\s*(?:min|minute|hour|hr|day)s?|all day|all morning|all night|for\s+\d+)\b',
    ).hasMatch(lower);
    final missing = <String>[];
    if (!hasSymptom) missing.add('the symptom');
    if (!hasFrequency) missing.add('how often it happens');
    if (!hasTrigger) missing.add('what seems to trigger it');
    if (!hasDuration) missing.add('how long it lasts');
    return missing.isEmpty
        ? const ['a little more detail']
        : missing.take(3).toList(growable: false);
  }

  ChatPendingAction? _forcedSymptomPendingAction({
    required String sourceText,
    required DateTime loggedAt,
  }) {
    final parsed = const SymptomParserService()
        .parse(transcript: sourceText, loggedAt: loggedAt)
        .structuredSymptom;
    final matches = SymptomParserService.matchAllSymptoms(sourceText);
    final manualType = _manualHealthSymptomType(sourceText);
    final unknownHealthNarrative = matches.isEmpty &&
        parsed.symptomType == 'other' &&
        (_containsHealthTerms(sourceText) || manualType != null);
    if (matches.isEmpty &&
        parsed.symptomType == 'other' &&
        !unknownHealthNarrative) {
      return null;
    }
    final allSymptoms = <Map<String, Object?>>[];
    final seen = <String>{};
    if (parsed.symptomType != 'other' || manualType != null) {
      final canonicalType = _canonicalSymptomType(
        manualType ?? parsed.symptomType,
      );
      allSymptoms.add({
        'symptom_type': canonicalType,
        'severity': parsed.severity1To10,
        'duration_minutes': parsed.durationMinutes,
        'meal_relation': parsed.mealRelation,
        'notes': parsed.notes,
        'user_facing_description': _humanSymptomLabel(canonicalType),
      });
      seen.add(canonicalType);
    } else if (unknownHealthNarrative) {
      allSymptoms.add({
        'symptom_type': 'other_health_symptom',
        'severity': parsed.severity1To10,
        'duration_minutes': parsed.durationMinutes,
        'meal_relation': parsed.mealRelation,
        'notes': _clip(sourceText, 280),
        'user_facing_description': 'other health symptom',
      });
      seen.add('other_health_symptom');
    }
    for (final match in matches) {
      final canonicalType = _canonicalSymptomType(match.symptomType);
      if (seen.contains(canonicalType)) continue;
      allSymptoms.add({
        'symptom_type': canonicalType,
        'severity': null,
        'duration_minutes': parsed.durationMinutes,
        'meal_relation': parsed.mealRelation,
        'notes': _clip(sourceText, 280),
        'user_facing_description': _humanSymptomLabel(canonicalType),
      });
      seen.add(canonicalType);
    }
    final scopedSymptoms = _preferSpecificSymptomPayloads(
      sourceText,
      _filterOverlappingSymptomPayloads(sourceText, allSymptoms),
    );
    allSymptoms
      ..clear()
      ..addAll(scopedSymptoms);
    if (allSymptoms.isEmpty) return null;
    final primary = allSymptoms.first;
    return ChatPendingAction(
      type: 'symptom_review',
      payloadJson: {
        'symptom_type': primary['symptom_type'],
        'analytics_category': primary['symptom_type'],
        'severity': primary['severity'],
        'duration_minutes': primary['duration_minutes'],
        'meal_relation': primary['meal_relation'],
        'source_text': _clip(sourceText, 280),
        'user_facing_description': allSymptoms
            .map((s) => _humanSymptomLabel(s['symptom_type']?.toString() ?? ''))
            .join(' and '),
        'uncertainty_notes': parsed.uncertaintyNotes,
        'safety_flags': parsed.safetyFlags,
        'extraction_method': 'deterministic_forced_recovery',
        'requires_confirmation': true,
        'all_symptoms': allSymptoms,
        'symptom_count': allSymptoms.length,
      },
      confidence: parsed.extractionConfidence,
    );
  }

  ChatPendingAction? _manualSymptomPendingAction({
    required String sourceText,
    required DateTime loggedAt,
  }) {
    final primaryType = _manualHealthSymptomType(sourceText);
    if (primaryType == null) return null;
    final lower = sourceText.toLowerCase();
    final symptoms = <Map<String, Object?>>[
      {
        'symptom_type': primaryType,
        'severity': null,
        'duration_minutes': _durationMinutesFromText(lower),
        'meal_relation': _mealRelationFromText(lower),
        'notes': _clip(sourceText, 280),
        'user_facing_description': _humanSymptomLabel(primaryType),
      },
    ];
    final secondary = _secondaryManualSymptomTypes(sourceText, primaryType);
    for (final type in secondary) {
      symptoms.add({
        'symptom_type': type,
        'severity': null,
        'duration_minutes': _durationMinutesFromText(lower),
        'meal_relation': _mealRelationFromText(lower),
        'notes': _clip(sourceText, 280),
        'user_facing_description': _humanSymptomLabel(type),
      });
    }
    final scoped = _preferSpecificSymptomPayloads(
      sourceText,
      _filterOverlappingSymptomPayloads(sourceText, symptoms),
    );
    if (scoped.isEmpty) return null;
    final primary = scoped.first;
    return ChatPendingAction(
      type: 'symptom_review',
      payloadJson: {
        'symptom_type': primary['symptom_type'],
        'analytics_category': primary['symptom_type'],
        'severity': primary['severity'],
        'duration_minutes': primary['duration_minutes'],
        'meal_relation': primary['meal_relation'],
        'source_text': _clip(sourceText, 280),
        'user_facing_description': scoped
            .map((s) => _humanSymptomLabel(s['symptom_type']?.toString() ?? ''))
            .join(' and '),
        'uncertainty_notes': const ['Severity was not explicit.'],
        'safety_flags': [if (primaryType == 'bleeding') 'bleeding_reported'],
        'extraction_method': 'deterministic_manual_health_recovery',
        'requires_confirmation': true,
        'all_symptoms': scoped,
        'symptom_count': scoped.length,
      },
      confidence: 0.76,
    );
  }

  int? _durationMinutesFromText(String lower) {
    if (lower.contains('all morning')) return 240;
    if (lower.contains('all afternoon')) return 240;
    if (lower.contains('all night')) return 480;
    if (lower.contains('all day')) return 1440;
    final days = RegExp(r'\b(\d+)\s*days?\b').firstMatch(lower);
    if (days != null) return (int.tryParse(days.group(1) ?? '') ?? 0) * 1440;
    final hours = RegExp(r'\b(\d+)\s*(?:hours?|hrs?)\b').firstMatch(lower);
    if (hours != null) return (int.tryParse(hours.group(1) ?? '') ?? 0) * 60;
    final minutes = RegExp(r'\b(\d+)\s*(?:minutes?|mins?)\b').firstMatch(lower);
    if (minutes != null) return int.tryParse(minutes.group(1) ?? '');
    if (lower.contains('half an hour')) return 30;
    return null;
  }

  String? _mealRelationFromText(String lower) {
    if (lower.contains('after breakfast')) return 'after_breakfast';
    if (lower.contains('after lunch')) return 'after_lunch';
    if (lower.contains('after dinner')) return 'after_dinner';
    if (lower.contains('after eating') ||
        lower.contains('after meal') ||
        lower.contains('food')) {
      return 'after_meal';
    }
    return null;
  }

  List<String> _secondaryManualSymptomTypes(
    String sourceText,
    String primaryType,
  ) {
    final lower = _normalizeIntentText(sourceText).toLowerCase();
    final types = <String>[];
    void add(String type) {
      if (type != primaryType && !types.contains(type)) types.add(type);
    }

    if (lower.contains('nausea') || lower.contains('nauseous')) add('nausea');
    if (lower.contains('bloated') ||
        lower.contains('bloating') ||
        lower.contains('bloateed')) {
      add('bloating');
    }
    if (lower.contains('tired') ||
        lower.contains('fatigue') ||
        lower.contains('exhausted')) {
      add('fatigue');
    }
    if (lower.contains('cramping') || lower.contains('cramps')) {
      add('abdominal_pain');
    }
    if (lower.contains('mouth sore') ||
        lower.contains('mouth sores') ||
        lower.contains('mouth ulcer') ||
        lower.contains('canker')) {
      add('mouth_sores');
    }
    if (lower.contains('fever') || lower.contains('chills')) add('fever');
    if (lower.contains('vomit')) add('vomiting');
    if (lower.contains('fever')) add('fever');
    if (primaryType != 'urinary_urgency' && lower.contains('urgency')) {
      add('urgency');
    }
    if (lower.contains('diarrhea') || lower.contains('loose stool')) {
      add('stool_frequency');
    }
    return types;
  }

  /// Converts a duration in minutes to a human-readable string that mirrors
  /// natural language ("all day", "2 hours", "45m").
  String _humanizeDuration(int minutes) {
    if (minutes >= 1380) return 'all day'; // 23h+ → "all day"
    if (minutes >= 660) {
      // 11h+ → "X hours" (rounds to nearest hour)
      return '${(minutes / 60).round()} hours';
    }
    if (minutes >= 60) {
      final h = minutes ~/ 60;
      final m = minutes % 60;
      return m > 0 ? '${h}h ${m}m' : '${h}h';
    }
    return '${minutes}m';
  }

  String? _symptomSafetyNote(Map<String, Object?> payload) {
    final flags = (payload['safety_flags'] as List?)
            ?.map((item) => item.toString())
            .toSet() ??
        const <String>{};
    if (flags.contains('urgent_review')) {
      return 'Because this note mentions higher-risk symptoms, contact urgent care or your GI team if you feel unsafe.';
    }
    if (flags.contains('bleeding_reported')) {
      return 'Because you mentioned bleeding, keep clinician follow-up in mind when you review this note.';
    }
    return null;
  }

  /// If the user mentioned symptoms in a question-like message that didn't
  /// trigger the full symptom-review flow, append a gentle offer to log.
  String _appendSymptomLogHint(
    String response, {
    required String userMessage,
    required String intent,
  }) {
    // Don't double up — these intents already handle symptom logging
    if (intent == 'symptom_log_followup' || intent == 'greeting') {
      return response;
    }
    final lower = userMessage.toLowerCase();
    if (!_looksLikeSymptomNarrative(lower)) return response;
    // Only append if the message was question-like (narrative messages
    // already go through _pendingSymptomActionFor)
    if (!_isQuestionLike(lower)) return response;
    return '$response\n\n'
        'It sounds like you mentioned a symptom — would you like me to log it? '
        'Just say "log that" and I\'ll save it for your timeline.';
  }

  // Intents where the generic "tracking tool" disclaimer erodes the companion
  // persona. These flows have targeted safety notes via _symptomSafetyNote()
  // or deterministic escalation language that already handles safety.
  static const _disclaimerSuppressedIntents = {
    'emotional_support',
    'emotional_vent_with_symptoms',
    'symptom_log_followup',
    'multi_symptom_log',
    'check_in_log',
    'doctor_summary',
    'greeting',
    'smalltalk',
    // Wearable/activity data answers are factual metrics, not clinical findings
    // — a disclaimer adds noise and breaks conversational tone.
    'wearable_data_question',
    'app_meta_question',
  };

  String _applySafetyEnvelope(
    String message,
    String userMessage, {
    String? intent,
  }) {
    var trimmed = _stripRuntimeLoadingNotice(message).trim();
    if (intent != null &&
        const {
          'symptom_log_followup',
          'symptom_question',
          'multi_symptom_log',
          'lab_question',
          'continuation',
          'check_in_log',
          'greeting',
          'smalltalk',
          'app_meta_question',
          'wearable_data_question',
        }.contains(intent)) {
      trimmed = trimmed.replaceAll(
        'There is more to cover — ask me to continue and I will pick up where I left off.',
        '',
      );
      trimmed = trimmed.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    }
    if (intent == 'forecast_watchlist') {
      trimmed = _formatForecastWatchlistForDisplay(trimmed);
    }
    if (trimmed.isEmpty) {
      return _requiresSafetyNotice(userMessage)
          ? 'I was not able to generate a response right now. Please try again. This is not a diagnosis.'
          : 'I was not able to generate a response right now. Please try again.';
    }
    // Suppress disclaimer for intents where it hurts more than it helps
    if (intent != null && _disclaimerSuppressedIntents.contains(intent)) {
      return trimmed;
    }
    if (_isGreeting(userMessage.toLowerCase())) {
      return trimmed;
    }
    final lower = trimmed.toLowerCase();
    // Already contains safety language — don't double-append
    if (lower.contains('not a diagnosis') ||
        lower.contains('tracking tool') ||
        (lower.contains('consult') && lower.contains('gi doctor'))) {
      return trimmed;
    }
    if (!_requiresSafetyNotice(userMessage) && !_containsHealthTerms(trimmed)) {
      return trimmed;
    }
    // Each generic disclaimer fires at most once per session. Repeat appearances
    // of "I'm a tracking tool" erode the companion persona without adding safety value.
    const disclaimerKey = 'tracking_tool';
    if (_deliveredDisclaimers.contains(disclaimerKey)) return trimmed;
    _deliveredDisclaimers.add(disclaimerKey);
    return '$trimmed\n\nRemember, I\'m a tracking tool — not a doctor. For any medical decisions, your GI team is the best resource.';
  }

  String _formatForecastWatchlistForDisplay(String message) {
    var value = message;
    value = value.replaceAllMapped(
      RegExp(r'\s+(Watchpoint\s+\d+\s*:)', caseSensitive: false),
      (m) => '\n\n${m[1]}',
    );
    value = value.replaceAllMapped(
      RegExp(r'\s+(Your global flare risk\b)', caseSensitive: false),
      (m) => '\n\n${m[1]}',
    );
    value = value.replaceAllMapped(
      RegExp(r'\s+(There is more to cover\b)', caseSensitive: false),
      (m) => '\n\n${m[1]}',
    );
    return value.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  bool _isGreeting(String lower) {
    final normalized = lower
        .replaceAll(RegExp(r'[^a-z\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.isEmpty) {
      return false;
    }
    const greetings = {
      'hi',
      'hello',
      'hey',
      'yo',
      'sup',
      'hiya',
      'howdy',
      'good morning',
      'good afternoon',
      'good evening',
      'good night',
      'gm',
      'morning',
      'evening',
      'afternoon',
      'how are you',
      'how r u',
      'how are u',
      'how r you',
      'how you doing',
      'how ya doing',
      'how u doing',
      'hows it going',
      'how s it going',
      'whats up',
      'what s up',
      'hey there',
      'hi there',
      'hello there',
      'hey gemma_flares',
      'hi gemma_flares',
      'hello gemma_flares',
      'hey gut guard',
      'hi gut guard',
      'greetings',
      'ayo',
      'hey hey',
      'heya',
      'hola',
      'bonjour',
      'namaste',
      // Bug-D: positive casual check-ins misread as negative sentiment
      'good u',
      'good you',
      'im good',
      'i m good',
      'i am good',
      'doing good',
      'doing well',
      'pretty good',
      'not bad',
      'feeling good',
      'all good',
      'all good here',
      'good thanks',
      'good thank you',
      'im great',
      'i m great',
      'feeling great',
      'great',
    };
    return greetings.contains(normalized);
  }

  bool _isThanks(String lower) {
    final normalized = lower
        .replaceAll(RegExp(r'[^a-z\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    const thanks = {
      'thanks',
      'thank you',
      'thx',
      'ok thanks',
      'okay thanks',
      'ok thx',
      'okay thx',
      'got it thanks',
      'cool thanks',
    };
    return thanks.contains(normalized);
  }

  bool _isMemoryPrivacyQuestion(String lower) {
    return (lower.contains('memory') ||
            lower.contains('saved') ||
            lower.contains('delete') ||
            lower.contains('export')) &&
        (lower.contains('local') ||
            lower.contains('where') ||
            lower.contains('can i') ||
            lower.contains('was that') ||
            lower.contains('privacy'));
  }

  bool _isCommandListRequest(String lower) {
    final normalized = lower
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return normalized == 'help' ||
        normalized == 'commands' ||
        normalized == 'command list' ||
        normalized == 'show commands' ||
        normalized == 'list commands' ||
        normalized == 'show prompts' ||
        normalized == 'prompt list' ||
        normalized == 'show prompt list' ||
        normalized == 'what were those prompts again' ||
        normalized == 'what were those commands again' ||
        normalized == 'what can i ask' ||
        normalized == 'what can i ask you' ||
        normalized == 'more info' ||
        normalized == 'more information' ||
        normalized == 'menu' ||
        normalized == 'options' ||
        normalized.contains('show me commands') ||
        normalized.contains('show me prompts') ||
        normalized.contains('what commands') ||
        normalized.contains('what prompts');
  }

  String _commandListReply() {
    final presetLines = prompts.kPromptPresetDefinitions
        .map((preset) => '- ${preset.label}')
        .join('\n');
    final summaryCommandLines = const [
      '- Give me my daily summary',
      '- Give me my weekly summary',
      '- Give me my monthly summary',
    ].join('\n');
    final starterLines = prompts.kChatStarterPromptDefinitions
        .map((starter) => '- ${starter.prompt}')
        .join('\n');
    return [
      'Absolutely — here is your command list. You can type or copy any of these prompts:',
      '',
      'Preset commands (special routed outputs):',
      presetLines,
      '',
      'Direct summary commands (deterministic summaries):',
      summaryCommandLines,
      '',
      'Starter prompts (copy/paste examples):',
      starterLines,
      '',
      'Tip: you can say "help", "command list", "what were those prompts again", or "show prompts" any time to see this list again.',
    ].join('\n');
  }

  String? _appFeatureReply(String lower) {
    if (_isCommandListRequest(lower)) {
      return _commandListReply();
    }
    if (lower.contains('profile details') ||
        lower.contains('before i can use gemma_flares') ||
        lower.contains('what profile')) {
      return 'Gemma Flares uses your basic IBD profile, care context, privacy choices, and setup status to personalize check-ins, symptoms, labs, risk, and local memory.';
    }
    if (lower.contains('why does gemma_flares need apple health') ||
        lower.contains('health access')) {
      return 'Gemma Flares uses Apple Health locally for wearable signals like sleep, activity, heart rate, and HRV so risk and trend answers can use synced context on this device.';
    }
    if ((lower.contains('gemma') || lower.contains('model')) &&
        (lower.contains('locally') ||
            lower.contains('sending') ||
            lower.contains('somewhere') ||
            lower.contains('device'))) {
      return 'Gemma 4 runs locally on this iPhone when the model is loaded. Gemma Flares keeps health context on device unless you choose to export it.';
    }
    if (lower.contains('notify') || lower.contains('notification')) {
      return 'Gemma Flares can notify you locally about risk changes, missed check-ins, new labs to review, medication reminders, or symptom escalation patterns.';
    }
    if (lower.contains('export')) {
      return 'Use Settings export to create a local Gemma Flares bundle for a doctor or tester, including symptoms, labs, risk context, runtime status, and RAG transactions.';
    }
    if (lower.contains('iphone test agent') ||
        lower.contains('device agent') ||
        lower.contains('prove gemma loaded')) {
      return 'Gemma Flares can run the iPhone test agent on this device. It loads Gemma, sends persona prompts through the app, shows progress, and writes a local report you can review.';
    }
    return null;
  }

  bool _isUrgentSymptom(String lower) {
    // Explicit past-tense log requests ("log that I had a fever") are symptom
    // logging commands, not active emergencies — skip urgent detection.
    final isExplicitPastLog = (lower.contains('log that i had') ||
            lower.contains('log that i have') ||
            lower.contains('log that i was') ||
            lower.contains('record that i had') ||
            lower.contains('note that i had') ||
            lower.contains('note: i had') ||
            lower.contains('note that i had')) &&
        !lower.contains('right now') &&
        !lower.contains(' now') &&
        !lower.contains('emergency') &&
        !lower.contains('still happening') &&
        !lower.contains('still have');
    if (isExplicitPastLog) return false;
    final educationalQuestion = _isQuestionLike(lower) &&
        (lower.contains('difference between') ||
            lower.contains('what causes') ||
            lower.contains('why do i') ||
            lower.contains('what does') ||
            lower.contains('what is') ||
            lower.contains('explain')) &&
        !lower.contains('right now') &&
        !lower.contains('today') &&
        !lower.contains('this morning') &&
        !lower.contains('worried') &&
        !lower.contains('more than usual');
    if (educationalQuestion) {
      return false;
    }

    // Detect combinations that suggest urgent medical needs
    final hasSeverePain = lower.contains('severe pain') ||
        lower.contains('worst pain') ||
        lower.contains('excruciating') ||
        lower.contains('unbearable') ||
        lower.contains('severe abdominal pain') ||
        lower.contains('can\'t take the pain') ||
        lower.contains('cant take the pain') ||
        lower.contains('10/10 pain') ||
        lower.contains('10 out of 10') ||
        lower.contains('can barely walk') ||
        lower.contains('barely walk') ||
        lower.contains('doubled over') ||
        lower.contains('doubled up') ||
        lower.contains('pain is unbearable') ||
        lower.contains('intense pain') ||
        lower.contains('screaming in pain') ||
        lower.contains('writhing') ||
        lower.contains('severe gas pain') ||
        lower.contains('can\'t move') ||
        lower.contains('cant move') ||
        lower.contains('can\'t stand up') ||
        lower.contains('cant stand up') ||
        lower.contains('can\'t function') ||
        lower.contains('cant function');
    // Any rectal bleeding or blood in stool is urgent regardless of amount.
    final hasHeavyBleeding = lower.contains('blood in my stool') ||
        lower.contains('blood in stool') ||
        lower.contains('blood in the stool') ||
        lower.contains('blood in my toilet') ||
        lower.contains('blood in the toilet') ||
        lower.contains('rectal bleeding') ||
        lower.contains('rectal bleed') ||
        lower.contains('bleeding rectally') ||
        lower.contains('noticed blood') ||
        lower.contains('seeing blood') ||
        lower.contains('blood when i wipe') ||
        lower.contains('blood on the paper') ||
        lower.contains('blood on toilet paper') ||
        lower.contains('heavy bleeding') ||
        lower.contains('black stool') ||
        lower.contains('black stools') ||
        lower.contains('black and tarry') ||
        lower.contains('tarry stool') ||
        lower.contains('bright red blood') ||
        lower.contains('a lot of blood') ||
        lower.contains('blood everywhere') ||
        lower.contains('soaked in blood') ||
        lower.contains('can\'t stop bleeding') ||
        lower.contains('cant stop bleeding') ||
        lower.contains('massive bleeding') ||
        lower.contains('passing blood') ||
        lower.contains('more blood than usual') ||
        lower.contains('escalating blood') ||
        lower.contains('blood is getting worse') ||
        // "blood this morning", "blood today" without stool context
        (lower.contains('blood') &&
            (lower.contains('this morning') ||
                lower.contains('today') ||
                lower.contains('right now'))) ||
        ((lower.contains('blood') || lower.contains('bleeding')) &&
            (lower.contains('in my stool') ||
                lower.contains('in the stool') ||
                lower.contains('more than usual') ||
                lower.contains('worse than usual') ||
                lower.contains('when should i be worried') ||
                lower.contains('worried') ||
                lower.contains('when to worry') ||
                lower.contains('safe to wait') ||
                lower.contains('wait until next week')));
    // Fever with any associated symptom (chills, nausea) is urgent.
    final hasFeverWithSymptom = (lower.contains('fever') ||
            lower.contains('temp') ||
            lower.contains('temperature')) &&
        (lower.contains('chills') ||
            lower.contains('nausea') ||
            lower.contains('vomit') ||
            lower.contains('shiver') ||
            lower.contains('shaking'));
    final hasFever = hasFeverWithSymptom ||
        lower.contains('high fever') ||
        lower.contains('burning up') ||
        lower.contains('really high temp') ||
        RegExp(
          r'\b(?:fever|temp(?:erature)?)\D{0,12}10[34](?:\.\d)?\b',
        ).hasMatch(lower);
    final hasDehydration = lower.contains('dehydrated') ||
        lower.contains('can\'t keep anything down') ||
        lower.contains('cant keep anything down') ||
        lower.contains('can\'t drink') ||
        lower.contains('haven\'t eaten in') ||
        lower.contains('no fluids') ||
        lower.contains('throwing up everything');
    final hasObstructionSignal = lower.contains('partial blockage') ||
        lower.contains('bowel obstruction') ||
        lower.contains('obstruction') ||
        lower.contains('partial bowel') ||
        lower.contains('blocked up') ||
        lower.contains('nothing is coming out') ||
        lower.contains('nothing coming out') ||
        lower.contains('no bowel movement') ||
        lower.contains('no stool') ||
        (lower.contains('nothing coming out') && lower.contains('cramping')) ||
        lower.contains('cant pass stool') ||
        lower.contains('can\'t pass stool') ||
        lower.contains('cant pass gas') ||
        lower.contains('can\'t pass gas') ||
        lower.contains('stopped passing') ||
        lower.contains('haven\'t had a bowel') ||
        lower.contains('havent had a bowel');
    // Vomiting combined with cramping is a potential obstruction/urgent signal.
    final hasVomitingWithCramping =
        (lower.contains('vomit') || lower.contains('throwing up')) &&
            (lower.contains('cramp') || lower.contains('pain'));
    final hasUnintentionalWeightLoss = RegExp(
              r'\blost\s+\d+(?:\.\d+)?\s+(?:pounds?|lbs?)\b',
            ).hasMatch(lower) &&
            (lower.contains('without trying') ||
                lower.contains('unintentional') ||
                lower.contains('unexpected') ||
                lower.contains('without meaning') ||
                lower.contains('not trying') ||
                lower.contains('not on purpose') ||
                lower.contains('without dieting') ||
                lower.contains('without diet') ||
                lower.contains('by accident') ||
                lower.contains('sudden') ||
                lower.contains('rapid')) ||
        // "lost X pounds in the last N weeks/months" phrasing without qualifier
        RegExp(
          r'\blost\s+\d+(?:\.\d+)?\s+(?:pounds?|lbs?)\s+in\s+the\s+last\b',
        ).hasMatch(lower) ||
        // "losing weight rapidly / losing weight fast"
        lower.contains('losing weight rapidly') ||
        lower.contains('losing weight fast') ||
        lower.contains('rapid weight loss') ||
        lower.contains('unexplained weight loss') ||
        lower.contains('unintentional weight loss');
    final hasEmergency = lower.contains('emergency') ||
        lower.contains('dizzy') ||
        lower.contains('faint') ||
        lower.contains('lightheaded') ||
        lower.contains(' er ') ||
        lower.contains('going to the er') ||
        lower.contains('go to er') ||
        lower.contains('hospital') ||
        lower.contains('ambulance') ||
        lower.contains('call 911') ||
        lower.contains('should i go to the er');
    return hasSeverePain ||
        hasHeavyBleeding ||
        hasFever ||
        hasDehydration ||
        hasObstructionSignal ||
        hasVomitingWithCramping ||
        hasUnintentionalWeightLoss ||
        hasEmergency;
  }

  bool _isEmotionalDistress(String lower) {
    // Explicit clinical/emotional distress
    if (lower.contains('scared') ||
        lower.contains('not the best') ||
        lower.contains('not feeling great') ||
        lower.contains('not doing great') ||
        lower.contains('rough day') ||
        lower.contains('tough day') ||
        lower.contains('bad day') ||
        lower.contains('afraid') ||
        lower.contains('anxious') ||
        lower.contains('anxiety') ||
        lower.contains('worried') ||
        lower.contains('terrified') ||
        lower.contains('depressed') ||
        lower.contains('hopeless') ||
        lower.contains('overwhelmed') ||
        lower.contains('can\'t cope') ||
        lower.contains('cant cope') ||
        lower.contains('breaking down') ||
        lower.contains('freaking out') ||
        lower.contains('panicking') ||
        lower.contains('i can\'t do this') ||
        lower.contains('i cant do this') ||
        lower.contains('i\'m so tired of this') ||
        lower.contains('im so tired of this') ||
        lower.contains('will this ever get better') ||
        lower.contains('give up') ||
        lower.contains('tired of being sick') ||
        lower.contains('hate this disease') ||
        lower.contains('why me') ||
        lower.contains('not fair') ||
        lower.contains('so frustrated') ||
        lower.contains('feel alone') ||
        lower.contains('i cried') ||
        lower.contains('crying') ||
        lower.contains('no one understands') ||
        lower.contains('isolating') ||
        lower.contains('isolated') ||
        lower.contains('work is suffering') ||
        lower.contains('exhausted') ||
        lower.contains('burnout') ||
        lower.contains('burn out') ||
        lower.contains('burnt out') ||
        lower.contains('can\'t do it anymore') ||
        lower.contains('cant do it anymore') ||
        lower.contains('done with this') ||
        lower.contains('so done') ||
        lower.contains('at my limit') ||
        lower.contains('at my wit') ||
        lower.contains('falling apart') ||
        lower.contains('losing it') ||
        lower.contains('can\'t handle') ||
        lower.contains('cant handle') ||
        lower.contains('fed up') ||
        lower.contains('so over this') ||
        lower.contains('this disease is ruining') ||
        lower.contains('chronic illness') && lower.contains('hard') ||
        lower.contains('life is hard') ||
        lower.contains('quality of life') && lower.contains('poor') ||
        lower.contains('quality of life') && lower.contains('bad')) {
      return true;
    }
    // Casual venting — "I feel like shit", "feeling horrible", "having a rough day"
    const ventPatterns = [
      'feel like shit',
      'feeling like shit',
      'feel horrible',
      'feeling horrible',
      'feel awful',
      'feeling awful',
      'feel terrible',
      'feeling terrible',
      'feel miserable',
      'feeling miserable',
      'feel like crap',
      'feeling like crap',
      'feel like garbage',
      'not feeling well',
      'not feeling ok',
      'not feeling okay',
      'feel bad today',
      'feeling bad today',
      'having a rough',
      'having a hard day',
      'having a hard time',
      'struggling today',
      'not ok today',
      'not okay today',
      'just not ok',
      'just not okay',
      'having a tough',
      'really rough',
      'pretty rough',
      // Short-form vents — common single-line responses to "how are you feeling?"
      'not good',
      'not great',
      'not well',
      'not doing well',
      'not feeling good',
      'feeling bad',
      'feel bad',
      'pretty bad',
      'really bad',
      'kind of rough',
      'sort of rough',
      'a bit rough',
      'not amazing',
      'could be better',
      'been better',
      'not the greatest',
      'not at my best',
      'rough one',
      'bad one today',
      'terrible today',
      'horrible today',
      'awful today',
      'miserable today',
    ];
    return ventPatterns.any((p) => lower.contains(p));
  }

  bool _isEmotionalVentWithSymptoms(String lower) {
    if (!_isEmotionalDistress(lower)) return false;
    return _looksLikeSymptomNarrative(lower);
  }

  bool _isMedicationQuestion(String lower) {
    final hasMedicationKeyword = lower.contains('medication') ||
        lower.contains('medicine') ||
        lower.contains('med') ||
        lower.contains('drug') ||
        lower.contains('prescription') ||
        lower.contains('dose') ||
        lower.contains('dosage') ||
        lower.contains('ibuprofen') ||
        lower.contains('naproxen') ||
        lower.contains('nsaid') ||
        lower.contains('aspirin') ||
        lower.contains('tylenol') ||
        lower.contains('acetaminophen') ||
        lower.contains('humira') ||
        lower.contains('remicade') ||
        lower.contains('stelara') ||
        lower.contains('entyvio') ||
        lower.contains('azathioprine') ||
        lower.contains('6-mp') ||
        lower.contains('methotrexate') ||
        lower.contains('prednisone') ||
        lower.contains('budesonide') ||
        lower.contains('mesalamine') ||
        lower.contains('biologic') ||
        lower.contains('infusion') ||
        lower.contains('injection') ||
        lower.contains('skyrizi') ||
        lower.contains('risankizumab') ||
        lower.contains('rinvoq') ||
        lower.contains('upadacitinib') ||
        lower.contains('cimzia') ||
        lower.contains('omvoh') ||
        lower.contains('tremfya') ||
        lower.contains('imuran') ||
        lower.contains('pentasa') ||
        lower.contains('sulfasalazine') ||
        lower.contains('lialda') ||
        lower.contains('simponi') ||
        lower.contains('mercaptopurine') ||
        lower.contains('ciprofloxacin') ||
        lower.contains('flagyl') ||
        lower.contains('metronidazole') ||
        lower.contains('jak inhibitor');
    if (!hasMedicationKeyword) return false;

    final isLoggingOnly = (lower.contains('log') ||
            lower.contains('logging') ||
            lower.contains('track') ||
            lower.contains('record') ||
            lower.contains('note that')) &&
        !lower.contains('should i') &&
        !lower.contains('can i') &&
        !lower.contains('what should i') &&
        !lower.contains('what do i do') &&
        !lower.contains('is it normal') &&
        !lower.contains('side effect');
    if (isLoggingOnly) return false;

    return lower.contains('should i') ||
        lower.contains('can i') ||
        lower.contains('can you') ||
        lower.contains('what should i') ||
        lower.contains('what do i do') ||
        lower.contains('is it normal') ||
        lower.contains('safe') ||
        lower.contains('worried') ||
        lower.contains('side effect') ||
        lower.contains('forgot') ||
        lower.contains('ran out') ||
        lower.contains('refill') ||
        lower.contains('not absorbing') ||
        lower.contains('what does that look') ||
        lower.contains('stop') ||
        lower.contains('change') ||
        lower.contains('switch') ||
        lower.contains('increase') ||
        lower.contains('decrease') ||
        lower.contains('adjust') ||
        lower.contains('raise') ||
        lower.contains('lower') ||
        lower.contains('work') ||
        lower.contains('help') ||
        lower.contains('take') ||
        lower.contains('start') ||
        lower.contains('about');
  }

  bool _isMedicationLogRequest(String lower) {
    final normalized = TextNormalizationService.normalizeForIntent(lower);
    final hasMedicationObject = _mentionsMedicationOrSupplement(normalized);
    if (!hasMedicationObject) return false;

    final asksAdvice = normalized.contains('should i') ||
        normalized.contains('can i') ||
        normalized.contains('safe') ||
        normalized.contains('is it normal') ||
        normalized.contains('side effect') ||
        normalized.contains('what do i do') ||
        normalized.contains('what should i') ||
        normalized.contains('change') ||
        normalized.contains('switch') ||
        normalized.contains('increase') ||
        normalized.contains('decrease') ||
        normalized.contains('adjust') ||
        normalized.contains('stop taking') ||
        normalized.contains('start taking');
    if (asksAdvice &&
        !(normalized.contains('log') ||
            normalized.contains('record') ||
            normalized.contains('track') ||
            normalized.contains('note that'))) {
      return false;
    }

    final hasExplicitLogVerb = normalized.contains('log') ||
        normalized.contains('logging') ||
        normalized.contains('record') ||
        normalized.contains('track') ||
        normalized.contains('note that') ||
        normalized.contains('add ') && normalized.contains('medication');
    final hasAdherenceVerb = RegExp(
      r'\b(took|take|taken|taking|started|had|got|received|did|missed|skipped|forgot)\b',
    ).hasMatch(normalized);
    final hasDoseEventNoun = normalized.contains('dose') ||
        normalized.contains('infusion') ||
        normalized.contains('injection') ||
        normalized.contains('shot') ||
        normalized.contains('pill') ||
        normalized.contains('tablet') ||
        normalized.contains('capsule');
    final looksLikeLabValue = _looksLikeLabValues(normalized);
    if (looksLikeLabValue && !hasAdherenceVerb && !hasExplicitLogVerb) {
      return false;
    }
    return hasExplicitLogVerb || hasAdherenceVerb || hasDoseEventNoun;
  }

  bool _mentionsMedicationOrSupplement(String lower) {
    return lower.contains('medication') ||
        lower.contains('medicine') ||
        lower.contains('med ') ||
        lower.contains('meds') ||
        lower.contains('prescription') ||
        lower.contains('dose') ||
        lower.contains('supplement') ||
        lower.contains('vitamin') ||
        lower.contains('b12') ||
        lower.contains('d3') ||
        lower.contains('biologic') ||
        lower.contains('infusion') ||
        lower.contains('injection') ||
        lower.contains('shot') ||
        lower.contains('humira') ||
        lower.contains('remicade') ||
        lower.contains('stelara') ||
        lower.contains('entyvio') ||
        lower.contains('skyrizi') ||
        lower.contains('rinvoq') ||
        lower.contains('prednisone') ||
        lower.contains('budesonide') ||
        lower.contains('mesalamine') ||
        lower.contains('azathioprine') ||
        lower.contains('methotrexate') ||
        lower.contains('imuran') ||
        lower.contains('lialda') ||
        lower.contains('pentasa');
  }

  bool _isDietQuestion(String lower) {
    if (lower.contains('log') ||
        lower.contains('logging') ||
        lower.contains('track') ||
        lower.contains('record') ||
        lower.contains('note that')) {
      return false;
    }

    final hasDietContext = RegExp(r'\beat\b').hasMatch(lower) ||
        lower.contains('food') ||
        lower.contains('diet') ||
        lower.contains('nutrition') ||
        lower.contains('meal') ||
        lower.contains('drink') ||
        lower.contains('dairy') ||
        lower.contains('gluten') ||
        lower.contains('fiber') ||
        lower.contains('alcohol') ||
        lower.contains('coffee') ||
        lower.contains('spicy') ||
        lower.contains('trigger food') ||
        lower.contains('safe to eat');
    if (!hasDietContext) return false;

    return lower.contains('should') ||
        lower.contains('can i') ||
        lower.contains('what should i') ||
        lower.contains('what can i') ||
        lower.contains('avoid') ||
        lower.contains('help') ||
        lower.contains('worse') ||
        lower.contains('better') ||
        lower.contains('about') ||
        lower.contains('what') ||
        lower.contains('safe to eat');
  }

  bool _isDataGapQuestion(String lower) {
    // Pure "apple watch" / "sync" mentions are NOT data-gap questions on their
    // own — "tell me about my apple watch data" should route to
    // wearable_data_question, not data-gap. Require an explicit gap/problem
    // signal paired with the watch/sync mention so we don't swallow benign
    // wearable queries here.
    final hasExplicitGap = lower.contains('missing data') ||
        lower.contains('no data') ||
        lower.contains('not syncing') ||
        lower.contains('syncing') ||
        lower.contains('why no') ||
        lower.contains("haven't synced") ||
        lower.contains('havent synced') ||
        lower.contains('watch not') ||
        lower.contains('need more data') ||
        lower.contains('not connected') ||
        lower.contains('data gap') ||
        lower.contains('empty') ||
        lower.contains("where's my data") ||
        lower.contains('wheres my data');
    if (hasExplicitGap) return true;
    // "sync" / "apple watch" alone are too broad; only treat as data-gap when
    // combined with a problem word like "not", "isn't", "issue", "stuck",
    // "broken", "problem".
    final hasProblemWord = lower.contains(' not ') ||
        lower.contains("isn't") ||
        lower.contains('issue') ||
        lower.contains('stuck') ||
        lower.contains('broken') ||
        lower.contains('problem') ||
        lower.contains("won't") ||
        lower.contains('wont ');
    if (hasProblemWord &&
        (lower.contains('apple watch') ||
            lower.contains('sync') ||
            lower.contains('healthkit'))) {
      return true;
    }
    return false;
  }

  bool _isOutOfScope(String lower) {
    final normalized = lower
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    const scopedRedirectFragments = {
      'idiot',
      'stupid',
      'dumb',
      'sexy',
      'sex',
      'love',
      'loce',
      'lol',
      'lmao',
      'bruh',
      'asdf',
      'qwerty',
    };
    return scopedRedirectFragments.contains(normalized) ||
        lower.contains('weather') ||
        lower.contains('stock') ||
        lower.contains('recipe') ||
        lower.contains('joke') ||
        lower.contains('tell me a story') ||
        lower.contains('what year') ||
        lower.contains('who is the president') ||
        lower.contains('play music') ||
        lower.contains('capital of') ||
        lower.contains('write me a') ||
        lower.contains('write a ') ||
        lower.contains('code') ||
        lower.contains('calculate') ||
        lower.contains('translate');
  }

  bool _isForecastWatchlistRequest(String lower) {
    return lower.contains('what should i watch') ||
        lower.contains('what shud i watch') ||
        lower.contains('what shud i watc') ||
        lower.contains('what shud i wach') ||
        lower.contains('what to watch') ||
        lower.contains('what do i watch') ||
        lower.contains('what should i look for') ||
        lower.contains('what should i look out') ||
        lower.contains('what should i monitor') ||
        lower.contains('what should i keep an eye on') ||
        lower.contains('watch out for') ||
        lower.contains('warning signs') ||
        lower.contains('early warning') ||
        lower.contains('early signs') ||
        lower.contains('signs to watch') ||
        lower.contains('signs of a flare') ||
        lower.contains('upcoming flare') ||
        lower.contains('about to flare') ||
        lower.contains('going to flare') ||
        lower.contains('flare coming') ||
        lower.contains('flare prediction') ||
        lower.contains('predict a flare') ||
        lower.contains('forecast') ||
        lower.contains('what should i be watching') ||
        lower.contains('what should i be watching for') ||
        lower.contains('what to be aware of') ||
        lower.contains('heads up') ||
        lower.contains('proactive') ||
        lower.contains('anticipate');
  }

  bool _isRiskQuestion(String lower) {
    // Note: 'why' deliberately excluded — it is too broad and routes unrelated
    // questions ("Why do I feel bloated?") through the risk path, causing Gemma
    // to receive risk context for non-risk questions and return filler.
    return lower.contains('risk') ||
        lower.contains('score') ||
        lower.contains('higher') ||
        lower.contains('high') ||
        lower.contains('worse') ||
        lower.contains('flare') ||
        // Trend/direction phrasing — e.g. "has my risk gone up or down this month?"
        lower.contains('gone up') ||
        lower.contains('gone down') ||
        lower.contains('up or down') ||
        lower.contains('risk trend') ||
        lower.contains('risk changed') ||
        lower.contains('risk getting') ||
        lower.contains('trending worse') ||
        lower.contains('trending better') ||
        lower.contains('baseline') ||
        lower.contains('unusual compared') ||
        lower.contains('is this a pattern') ||
        lower.contains('heading into a flare') ||
        lower.contains('creeping up') ||
        lower.contains('bad days in a row') ||
        lower.contains('should i be worried based on my trends');
  }

  bool _isConfidenceQuestion(String lower) {
    return lower.contains('confidence') ||
        lower.contains('how is it calculated') ||
        lower.contains('how is this calculated') ||
        lower.contains('why is confidence') ||
        lower.contains('data quality') ||
        lower.contains('how accurate') ||
        lower.contains('how reliable') ||
        lower.contains('how sure');
  }

  bool _isCheckInScoreQuestion(String lower) {
    final hasCheckIn = lower.contains('check in') ||
        lower.contains('check-in') ||
        lower.contains('checkin') ||
        lower.contains('pro2') ||
        lower.contains('pro-2');
    final hasScoreLike = lower.contains('score') ||
        lower.contains('scores') ||
        lower.contains('how did i do') ||
        lower.contains('how am i doing');
    return hasCheckIn && hasScoreLike;
  }

  bool _isLabQuestion(String lower) {
    return lower.contains('lab') ||
        lower.contains('lab result') ||
        lower.contains('test result') ||
        lower.contains('blood result') ||
        lower.contains('blood report') ||
        lower.contains('lab report') ||
        lower.contains('blood panel') ||
        lower.contains('specimen') ||
        lower.contains('bloodwork') ||
        lower.contains('blood work') ||
        lower.contains('blood test') ||
        lower.contains('blood panel') ||
        lower.contains('blood draw') ||
        lower.contains('test results') ||
        lower.contains('results came back') ||
        lower.contains('portal updated') ||
        lower.contains('quest diagnostics') ||
        lower.contains('labcorp') ||
        lower.contains('crp') ||
        lower.contains('hs-crp') ||
        lower.contains('esr') ||
        lower.contains('sed rate') ||
        lower.contains('sedimentation') ||
        lower.contains('calprotectin') ||
        lower.contains('fecal cal') ||
        lower.contains('ferritin') ||
        lower.contains('hemoglobin') ||
        lower.contains('haemoglobin') ||
        lower.contains('hematocrit') ||
        lower.contains('wbc') ||
        lower.contains('white blood') ||
        lower.contains('platelet') ||
        lower.contains('albumin') ||
        lower.contains('vitamin') ||
        lower.contains('b12') ||
        lower.contains('iron') ||
        RegExp(r'\balt\b').hasMatch(lower) ||
        RegExp(r'\bast\b').hasMatch(lower) ||
        lower.contains('alkaline phosphatase') ||
        lower.contains('creatinine') ||
        lower.contains('bun') ||
        lower.contains('electrolyte') ||
        lower.contains('tsh') ||
        ((lower.contains('my results') ||
                lower.contains('these results') ||
                lower.contains('the results')) &&
            (lower.contains('explain') ||
                lower.contains('show') ||
                lower.contains('mean') ||
                lower.contains('understand') ||
                lower.contains('what do')) &&
            !lower.contains('check in') &&
            !lower.contains('check-in') &&
            !lower.contains('checkin')) ||
        _mentionsAnyLabAnalyte(lower);
  }

  bool _mentionsAnyLabAnalyte(String lower) {
    const analytes = [
      'cbc',
      'cmp',
      'chemistry',
      'metabolic panel',
      'lipid panel',
      'thyroid panel',
      'urinalysis',
      'stool culture',
      'c diff',
      'c. diff',
      'clostridioides',
      'h pylori',
      'hemoglobin',
      'hgb',
      'hematocrit',
      'hct',
      'mcv',
      'mch',
      'mchc',
      'rdw',
      'rbc',
      'wbc',
      'platelet',
      'neutrophil',
      'lymphocyte',
      'monocyte',
      'eosinophil',
      'basophil',
      'crp',
      'hs-crp',
      'esr',
      'sed rate',
      'calprotectin',
      'lactoferrin',
      'albumin',
      'prealbumin',
      'total protein',
      'ferritin',
      'iron',
      'tibc',
      'transferrin',
      'b12',
      'folate',
      'vitamin',
      'vitamin c',
      'vitamin d',
      '25-oh',
      'alt',
      'ast',
      'alp',
      'alk phos',
      'alkaline phosphatase',
      'bilirubin',
      'ggt',
      'creatinine',
      'bun',
      'egfr',
      'gfr',
      'sodium',
      'potassium',
      'chloride',
      'bicarbonate',
      'co2',
      'calcium',
      'magnesium',
      'phosphorus',
      'phosphate',
      'glucose',
      'a1c',
      'hba1c',
      'tsh',
      'free t4',
      'free t3',
      'lipase',
      'amylase',
      'ldh',
    ];
    return analytes.any((term) {
      if (term.length <= 3 || term.contains(' ')) {
        final pattern = '(^|[^a-z0-9])${RegExp.escape(term)}([^a-z0-9]|\$)';
        return RegExp(pattern).hasMatch(lower);
      }
      return lower.contains(term);
    });
  }

  bool _isAppointmentPrepRequest(String lower) {
    final hasAppointmentContext = lower.contains('appointment') ||
        lower.contains('gi visit') ||
        lower.contains('doctor visit') ||
        lower.contains('before my appointment') ||
        lower.contains('before my gi') ||
        lower.contains('before my visit') ||
        lower.contains('ahead of my appointment') ||
        lower.contains('prepare for my') ||
        lower.contains('prep for my');
    if (!hasAppointmentContext) return false;
    return lower.contains('review') ||
        lower.contains('summary') ||
        lower.contains('prepare') ||
        lower.contains('prep') ||
        lower.contains('what should i bring') ||
        lower.contains('what to bring') ||
        lower.contains('what to tell') ||
        lower.contains('talking points') ||
        lower.contains('discuss') ||
        lower.contains('catch up');
  }

  bool _isDoctorSummaryRequest(String lower) {
    if (_isDailySummaryRequest(lower)) return false;
    // Require explicit clinical-visit language (doctor/GI/gastro/appointment),
    // not just 'visit' alone — 'since my last visit' is a temporal prefix and
    // must not be conflated with a request to produce a doctor's summary.
    final hasClinicalTarget = lower.contains('doctor') ||
        lower.contains('gi ') ||
        lower.contains('gastro') ||
        lower.contains('appointment') ||
        (lower.contains('visit') &&
            (lower.contains('doctor') ||
                lower.contains('gi ') ||
                lower.contains('gastro') ||
                lower.contains('note') ||
                lower.contains('report')));
    return hasClinicalTarget &&
        (lower.contains('summary') ||
            lower.contains('report') ||
            lower.contains('note') ||
            lower.contains('prepare') ||
            lower.contains('trend chart') ||
            lower.contains('symptom chart') ||
            (lower.contains('show') &&
                (lower.contains('chart') ||
                    lower.contains('trend') ||
                    lower.contains('symptom'))) ||
            ((lower.contains('pull together') ||
                    lower.contains('compile') ||
                    lower.contains('collect')) &&
                (lower.contains('lab') ||
                    lower.contains('symptom') ||
                    lower.contains('history') ||
                    lower.contains('records'))));
  }

  bool _isDailySummaryRequest(String lower) {
    final normalized = _normalizeIntentText(lower);
    final asksForSummary = normalized.contains('daily summary') ||
        normalized.contains('today summary') ||
        normalized.contains('summary for today') ||
        normalized.contains('summarize today') ||
        normalized.contains('day summary');
    final explicitlyGiExport = normalized.contains('gi summary') ||
        normalized.contains('doctor summary') ||
        normalized.contains('visit summary');
    return asksForSummary && !explicitlyGiExport;
  }

  bool _isWeeklySummaryRequest(String lower) {
    final normalized = _normalizeIntentText(lower);
    final asksForWeeklySummary = normalized.contains('weekly summary') ||
        normalized.contains('week summary') ||
        normalized.contains('this week summary') ||
        normalized.contains('summary for this week') ||
        normalized.contains('summarize this week') ||
        normalized.contains('weekly recap') ||
        normalized.contains('summary this week') ||
        normalized.contains('recap this week') ||
        normalized.contains('past 7 days') ||
        normalized.contains('last 7 days') ||
        normalized.contains('past seven days') ||
        normalized.contains('last seven days') ||
        normalized.contains('symptom summary') ||
        normalized.contains('summary of symptoms') ||
        normalized.contains('7 day summary') ||
        normalized.contains('seven day summary') ||
        normalized.contains('week of data') ||
        normalized.contains('past week');
    final explicitlyGiExport = normalized.contains('gi summary') ||
        normalized.contains('doctor summary') ||
        normalized.contains('visit summary');
    return asksForWeeklySummary && !explicitlyGiExport;
  }

  bool _isMonthlySummaryRequest(String lower) {
    final normalized = _normalizeIntentText(lower);
    final asksForMonthlySummary = normalized.contains('monthly summary') ||
        normalized.contains('month summary') ||
        normalized.contains('this month summary') ||
        normalized.contains('summary for this month') ||
        normalized.contains('summarize this month') ||
        normalized.contains('monthly recap');
    final explicitlyGiExport = normalized.contains('gi summary') ||
        normalized.contains('doctor summary') ||
        normalized.contains('visit summary');
    return asksForMonthlySummary && !explicitlyGiExport;
  }

  bool _contractSuppressesSymptomDraft(_ChatTaskContract contract) {
    return contract == _ChatTaskContract.appleWatchReview ||
        contract == _ChatTaskContract.ragRecall ||
        contract == _ChatTaskContract.ibdKnowledge ||
        contract == _ChatTaskContract.healthSummary ||
        contract == _ChatTaskContract.forecastWatchlist ||
        contract == _ChatTaskContract.memoryLedger ||
        contract == _ChatTaskContract.doctorSummary ||
        // Urgent safety and medication boundary responses must not be
        // intercepted by the symptom-draft path — the safety reply is more
        // important than creating a log review card.
        contract == _ChatTaskContract.safety ||
        // New starter prompt contracts — focused responses, no symptom drafts
        contract == _ChatTaskContract.medicationNote ||
        contract == _ChatTaskContract.foodTrigger ||
        contract == _ChatTaskContract.hrvTrend ||
        contract == _ChatTaskContract.activityPattern ||
        contract == _ChatTaskContract.prepForVisit;
  }

  /// Resolves the task contract from message text, then applies a preset
  /// override when the preset explicitly declares a contract name that maps to
  /// a known enum value.  This lets presets like "Explain my labs" (text
  /// indistinguishable from a labRecall request) route to a distinct contract
  /// such as labGemmaExplain that bypasses deterministic fast paths.
  _ChatTaskContract _resolveTaskContract({
    required String lower,
    required String intent,
    required String? presetContractName,
  }) {
    // Base resolution from message content.
    final base = _contractForMessage(lower: lower, intent: intent);
    // Preset override — only honour explicit enum-mapped values to prevent
    // arbitrary string injection from routing to wrong contracts.
    if (presetContractName != null) {
      final override = _ChatTaskContract.values
          .where((c) => c.name == presetContractName)
          .firstOrNull;
      if (override != null) return override;
    }
    return base;
  }

  _ChatTaskContract _contractForMessage({
    required String lower,
    required String intent,
  }) {
    // Clinical records and lab-like text need review gates before education;
    // pure Crohn/colitis knowledge questions still route to education.
    if (intent == 'medication_log') return _ChatTaskContract.general;
    if (_isClinicalRecordReviewInput(lower)) return _ChatTaskContract.labRecall;
    if (intent == 'lab_question' && _looksLikeLabValues(lower)) {
      return _ChatTaskContract.labRecall;
    }
    // Emotional distress with medical topic context (e.g. "anxious about
    // colonoscopy") must stay on the emotional path, not route to IBD education.
    if (!_isEmotionalDistress(lower) && !_isEmotionalVentWithSymptoms(lower)) {
      if (_isIbdKnowledgeRequest(lower)) return _ChatTaskContract.ibdKnowledge;
    }
    if (intent == 'urgent_safety') return _ChatTaskContract.safety;
    if (intent == 'wearable_data_question') {
      return _ChatTaskContract.appleWatchReview;
    }
    // Medication boundary questions belong in the safety contract so that the
    // no-med-change safety envelope is always applied.
    if (intent == 'medication_question') return _ChatTaskContract.safety;
    if (_isCheckInStartRequest(lower)) return _ChatTaskContract.startCheckIn;
    if (_isMemoryLedgerRequest(lower)) return _ChatTaskContract.memoryLedger;
    if (_isSymptomListRequest(lower)) return _ChatTaskContract.symptomList;
    if (_isAppleWatchReviewRequest(lower)) {
      return _ChatTaskContract.appleWatchReview;
    }
    if (_isRagRecallRequest(lower)) return _ChatTaskContract.ragRecall;
    // Lab-intake phrases ("log a lab result", "add a lab", "enter my labs")
    // must NOT route to labRecall — they are intake requests that need the
    // deterministic intake prompt, not the no-data recall reply.
    if (intent == 'lab_question' &&
        !_looksLikeLabValues(lower) &&
        !_looksLikePhotoAttachment(lower) &&
        !_isLabIntakePhrase(lower)) {
      return _ChatTaskContract.labRecall;
    }
    if (intent == 'forecast_watchlist') {
      return _ChatTaskContract.forecastWatchlist;
    }
    if (intent == 'risk_question' ||
        intent == 'daily_summary' ||
        intent == 'week_summary') {
      return _ChatTaskContract.healthSummary;
    }
    // followup_compare (e.g. 'yesterday what does my data say?') routes to
    // healthSummary when the core question is about health data, not labs.
    if (intent == 'followup_compare') {
      if (_isLabQuestion(lower)) return _ChatTaskContract.labRecall;
      return _ChatTaskContract.healthSummary;
    }
    // emotional_support / emotional_vent_with_symptoms do NOT override
    // explicit data-access contracts. 'I feel awful, what was my CRP?' must
    // still reach labRecall.
    if (intent == 'emotional_support' ||
        intent == 'emotional_vent_with_symptoms') {
      if (_isLabQuestion(lower)) return _ChatTaskContract.labRecall;
      if (_isAppleWatchReviewRequest(lower)) {
        return _ChatTaskContract.appleWatchReview;
      }
      if (_isSymptomListRequest(lower)) return _ChatTaskContract.symptomList;
      if (_isRiskQuestion(lower)) return _ChatTaskContract.healthSummary;
    }
    // diet_question intent does NOT override explicit data-access contracts.
    // 'Repeat request: what did my bloodwork show?' must still reach labRecall.
    if (intent == 'diet_question') {
      if (_isLabQuestion(lower)) return _ChatTaskContract.labRecall;
      if (_isAppleWatchReviewRequest(lower)) {
        return _ChatTaskContract.appleWatchReview;
      }
    }
    if (lower.contains('health summary') ||
        lower.contains('summary of my health') ||
        lower.contains('my health data') ||
        lower.contains('what does my data say') ||
        RegExp(r'what does\b.*\bmy data\b').hasMatch(lower) ||
        lower.contains('how am i doing')) {
      return _ChatTaskContract.healthSummary;
    }
    // New starter prompt contracts
    if (intent == 'medication_context') return _ChatTaskContract.medicationNote;
    if (intent == 'food_trigger_analysis') return _ChatTaskContract.foodTrigger;
    if (intent == 'hrv_trend_analysis') return _ChatTaskContract.hrvTrend;
    if (intent == 'activity_pattern_analysis') {
      return _ChatTaskContract.activityPattern;
    }
    if (intent == 'visit_preparation') return _ChatTaskContract.prepForVisit;
    if (_isDoctorSummaryRequest(lower)) return _ChatTaskContract.doctorSummary;
    // Symptom explanation — causal/explanatory questions about symptoms
    if (intent == 'symptom_explanation') {
      return _ChatTaskContract.symptomExplanation;
    }
    return _ChatTaskContract.general;
  }

  String _contractRouteName(_ChatTaskContract contract) {
    return switch (contract) {
      _ChatTaskContract.healthSummary => 'structured_health_summary',
      _ChatTaskContract.forecastWatchlist => 'forecast_watchlist',
      _ChatTaskContract.memoryLedger => 'local_memory_ledger',
      _ChatTaskContract.labRecall => 'structured_lab_recall',
      _ChatTaskContract.labGemmaExplain => 'gemma_lab_explain',
      _ChatTaskContract.symptomList => 'structured_symptom_list',
      _ChatTaskContract.startCheckIn => 'check_in_intake',
      _ChatTaskContract.appleWatchReview => 'structured_wearable_review',
      _ChatTaskContract.ragRecall => 'rag_memory_recall',
      _ChatTaskContract.doctorSummary => 'doctor_summary_export',
      _ChatTaskContract.ibdKnowledge => 'local_ibd_knowledge',
      _ChatTaskContract.safety => 'urgent_safety_boundary',
      _ChatTaskContract.general => 'general_chat',
      // New starter prompt routes
      _ChatTaskContract.medicationNote => 'medication_note_gemma',
      _ChatTaskContract.foodTrigger => 'food_trigger_gemma',
      _ChatTaskContract.hrvTrend => 'hrv_trend_gemma',
      _ChatTaskContract.activityPattern => 'activity_pattern_gemma',
      _ChatTaskContract.prepForVisit => 'prep_for_visit_gemma',
      _ChatTaskContract.symptomExplanation => 'symptom_explanation_gemma',
    };
  }

  List<String> _toolsForContract(_ChatTaskContract contract, String intent) {
    return switch (contract) {
      _ChatTaskContract.healthSummary => const [
          'get_health_summary_context',
          'get_today_risk_snapshot',
          'get_context_attribution',
          'get_recent_symptoms',
          'get_recent_labs',
          'get_recent_checkins',
          'query_memory_transactions',
          'get_sync_state',
        ],
      _ChatTaskContract.forecastWatchlist => const [
          'get_today_risk_snapshot',
          'get_context_attribution',
          'get_recent_symptoms',
          'get_recent_checkins',
          'get_early_warning_outlook',
          'query_memory_transactions',
        ],
      _ChatTaskContract.memoryLedger => const ['get_memory_ledger'],
      _ChatTaskContract.labRecall => const [
          'get_lab_recall_context',
          'get_recent_labs',
          'get_pending_lab_reviews',
        ],
      _ChatTaskContract.labGemmaExplain => const [
          'get_lab_recall_context',
          'get_recent_labs',
        ],
      _ChatTaskContract.symptomList => const ['get_symptom_list_context'],
      _ChatTaskContract.startCheckIn => const ['get_start_check_in_context'],
      _ChatTaskContract.appleWatchReview => const [
          'get_apple_watch_review_context',
          'get_wearable_metric_aggregates',
          'get_sync_state',
          'get_today_risk_snapshot',
        ],
      _ChatTaskContract.ragRecall => const [
          'get_rag_recall_context',
          'query_memory_transactions',
        ],
      _ChatTaskContract.doctorSummary => const [
          'get_doctor_summary_context',
          'get_recent_symptoms',
          'get_recent_labs',
          'get_recent_checkins',
          'get_recent_procedures',
        ],
      _ChatTaskContract.ibdKnowledge => const ['get_ibd_knowledge_context'],
      _ChatTaskContract.safety => const [],
      _ChatTaskContract.medicationNote => const [
          'get_medication_profile_context',
          'get_recent_symptoms',
          'query_memory_transactions',
        ],
      _ChatTaskContract.foodTrigger => const [
          'get_recent_symptoms',
          'get_meal_related_symptom_notes',
          'query_memory_transactions',
        ],
      _ChatTaskContract.hrvTrend => const [
          'get_wearable_metric_aggregates',
          'get_hrv_baseline_context',
          'query_memory_transactions',
        ],
      _ChatTaskContract.activityPattern => const [
          'get_wearable_metric_aggregates',
          'get_recent_symptoms',
          'get_activity_baseline_context',
          'query_memory_transactions',
        ],
      _ChatTaskContract.prepForVisit => const [
          'get_recent_symptoms',
          'get_recent_labs',
          'get_recent_checkins',
          'get_recent_procedures',
          'get_medication_profile_context',
          'query_memory_transactions',
        ],
      _ChatTaskContract.symptomExplanation => const [],
      _ChatTaskContract.general => _toolsForIntent(intent),
    };
  }

  List<String> _structuredSourcesForContract(_ChatTaskContract contract) {
    return switch (contract) {
      _ChatTaskContract.healthSummary => const [
          'flare_risk_scores',
          'daily_summaries',
          'symptoms',
          'lab_values',
          'pro2_surveys',
          'rag_memory_transactions',
        ],
      _ChatTaskContract.forecastWatchlist => const [
          'flare_risk_scores',
          'daily_summaries',
          'daily_features',
          'cosinor_features',
          'pro2_surveys',
          'symptoms',
          'rag_memory_transactions',
        ],
      _ChatTaskContract.memoryLedger => const ['rag_memory_transactions'],
      _ChatTaskContract.labRecall => const [
          'lab_values',
          'gemma_extraction_reviews',
          'rag_memory_transactions',
        ],
      _ChatTaskContract.labGemmaExplain => const [
          'lab_values',
          'gemma_extraction_reviews',
        ],
      _ChatTaskContract.symptomList => const ['symptoms'],
      _ChatTaskContract.startCheckIn => const ['pro2_surveys', 'user_profile'],
      _ChatTaskContract.appleWatchReview => const [
          'wearable_samples',
          'daily_summaries',
          'daily_features',
          'cosinor_features',
          'flare_risk_scores',
        ],
      _ChatTaskContract.ragRecall => const ['rag_memory_transactions'],
      _ChatTaskContract.doctorSummary => const [
          'flare_risk_scores',
          'symptoms',
          'lab_values',
          'pro2_surveys',
          'endoscopy_records',
          'rag_memory_transactions',
        ],
      _ChatTaskContract.ibdKnowledge => const ['crohns_info_knowledge'],
      _ChatTaskContract.medicationNote => const [
          'user_profile',
          'rag_memory_transactions',
          'symptoms',
        ],
      _ChatTaskContract.foodTrigger => const [
          'symptoms',
          'rag_memory_transactions',
        ],
      _ChatTaskContract.hrvTrend => const [
          'daily_summaries',
          'wearable_samples',
          'cosinor_features',
          'rag_memory_transactions',
        ],
      _ChatTaskContract.activityPattern => const [
          'daily_summaries',
          'wearable_samples',
          'symptoms',
          'rag_memory_transactions',
        ],
      _ChatTaskContract.prepForVisit => const [
          'symptoms',
          'lab_values',
          'pro2_surveys',
          'endoscopy_records',
          'user_profile',
          'rag_memory_transactions',
        ],
      _ChatTaskContract.symptomExplanation => const [],
      _ChatTaskContract.safety => const [],
      _ChatTaskContract.general => const [],
    };
  }

  bool _ragRequiredForContract(_ChatTaskContract contract) {
    return contract == _ChatTaskContract.ragRecall;
  }

  bool _ragWriteExpectedAfterConfirmation(_ChatTaskContract contract) {
    return contract == _ChatTaskContract.startCheckIn;
  }

  List<String> _allowedClaimsForContract(_ChatTaskContract contract) {
    return switch (contract) {
      _ChatTaskContract.healthSummary => const [
          'local health data that was read in this turn',
          'risk score if present',
          'recent symptoms, labs, check-ins, and wearable summaries if present',
        ],
      _ChatTaskContract.memoryLedger => const [
          'local RAG transaction status',
          'whether health items are saved only after confirmation',
        ],
      _ChatTaskContract.labRecall => const [
          'saved lab rows',
          'pending lab review rows',
          'lab RAG transaction status',
        ],
      _ChatTaskContract.labGemmaExplain => const [
          'saved lab rows — explain reference ranges and IBD relevance',
          'flag elevated values using grounded numbers only',
        ],
      _ChatTaskContract.appleWatchReview => const [
          'Apple Watch-derived summaries only when local rows exist',
        ],
      _ChatTaskContract.ibdKnowledge => const [
          'general Crohn, colitis, and IBD education',
        ],
      _ => const ['claims supported by provided grounding only'],
    };
  }

  List<String> _forbiddenClaimsForContract(_ChatTaskContract contract) {
    return const [
      'accessed Apple Watch data when no wearable rows were read',
      'used RAG or memory when rag_query_performed is false',
      'saved data to memory without a confirmed write transaction',
      'diagnosed a flare, stricture, fistula, cancer, obstruction, or infection',
      'recommended medication dose changes',
    ];
  }

  List<_ChatToolResult> _contractToolResults(
    _ChatTaskContract contract,
    Map<String, Object?> grounding,
  ) {
    int count(String key) => (grounding[key] as List?)?.length ?? 0;
    bool has(String key) {
      final value = grounding[key];
      if (value == null) return false;
      if (value is List) return value.isNotEmpty;
      if (value is Map) return value.isNotEmpty;
      return true;
    }

    _ChatToolResult result({
      required String name,
      required List<String> tables,
      required int rows,
      bool? used,
      String? freshness,
      String? preview,
    }) {
      return _ChatToolResult(
        toolName: name,
        status: rows > 0 || used == true ? 'ok' : 'empty',
        rowCount: rows,
        sourceTables: tables,
        usedForAnswer: used ?? rows > 0,
        dataFreshness: freshness,
        error: null,
        redactedPreview: preview,
        evidenceHash: '${name}_$rows',
      );
    }

    return switch (contract) {
      _ChatTaskContract.healthSummary => [
          result(
            name: 'get_health_summary_context',
            tables: const [
              'flare_risk_scores',
              'daily_summaries',
              'symptoms',
              'lab_values',
              'pro2_surveys',
            ],
            rows: [
              if (has('latest_score')) 1,
              count('recent_symptoms'),
              count('lab_results'),
              count('recent_pro2_surveys'),
            ].fold<int>(0, (sum, value) => sum + value),
            used: true,
          ),
        ],
      _ChatTaskContract.memoryLedger => [
          result(
            name: 'get_memory_ledger',
            tables: const ['rag_memory_transactions'],
            rows: count('rag_memory_transactions'),
            used: true,
          ),
        ],
      _ChatTaskContract.labRecall => [
          result(
            name: 'get_lab_recall_context',
            tables: const [
              'lab_values',
              'gemma_extraction_reviews',
              'rag_memory_transactions',
            ],
            rows: count('lab_results') + count('recent_lab_reviews'),
            used: true,
          ),
        ],
      _ChatTaskContract.labGemmaExplain => [
          result(
            name: 'get_lab_recall_context',
            tables: const [
              'lab_values',
              'gemma_extraction_reviews',
              'rag_memory_transactions',
            ],
            rows: count('lab_results') +
                count('recent_lab_reviews') +
                count('rag_memory_transactions'),
            used: true,
          ),
        ],
      _ChatTaskContract.symptomList => [
          result(
            name: 'get_symptom_list_context',
            tables: const ['symptoms'],
            rows: count('recent_symptoms'),
            used: true,
          ),
        ],
      _ChatTaskContract.startCheckIn => [
          result(
            name: 'get_start_check_in_context',
            tables: const ['pro2_surveys', 'user_profile'],
            rows: count('recent_pro2_surveys') + (has('user_profile') ? 1 : 0),
            used: true,
          ),
        ],
      _ChatTaskContract.appleWatchReview => [
          result(
            name: 'get_apple_watch_review_context',
            tables: const [
              'wearable_samples',
              'daily_summaries',
              'daily_features',
              'cosinor_features',
              'flare_risk_scores',
            ],
            rows: [
              if (has('latest_score')) 1,
              if (has('latest_summary')) 1,
              if (has('hrv_circadian_rhythm')) 1,
              count('wearable_metric_aggregates'),
            ].fold<int>(0, (sum, value) => sum + value),
            used: true,
          ),
        ],
      _ChatTaskContract.ragRecall => [
          result(
            name: 'get_rag_recall_context',
            tables: const ['rag_memory_transactions'],
            rows: count('rag_memory_transactions'),
            used: true,
          ),
        ],
      _ChatTaskContract.doctorSummary => [
          result(
            name: 'get_doctor_summary_context',
            tables: const [
              'flare_risk_scores',
              'symptoms',
              'lab_values',
              'pro2_surveys',
              'endoscopy_records',
            ],
            rows: count('recent_symptoms') +
                count('lab_results') +
                count('recent_pro2_surveys') +
                (has('latest_procedure') ? 1 : 0),
            used: true,
          ),
        ],
      _ChatTaskContract.forecastWatchlist => [
          result(
            name: 'get_early_warning_outlook',
            tables: const [
              'flare_risk_scores',
              'daily_summaries',
              'daily_features',
              'cosinor_features',
              'pro2_surveys',
              'symptoms',
            ],
            rows: count('early_warning_outlook') +
                (has('hrv_circadian_rhythm') ? 1 : 0) +
                count('recent_symptoms') +
                count('recent_pro2_surveys'),
            used: true,
          ),
        ],
      _ChatTaskContract.ibdKnowledge => [
          result(
            name: 'get_ibd_knowledge_context',
            tables: const ['crohns_info_knowledge'],
            rows: 1,
            used: true,
            preview: 'curated Crohn, colitis, and IBD education',
          ),
        ],
      _ChatTaskContract.medicationNote => [
          result(
            name: 'get_medication_profile_context',
            tables: const ['user_profile', 'rag_memory_transactions'],
            rows: (has('user_profile') ? 1 : 0) +
                count('rag_context_snippets') +
                count('recent_symptoms'),
            used: true,
          ),
        ],
      _ChatTaskContract.foodTrigger => [
          result(
            name: 'get_meal_related_symptom_notes',
            tables: const ['symptoms', 'rag_memory_transactions'],
            rows: count('recent_symptoms') + count('rag_context_snippets'),
            used: true,
          ),
        ],
      _ChatTaskContract.hrvTrend => [
          result(
            name: 'get_wearable_metric_aggregates',
            tables: const [
              'wearable_samples',
              'daily_summaries',
              'cosinor_features',
            ],
            rows: count('wearable_metric_aggregates') +
                (has('hrv_circadian_rhythm') ? 1 : 0),
            used: true,
          ),
        ],
      _ChatTaskContract.activityPattern => [
          result(
            name: 'get_activity_baseline_context',
            tables: const ['wearable_samples', 'daily_summaries', 'symptoms'],
            rows:
                count('wearable_metric_aggregates') + count('recent_symptoms'),
            used: true,
          ),
        ],
      _ChatTaskContract.prepForVisit => [
          result(
            name: 'get_visit_preparation_context',
            tables: const [
              'symptoms',
              'lab_values',
              'pro2_surveys',
              'endoscopy_records',
              'user_profile',
            ],
            rows: count('recent_symptoms') +
                count('lab_results') +
                count('recent_pro2_surveys') +
                (has('latest_procedure') ? 1 : 0) +
                (has('user_profile') ? 1 : 0),
            used: true,
          ),
        ],
      _ChatTaskContract.symptomExplanation => const [],
      _ChatTaskContract.safety => const [],
      _ChatTaskContract.general => const [],
    };
  }

  String? _inspectUnsupportedClaims(
    String response,
    Map<String, Object?> trace,
    Map<String, Object?> grounding,
  ) {
    final lower = response.toLowerCase();
    final contract = trace['task_contract']?.toString();
    final hasScore = grounding['latest_score'] != null;
    final hasLabs = (grounding['lab_results'] as List?)?.isNotEmpty == true ||
        (grounding['recent_lab_reviews'] as List?)?.isNotEmpty == true;
    final hasSymptoms =
        (grounding['recent_symptoms'] as List?)?.isNotEmpty == true;
    final hasWearables = grounding['latest_score'] != null ||
        grounding['latest_summary'] != null ||
        grounding['hrv_circadian_rhythm'] != null;
    final ragPerformed = trace['rag_query_performed'] == true;
    final pendingAction = trace['pending_action_type'] != null;

    if ((lower.contains('apple watch') || lower.contains('watch data')) &&
        lower.contains('review') &&
        !hasWearables) {
      return 'unsupported_apple_watch_access_claim';
    }
    if ((lower.contains('your labs show') ||
            lower.contains('your lab shows') ||
            lower.contains('your crp') ||
            lower.contains('your bloodwork')) &&
        !hasLabs) {
      return 'unsupported_lab_access_claim';
    }
    if (hasLabs &&
        (lower.contains('no lab results are saved') ||
            lower.contains('no lab results on file') ||
            lower.contains('i need lab results') ||
            lower.contains('please paste') && lower.contains('lab') ||
            lower.contains('attach a scan') && lower.contains('lab'))) {
      return 'unsupported_no_labs_prompt_when_labs_exist';
    }
    if ((lower.contains('found in memory') ||
            lower.contains('from memory') ||
            lower.contains('from rag') ||
            lower.contains('retrieved')) &&
        !ragPerformed &&
        contract != _ChatTaskContract.memoryLedger.name) {
      return 'unsupported_memory_access_claim';
    }
    if (lower.contains('your symptoms') &&
        !hasSymptoms &&
        contract != _ChatTaskContract.startCheckIn.name) {
      return 'unsupported_symptom_access_claim';
    }
    if ((lower.contains('your current score') ||
            lower.contains('your gemma_flares score') ||
            RegExp(r'\b\d{1,3}/100\b').hasMatch(lower)) &&
        !hasScore) {
      return 'unsupported_score_access_claim';
    }
    if ((lower.contains('saved to memory') ||
            lower.contains('i saved') ||
            lower.contains('saved this')) &&
        !pendingAction) {
      return 'unsupported_save_claim';
    }
    return null;
  }

  bool _isAppleWatchReviewRequest(String lower) {
    final asksReview = lower.contains('review') ||
        lower.contains('what can you see') ||
        lower.contains('what does') ||
        lower.contains('summarize') ||
        lower.contains('show');
    return (lower.contains('apple watch') ||
            lower.contains('watch data') ||
            lower.contains('healthkit') ||
            lower.contains('apple health') ||
            lower.contains('hrv') ||
            lower.contains('resting heart') ||
            lower.contains('heart rate') ||
            lower.contains('sleep') ||
            lower.contains('steps')) &&
        asksReview;
  }

  bool _isRagRecallRequest(String lower) {
    return lower.contains('access rag') ||
        lower.contains('query rag') ||
        lower.contains('use rag') ||
        lower.contains('search memory') ||
        lower.contains('what did you save') ||
        lower.contains('what is in memory') ||
        lower.contains('remember when') ||
        lower.contains('what did i tell you') ||
        lower.contains('recall my') ||
        lower.contains('use memory');
  }

  bool _isIbdKnowledgeRequest(String lower) {
    // Any question containing an IBD disease term is a knowledge request,
    // unless it explicitly asks about the user's own personal data.
    final hasIbdTerm = lower.contains('crohn') ||
        lower.contains('colitis') ||
        lower.contains('colit') ||
        lower.contains('ulcerative') ||
        lower.contains('ibd') ||
        lower.contains('inflammatory bowel') ||
        lower.contains('stricture') ||
        lower.contains('fistula') ||
        lower.contains('biologics') ||
        lower.contains('aminosalicylate') ||
        lower.contains('calprotectin') ||
        lower.contains('gastroenterologist') ||
        lower.contains('gi doctor') ||
        lower.contains('colonoscopy') ||
        lower.contains('endoscopy') ||
        // Symptom questions about IBD red flags / urgency without explicit term.
        (lower.contains('urgent care') && lower.contains('symptom')) ||
        (lower.contains('urgent care') && lower.contains('sign')) ||
        // Lab/biomarker education without personal data context.
        (lower.contains('blood tests') && lower.contains('inflammation')) ||
        (lower.contains('track inflammation')) ||
        (lower.contains('labs matter') && !lower.contains('my labs')) ||
        // Appointment prep without personal data context.
        (lower.contains('prepare') &&
            lower.contains('appointment') &&
            !lower.contains('my appointment'));
    // Symptom explanation questions ("what's causing my X", "why do I get X")
    // are knowledge requests even without an explicit IBD disease term.
    final isSymptomExplanation = (lower.contains("what's causing") ||
            lower.contains('what is causing') ||
            lower.contains('why do i') ||
            lower.contains('why am i') ||
            lower.contains('why does') ||
            lower.contains('what causes') ||
            lower.contains('how come') ||
            lower.contains('is it the disease') ||
            lower.contains('is it my medication') ||
            lower.contains('explain why') ||
            lower.contains('can you explain why') ||
            lower.contains('why worse') ||
            lower.contains('why better') ||
            lower.contains('why fatigue') ||
            lower.contains('why urgency') ||
            lower.contains('why nauseous') ||
            lower.contains('why pain') ||
            lower.contains('why stress') ||
            lower.contains('what happens when') ||
            lower.contains('what questions') && lower.contains('ask') ||
            lower.contains('how many bad days') ||
            lower.contains('how bad') && lower.contains('before') ||
            lower.contains('night sweats') ||
            lower.contains('hair thinning') ||
            lower.contains('mouth sores') ||
            lower.contains('not absorbing') ||
            lower.contains('switching biologic') ||
            lower.contains('switch biologic') ||
            lower.contains('switching to') && lower.contains('biologic')) &&
        !lower.contains(' right now') &&
        !lower.contains(' today') &&
        !lower.contains(' this morning') &&
        !_isExplicitSymptomLogRequest(lower);
    if (isSymptomExplanation) return true;
    if (!hasIbdTerm) return false;
    // Disease-diagnosis questions like "based on my symptoms do I have crohn?"
    // are knowledge requests even when they contain 'my symptoms' — the user
    // is asking about the disease, not requesting their logged symptom list.
    final isDiseaseQuestion = lower.contains('do i have') ||
        lower.contains('is this crohn') ||
        lower.contains('is this ibd') ||
        lower.contains('is this colitis') ||
        lower.contains('have crohn') ||
        lower.contains('have ibd') ||
        lower.contains('have colitis');
    // Action / check-in commands that mention "IBD" in the label (e.g.
    // "start daily IBD check", "Voice: start daily ibd check") must not be
    // routed to the knowledge path.  We use a regex so that "start ... check"
    // only exempts the check-in action, not "start checking my colonoscopy".
    final isCheckInCommand = RegExp(
          r'\b(start|begin)\b.{0,40}\b(check-in|check in|daily check|ibd check)\b',
        ).hasMatch(lower) ||
        ((lower.contains('start') || lower.contains('begin')) &&
            RegExp(r'\bibd check\b').hasMatch(lower));
    if (isCheckInCommand) return false;

    final isDefinitionQuestion = lower.contains('what is') ||
        lower.contains('what does') ||
        lower.contains('difference between') ||
        lower.contains('why') ||
        lower.contains('how') ||
        lower.contains('explain');
    final looksLikeCurrentSymptomReport = (lower.startsWith('i ') ||
            lower.startsWith("i'm") ||
            lower.startsWith('im ') ||
            lower.contains(' right now') ||
            lower.contains(' today') ||
            lower.contains(' this morning')) &&
        (_looksLikeSymptomNarrative(lower) ||
            lower.contains('flare') ||
            lower.contains('drainage') ||
            lower.contains('bleeding') ||
            lower.contains('pain'));
    if (looksLikeCurrentSymptomReport && !isDefinitionQuestion) {
      return false;
    }

    // Personal-data queries are handled by other contracts; don't hijack them.
    // Note: 'my symptoms' counts as personal data only when NOT framing a disease
    // question (e.g. 'based on my symptoms do I have crohn?' IS knowledge).
    final isPersonalDataQuery = lower.contains('my score') ||
        lower.contains('my crp') ||
        lower.contains('my results') ||
        lower.contains('my labs') ||
        (lower.contains('my symptoms') && !isDiseaseQuestion) ||
        lower.contains('my data') ||
        lower.contains('my watch') ||
        lower.contains('my risk');
    return !isPersonalDataQuery;
  }

  String _appleWatchReviewReply({
    required FlareRiskScoreRecord? latestScore,
    required DailySummaryRecord? latestSummary,
    required DailyFeatureRecord? todayFeatures,
    required Map<String, Object?>? heartRhythmContext,
    List<Map<String, Object?>> earlyWarningOutlook = const [],
  }) {
    if (latestSummary == null && todayFeatures == null && latestScore == null) {
      return 'I do not have local Apple Watch or Apple Health rows to review yet. Once Health data syncs, I can review sleep, activity, resting heart rate, HRV patterns, and how they relate to your flare risk.';
    }
    final parts = <String>[];
    if (latestScore != null) {
      final ready7d = _readyUserFacingRiskPoint(
        latestScore: latestScore,
        outlook: earlyWarningOutlook,
        horizonDays: 7,
      );
      final riskDisplay = _flareRiskDisplay(ready7d);
      parts.add(
        'Local flare risk: $riskDisplay (${latestScore.riskBand}), confidence ${latestScore.confidenceScore.round()}/100.',
      );
    }
    final summary = latestSummary?.summaryJson ?? const <String, Object?>{};
    final sleep = summary['sleep_total_minutes'];
    final steps = summary['step_count_total'];
    final restingHr = summary['resting_hr_mean'];
    final hrv = summary['hrv_sdnn_mean'];
    final wearableBits = <String>[
      if (sleep is num) 'sleep ${_formatLabNumber(sleep / 60)} hours',
      if (steps is num) '${steps.round()} steps',
      if (restingHr is num) 'resting heart rate ${restingHr.round()} bpm',
      if (hrv is num) 'HRV ${_formatLabNumber(hrv.toDouble())} ms',
    ];
    if (wearableBits.isNotEmpty) {
      parts.add(
        'Apple Watch-derived summaries I can see: ${wearableBits.join(', ')}.',
      );
    }
    if (heartRhythmContext?.isNotEmpty == true) {
      parts.add(
        'I also checked local heart-rhythm context for circadian HRV interpretation.',
      );
    }
    parts.add(
      'This is pattern review, not a diagnosis. If symptoms are worsening or you have red flags like heavy bleeding, fever, severe pain, fainting, or dehydration, contact urgent care or your GI team.',
    );
    return parts.join(' ');
  }

  /// Deterministic wearable reply using [WearableAggregationService].
  /// Tries to resolve a specific metric+window from [userMessage]. If
  /// resolved, executes the DB query and renders the answer without Gemma.
  /// Falls back to [_timeSpecificWearableReply] (steps-only legacy) or
  /// [_appleWatchReviewReply] (general summary) when no plan resolves.
  Future<String> _resolvedWearableReply({
    required String userMessage,
    required String lower,
    required String todayDate,
    required List<DailySummaryRecord> recentSummaries,
    required FlareRiskScoreRecord? latestScore,
    required DailySummaryRecord? latestSummary,
    required DailyFeatureRecord? todayFeatures,
    required Map<String, Object?>? heartRhythmContext,
    List<Map<String, Object?>> earlyWarningOutlook = const [],
  }) async {
    // Future-window explicit refusal
    if (lower.contains('tomorrow') ||
        (lower.contains('next week') && !lower.contains('last')) ||
        (lower.contains('next month') && !lower.contains('last'))) {
      return "I can only look at data we've already recorded — I can't show future metrics.";
    }

    final now = _nowProvider();
    final plan = _wearableAgg.resolve(userMessage, now: now);
    if (plan != null) {
      final result = await _wearableAgg.execute(plan);
      if (result.value == null && plan.metric.dbName == 'steps') {
        final fallback = _timeSpecificWearableReply(
          userMessage: userMessage,
          todayDate: todayDate,
          recentSummaries: recentSummaries,
        );
        if (!_isWearableNoDataReply(fallback)) {
          return fallback;
        }
      }
      return _wearableAgg.render(result);
    }

    // Legacy steps-only path for phrasing like "how many steps did I take"
    // without an explicit window that the new resolver handles.
    if (_isTimeSpecificWearableQuestion(lower)) {
      return _timeSpecificWearableReply(
        userMessage: userMessage,
        todayDate: todayDate,
        recentSummaries: recentSummaries,
      );
    }

    return _appleWatchReviewReply(
      latestScore: latestScore,
      latestSummary: latestSummary,
      todayFeatures: todayFeatures,
      heartRhythmContext: heartRhythmContext,
      earlyWarningOutlook: earlyWarningOutlook,
    );
  }

  bool _isTimeSpecificWearableQuestion(String lower) {
    final asksMetric = lower.contains('steps') ||
        lower.contains('step count') ||
        lower.contains('heart rate') ||
        lower.contains('hrv') ||
        lower.contains('sleep');
    final asksWindow = lower.contains('today') ||
        lower.contains('yesterday') ||
        lower.contains('this week') ||
        lower.contains('last week') ||
        lower.contains('this month') ||
        lower.contains('month') ||
        lower.contains('how many') ||
        lower.contains('how much');
    return asksMetric && asksWindow;
  }

  bool _isWearableNoDataReply(String reply) {
    final normalized = reply.trim().toLowerCase();
    return normalized.startsWith('i do not have') ||
        normalized.startsWith("i don't have") ||
        normalized.startsWith('i dont have');
  }

  String _timeSpecificWearableReply({
    required String userMessage,
    required String todayDate,
    required List<DailySummaryRecord> recentSummaries,
  }) {
    final lower = userMessage.toLowerCase();
    if (!lower.contains('steps') && !lower.contains('step count')) {
      return 'I can answer time-specific wearable questions from local daily summaries. Ask for steps, sleep, resting heart rate, or HRV for today, yesterday, or this week.';
    }
    if (recentSummaries.isEmpty) {
      return 'I do not have local step summaries for that time window yet. Sync Apple Health and open Gemma Flares again, then I can answer steps by day or recent week.';
    }

    final byDate = {
      for (final summary in recentSummaries) summary.dateLocal: summary,
    };
    num? stepsFor(String date) =>
        byDate[date]?.summaryJson['step_count_total'] as num?;

    if (lower.contains('yesterday')) {
      final date = _offsetDate(todayDate, -1);
      final steps = stepsFor(date);
      if (steps == null) {
        return 'I do not have a local step total for yesterday ($date). I can only answer from days that have synced Apple Health summaries.';
      }
      return 'Yesterday ($date), your local step total was ${steps.round()} steps.';
    }

    if (lower.contains('today')) {
      final steps = stepsFor(todayDate);
      if (steps == null) {
        return 'I do not have a local step total for today yet. If Apple Health has updated, reopen Gemma Flares to refresh the daily summary.';
      }
      return 'Today ($todayDate), your local step total is ${steps.round()} steps so far.';
    }

    if (lower.contains('month')) {
      final totals = recentSummaries
          .map((summary) => summary.summaryJson['step_count_total'])
          .whereType<num>()
          .toList(growable: false);
      if (totals.isEmpty) {
        return 'I do not have local step totals for this month yet.';
      }
      final total = totals.fold<num>(0, (sum, value) => sum + value).round();
      return 'I can see $total steps across the ${totals.length} synced daily summaries available locally. I do not have a complete month total unless every day in the month has synced.';
    }

    final totals = recentSummaries
        .take(7)
        .map((summary) => summary.summaryJson['step_count_total'])
        .whereType<num>()
        .toList(growable: false);
    if (totals.isEmpty) {
      return 'I do not have local step totals for this week yet.';
    }
    final total = totals.fold<num>(0, (sum, value) => sum + value).round();
    return 'Across the latest ${totals.length} synced day${totals.length == 1 ? '' : 's'}, I can see $total steps locally.';
  }

  String _ibdKnowledgeReply(String lower) {
    // Red flags / urgent safety — must be first priority in knowledge routing.
    if (RegExp(r'\ber\b').hasMatch(lower) ||
        lower.contains('emergency') ||
        lower.contains('urgent care') ||
        lower.contains('dangerous') ||
        lower.contains('life-threatening') ||
        lower.contains('go to the') ||
        lower.contains('when should i')) {
      return 'Seek urgent or emergency care for any of these IBD warning signs: '
          'heavy rectal bleeding or black tarry stool, severe belly pain or rigid abdomen, '
          'fever above 101\u00b0F with belly pain, signs of dehydration such as dizziness or rapid heart rate, '
          'persistent vomiting, or pain near the anus with swelling or drainage. '
          'These may indicate a flare complication, abscess, obstruction, or perforation. '
          'Contact your GI team or go to the ER rather than waiting. '
          'This is general IBD education, not a diagnosis.';
    }
    // Complications: fistulas, strictures, abscesses, cancer risk.
    if (lower.contains('fistula') ||
        lower.contains('abscess') ||
        lower.contains('stricture') ||
        lower.contains('obstruction') ||
        lower.contains('narrowing') ||
        lower.contains('complication') ||
        lower.contains('cancer risk') ||
        lower.contains('cancer')) {
      return 'Crohn\'s disease can lead to complications including: '
          'fistulas (abnormal tunnels from the bowel to skin or other organs), '
          'abscesses (pockets of infection near the bowel or anus), '
          'strictures (scarred narrowings that can cause blockages), '
          'malnutrition from poor absorption, and a slightly elevated long-term risk of colorectal cancer with chronic inflammation. '
          'Perianal disease, meaning pain, drainage, or skin tags near the anus, is also common. '
          'Complications are why regular follow-up with your GI team matters even during remission. '
          'This is general IBD education, not personal medical advice.';
    }
    // Labs and biomarkers: CRP, ESR, fecal calprotectin, albumin, ferritin.
    if (lower.contains('crp') ||
        lower.contains('esr') ||
        lower.contains('calprotectin') ||
        lower.contains('ferritin') ||
        lower.contains('albumin') ||
        lower.contains('blood test') ||
        lower.contains('stool test') ||
        lower.contains('biomarker') ||
        lower.contains('lab marker') ||
        lower.contains('inflammation marker')) {
      return 'Key labs used to monitor IBD activity include:\n'
          '\u2022 CRP (C-reactive protein): blood marker of acute inflammation; elevated means active disease or infection.\n'
          '\u2022 ESR (erythrocyte sedimentation rate): another inflammation marker, slower to change than CRP.\n'
          '\u2022 Fecal calprotectin: stool test that reflects gut-wall inflammation specifically; very useful to track IBD activity without a scope.\n'
          '\u2022 Albumin and ferritin: low albumin suggests malnutrition or protein loss; low ferritin indicates iron deficiency, common in IBD.\n'
          '\u2022 CBC (complete blood count): checks for anemia and white cell changes.\n'
          'Normal lab values do not always mean remission; your GI team interprets results in context. '
          'This is general IBD education.';
    }
    // Diagnosis and testing procedures.
    if (lower.contains('diagnos') ||
        lower.contains('colonoscopy') ||
        lower.contains('endoscopy') ||
        lower.contains('biopsy') ||
        lower.contains('imaging') ||
        lower.contains('mri') ||
        lower.contains('ct scan') ||
        lower.contains('capsule') ||
        lower.contains('test for') ||
        lower.contains('how is it diagnosed')) {
      return 'Crohn\'s disease is diagnosed by combining history, labs, stool tests, imaging, and endoscopy:\n'
          '\u2022 Blood labs: CRP, ESR, CBC, albumin, liver enzymes.\n'
          '\u2022 Stool tests: fecal calprotectin and stool cultures to rule out infection.\n'
          '\u2022 Colonoscopy with biopsy: the most definitive test; sees the bowel lining and takes tissue samples.\n'
          '\u2022 Upper endoscopy or capsule endoscopy: for small bowel involvement.\n'
          '\u2022 MRI or CT enterography: imaging of the small bowel, looking for strictures, fistulas, abscesses, or deep wall thickening.\n'
          'A diagnosis usually requires finding a consistent pattern across multiple tests. '
          'This is general IBD education, not a diagnosis for you.';
    }
    // Treatment classes: biologics, immunosuppressants, steroids, surgery.
    if (lower.contains('biologic') ||
        lower.contains('immunosuppres') ||
        lower.contains('steroid') ||
        lower.contains('prednisone') ||
        lower.contains('vedolizumab') ||
        lower.contains('adalimumab') ||
        lower.contains('infliximab') ||
        lower.contains('ustekinumab') ||
        lower.contains('aminosalicylate') ||
        lower.contains('mesalamine') ||
        lower.contains('azathioprine') ||
        lower.contains('methotrexate') ||
        lower.contains('surgery') ||
        lower.contains('resection') ||
        lower.contains('treatment') ||
        lower.contains('medication') ||
        lower.contains('medicine') ||
        lower.contains('remission')) {
      return 'Crohn\'s treatment is matched to disease severity and location. Main classes:\n'
          '\u2022 Aminosalicylates (e.g., mesalamine): mild anti-inflammatory.\n'
          '\u2022 Corticosteroids (e.g., prednisone): short-term flare control only.\n'
          '\u2022 Immunomodulators (e.g., azathioprine, methotrexate): reduce immune overactivity.\n'
          '\u2022 Biologics (e.g., adalimumab, infliximab): targeted therapy for moderate-to-severe disease.\n'
          '\u2022 JAK inhibitors (e.g., upadacitinib): newer oral agents.\n'
          '\u2022 Surgery: reserved for when medications fail.\n'
          'Never stop or change medications without your prescriber. General IBD education only.';
    }
    // Lifestyle: diet, stress, exercise, nutrition.
    if (lower.contains('diet') ||
        lower.contains('food') ||
        lower.contains('eating') ||
        lower.contains('nutrition') ||
        lower.contains('trigger') ||
        lower.contains('stress') ||
        lower.contains('exercise') ||
        lower.contains('lifestyle') ||
        lower.contains('smoking') ||
        lower.contains('alcohol')) {
      return 'Lifestyle factors in Crohn\'s disease:\n'
          '\u2022 Diet: no single diet fits all \u2014 low-fiber foods may ease flares; a dietitian can help.\n'
          '\u2022 Nutrition: iron, B12, vitamin D, and folate are frequently low.\n'
          '\u2022 Stress: does not cause Crohn\'s but can worsen symptoms.\n'
          '\u2022 Exercise: generally beneficial; adjust intensity to current activity level.\n'
          '\u2022 Smoking: strongly linked to worse outcomes and higher surgery rates.\n'
          '\u2022 Alcohol: can irritate the gut and interact with IBD medications.\n'
          'General IBD education only.';
    }
    // Appointment preparation.
    if (lower.contains('doctor') ||
        lower.contains('appointment') ||
        lower.contains('gi visit') ||
        lower.contains('what to tell') ||
        lower.contains('what to bring') ||
        lower.contains('questions to ask') ||
        lower.contains('prepare') ||
        lower.contains('gastroenterologist')) {
      return 'Before a GI or IBD appointment, it helps to track:\n'
          '\u2022 Symptom log: stool frequency, consistency, bleeding, belly pain scale, fatigue.\n'
          '\u2022 Recent lab results and dates if you have them.\n'
          '\u2022 Current medications, doses, and how long you have been on each.\n'
          '\u2022 Any recent hospitalizations, scope reports, or imaging.\n'
          '\u2022 Questions about your disease course, medication options, upcoming scopes, or remission targets.\n'
          'Gemma Flares\'s symptom logs and check-in history are designed to help you give your care team a clear picture. '
          'This is general guidance, not medical advice.';
    }
    // Colitis / UC vs Crohn differences.
    if (lower.contains('colitis') ||
        lower.contains('colit') ||
        lower.contains('ulcerative') ||
        lower.contains('difference') ||
        lower.contains('vs uc') ||
        lower.contains('vs crohn') ||
        lower.contains('what type')) {
      return 'Crohn\'s disease and ulcerative colitis are both types of inflammatory bowel disease (IBD), '
          'but they differ in important ways:\n'
          '\u2022 Location: Crohn\'s can affect any part of the digestive tract from mouth to anus; UC affects only the colon and rectum.\n'
          '\u2022 Pattern: Crohn\'s often causes patchy, skip-lesion inflammation through the full bowel wall; UC causes continuous inflammation limited to the inner lining.\n'
          '\u2022 Complications: Crohn\'s is more prone to fistulas, strictures, and small bowel involvement; UC has a higher colitis-associated cancer risk with long duration.\n'
          '\u2022 Treatment: many medications overlap, but some therapies target one type more than the other; surgery can cure UC but not Crohn\'s.\n'
          'Only a clinician with a full workup can determine which type of IBD is present. '
          'This is general IBD education.';
    }
    // Genetics and cause — "why do I have Crohn's", "is it genetic", "hereditary".
    if (lower.contains('genetic') ||
        lower.contains('hereditary') ||
        lower.contains('inherit') ||
        lower.contains('family') ||
        lower.contains('why do i have') ||
        lower.contains('why did i get') ||
        lower.contains('how did i get') ||
        lower.contains('what causes') ||
        lower.contains('cause of') ||
        lower.contains('root cause') ||
        lower.contains('why me')) {
      return 'Crohn\'s disease has no single cause — it results from a combination of:\n'
          '• Genetics: 240+ gene variants linked to IBD risk; first-degree relatives have 5–10× higher risk.\n'
          '• Immune system: abnormal gut immune response causes chronic inflammation without infection.\n'
          '• Microbiome: gut bacterial imbalance (dysbiosis) is consistently seen in Crohn\'s.\n'
          '• Environment: smoking, antibiotic use, and highly processed diets are associated with higher risk.\n'
          'Crohn\'s is not caused by anything you did wrong. General IBD education only.';
    }
    // Symptom descriptions.
    if (lower.contains('symptom') ||
        lower.contains('flare') ||
        lower.contains('what does it feel') ||
        lower.contains('feel like')) {
      return 'Common symptoms of Crohn\'s disease include: '
          'diarrhea (sometimes with blood or mucus), belly pain and cramping especially before bowel movements, '
          'fatigue, weight loss, reduced appetite, mouth sores, and pain or drainage near the anus from fistulas. '
          'People with severe disease may also have joint pain, skin rashes, eye inflammation, or liver involvement. '
          'Symptoms can vary widely. Some people have periods of remission with no symptoms, while others have persistent daily symptoms. '
          'Seek urgent care for severe pain, heavy bleeding, high fever, or signs of dehydration. '
          'This is general IBD education, not a diagnosis.';
    }
    // Default: overview.
    return 'Crohn\'s disease is a type of inflammatory bowel disease (IBD) that causes inflammation '
        'in the digestive tract. It most commonly affects the end of the small intestine and beginning of the colon, '
        'but it can affect any part of the GI tract from mouth to anus. '
        'Inflammation often spreads into the deeper layers of the bowel, causing belly pain, severe diarrhea, fatigue, '
        'weight loss, and malnutrition. '
        'Crohn\'s can be both painful and debilitating, and sometimes leads to serious complications. '
        'There is no known cure, but treatments can reduce inflammation, relieve symptoms, and help people reach remission. '
        'With proper treatment, many people with Crohn\'s disease function well. '
        'This is general IBD education, not a diagnosis.';
  }

  String _classifyIntent(String lower) {
    final normalizedLower = _normalizeIntentText(lower);
    final session = _sessionState;

    // BUG-081: Preset commands are an explicit navigation contract and must
    // always win over pending session state (e.g. awaitingSymptomIntake). The
    // canonical preset registry in prompt_templates.dart is the single source
    // of truth; consulting it here closes a latent gap where a stale
    // _shouldStayInSymptomIntake allow-list could trap presets like
    // "Show my lab results" or "Scan a lab photo" into symptom_log_followup.
    final earlyPreset = prompts.presetForUserText(lower);
    if (earlyPreset != null) {
      // Preset matching is intentionally fuzzy so typed chip shortcuts work,
      // but explicit time-window summaries are more specific than a generic
      // "summary" preset.
      if (_isMonthlySummaryRequest(normalizedLower)) return 'week_summary';
      if (_isDailySummaryRequest(normalizedLower) ||
          _isWeeklySummaryRequest(normalizedLower)) {
        return _resolveSummaryIntent(normalizedLower);
      }
      return earlyPreset.intent;
    }

    if (session?.awaitingSymptomIntake == true &&
        _shouldStayInSymptomIntake(lower)) {
      return 'symptom_log_followup';
    }

    // Priority 0: Session-aware continuations — only when a prior turn exists
    final sessionTurns = session?.turns ?? [];
    if (sessionTurns.isNotEmpty) {
      final normalized = normalizedLower;
      const continuations = {
        'ok',
        'ok go',
        'go',
        'go ahead',
        'continue',
        'ok continue',
        'and',
        'yeah',
        'yes',
        'yep',
        'sure',
        'sounds good',
        'ok cool',
        'got it',
        'i see',
        'ok and',
        'what else',
        'what does that mean',
        'what now',
        'next',
        // Bug-A: casual continuations that were routing to general_health_question
        'okay',
        'ok okay',
        'alright',
        'alright then',
        'fine',
        'noted',
        'makes sense',
        'that makes sense',
        'interesting',
        'oh',
        'oh ok',
        'oh okay',
        'ah',
        'ah ok',
        'ah okay',
        'ah i see',
        'i see ok',
        'i see okay',
        // Bug-B: standalone "why"/"how" in session context — treat as continuation
        // rather than routing to followup_expand which causes Gemma to produce
        // a clinical analysis with no clear referent
        'why',
        'why?',
        'how',
        'how?',
        // Bug-C: single ambiguous words with prior session context
        'what',
        'what?',
        'who',
        'who?',
      };
      if (continuations.contains(normalized)) return 'continuation';
    }

    // Priority 1: Urgent safety — always check first
    if (_isUrgentSymptom(normalizedLower)) {
      return 'urgent_safety';
    }

    // Appointment prep — check BEFORE summary routing so "weekly review before
    // my appointment" does not collapse to week_summary. These asks belong to
    // the visit-preparation starter contract, not doctor-summary export.
    if (_isAppointmentPrepRequest(normalizedLower)) {
      return 'visit_preparation';
    }

    // Route explicit day/week/month summary asks before preset lookup so
    // generic summary presets cannot hijack these data-window requests.
    if (_isMonthlySummaryRequest(normalizedLower)) {
      return 'week_summary';
    }
    if (_isDailySummaryRequest(normalizedLower) ||
        _isWeeklySummaryRequest(normalizedLower)) {
      return _resolveSummaryIntent(normalizedLower);
    }

    // Medication/vitamin logging must win before preset/lab/IBD education
    // routing. Otherwise phrases like "I took my vitamins today" look like labs
    // because "vitamin D" is also a lab analyte, and "I took my biologics"
    // looks like treatment education.
    if (_isMedicationLogRequest(normalizedLower)) {
      return 'medication_log';
    }

    final preset = prompts.presetForUserText(normalizedLower);
    if (preset != null) return preset.intent;

    // Priority 2: Lab value submissions — before explicit symptom log so
    // "ESR came back at 42 — log that" routes to lab_question not symptom_log.
    if ((_isClinicalRecordReviewInput(normalizedLower) ||
            _looksLikeLabValues(normalizedLower)) &&
        (_isExplicitSymptomLogRequest(normalizedLower) ||
            normalizedLower.contains('note that') ||
            normalizedLower.contains('log that'))) {
      return 'lab_question';
    }

    // Priority 2b: Explicit actions
    if (_isExplicitSymptomLogRequest(normalizedLower)) {
      return 'symptom_log_followup';
    }
    // Priority 2b: Check-in narrative (scale values + pain/urgency keywords)
    if (_isCheckInNarrative(normalizedLower)) {
      return 'check_in_log';
    }
    // Priority 2b.5: Comparison / trend questions must NOT fall into multi-symptom
    // log even when symptom words appear (e.g. "no urgency in 4 days, is that good?").
    if (normalizedLower.contains('is that good') ||
        normalizedLower.contains('is that normal') ||
        normalizedLower.contains('is that better') ||
        normalizedLower.contains('unusual vs') ||
        normalizedLower.contains('vs my baseline') ||
        normalizedLower.contains('vs baseline') ||
        normalizedLower.contains('compared to baseline') ||
        (normalizedLower.contains('unusual') &&
            normalizedLower.contains('baseline'))) {
      return 'followup_compare';
    }
    // Priority 2c: Multiple symptoms in one message — but emotional distress with
    // symptom words (e.g. "cried today, tired of being sick") must stay on the
    // emotional path, not collapse to symptom logging.
    if (_isMultiSymptomNarrative(normalizedLower) &&
        !_isEmotionalDistress(normalizedLower)) {
      return 'multi_symptom_log';
    }
    if (_looksLikePhotoAttachment(normalizedLower)) {
      return 'lab_question';
    }
    if (_isDailySummaryRequest(normalizedLower)) {
      return 'daily_summary';
    }
    if (_isWeeklySummaryRequest(normalizedLower)) {
      return 'week_summary';
    }
    if (_isDoctorSummaryRequest(normalizedLower)) {
      return 'doctor_summary';
    }
    if (_isCheckInStartRequest(normalizedLower)) {
      return 'symptom_question';
    }
    if (_isMemoryLedgerRequest(normalizedLower)) {
      return 'data_gap_question';
    }
    // Medication questions that contain 'symptom' or 'what' must be checked
    // before _isSymptomListRequest, which also matches on those tokens.
    if (_isMedicationQuestion(normalizedLower)) {
      return 'medication_question';
    }
    if (_isSymptomListRequest(normalizedLower)) {
      return 'symptom_question';
    }
    if (_isRagRecallRequest(normalizedLower)) {
      return 'data_gap_question';
    }
    if (_isClinicalRecordReviewInput(normalizedLower) ||
        _looksLikeLabValues(normalizedLower)) {
      return 'lab_question';
    }

    // Priority 3: Correction / conversation repair
    if (normalizedLower.contains("that's not right") ||
        normalizedLower.contains('that is not right') ||
        normalizedLower.contains('that is wrong') ||
        normalizedLower.contains("that's wrong") ||
        normalizedLower.contains('incorrect') ||
        normalizedLower.contains('you got that wrong') ||
        normalizedLower.contains('no that') ||
        normalizedLower.contains('actually it')) {
      return 'followup_correction';
    }

    // Priority 4: Emotional distress (before data questions)
    if (_isEmotionalVentWithSymptoms(normalizedLower)) {
      return 'emotional_vent_with_symptoms';
    }
    if (_isEmotionalDistress(normalizedLower)) {
      return 'emotional_support';
    }

    // Food/lifestyle trigger updates should stay on symptom paths, even when
    // diet keywords are present.
    if (_isFoodLifestyleUpdate(normalizedLower)) {
      if (_isExplicitSymptomLogRequest(normalizedLower) ||
          normalizedLower.contains('logging') ||
          normalizedLower.contains('track')) {
        return 'symptom_log_followup';
      }
      return 'symptom_question';
    }

    if (_isIbdKnowledgeRequest(normalizedLower)) {
      return 'general_health_question';
    }

    // Priority 5: Out of scope
    if (_isOutOfScope(normalizedLower)) {
      return 'out_of_scope';
    }

    // Priority 6: Medication and diet (redirect intents)
    if (_isMedicationQuestion(normalizedLower)) {
      return 'medication_question';
    }
    if (_isDietQuestion(normalizedLower)) {
      return 'diet_question';
    }

    // Priority 6.5: App meta-questions — how/why the app behaves
    if (_isAppMetaQuestion(normalizedLower)) {
      return 'app_meta_question';
    }

    final appFeatureReply = _appFeatureReply(normalizedLower);
    if (appFeatureReply != null) {
      if (normalizedLower.contains('apple health') ||
          normalizedLower.contains('health access')) {
        return 'data_gap_question';
      }
      return 'app_meta_question';
    }

    // Priority 6.8: Symptom explanation questions (why/how/what/when + symptom)
    // Must precede generic symptom_question to provide causal explanations
    // grounded on recent symptom logs + RAG knowledge instead of symptom logging
    if (_isSymptomExplanationQuestion(normalizedLower)) {
      return 'symptom_explanation';
    }

    // Priority 7: Data gap questions
    if (_isDataGapQuestion(normalizedLower)) {
      return 'data_gap_question';
    }
    if (_isThanks(normalizedLower)) {
      return 'smalltalk';
    }
    if (_isClinicalRecordQuestion(normalizedLower)) {
      return 'lab_question';
    }

    if (_isConfidenceQuestion(normalizedLower)) {
      return 'confidence_question';
    }
    if (_isCheckInScoreQuestion(normalizedLower)) {
      return 'week_summary';
    }
    if (_isLabQuestion(normalizedLower)) {
      return 'lab_question';
    }
    if (_isSymptomQuestion(normalizedLower)) {
      // Guard: messages directed at Gemma ("you have symptoms", "you said I had...") are
      // NOT self-reports. Route to general_health_question so Gemma asks a clarifying
      // question rather than confabulating symptom names from training distribution.
      final isAddressedToGemma = normalizedLower.startsWith('you ') ||
          normalizedLower.startsWith('you\'ve ') ||
          normalizedLower.startsWith('you said') ||
          normalizedLower.startsWith('you told') ||
          normalizedLower.startsWith('you mentioned');
      if (isAddressedToGemma) return 'general_health_question';
      return 'symptom_question';
    }
    // forecast_watchlist: forward-looking watchpoints and early warning signals.
    // Must precede risk_question — "what should I watch" is NOT a risk snapshot.
    if (_isForecastWatchlistRequest(normalizedLower)) {
      return 'forecast_watchlist';
    }
    if (_isRiskQuestion(normalizedLower)) {
      return 'risk_question';
    }

    // Priority 8: Wearable data questions — must precede followup_compare
    // because queries like "how many steps did I take yesterday" contain
    // 'yesterday' and would otherwise be misclassified as followup_compare.
    if (_isWearableDataQuestion(normalizedLower)) {
      return 'wearable_data_question';
    }

    // Priority 8b: Follow-up intents (compare / expand)
    if (normalizedLower.contains('what changed') ||
        normalizedLower.contains('compared with') ||
        normalizedLower.contains('compare') ||
        normalizedLower.contains('vs ') ||
        normalizedLower.contains('versus') ||
        normalizedLower.contains('different from') ||
        normalizedLower.contains('yesterday') ||
        normalizedLower.contains('last week') ||
        normalizedLower.contains('last month') ||
        normalizedLower.contains('before and after') ||
        normalizedLower.contains('vs baseline') ||
        normalizedLower.contains('vs my baseline') ||
        normalizedLower.contains('vs normal') ||
        normalizedLower.contains('unusual vs') ||
        normalizedLower.contains('unusual for me') ||
        normalizedLower.contains('compared to baseline') ||
        normalizedLower.contains('compared to normal') ||
        normalizedLower.contains('is that good') ||
        normalizedLower.contains('is that normal') ||
        normalizedLower.contains('is that better') ||
        (normalizedLower.contains('days since') &&
            (normalizedLower.contains('flare') ||
                normalizedLower.contains('symptom'))) ||
        (normalizedLower.contains('no ') &&
            (normalizedLower.contains('in 4 days') ||
                normalizedLower.contains('in 5 days') ||
                normalizedLower.contains('in 3 days') ||
                normalizedLower.contains('in a week')))) {
      return 'followup_compare';
    }
    if (normalizedLower.contains('explain more') ||
        normalizedLower.contains('say more') ||
        normalizedLower.contains('more detail') ||
        normalizedLower.contains('more detailed') ||
        normalizedLower.contains('more info') ||
        normalizedLower.contains('more information') ||
        normalizedLower.contains('elaborate') ||
        normalizedLower.contains('go deeper') ||
        normalizedLower.contains('tell me more') ||
        normalizedLower.contains('be more specific') ||
        normalizedLower.contains('expand on') ||
        normalizedLower == 'more') {
      return 'followup_expand';
    }

    // Priority 9: Specific data intents
    if (_isClinicalRecordQuestion(normalizedLower)) {
      return 'lab_question';
    }
    if (_isWearableDataQuestion(normalizedLower)) {
      return 'wearable_data_question';
    }
    if (normalizedLower.contains('week') ||
        normalizedLower.contains('recent') ||
        normalizedLower.contains('trend') ||
        normalizedLower.contains('summarize') ||
        normalizedLower.contains('summary') ||
        normalizedLower.contains('overview') ||
        normalizedLower.contains('catch me up') ||
        normalizedLower.contains('what have i missed')) {
      if (_isDailySummaryRequest(normalizedLower) ||
          _isWeeklySummaryRequest(normalizedLower)) {
        return _resolveSummaryIntent(normalizedLower);
      }
      // Guard: if the query is actually a risk-trend question, route to
      // risk_question first — e.g. "has my risk gone up or down this month?"
      if (_isRiskQuestion(normalizedLower)) return 'risk_question';
      return 'week_summary';
    }
    // Priority 10: Greeting
    if (_isGreeting(normalizedLower)) {
      return 'greeting';
    }

    // Default
    return 'general_health_question';
  }

  String _normalizeIntentText(String value) =>
      TextNormalizationService.normalizeForIntent(value);

  /// Returns true when the user clearly pivoted away from the symptom intake
  /// thread (greeting, cancel, doctor summary request, lab question, etc.).
  /// Used by the intake clarifier loop — anything that isn't an explicit pivot
  /// keeps us in intake so the clarifier can ask for more detail (bounded by
  /// `_maxSymptomClarifierRetries`).
  bool _shouldExitSymptomIntake(String lower) {
    final normalized = _normalizeIntentText(lower).trim();
    if (normalized.isEmpty) return false;
    if (_isCancelLike(normalized)) return true;
    if (_isGreeting(normalized)) return true;
    if (_isDoctorSummaryRequest(normalized) ||
        _isMemoryLedgerRequest(normalized) ||
        _looksLikePhotoAttachment(normalized) ||
        _isLabQuestion(normalized) ||
        _isClinicalRecordQuestion(normalized) ||
        _isForecastWatchlistRequest(normalized)) {
      return true;
    }
    if (_isRiskQuestion(normalized) && !normalized.contains('poop')) {
      return true;
    }
    // Question-like prompts that aren't symptom narratives are pivots.
    if (_isQuestionLike(normalized) &&
        !_looksLikeSymptomNarrative(normalized) &&
        !_containsStoolColloquial(normalized)) {
      return true;
    }
    return false;
  }

  bool _shouldStayInSymptomIntake(String lower) {
    final normalized = _normalizeIntentText(lower).trim();
    if (normalized.isEmpty) return false;
    if (_isCancelLike(normalized)) return false;
    // Exit symptom intake if user says a greeting like "hi" or "hello"
    if (_isGreeting(normalized)) return false;
    if (_isDoctorSummaryRequest(normalized) ||
        _isMemoryLedgerRequest(normalized) ||
        _looksLikePhotoAttachment(normalized) ||
        _isLabQuestion(normalized) ||
        _isClinicalRecordQuestion(normalized) ||
        _isForecastWatchlistRequest(normalized)) {
      return false;
    }
    if (_isRiskQuestion(normalized) && !normalized.contains('poop')) {
      return false;
    }
    if (_isExplicitSymptomLogRequest(normalized) ||
        _isCheckInNarrative(normalized) ||
        _containsSymptomContinuationSignals(normalized) ||
        _looksLikeSymptomNarrative(normalized) ||
        _containsStoolColloquial(normalized)) {
      return true;
    }
    if (_isQuestionLike(normalized)) {
      return false;
    }
    // For short messages (<=10 words), only stay in symptom intake if they
    // contain health-related terms. This prevents non-health inputs like
    // "silly willy" or "hi" from being treated as symptom continuations.
    // Longer messages (>10 words) are assumed to be legitimate symptom
    // descriptions and are allowed to continue. The 10-word threshold is based
    // on the original logic and balances two goals:
    //   1. Reject obvious non-health inputs (greetings, nonsense, off-topic)
    //   2. Accept multi-sentence symptom narratives without requiring every
    //      sentence to contain a health keyword (e.g., "it started after lunch.
    //      lasted about two hours. felt really bad.")
    final wordCount = normalized.split(RegExp(r'\s+')).length;
    if (wordCount <= 10) {
      return _containsHealthTerms(normalized);
    }
    return true;
  }

  /// Returns true when a message in an active symptom intake session is clearly
  /// not a health-related description. Used to trigger the progressive rejection
  /// path instead of the generic clarifier loop.
  ///
  /// Design constraints:
  /// - Conservative: short inputs (≤ 2 words) are never rejected — "tired",
  ///   "bad", "stomach" are valid terse symptom starts.
  /// - Known non-health topics (sports, politics, weather) always return true.
  /// - General feeling/bodily words exempt inputs from rejection even if they
  ///   lack explicit medical keywords (e.g., "I feel rough today").
  /// - Falls back to the inverse of `_shouldStayInSymptomIntake` for everything
  ///   else — if the input neither exits nor stays, it's treated as non-health.
  /// Cheap deterministic gibberish detector. Catches obvious random-keystroke
  /// input ("bdyagayauHb", "asdfqwerty") before we burn a Gemma classifier
  /// call. Conservative — only fires on single-token, length-6+ input whose
  /// letter pattern is far from any English-like distribution. Multi-word
  /// inputs and short tokens fall through to the LLM classifier so real
  /// symptoms phrased with typos still get accepted.
  bool _looksLikeGibberish(String input) {
    final trimmed = input.trim();
    if (trimmed.length < 6) return false;
    // Multi-word inputs are likely real text — let the classifier judge.
    if (trimmed.contains(RegExp(r'\s'))) return false;
    // Only alpha tokens are considered; numbers / punctuation / emoji are
    // someone else's problem.
    if (!RegExp(r'^[A-Za-z]+$').hasMatch(trimmed)) return false;

    final lower = trimmed.toLowerCase();
    final vowelCount = RegExp(r'[aeiou]').allMatches(lower).length;
    final vowelRatio = vowelCount / lower.length;

    // English averages ~38-40% vowels; extreme deviation in either direction
    // strongly suggests keysmash.
    final extremeVowelRatio = vowelRatio < 0.20 || vowelRatio > 0.70;

    // Any consonant run of 5+ is essentially impossible in English.
    final hasLongConsonantRun =
        RegExp(r'[bcdfghjklmnpqrstvwxyz]{5,}').hasMatch(lower);

    // Mixed case in the interior (not just a single leading capital) is a
    // very strong keysmash tell — real symptoms and even unusual loanwords
    // are written all-lower or with leading-cap only. "bdyagayauHb" is the
    // canonical example. Single-signal reject.
    final interior = trimmed.substring(1);
    final hasInteriorCase = RegExp(r'[A-Z]').hasMatch(interior) &&
        RegExp(r'[a-z]').hasMatch(interior);

    // Long consonant runs are essentially impossible in English; single-signal
    // reject.
    // Extreme vowel ratio alone is too noisy (some real words / loanwords
    // skew), so only reject on extreme-vowel-ratio when paired with another
    // signal.
    if (hasInteriorCase) return true;
    if (hasLongConsonantRun) return true;
    if (extremeVowelRatio && (hasInteriorCase || hasLongConsonantRun)) {
      return true;
    }
    return false;
  }

  bool _isNonHealthSymptomInput(String lower) {
    final normalized = _normalizeIntentText(lower).trim();
    if (normalized.isEmpty) return false;
    final words = normalized.split(RegExp(r'\s+'));
    // Short inputs are too ambiguous to reject — let the clarifier handle them.
    if (words.length <= 2) return false;
    // Explicitly known non-health topic domains.
    if (_isNonHealthTopic(normalized)) return true;
    // Companion-animal narratives are usually off-topic in this flow
    // ("my cat is sleeping", "my dog ran away this morning").
    // Keep the heuristic conservative by requiring no explicit health cues.
    final hasPetTopic = RegExp(
      r'\bmy\s+(?:cat|dog|kitten|puppy|pet)\b',
    ).hasMatch(normalized);
    if (hasPetTopic &&
        !_containsHealthTerms(normalized) &&
        _manualHealthSymptomType(normalized) == null) {
      return true;
    }
    // General feeling/bodily-state words that describe how someone feels,
    // even without specific medical keywords ("I feel rough", "getting worse").
    const healthAdjacent = {
      'feel',
      'feeling',
      'felt',
      'hurt',
      'hurts',
      'hurting',
      'ache',
      'aching',
      'aches',
      'sore',
      'tender',
      'sensitive',
      'worse',
      'better',
      'worsening',
      'improving',
      'sick',
      'unwell',
      'awful',
      'terrible',
      'horrible',
      'rough',
      'bad',
      'weak',
      'dizzy',
      'dizziness',
      'lightheaded',
      'uncomfortable',
      'off',
      'weird',
      'strange',
      'odd',
      'can\'t',
      'cannot',
      'unable',
      'struggling',
      'struggle',
      'since',
      'after',
      'before',
      'started',
      'woke',
      'sleep',
      'eating',
      'breakfast',
      'lunch',
      'dinner',
      'meal',
      'food',
      'bathroom',
      'toilet',
      'bowel',
      'stool',
      'poop',
    };
    if (words.any((w) => healthAdjacent.contains(w))) return false;
    // Defer to the inverse of the health-continuity check.
    // Note: _shouldStayInSymptomIntake already guards continuation signals
    // (trigger words, frequency, timing). Do NOT add a separate
    // _containsSymptomContinuationSignals check here — timing words like
    // 'this morning' and 'yesterday' appear in non-health phrases too
    // (e.g. "my dog ran away this morning", "I bought shoes yesterday").
    return !_shouldStayInSymptomIntake(lower);
  }

  bool _isCancelLike(String lower) {
    final normalized = _normalizeIntentText(lower);
    return normalized == 'cancel' ||
        normalized == 'stop' ||
        normalized == 'never mind' ||
        normalized == 'nevermind' ||
        normalized == 'forget it' ||
        normalized == 'dont log' ||
        normalized == "don't log";
  }

  bool _containsStoolColloquial(String lower) {
    return lower.contains('poop') ||
        lower.contains('pooping') ||
        lower.contains('bowel movement') ||
        lower.contains('bowel movements') ||
        lower.contains('bm ');
  }

  bool _isWearableDataQuestion(String lower) {
    const triggers = [
      'steps',
      'step count',
      'how much did i walk',
      'how far did i walk',
      'heart rate',
      'resting heart rate',
      'my hr',
      ' bpm',
      'hrv',
      'heart rate variability',
      'how long did i sleep',
      'how many hours did i sleep',
      'sleep trend',
      'sleep data',
      'oxygen',
      'spo2',
      'blood oxygen',
      'active calories',
      'energy burned',
      'calories burned',
      'activity rings',
      'move ring',
      'exercise ring',
      'wrist temperature',
      'body temperature',
      'respiratory rate',
      'breathing rate',
      'walking heart rate',
      'heart rate recovery',
      'recovery rate',
      'vo2',
      'cardio fitness',
      'walking speed',
      'stair ascent',
      'stair speed',
      'afib',
      'atrial fibrillation',
      'breathing disturbance',
      'sleep disturbance',
      'water intake',
      'hydration',
      'caffeine',
      'apple watch',
      'health app',
      'my wearable',
      'my sensor data',
      'how active',
      'how much did i move',
    ];
    return triggers.any((kw) => lower.contains(kw));
  }

  bool _isCheckInNarrative(String lower) {
    final normalized = _normalizeIntentText(lower);
    // Check scale in both normalized (where "/" is stripped to space) and raw.
    final hasScale = RegExp(r'\b\d+\s*/\s*\d+\b').hasMatch(lower) ||
        RegExp(r'\b\d+\s+out of\s+\d+\b').hasMatch(normalized) ||
        // Post-normalization: "7/10" → "7 10"; check adjacent digit pair.
        RegExp(r'\b([1-9]|10)\s+(10)\b').hasMatch(normalized);
    final hasBm = RegExp(
      r'\b\d+\s*(bm|bowel|poop|poops|stool|stools|time|times)\b',
    ).hasMatch(normalized);
    final hasCheckinKeyword = normalized.contains('pain') ||
        normalized.contains('urgency') ||
        normalized.contains('bleeding') ||
        normalized.contains('fatigue') ||
        normalized.contains('check') ||
        normalized.contains('belly') ||
        normalized.contains('stomach');
    return (hasScale || hasBm) && hasCheckinKeyword;
  }

  bool _isMultiSymptomNarrative(String lower) {
    final normalized = _normalizeIntentText(lower);
    // Plain personal symptom reports ("My pain is worse and I had loose stool")
    // should receive grounded symptom guidance unless the user explicitly asks
    // to log/save. Reserve multi_symptom_log for list-like logging turns.
    final explicitLogOrSave = _isExplicitSymptomLogRequest(normalized) ||
        normalized.contains('save ') ||
        normalized.contains('record ');
    if (!explicitLogOrSave &&
        (normalized.startsWith('my ') ||
            normalized.startsWith('i have ') ||
            normalized.startsWith('i had ') ||
            normalized.startsWith('i am having ') ||
            normalized.startsWith("i'm having "))) {
      return false;
    }
    // 3-token sliding window over the lexicon — word variants like "bloated",
    // "stomach pain", "the runs" are recognised without a fragile keyword list.
    final tokens = normalized.split(RegExp(r'[\s,;.!?]+'));
    final detectedTypes = <String>{};
    for (var i = 0; i < tokens.length; i++) {
      for (var len = 3; len >= 1; len--) {
        if (i + len > tokens.length) continue;
        final phrase = tokens.sublist(i, i + len).join(' ').trim();
        if (phrase.length < 3) continue;
        final m = SymptomParserService.matchSymptom(phrase);
        if (m != null) {
          detectedTypes.add(m.symptomType);
          break; // longest match wins for this window start position
        }
      }
    }
    // Common symptom words not always in the lexicon — treat each as +1 distinct type
    if (normalized.contains('pain') ||
        normalized.contains('ache') ||
        normalized.contains('hurt') ||
        normalized.contains('sore')) {
      detectedTypes.add('_pain_signal');
    }
    if (normalized.contains('tired') ||
        normalized.contains('exhausted') ||
        normalized.contains('fatigue') ||
        normalized.contains('wiped out') ||
        normalized.contains('no energy') ||
        normalized.contains('drained')) {
      detectedTypes.add('_fatigue_signal');
    }
    if (normalized.contains('nausea') ||
        normalized.contains('nauseous') ||
        normalized.contains('queasy') ||
        normalized.contains('feel sick')) {
      detectedTypes.add('_nausea_signal');
    }
    final hasJoiner =
        normalized.contains(' and ') || RegExp(r'[,;]').hasMatch(normalized);
    return detectedTypes.length >= 2 && hasJoiner;
  }

  bool _isAppMetaQuestion(String lower) {
    final normalized = _normalizeIntentText(lower);
    return normalized.contains("why can't you") ||
        normalized.contains("why cant you") ||
        normalized.contains("why won't you") ||
        normalized.contains("why don't you") ||
        normalized.contains("why do you") ||
        normalized.contains("how do you") ||
        normalized.contains("how does this work") ||
        normalized.contains("how does gemma_flares") ||
        normalized.contains("can you save") ||
        normalized.contains("can you log") ||
        normalized.contains("can you track") ||
        normalized.contains("what can you do") ||
        normalized.contains("what can this app") ||
        normalized.contains("what does this app") ||
        normalized.contains("what does gemma_flares do") ||
        normalized.contains("is my data local") ||
        normalized.contains("is my data private") ||
        normalized.contains("where is my data") ||
        normalized.contains("what do you use") ||
        normalized.contains("why are you") ||
        // Bug-A: identity questions routing to risk score dump
        normalized.contains("who are you") ||
        normalized.contains("what are you") ||
        normalized.contains("who r u") ||
        normalized.contains("who r you") ||
        normalized.contains("what r you") ||
        normalized.contains("who is gemma_flares") ||
        normalized.contains("what is gemma_flares") ||
        normalized.contains("tell me about yourself") ||
        normalized.contains("how did i get") ||
        normalized.contains("what are you made of") ||
        normalized.contains("are you an ai") ||
        normalized.contains("are you a bot") ||
        normalized.contains("are you real");
  }

  bool _isSymptomQuestion(String lower) {
    final normalized = _normalizeIntentText(lower);
    return normalized.contains('symptom') ||
        normalized.contains('pain') ||
        normalized.contains('stool') ||
        normalized.contains('poop') ||
        normalized.contains('pooping') ||
        normalized.contains('bowel movement') ||
        normalized.contains('bowel movements') ||
        normalized.contains('bleeding') ||
        normalized.contains('nausea') ||
        normalized.contains('fatigue') ||
        normalized.contains('cramp') ||
        normalized.contains('bloating') ||
        normalized.contains('diarrhea') ||
        normalized.contains('vomit') ||
        normalized.contains('urgency') ||
        normalized.contains('constipat') ||
        normalized.contains('fistula') ||
        normalized.contains('abscess') ||
        normalized.contains('fissure') ||
        normalized.contains('stricture') ||
        normalized.contains('obstruction') ||
        normalized.contains('mouth sore') ||
        normalized.contains('night sweat') ||
        normalized.contains('joint pain') ||
        normalized.contains('rectal') ||
        normalized.contains('drainage') ||
        normalized.contains('weight loss') ||
        normalized.contains('losing weight') ||
        normalized.contains('malnutrition') ||
        normalized.contains('anemia') ||
        normalized.contains('dehydrat') ||
        normalized.contains('tenesmus') ||
        normalized.contains('gas') ||
        normalized.contains('headache') ||
        normalized.contains('head ache') ||
        normalized.contains('migraine') ||
        normalized.contains('chills') ||
        normalized.contains('mucus') ||
        normalized.contains('incontinence') ||
        normalized.contains('appetite');
  }

  bool _isSymptomExplanationQuestion(String lower) {
    final normalized = _normalizeIntentText(lower);

    // Production-grade question word detection (100+ patterns)
    final hasQuestionWord = _hasExplanatoryQuestionWord(normalized);
    if (!hasQuestionWord) return false;

    // Reject non-health topics explicitly before symptom detection
    if (_isNonHealthTopic(normalized)) return false;

    // Use SymptomParserService lexicon (535+ terms) with sliding window
    // detection to match any symptom phrase (1-3 words)
    if (_containsSymptomViaLexicon(normalized)) return true;

    // Fallback: common health state terms not always in symptom lexicon
    // (exhausted, wiped out, feel awful, feel sick, etc.)
    return _containsHealthStateTerm(normalized);
  }

  bool _hasExplanatoryQuestionWord(String normalized) {
    // Core question patterns (why/what/when/where/how + personal reference)
    if (normalized.contains('why am i') ||
        normalized.contains('why do i') ||
        normalized.contains('why is my') ||
        normalized.contains('why is the') ||
        normalized.contains('why does my') ||
        normalized.contains('why have i') ||
        normalized.contains('why did i')) {
      return true;
    }

    if (normalized.contains('what causes') ||
        normalized.contains('what is causing') ||
        normalized.contains('what\'s causing') ||
        normalized.contains('whats causing') ||
        normalized.contains('what makes my') ||
        normalized.contains('what gives me') ||
        normalized.contains('what brings on')) {
      return true;
    }

    if (normalized.contains('how come i') ||
        normalized.contains('how come my') ||
        normalized.contains('how did i') ||
        normalized.contains('how do i get')) {
      return true;
    }

    if (normalized.contains('when does my') ||
        normalized.contains('when do i') ||
        normalized.contains('when did my') ||
        normalized.contains('when will my')) {
      return true;
    }

    if (normalized.contains('where does my') ||
        normalized.contains('where is my') ||
        normalized.contains('where did my')) {
      return true;
    }

    // Informal / conversational variants
    if (normalized.startsWith('why so ') ||
        normalized.startsWith('why such a ') ||
        normalized.startsWith('why this ') ||
        normalized.startsWith('why the ')) {
      return true;
    }

    return false;
  }

  bool _isNonHealthTopic(String normalized) {
    // Explicit rejection of common non-health question domains
    // Politics & current events
    if (normalized.contains('trump') ||
        normalized.contains('biden') ||
        normalized.contains('president') ||
        normalized.contains('election') ||
        normalized.contains('congress') ||
        normalized.contains('senate') ||
        normalized.contains('democrat') ||
        normalized.contains('republican')) {
      return true;
    }

    // Sports
    if (normalized.contains('game') ||
        normalized.contains('score') ||
        normalized.contains('team') ||
        normalized.contains('player') ||
        normalized.contains('nfl') ||
        normalized.contains('nba') ||
        normalized.contains('mlb') ||
        normalized.contains('soccer') ||
        normalized.contains('football') ||
        normalized.contains('basketball') ||
        normalized.contains('baseball')) {
      return true;
    }

    // Weather
    if (normalized.contains('weather') ||
        normalized.contains('forecast') ||
        normalized.contains('rain') ||
        normalized.contains('snow') ||
        normalized.contains('sunny') ||
        normalized.contains('cloudy') ||
        normalized.contains('temperature outside')) {
      return true;
    }

    // Technology/devices (not health tech)
    if (normalized.contains('wifi') ||
        normalized.contains('internet') ||
        normalized.contains('computer') ||
        normalized.contains('laptop') ||
        normalized.contains('iphone') ||
        normalized.contains('android') ||
        normalized.contains('app crash') ||
        normalized.contains('windows') ||
        normalized.contains('mac') ||
        normalized.contains('download') ||
        normalized.contains('install')) {
      return true;
    }

    // Finance
    if (normalized.contains('stock') ||
        normalized.contains('crypto') ||
        normalized.contains('bitcoin') ||
        normalized.contains('investment') ||
        normalized.contains('market') ||
        normalized.contains('dow jones') ||
        normalized.contains('nasdaq')) {
      return true;
    }

    // Entertainment
    if (normalized.contains('movie') ||
        normalized.contains('tv show') ||
        normalized.contains('netflix') ||
        normalized.contains('spotify') ||
        normalized.contains('music') ||
        normalized.contains('song')) {
      return true;
    }

    // Everyday non-health subjects that often include timing words.
    if (RegExp(r'\b(?:cat|dog|pet)\b').hasMatch(normalized) ||
        RegExp(
          r'\b(?:shoe|shoes|clothes|bought|shopping)\b',
        ).hasMatch(normalized) ||
        RegExp(
          r'\b(?:school|class|homework|meeting|bus)\b',
        ).hasMatch(normalized) ||
        RegExp(r'\b(?:cooked|cooking)\b').hasMatch(normalized)) {
      return true;
    }

    return false;
  }

  bool _containsSymptomViaLexicon(String normalized) {
    // Sliding window detection (1-3 word phrases) using SymptomParserService
    // lexicon to match any of 535+ symptom terms across 40+ symptom types.
    final tokens = normalized.split(RegExp(r'[\s,;.!?]+'));
    for (var i = 0; i < tokens.length; i++) {
      for (var len = 3; len >= 1; len--) {
        if (i + len > tokens.length) continue;
        final phrase = tokens.sublist(i, i + len).join(' ').trim();
        if (phrase.length < 3) continue;
        final match = SymptomParserService.matchSymptom(phrase);
        if (match != null && match.confidence >= 0.7) {
          return true;
        }
      }
    }
    return false;
  }

  bool _containsHealthStateTerm(String normalized) {
    // Common health state expressions not always captured by symptom lexicon
    return normalized.contains('feel awful') ||
        normalized.contains('feel terrible') ||
        normalized.contains('feel sick') ||
        normalized.contains('feel bad') ||
        normalized.contains('feel worse') ||
        normalized.contains('feeling awful') ||
        normalized.contains('feeling terrible') ||
        normalized.contains('feeling sick') ||
        normalized.contains('feeling worse') ||
        normalized.contains('not feeling well') ||
        normalized.contains('unwell') ||
        normalized.contains('wiped out') ||
        normalized.contains('run down') ||
        normalized.contains('beat up') ||
        normalized.contains('worn out') ||
        normalized.contains('no energy') ||
        normalized.contains('low energy') ||
        normalized.contains('weak') ||
        normalized.contains('weakness');
  }

  bool _isClinicalRecordQuestion(String lower) {
    return lower.contains('colonoscopy') ||
        lower.contains('endoscopy') ||
        lower.contains('biopsy') ||
        lower.contains('pathology') ||
        lower.contains('pathologic diagnosis') ||
        lower.contains('microscopic diagnosis') ||
        lower.contains('terminal ileum') ||
        lower.contains('ileitis') ||
        lower.contains('colitis') ||
        lower.contains('proctitis') ||
        lower.contains('dysplasia') ||
        lower.contains('granuloma') ||
        lower.contains('ulcerated mucosa') ||
        lower.contains('punctate ulceration') ||
        lower.contains('erythema') ||
        lower.contains('erosion');
  }

  bool _isClinicalRecordReviewInput(String lower) {
    final hasRecordMarker = lower.contains('lab photo ocr') ||
        lower.contains('photo ocr') ||
        lower.contains('report') ||
        lower.contains('record') ||
        lower.contains('findings') ||
        lower.contains('impression') ||
        lower.contains('diagnosis') ||
        lower.contains('biopsy');
    return hasRecordMarker && _isClinicalRecordQuestion(lower);
  }

  List<String> _toolsForIntent(String intent) {
    switch (intent) {
      case 'risk_question':
        return const [
          'get_today_risk_snapshot',
          'get_context_attribution',
          'get_recent_symptoms',
          'get_early_warning_outlook',
        ];
      case 'confidence_question':
        return const [
          'get_today_risk_snapshot',
          'get_confidence_components',
          'get_sync_state',
        ];
      case 'followup_expand':
        return const [
          'get_recent_conversation_context',
          'get_today_risk_snapshot',
          'get_context_attribution',
          'get_recent_symptoms',
        ];
      case 'followup_compare':
        return const [
          'get_week_summary',
          'get_recent_checkins',
          'get_early_warning_outlook',
          'get_context_attribution',
        ];
      case 'followup_correction':
        return const [
          'get_recent_conversation_context',
          'get_today_risk_snapshot',
          'get_recent_symptoms',
        ];
      case 'symptom_log_followup':
        return const ['get_recent_conversation_context', 'get_recent_symptoms'];
      case 'lab_question':
        return const [
          'get_recent_labs',
          'get_flare_label_context',
          'get_recent_procedures',
        ];
      case 'daily_summary':
        return const [
          'get_week_summary',
          'get_recent_symptoms',
          'get_recent_labs',
          'get_recent_checkins',
          'get_early_warning_outlook',
        ];
      case 'week_summary':
        return const [
          'get_week_summary',
          'get_recent_symptoms',
          'get_recent_labs',
          'get_recent_checkins',
          'get_early_warning_outlook',
        ];
      case 'symptom_question':
        return const [
          'get_recent_symptoms',
          'get_recent_checkins',
          'get_today_risk_snapshot',
        ];
      case 'emotional_support':
      case 'emotional_vent_with_symptoms':
        return const ['get_recent_conversation_context', 'get_recent_symptoms'];
      case 'medication_question':
        return const ['get_recent_symptoms', 'get_recent_checkins'];
      case 'diet_question':
        return const ['get_recent_symptoms'];
      case 'wearable_data_question':
        return const ['get_wearable_metric_aggregates', 'get_sync_state'];
      case 'data_gap_question':
        return const [
          'get_sync_state',
          'get_today_risk_snapshot',
          'query_memory_transactions',
        ];
      case 'urgent_safety':
        return const [];
      case 'out_of_scope':
        return const [];
      case 'greeting':
        return const ['get_recent_conversation_context'];
      case 'smalltalk':
        return const ['get_recent_conversation_context'];
      case 'doctor_summary':
        return const [
          'get_today_risk_snapshot',
          'get_recent_symptoms',
          'get_recent_labs',
          'get_recent_checkins',
          'get_recent_procedures',
          'get_context_attribution',
          'get_early_warning_outlook',
        ];
      default:
        return const [
          'get_today_risk_snapshot',
          'get_recent_symptoms',
          'get_recent_labs',
        ];
    }
  }

  Map<String, Object?> _groundingForIntent(
    String intent,
    Map<String, Object?> allContext,
  ) {
    final grounding = <String, Object?>{
      'agent_intent': intent,
      'latest_score': allContext['latest_score'],
      // Always include the UI-facing flare risk state so the model uses the
      // correct display value (display_text: "23%" or "Learning") instead of
      // the raw latest_score.risk_score internal signal index.
      'global_flare_risk': allContext['global_flare_risk'],
      'recent_conversation_turns': allContext['recent_conversation_turns'],
      'chat_session_summary': allContext['chat_session_summary'],
      'user_profile': allContext['user_profile'],
    };
    void copy(String key) {
      if (allContext.containsKey(key)) {
        grounding[key] = allContext[key];
      }
    }

    switch (intent) {
      case 'risk_question':
        copy('latest_summary');
        copy('context_attribution');
        copy('recent_symptoms');
        copy('recent_pro2_surveys');
        copy('checkin_summary_7d');
        copy('hrv_circadian_rhythm');
        copy('early_warning_outlook');
        copy('logistic_model_status');
        copy('rag_context_snippets');
        break;
      case 'forecast_watchlist':
        // Forward-looking: emphasise early warning outlook + trend data.
        // Intentionally omits latest_summary (current state) — this is
        // about what is COMING, not what IS.
        copy('early_warning_outlook');
        copy('hrv_circadian_rhythm');
        copy('checkin_trend_7d');
        copy('checkin_summary_7d');
        copy('recent_symptoms');
        copy('recent_pro2_surveys');
        copy('context_attribution');
        copy('logistic_model_status');
        copy('rag_context_snippets');
        break;
      case 'confidence_question':
        copy('latest_summary');
        copy('context_attribution');
        copy('checkin_summary_7d');
        break;
      case 'continuation':
      case 'followup_expand':
        // Full context — user is deepening a conversation and needs everything
        copy('latest_summary');
        copy('context_attribution');
        copy('recent_symptoms');
        copy('recent_pro2_surveys');
        copy('checkin_summary_7d');
        copy('checkin_trend_7d');
        copy('hrv_circadian_rhythm');
        copy('early_warning_outlook');
        copy('logistic_model_status');
        copy('lab_results');
        copy('latest_lab_explain');
        copy('flare_label_today');
        copy('latest_procedure');
        copy('recent_summary_dates');
        copy('rag_memory_transactions');
        copy('rag_context_snippets');
        break;
      case 'followup_compare':
        copy('recent_summary_dates');
        copy('requested_summary_window');
        copy('summary_window_rollups');
        copy('checkin_trend_7d');
        copy('checkin_summary_7d');
        copy('early_warning_outlook');
        copy('context_attribution');
        copy('recent_symptoms');
        copy('recent_pro2_surveys');
        copy('lab_results');
        copy('hrv_circadian_rhythm');
        copy('rag_context_snippets');
        break;
      case 'followup_correction':
        copy('recent_symptoms');
        copy('context_attribution');
        copy('early_warning_outlook');
        break;
      case 'symptom_log_followup':
        copy('recent_symptoms');
        break;
      case 'lab_question':
        copy('lab_results');
        copy('latest_lab_explain');
        copy('recent_lab_reviews');
        copy('rag_memory_transactions');
        copy('rag_context_snippets');
        copy('flare_label_today');
        copy('latest_procedure');
        copy('recent_pro2_surveys');
        break;
      case 'daily_summary':
      case 'week_summary':
        copy('latest_summary');
        copy('recent_daily_summaries');
        copy('recent_summary_dates');
        copy('requested_summary_window');
        copy('summary_window_rollups');
        copy('recent_symptoms');
        copy('recent_pro2_surveys');
        copy('checkin_trend_7d');
        copy('checkin_summary_7d');
        copy('lab_results');
        copy('latest_procedure');
        copy('rag_memory_transactions');
        copy('early_warning_outlook');
        copy('context_attribution');
        copy('rag_context_snippets');
        break;
      case 'symptom_question':
        copy('recent_symptoms');
        copy('recent_pro2_surveys');
        copy('checkin_trend_7d');
        copy('checkin_summary_7d');
        copy('context_attribution');
        copy('rag_context_snippets');
        break;
      case 'emotional_support':
      case 'emotional_vent_with_symptoms':
        // Minimal data — empathy first, not numbers
        copy('recent_symptoms');
        grounding.remove('latest_score');
        break;
      case 'medication_question':
        copy('recent_symptoms');
        copy('recent_pro2_surveys');
        break;
      case 'diet_question':
        copy('recent_symptoms');
        break;
      case 'wearable_data_question':
        // Raw Apple Health metric aggregates — not IBD analysis, so strip score.
        // Inject date anchor strings so Gemma can resolve "yesterday" / "this
        // week" to specific keys inside wearable_metric_aggregates.
        copy('wearable_metric_aggregates');
        copy('recent_summary_dates');
        grounding.remove('latest_score');
        final wNow = _nowProvider();
        final wToday = '${wNow.year.toString().padLeft(4, '0')}-'
            '${wNow.month.toString().padLeft(2, '0')}-'
            '${wNow.day.toString().padLeft(2, '0')}';
        grounding['today_date'] = wToday;
        grounding['yesterday_date'] = _offsetDate(wToday, -1);
        grounding['week_start_date'] = _offsetDate(wToday, -6);
        break;
      case 'data_gap_question':
        copy('latest_summary');
        copy('context_attribution');
        copy('rag_memory_transactions');
        copy('rag_context_snippets');
        break;
      case 'urgent_safety':
        // No health data — just redirect to care team
        grounding.remove('latest_score');
        break;
      case 'out_of_scope':
        // No health data needed
        grounding.remove('latest_score');
        break;
      case 'doctor_summary':
        copy('latest_summary');
        copy('context_attribution');
        copy('recent_symptoms');
        copy('recent_pro2_surveys');
        copy('checkin_trend_7d');
        copy('checkin_summary_7d');
        copy('lab_results');
        copy('flare_label_today');
        copy('latest_procedure');
        copy('early_warning_outlook');
        copy('logistic_model_status');
        copy('hrv_circadian_rhythm');
        break;
      case 'app_meta_question':
        copy('latest_summary');
        copy('context_attribution');
        copy('rag_memory_transactions');
        break;
      case 'check_in_log':
        copy('recent_pro2_surveys');
        copy('recent_symptoms');
        copy('checkin_summary_7d');
        copy('rag_context_snippets');
        break;
      case 'multi_symptom_log':
        copy('recent_symptoms');
        copy('recent_pro2_surveys');
        copy('rag_context_snippets');
        break;
      case 'greeting':
        // No health data for greetings — strip latest_score too.
        grounding.remove('latest_score');
        break;
      case 'smalltalk':
        grounding.remove('latest_score');
        break;
      // New starter prompt intents — targeted data only, no score/confidence
      case 'medication_context':
        copy('rag_context_snippets'); // Medication notes from RAG
        copy('recent_symptoms'); // Symptom context
        copy('recent_pro2_surveys'); // Check-in context
        grounding.remove('latest_score'); // No score/confidence
        break;
      case 'food_trigger_analysis':
        copy('recent_symptoms'); // Symptoms with meal_relation field
        copy('recent_pro2_surveys'); // Check-in data
        copy('rag_context_snippets'); // Food-related notes
        grounding.remove('latest_score'); // No score/confidence
        break;
      case 'hrv_trend_analysis':
        copy('wearable_metric_aggregates'); // Apple Watch HRV data
        copy('hrv_circadian_rhythm'); // HRV context
        copy('recent_summary_dates'); // Date context
        grounding.remove('latest_score'); // No score/confidence
        // Add date anchors for time-based queries
        final hrvNow = _nowProvider();
        final hrvToday = '${hrvNow.year.toString().padLeft(4, '0')}-'
            '${hrvNow.month.toString().padLeft(2, '0')}-'
            '${hrvNow.day.toString().padLeft(2, '0')}';
        grounding['today_date'] = hrvToday;
        grounding['yesterday_date'] = _offsetDate(hrvToday, -1);
        grounding['week_start_date'] = _offsetDate(hrvToday, -6);
        break;
      case 'activity_pattern_analysis':
        copy('wearable_metric_aggregates'); // Steps, exercise, active energy
        copy('recent_summary_dates'); // Date context
        copy('recent_symptoms'); // Connect to gut symptoms if relevant
        grounding.remove('latest_score'); // No score/confidence
        // Add date anchors
        final actNow = _nowProvider();
        final actToday = '${actNow.year.toString().padLeft(4, '0')}-'
            '${actNow.month.toString().padLeft(2, '0')}-'
            '${actNow.day.toString().padLeft(2, '0')}';
        grounding['today_date'] = actToday;
        grounding['yesterday_date'] = _offsetDate(actToday, -1);
        grounding['week_start_date'] = _offsetDate(actToday, -6);
        break;
      case 'visit_preparation':
        // Comprehensive summary for GI appointment prep
        copy('recent_symptoms');
        copy('recent_pro2_surveys');
        copy('checkin_summary_7d');
        copy('checkin_trend_7d');
        copy('lab_results');
        copy('latest_procedure');
        copy('rag_context_snippets'); // Medication notes, etc.
        copy('flare_label_today');
        grounding.remove('latest_score'); // No score/confidence unless asked
        break;
      default:
        copy('recent_symptoms');
        copy('lab_results');
        copy('context_attribution');
        copy('early_warning_outlook');
        copy('recent_pro2_surveys');
        copy('checkin_summary_7d');
        copy('rag_context_snippets');
    }

    return _compactGrounding(grounding);
  }

  Map<String, Object?> _toolResultsForIntent(
    String intent,
    Map<String, Object?> grounding,
  ) {
    return {
      'intent': intent,
      'has_score': grounding['latest_score'] != null,
      'symptom_count': (grounding['recent_symptoms'] as List?)?.length ?? 0,
      'lab_count': (grounding['lab_results'] as List?)?.length ?? 0,
      'checkin_count': (grounding['recent_pro2_surveys'] as List?)?.length ?? 0,
      'has_context_attribution': grounding['context_attribution'] != null,
      'has_outlook':
          (grounding['early_warning_outlook'] as List?)?.isNotEmpty == true,
      'rag_transaction_count':
          (grounding['rag_memory_transactions'] as List?)?.length ?? 0,
      'has_confidence_components': ((grounding['latest_score']
              as Map?)?['contributions'] as Map?)?['confidence_components'] !=
          null,
    };
  }

  // WS1a — intents that never need rich health data in the model prompt.
  static const _lightIntents = {
    'greeting',
    'smalltalk',
    'emotional_support',
    'emotional_vent_with_symptoms',
    'out_of_scope',
    'urgent_safety',
    'medication_question',
    'diet_question',
    'app_meta_question',
  };

  bool _isLightIntent(String intent) => _lightIntents.contains(intent);

  Map<String, Object?> _lightGroundingForIntent(
    String intent,
    Map<String, Object?> grounding,
  ) {
    final now = _nowProvider();
    final today =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    final scoreObj = grounding['latest_score'];
    final scoreMap =
        scoreObj is Map ? Map<String, Object?>.from(scoreObj) : null;

    switch (intent) {
      case 'greeting':
      case 'smalltalk':
        // ~20 tokens: just enough for a warm, data-aware greeting
        return {
          'intent': intent,
          'current_date': today,
          if (scoreMap != null)
            'score': {
              'band': scoreMap['risk_band'],
              'value': scoreMap['risk_score'],
            },
        };
      case 'emotional_support':
      case 'emotional_vent_with_symptoms':
        // ~40 tokens: recent symptom types so Gemma can empathise accurately
        return {
          'intent': intent,
          'current_date': today,
          'symptoms': _compactListOfMaps(
            grounding['recent_symptoms'],
            keys: const ['symptom_type', 'severity'],
            limit: 2,
          ),
        };
      default:
        // urgent_safety, out_of_scope, medication_question, diet_question,
        // app_meta_question — all redirect; no health data needed
        return {
          'intent': intent,
          'current_date': today,
          'limits': 'Local estimate only; not diagnosis.',
        };
    }
  }

  Map<String, Object?> _runtimeGroundingForModel(
    Map<String, Object?> grounding,
  ) {
    final latestScore = grounding['latest_score'];
    final scoreMap = latestScore is Map
        ? Map<String, Object?>.from(latestScore)
        : const <String, Object?>{};
    final globalFlareRisk = grounding['global_flare_risk'];
    final globalFlareRiskMap = globalFlareRisk is Map
        ? Map<String, Object?>.from(globalFlareRisk)
        : const <String, Object?>{};
    final contributions = scoreMap['contributions'];
    final drivers = contributions is Map<String, Object?>
        ? _driverContributions(contributions).take(5).map((driver) {
            return {'label': driver.label, 'points': driver.points};
          }).toList(growable: false)
        : const <Map<String, Object?>>[];

    return {
      'intent': grounding['agent_intent'],
      'score': latestScore == null && globalFlareRiskMap.isEmpty
          ? null
          : {
              'date': _firstString(
                globalFlareRiskMap['date_local'],
                scoreMap['date_local'],
              ),
              'value': _firstString(
                globalFlareRiskMap['display_text'],
                scoreMap['risk_score'],
              ),
              'display_text': globalFlareRiskMap['display_text'],
              'status': globalFlareRiskMap['status'],
              'band': _firstString(
                globalFlareRiskMap['band'],
                scoreMap['risk_band'],
              ),
              'confidence': scoreMap['confidence_score'],
              'user_facing_probability':
                  globalFlareRiskMap['user_facing_probability'],
              'internal_signal_index': scoreMap['risk_score'],
              // confidence_components / confidence_inputs omitted — already
              // summarised as plain text in confidence_interpretation below.
              'drivers': drivers,
              'context_reason': _firstString(
                scoreMap['context_attribution_reason'],
                (grounding['context_attribution']
                    as Map?)?['context_attribution_reason'],
              ),
            },
      'global_flare_risk':
          globalFlareRiskMap.isEmpty ? null : globalFlareRiskMap,
      'requested_summary_window': grounding['requested_summary_window'],
      'summary_window_rollups': grounding['summary_window_rollups'],
      'latest_summary': grounding['latest_summary'],
      'wearable_daily_summaries': _compactListOfMaps(
        grounding['recent_daily_summaries'],
        keys: const ['date_local', 'summary'],
        limit: 7,
      ),
      'session_summary': _clipSessionSummary(grounding['chat_session_summary']),
      'symptoms': _compactListOfMaps(
        grounding['recent_symptoms'],
        keys: const ['symptom_type', 'severity', 'logged_at', 'notes'],
        limit: 8,
      ),
      'labs': _compactListOfMaps(
        grounding['lab_results'],
        keys: const [
          'drawn_date',
          'lab_type',
          'value_numeric',
          'unit',
          'elevated',
          'lab_name',
        ],
        limit: 6,
      ),
      'latest_lab_explain': grounding['latest_lab_explain'],
      'checkins': _compactListOfMaps(
        grounding['recent_pro2_surveys'],
        keys: const [
          'date',
          'disease_type',
          'score',
          'is_flare',
          'summary',
          'red_flags',
        ],
        limit: 5,
      ),
      'checkin_summary_7d': _clipSessionSummary(
        grounding['checkin_summary_7d'],
      ),
      'latest_procedure': grounding['latest_procedure'],
      'outlook': _compactListOfMaps(
        grounding['early_warning_outlook'],
        keys: const ['horizon_days', 'label', 'probability', 'band', 'status'],
        limit: 3,
      ),
      'rag_context_snippets': _compactListOfMaps(
        grounding['rag_context_snippets'],
        keys: const [
          'source_type',
          'transaction_id',
          'status',
          'snippet',
          'indexed_at',
        ],
        limit: 3,
      ),
      'score_interpretation': _interpretScoreMap(scoreMap),
      'confidence_interpretation': _interpretConfidenceMap(scoreMap),
      'data_quality_summary': _dataQualitySummary(grounding),
      'limits': 'Local estimate only; not diagnosis.',
    }..removeWhere((key, value) {
        // Drop keys with no signal so sparse-data grounding stays compact and
        // tests can assert that, e.g., `latest_summary` is absent when the user
        // has no daily summary yet.
        if (value == null) return true;
        if (value is List && value.isEmpty) return true;
        if (value is Map && value.isEmpty) return true;
        if (value is String && value.trim().isEmpty) return true;
        return false;
      });
  }

  Map<String, Object?> _runtimeGroundingForLatestLabExplain(
    Map<String, Object?> grounding,
  ) {
    final base = _runtimeGroundingForModel(grounding);
    final latest = grounding['latest_lab_explain'];
    return {
      'intent': 'lab_question',
      'latest_lab_explain': latest,
      'labs': _compactListOfMaps(
        grounding['lab_results'],
        keys: const [
          'drawn_date',
          'lab_type',
          'value_numeric',
          'unit',
          'elevated',
          'lab_name',
        ],
        limit: 3,
      ),
      'checkins': base['checkins'],
      'rag_context_snippets': _compactListOfMaps(
        grounding['rag_context_snippets'],
        keys: const [
          'source_type',
          'transaction_id',
          'status',
          'snippet',
          'indexed_at',
        ],
        limit: 3,
      ),
      'score': base['score'],
      'limits': base['limits'],
      'data_quality_summary': base['data_quality_summary'],
    };
  }

  Future<_LatestLabExplainContext?> _latestLabExplainContext({
    required List<LabValueRecord> labs,
    required List<RagMemoryTransactionRecord> ragTransactions,
  }) async {
    if (labs.isEmpty) return null;
    final latestLab = _selectLatestLab(labs);
    final labId = latestLab.id;

    RagMemoryTransactionRecord? selectedTx;
    if (labId != null) {
      for (final tx in ragTransactions) {
        if (tx.sourceType == 'lab_value' && tx.sourceId == '$labId') {
          selectedTx = tx;
          break;
        }
      }
    }
    if (selectedTx == null) {
      for (final tx in ragTransactions) {
        if (tx.sourceType == 'lab_value') {
          selectedTx = tx;
          break;
        }
      }
    }

    String? ragExtract;
    if (selectedTx != null && _ragCorpusService != null) {
      try {
        final chunk = await _ragCorpusService.readChunkedForVerification(
          selectedTx.chunkId,
        );
        if (chunk != null && chunk.trim().isNotEmpty) {
          ragExtract = _clip(chunk.trim(), 380);
        }
      } catch (_) {
        ragExtract = null;
      }
    }

    return _LatestLabExplainContext(
      lab: {
        'id': latestLab.id,
        'drawn_date': latestLab.drawnDate,
        'lab_type': latestLab.labType,
        'value_numeric': latestLab.valueNumeric,
        'unit': latestLab.unit,
        'reference_high': latestLab.referenceHigh,
        'lab_name': latestLab.labName,
      },
      ragTransactionId: selectedTx?.transactionId,
      ragTransactionStatus: selectedTx?.status,
      ragTransactionIndexedAt: selectedTx?.indexedAt?.toUtc().toIso8601String(),
      ragExtractSnippet: ragExtract,
      askedAtUtc: _nowProvider().toUtc().toIso8601String(),
    );
  }

  int _ragTransactionLimitFor({
    required String intent,
    required bool hasPreset,
  }) {
    if (hasPreset || intent == 'rag_recall') {
      return _presetRagTransactionLimit;
    }
    if (intent == 'symptom_question' ||
        intent == 'lab_question' ||
        intent == 'risk_question' ||
        intent == 'followup_compare' ||
        intent == 'general_health_question') {
      return 64;
    }
    return _defaultRagTransactionLimit;
  }

  Future<_RagContextBuildResult> _buildRagContextSnippets({
    required String intent,
    required _ChatTaskContract taskContract,
    required List<RagMemoryTransactionRecord> ragTransactions,
    required Map<String, Object?> grounding,
    required bool hasPreset,
    required String userQuery,
  }) async {
    if (_isLightIntent(intent) || taskContract == _ChatTaskContract.safety) {
      return const _RagContextBuildResult(
        snippets: [],
        expectedSourceTypes: {},
        providedSourceTypes: {},
        duplicateCountRemoved: 0,
        realChunkCount: 0,
        structuredFallbackCount: 0,
      );
    }

    final allowedSourceTypes = _ragSourceTypesForContext(
      intent: intent,
      taskContract: taskContract,
    );
    final candidateRows = ragTransactions
        .where(
          (tx) =>
              allowedSourceTypes.contains(tx.sourceType) &&
              _isRagStatusReadable(tx.status) &&
              tx.chunkId.trim().isNotEmpty,
        )
        .toList(growable: false);
    final deduped = _dedupeRagTransactions(candidateRows);
    final snippetLimit =
        hasPreset ? _presetRagSnippetLimit : _defaultRagSnippetLimit;

    final snippets = <Map<String, Object?>>[];
    final seenSnippetKeys = <String>{};
    void addSnippet(Map<String, Object?> snippet) {
      if (snippets.length >= snippetLimit) return;
      final sourceType = snippet['source_type']?.toString() ?? '';
      final sourceId = snippet['source_id']?.toString() ?? '';
      final transactionId = snippet['transaction_id']?.toString() ?? '';
      final text = snippet['snippet']?.toString() ?? '';
      final key = transactionId.trim().isNotEmpty
          ? 'tx:$transactionId'
          : sourceId.trim().isNotEmpty
              ? '$sourceType:$sourceId'
              : '$sourceType:${text.hashCode}';
      if (!seenSnippetKeys.add(key)) return;
      snippets.add(snippet);
    }

    final ragQueryService = _ragQueryService;
    if (ragQueryService != null) {
      try {
        final queryResult = await ragQueryService.query(
          userQuery,
          config: RagQueryConfig(
            topKPerCollection: math.max(snippetLimit * 2, 4),
            maxTotal: math.max(snippetLimit * 3, 12),
            collections: _ragCollectionsForSourceTypes(allowedSourceTypes),
          ),
        );
        for (final match in queryResult.matches) {
          if (snippets.length >= snippetLimit) break;
          final sourceType =
              _sourceTypeForRagMatch(match.collection, match.metadata);
          if (!allowedSourceTypes.contains(sourceType)) continue;
          addSnippet({
            'transaction_id': match.metadata['transaction_id']?.toString(),
            'source_type': sourceType,
            'source_id': _firstNonEmptyString(
              match.metadata['source_id'],
              match.metadata['symptom_id'],
              match.metadata['lab_id'],
              match.metadata['checkin_id'],
              match.metadata['procedure_id'],
              match.id,
            ),
            'status': match.metadata['status']?.toString() ?? 'loaded_in_rag',
            'indexed_at': match.metadata['indexed_at']?.toString() ??
                match.metadata['timestamp']?.toString(),
            'snippet_source': 'rag_query',
            'collection': match.collection,
            'score': match.score,
            'chunk_id': match.id,
            'snippet': _clip(match.text, 320),
          });
        }
      } catch (_) {
        // Query failure should not block structured deterministic replies.
      }
    }

    if (_ragCorpusService != null) {
      for (final tx in deduped) {
        if (snippets.length >= snippetLimit) break;
        if (seenSnippetKeys.contains('tx:${tx.transactionId}')) continue;
        try {
          final chunk = await _ragCorpusService.readChunkedForVerification(
            tx.chunkId,
          );
          if (chunk == null || chunk.trim().isEmpty) continue;
          addSnippet({
            'transaction_id': tx.transactionId,
            'source_type': tx.sourceType,
            'source_id': tx.sourceId,
            'status': tx.status,
            'indexed_at': tx.indexedAt?.toUtc().toIso8601String(),
            'snippet_source': 'rag_corpus',
            'snippet': _clip(chunk, 320),
          });
        } catch (_) {
          // Best effort: missing corpus chunks should not block deterministic
          // grounded replies based on structured data.
        }
      }
    }
    final realChunkCount = snippets.length;

    final needsStructuredFallback = snippets.length < snippetLimit &&
        (hasPreset || _ragRequiredForContract(taskContract));
    if (needsStructuredFallback) {
      snippets.addAll(
        _structuredRagFallbackSnippets(
          allowedSourceTypes: allowedSourceTypes,
          grounding: grounding,
          limit: snippetLimit - snippets.length,
        ),
      );
    }
    final providedTypes = snippets
        .map((snippet) => snippet['source_type']?.toString() ?? '')
        .where((sourceType) => sourceType.isNotEmpty)
        .toSet();
    return _RagContextBuildResult(
      snippets: snippets,
      expectedSourceTypes: allowedSourceTypes,
      providedSourceTypes: providedTypes,
      duplicateCountRemoved: candidateRows.length - deduped.length,
      realChunkCount: realChunkCount,
      structuredFallbackCount: snippets.length - realChunkCount,
    );
  }

  List<String> _ragCollectionsForSourceTypes(Set<String> sourceTypes) {
    final collections = <String>{};
    for (final sourceType in sourceTypes) {
      switch (sourceType) {
        case 'lab_value':
        case 'lab':
          collections.add(RagCollection.labs);
          break;
        case 'symptom':
          collections.add(RagCollection.symptoms);
          break;
        case 'pro2_survey':
        case 'check_in':
          collections.add(RagCollection.checkins);
          break;
        case 'intake_event':
        case 'medication':
        case 'medication_event':
          collections
              .addAll({RagCollection.medications, RagCollection.summaries});
          break;
        case 'apple_health_sync':
        case 'flare_risk_score':
          collections
              .addAll({RagCollection.healthSync, RagCollection.summaries});
          break;
        case 'procedure':
        case 'endoscopy_record':
          collections.add(RagCollection.procedures);
          break;
        case 'gi_export':
          collections.add(RagCollection.giExports);
          break;
        default:
          collections.add(RagCollection.summaries);
      }
    }
    return collections.toList(growable: false)..sort();
  }

  String _sourceTypeForRagMatch(
    String collection,
    Map<String, Object?> metadata,
  ) {
    final explicit = metadata['source_type']?.toString().trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    return switch (collection) {
      RagCollection.labs => 'lab_value',
      RagCollection.symptoms => 'symptom',
      RagCollection.checkins => 'check_in',
      RagCollection.procedures => 'procedure',
      RagCollection.medications => 'medication',
      RagCollection.healthSync => 'apple_health_sync',
      RagCollection.giExports => 'gi_export',
      _ => 'intake_event',
    };
  }

  String? _firstNonEmptyString(
    Object? first, [
    Object? second,
    Object? third,
    Object? fourth,
    Object? fifth,
    Object? sixth,
  ]) {
    for (final value in [first, second, third, fourth, fifth, sixth]) {
      final text = value?.toString().trim();
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
  }

  List<RagMemoryTransactionRecord> _dedupeRagTransactions(
    List<RagMemoryTransactionRecord> transactions,
  ) {
    final ordered = transactions.toList(growable: false)
      ..sort((a, b) {
        final statusCompare = _ragStatusRank(
          b.status,
        ).compareTo(_ragStatusRank(a.status));
        if (statusCompare != 0) return statusCompare;
        final aTs = a.indexedAt ?? a.verifiedAt ?? a.createdAt;
        final bTs = b.indexedAt ?? b.verifiedAt ?? b.createdAt;
        return bTs.compareTo(aTs);
      });
    final byKey = <String, RagMemoryTransactionRecord>{};
    for (final tx in ordered) {
      byKey.putIfAbsent(_ragDedupeKey(tx), () => tx);
    }
    final deduped = byKey.values.toList(growable: false)
      ..sort((a, b) {
        final aTs = a.indexedAt ?? a.verifiedAt ?? a.createdAt;
        final bTs = b.indexedAt ?? b.verifiedAt ?? b.createdAt;
        return bTs.compareTo(aTs);
      });
    return deduped;
  }

  String _ragDedupeKey(RagMemoryTransactionRecord tx) {
    final sourceId = tx.sourceId.trim();
    if (sourceId.isNotEmpty) return '${tx.sourceType}|source_id|$sourceId';
    final textHash = tx.textHash.trim();
    if (textHash.isNotEmpty) return '${tx.sourceType}|text_hash|$textHash';
    return '${tx.sourceType}|chunk_id|${tx.chunkId}';
  }

  int _ragStatusRank(String status) {
    return switch (status) {
      'loaded_in_rag' => 3,
      'written_to_corpus' => 2,
      'verified' => 1,
      _ => 0,
    };
  }

  List<Map<String, Object?>> _structuredRagFallbackSnippets({
    required Set<String> allowedSourceTypes,
    required Map<String, Object?> grounding,
    required int limit,
  }) {
    if (limit <= 0) return const [];
    final snippets = <Map<String, Object?>>[];
    void add({
      required String sourceType,
      required String sourceId,
      required String text,
    }) {
      if (snippets.length >= limit) return;
      if (!allowedSourceTypes.contains(sourceType)) return;
      final trimmed = text.trim();
      if (trimmed.isEmpty) return;
      snippets.add({
        'transaction_id': 'structured_fallback_${sourceType}_$sourceId',
        'source_type': 'structured_${sourceType}_fallback',
        'source_id': sourceId,
        'status': 'structured_db_fallback',
        'snippet_source': 'structured_db',
        'snippet': _clip(trimmed, 320),
      });
    }

    final symptoms = (grounding['recent_symptoms'] as List?) ?? const [];
    for (final raw in symptoms) {
      if (raw is! Map) continue;
      add(
        sourceType: 'symptom',
        sourceId: '${raw['id'] ?? raw['logged_at'] ?? snippets.length}',
        text: [
          'Saved symptom',
          if (raw['logged_at'] != null) 'Logged: ${raw['logged_at']}',
          if (raw['symptom_type'] != null) 'Type: ${raw['symptom_type']}',
          if (raw['severity'] != null) 'Severity: ${raw['severity']}',
          if (raw['meal_relation'] != null)
            'Meal relation: ${raw['meal_relation']}',
          if (raw['notes'] != null) 'Notes: ${raw['notes']}',
        ].join('\n'),
      );
    }

    final labs = (grounding['lab_results'] as List?) ?? const [];
    for (final raw in labs) {
      if (raw is! Map) continue;
      add(
        sourceType: 'lab_value',
        sourceId: '${raw['drawn_date'] ?? ''}:${raw['lab_type'] ?? ''}',
        text: [
          'Saved lab result',
          if (raw['drawn_date'] != null) 'Drawn: ${raw['drawn_date']}',
          if (raw['lab_label'] != null) 'Lab: ${raw['lab_label']}',
          if (raw['value'] != null)
            'Value: ${raw['value']} ${raw['unit'] ?? ''}',
          if (raw['elevated'] != null) 'Elevated: ${raw['elevated']}',
        ].join('\n'),
      );
    }

    final checkins = (grounding['recent_pro2_surveys'] as List?) ?? const [];
    for (final raw in checkins) {
      if (raw is! Map) continue;
      add(
        sourceType: allowedSourceTypes.contains('pro2_survey')
            ? 'pro2_survey'
            : 'check_in',
        sourceId: '${raw['survey_date'] ?? snippets.length}',
        text: 'Saved check-in: ${jsonEncode(raw)}',
      );
    }

    final score = grounding['latest_score'];
    if (score is Map) {
      add(
        sourceType: 'flare_risk_score',
        sourceId: '${score['date_local'] ?? 'latest'}',
        text:
            'Saved flare-risk snapshot: ${score['date_local'] ?? 'latest'}, score ${score['risk_score']}, band ${score['risk_band']}, confidence ${score['confidence_score']}.',
      );
    }

    final outlook = grounding['early_warning_outlook'];
    if (outlook is Map && outlook.isNotEmpty) {
      add(
        sourceType: 'apple_health_sync',
        sourceId: 'early_warning_outlook',
        text: 'Saved Apple Health/risk outlook: ${jsonEncode(outlook)}',
      );
    }

    return snippets;
  }

  Set<String> _ragSourceTypesForContext({
    required String intent,
    required _ChatTaskContract taskContract,
  }) {
    if (taskContract == _ChatTaskContract.labRecall ||
        taskContract == _ChatTaskContract.labGemmaExplain ||
        intent == 'lab_question') {
      return const {'lab_value'};
    }
    if (taskContract == _ChatTaskContract.symptomList ||
        taskContract == _ChatTaskContract.foodTrigger ||
        intent == 'symptom_question' ||
        intent == 'symptom_log_followup' ||
        intent == 'multi_symptom_log') {
      return const {'symptom', 'intake_event'};
    }
    if (intent == 'check_in_log') {
      return const {'pro2_survey', 'check_in'};
    }
    if (taskContract == _ChatTaskContract.healthSummary ||
        taskContract == _ChatTaskContract.forecastWatchlist ||
        taskContract == _ChatTaskContract.doctorSummary ||
        taskContract == _ChatTaskContract.prepForVisit ||
        taskContract == _ChatTaskContract.activityPattern ||
        taskContract == _ChatTaskContract.hrvTrend ||
        taskContract == _ChatTaskContract.medicationNote ||
        intent == 'risk_question' ||
        intent == 'daily_summary' ||
        intent == 'week_summary' ||
        intent == 'general_health_question' ||
        intent == 'continuation' ||
        intent == 'followup_expand' ||
        intent == 'followup_compare') {
      return const {
        'symptom',
        'pro2_survey',
        'check_in',
        'lab_value',
        'flare_risk_score',
        'apple_health_sync',
        'intake_event',
        'procedure',
        'gi_export',
      };
    }
    return const {
      'symptom',
      'pro2_survey',
      'check_in',
      'lab_value',
      'intake_event',
    };
  }

  bool _isRagStatusReadable(String status) {
    return status == 'verified' ||
        status == 'written_to_corpus' ||
        status == 'loaded_in_rag';
  }

  LabValueRecord _selectLatestLab(List<LabValueRecord> labs) {
    final sorted = [...labs];
    sorted.sort((left, right) {
      final leftDate = DateTime.tryParse('${left.drawnDate}T23:59:59Z') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      final rightDate = DateTime.tryParse('${right.drawnDate}T23:59:59Z') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      final dateCmp = rightDate.compareTo(leftDate);
      if (dateCmp != 0) return dateCmp;
      return right.updatedAt.compareTo(left.updatedAt);
    });
    return sorted.first;
  }

  List<Map<String, Object?>> _compactListOfMaps(
    Object? value, {
    required List<String> keys,
    required int limit,
  }) {
    if (value is! List) return const [];
    return value.take(limit).whereType<Map>().map((item) {
      final mapped = <String, Object?>{};
      for (final key in keys) {
        final raw = item[key];
        if (raw is String) {
          mapped[key] = _clip(raw, 160);
        } else if (raw != null) {
          mapped[key] = raw;
        }
      }
      return mapped;
    }).toList(growable: false);
  }

  String? _firstString(Object? first, Object? second) {
    if (first is String && first.trim().isNotEmpty) return _clip(first, 160);
    if (second is String && second.trim().isNotEmpty) return _clip(second, 160);
    return null;
  }

  /// Keys whose list values are preserved at their full length when compacting
  /// the grounding payload. The conversation history is already capped at 20
  /// at the DB layer and is consumed by downstream renderers/tests that depend
  /// on the full window; truncating to 6 here would silently drop context.
  static const Set<String> _preserveFullListKeys = {
    'recent_conversation_turns',
  };

  Map<String, Object?> _compactGrounding(Map<String, Object?> value) {
    Object? compact(Object? input) {
      if (input is List) {
        return input.take(6).map(compact).toList(growable: false);
      }
      if (input is Map) {
        return input.map(
          (key, item) => MapEntry(key.toString(), compact(item)),
        );
      }
      if (input is String && input.length > 420) {
        return '${input.substring(0, 420)}...';
      }
      return input;
    }

    return value.map((key, item) {
      // Preserve full-length lists for whitelisted keys; still recursively
      // compact their elements so per-item strings stay under the 420-char cap.
      if (_preserveFullListKeys.contains(key) && item is List) {
        return MapEntry(key, item.map(compact).toList(growable: false));
      }
      return MapEntry(key, compact(item));
    });
  }

  // ── GI Summary date collection helpers ──────────────────────────────────────

  static const _kGiDatePromptMessage =
      'What date range would you like for your GI summary?\n\n'
      'Type or say dates like: **May 1, 2026 to May 15, 2026**\n\n'
      'Quick options:\n'
      '• **last 30 days** — default window\n'
      '• **all** — everything in your history\n'
      '• **cancel** — stop without generating\n\n'
      'You can also say a relative range like **last 90 days**.';

  Future<LocalAgentReply> _giSummaryDatePromptReply({
    required String userMessage,
    required DateTime now,
  }) async {
    const message = _kGiDatePromptMessage;
    final trace = <String, Object?>{
      'agent_intent': 'doctor_summary',
      'intent_raw': userMessage,
      'intent_normalized': 'doctor_summary',
      'used_model_output': false,
      'deterministic_fast_path_used': true,
      'chat_path': 'gi_summary_date_prompt',
      'asked_at': now.toIso8601String(),
    };
    await _repository.insertConversation(
      ConversationRecord(
        createdAt: _nowProvider(),
        userMessage: userMessage,
        assistantMessage: message,
        toolTraceJson: trace,
        groundedSummaryJson: const {},
      ),
    );
    _recordSessionTurn(
      userMessage: userMessage,
      assistantMessage: message,
      intent: 'doctor_summary',
      usedModelOutput: false,
      activeRuntimeProfile: _sessionState?.activeRuntimeProfile,
      activeTopic: 'doctor_summary',
      awaitingGiSummaryDates: true,
    );
    return LocalAgentReply(
      status: 'gi_summary_awaiting_dates',
      message: message,
      runtimeName: 'deterministic',
      toolTraceJson: trace,
      groundedSummaryJson: const {},
    );
  }

  Future<LocalAgentReply> _giSummaryCancelledReply({
    required String userMessage,
    required DateTime now,
  }) async {
    const message = 'Cancelled. No GI summary was generated.';
    final trace = <String, Object?>{
      'agent_intent': 'doctor_summary',
      'intent_raw': userMessage,
      'intent_normalized': 'doctor_summary_cancelled',
      'used_model_output': false,
      'deterministic_fast_path_used': true,
      'chat_path': 'gi_summary_cancelled',
      'asked_at': now.toIso8601String(),
    };
    await _repository.insertConversation(
      ConversationRecord(
        createdAt: _nowProvider(),
        userMessage: userMessage,
        assistantMessage: message,
        toolTraceJson: trace,
        groundedSummaryJson: const {},
      ),
    );
    _recordSessionTurn(
      userMessage: userMessage,
      assistantMessage: message,
      intent: 'doctor_summary',
      usedModelOutput: false,
      activeRuntimeProfile: _sessionState?.activeRuntimeProfile,
      activeTopic: null,
      awaitingGiSummaryDates: false,
    );
    return LocalAgentReply(
      status: 'gi_summary_cancelled',
      message: message,
      runtimeName: 'deterministic',
      toolTraceJson: trace,
      groundedSummaryJson: const {},
    );
  }

  Future<LocalAgentReply> _giSummaryDateRetryReply({
    required String userMessage,
    required DateTime now,
  }) async {
    const message = "I couldn't recognise those dates. Please try again.\n\n"
        'Format: **May 1, 2026 to May 15, 2026**\n\n'
        'Or say: **all** • **last 30 days** • **cancel**';
    final trace = <String, Object?>{
      'agent_intent': 'doctor_summary',
      'intent_raw': userMessage,
      'intent_normalized': 'doctor_summary_date_retry',
      'used_model_output': false,
      'deterministic_fast_path_used': true,
      'chat_path': 'gi_summary_date_retry',
      'asked_at': now.toIso8601String(),
    };
    await _repository.insertConversation(
      ConversationRecord(
        createdAt: _nowProvider(),
        userMessage: userMessage,
        assistantMessage: message,
        toolTraceJson: trace,
        groundedSummaryJson: const {},
      ),
    );
    _recordSessionTurn(
      userMessage: userMessage,
      assistantMessage: message,
      intent: 'doctor_summary',
      usedModelOutput: false,
      activeRuntimeProfile: _sessionState?.activeRuntimeProfile,
      activeTopic: 'doctor_summary',
      awaitingGiSummaryDates: true,
    );
    return LocalAgentReply(
      status: 'gi_summary_date_retry',
      message: message,
      runtimeName: 'deterministic',
      toolTraceJson: trace,
      groundedSummaryJson: const {},
    );
  }

  bool _isGiSummaryAllRequest(String lower) {
    final n = _normalizeIntentText(lower);
    return n == 'all' ||
        n == 'all dates' ||
        n == 'all data' ||
        n == 'all my data' ||
        n == 'all my dates' ||
        n.contains('all dates') ||
        n.contains('all my data') ||
        n.contains('full history') ||
        n.contains('entire history') ||
        n.contains('all history') ||
        n.contains('everything');
  }

  bool _isGiSummaryDefaultRequest(String lower) {
    final n = _normalizeIntentText(lower);
    return n == 'default' ||
        n == 'last 30 days' ||
        n == '30 days' ||
        n.contains('last 30 days') ||
        n.contains('default range') ||
        n.contains('default window') ||
        n.contains('past 30 days') ||
        n.contains('past month');
  }

  /// Parses a natural-language date range like "May 1, 2026 to May 15, 2026"
  /// or "last 90 days" from user input. Returns (start, end) or null.
  (DateTime, DateTime)? _parseGiDateRange(String text, DateTime now) {
    final lower = text.toLowerCase().trim();
    final today = DateTime(now.year, now.month, now.day);

    // "last N days" relative range
    final lastNMatch = RegExp(r'\blast\s+(\d+)\s+days?\b').firstMatch(lower);
    if (lastNMatch != null) {
      final n = int.tryParse(lastNMatch.group(1)!);
      if (n != null && n > 0 && n <= 3650) {
        return (today.subtract(Duration(days: n - 1)), today);
      }
    }

    // Normalize ordinal words before splitting (handles spoken dates)
    var normalized = _normalizeOrdinalWords(lower);
    // Strip leading prepositions
    normalized = normalized
        .replaceAll(RegExp(r'\b(from|between|starting|ending)\b'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // Split on "to", "through", "thru", " - ", " – "
    final splitPattern =
        RegExp(r'\s+to\s+|\s+through\s+|\s+thru\s+|\s*[–-]\s*(?=[a-z])');
    final parts = normalized.split(splitPattern);
    if (parts.length < 2) return null;

    final startText = parts.first.trim();
    final endText = parts.sublist(1).join(' to ').trim();

    final start = _parseSingleDate(startText, now);
    final end = _parseSingleDate(endText, now);
    if (start == null || end == null) return null;

    // Swap if user said them backwards
    return start.isAfter(end) ? (end, start) : (start, end);
  }

  DateTime? _parseSingleDate(String text, DateTime now) {
    final s = text.trim().toLowerCase();
    if (s.isEmpty) return null;
    final currentYear = now.year;

    // ISO: 2026-05-01
    if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) {
      return DateTime.tryParse(s);
    }

    // Slash: MM/DD/YYYY or MM/DD/YY
    final slash = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{2,4})$').firstMatch(s);
    if (slash != null) {
      final m = int.tryParse(slash.group(1)!);
      final d = int.tryParse(slash.group(2)!);
      var y = int.tryParse(slash.group(3)!);
      if (y != null && y < 100) y += 2000;
      return (m != null && d != null && y != null) ? _safeDate(y, m, d) : null;
    }

    // Month-first: "May 1, 2026" / "May 1st" / "May 1 2026"
    final mdy = RegExp(r'^([a-z]+)\s+(\d{1,2})(?:st|nd|rd|th)?,?\s*(\d{4})?$')
        .firstMatch(s);
    if (mdy != null) {
      final month = _monthNumber(mdy.group(1)!);
      final day = int.tryParse(mdy.group(2)!);
      final year = int.tryParse(mdy.group(3) ?? '') ?? currentYear;
      return (month != null && day != null)
          ? _safeDate(year, month, day)
          : null;
    }

    // Day-first: "1st May 2026" / "1 May"
    final dmy = RegExp(r'^(\d{1,2})(?:st|nd|rd|th)?\s+([a-z]+),?\s*(\d{4})?$')
        .firstMatch(s);
    if (dmy != null) {
      final day = int.tryParse(dmy.group(1)!);
      final month = _monthNumber(dmy.group(2)!);
      final year = int.tryParse(dmy.group(3) ?? '') ?? currentYear;
      return (month != null && day != null)
          ? _safeDate(year, month, day)
          : null;
    }

    return null;
  }

  static int? _monthNumber(String name) => const {
        'january': 1,
        'jan': 1,
        'february': 2,
        'feb': 2,
        'march': 3,
        'mar': 3,
        'april': 4,
        'apr': 4,
        'may': 5,
        'june': 6,
        'jun': 6,
        'july': 7,
        'jul': 7,
        'august': 8,
        'aug': 8,
        'september': 9,
        'sep': 9,
        'sept': 9,
        'october': 10,
        'oct': 10,
        'november': 11,
        'nov': 11,
        'december': 12,
        'dec': 12,
      }[name];

  static DateTime? _safeDate(int year, int month, int day) {
    if (month < 1 || month > 12) return null;
    if (day < 1 || day > 31) return null;
    if (year < 2020 || year > 2100) return null;
    try {
      final d = DateTime(year, month, day);
      // DateTime constructor silently overflows (e.g. Feb 31 → Mar 3)
      return (d.month == month && d.day == day) ? d : null;
    } catch (_) {
      return null;
    }
  }

  static String _normalizeOrdinalWords(String text) {
    const ordinals = {
      r'\bfirst\b': '1',
      r'\bsecond\b': '2',
      r'\bthird\b': '3',
      r'\bfourth\b': '4',
      r'\bfifth\b': '5',
      r'\bsixth\b': '6',
      r'\bseventh\b': '7',
      r'\beighth\b': '8',
      r'\bninth\b': '9',
      r'\btenth\b': '10',
      r'\beleventh\b': '11',
      r'\btwelfth\b': '12',
      r'\bthirteenth\b': '13',
      r'\bfourteenth\b': '14',
      r'\bfifteenth\b': '15',
      r'\bsixteenth\b': '16',
      r'\bseventeenth\b': '17',
      r'\beighteenth\b': '18',
      r'\bnineteenth\b': '19',
      r'\btwentieth\b': '20',
      r'\btwenty[- ]first\b': '21',
      r'\btwenty[- ]second\b': '22',
      r'\btwenty[- ]third\b': '23',
      r'\btwenty[- ]fourth\b': '24',
      r'\btwenty[- ]fifth\b': '25',
      r'\btwenty[- ]sixth\b': '26',
      r'\btwenty[- ]seventh\b': '27',
      r'\btwenty[- ]eighth\b': '28',
      r'\btwenty[- ]ninth\b': '29',
      r'\bthirtieth\b': '30',
      r'\bthirty[- ]first\b': '31',
    };
    var result = text;
    for (final entry in ordinals.entries) {
      result = result.replaceAll(RegExp(entry.key), entry.value);
    }
    return result;
  }

  String _shortDate(DateTime dt) {
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  String _clip(String value, int maxChars) {
    final trimmed = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (trimmed.length <= maxChars) return trimmed;
    return '${trimmed.substring(0, maxChars)}...';
  }

  // Cap rolling session summary to ~300 tokens (~1200 chars) to keep prefill
  // cost bounded. Older turns are already in the session summary; cutting here
  // trades detail for meaningfully faster CPU prefill.
  Object? _clipSessionSummary(Object? raw) {
    if (raw is! String) return raw;
    final trimmed = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (trimmed.length <= 1200) return trimmed;
    return '${trimmed.substring(0, 1200)}...';
  }

  String? _interpretScoreMap(Map<String, Object?> scoreMap) {
    if (scoreMap.isEmpty) return null;
    final band = (scoreMap['risk_band'] as String? ?? '').toLowerCase();
    final s = (scoreMap['risk_score'] as num? ?? 0).round();
    if (band.isEmpty) return null;
    return switch (band) {
      'low' =>
        'Score $s/100 (low) — things look relatively calm based on your recent data.',
      'moderate' =>
        'Score $s/100 (moderate) — some signals are a bit off from your usual baseline. Worth keeping an eye on.',
      'high' =>
        'Score $s/100 (high) — several signals are flagged compared to your recent baseline. Pay attention to how you are feeling.',
      _ => 'Score $s/100 ($band).',
    };
  }

  String? _interpretConfidenceMap(Map<String, Object?> scoreMap) {
    final conf = (scoreMap['confidence_score'] as num? ?? -1).round();
    if (conf < 0) return null;
    final contributions = scoreMap['contributions'];
    final rawInputs =
        contributions is Map ? contributions['confidence_inputs'] : null;
    final inputs =
        rawInputs is Map ? Map<String, Object?>.from(rawInputs) : null;
    final available =
        (inputs?['available_metric_families'] as num?)?.round() ?? 0;
    final stale = inputs?['stale_sync'] == true;
    final level = conf >= 70
        ? 'fairly confident'
        : conf >= 40
            ? 'somewhat confident'
            : 'not very confident yet';
    final parts = <String>[];
    if (available > 0 && available < 3) {
      parts.add('only $available of 5 data sources available');
    }
    if (stale) parts.add('some data has not synced recently');
    if (conf < 40) parts.add('more daily check-ins would help');
    final why = parts.isEmpty ? '' : ' Because: ${parts.join('; ')}.';
    return 'Confidence $conf/100 — the app is $level in this estimate.$why';
  }

  String _dataQualitySummary(Map<String, Object?> grounding) {
    final parts = <String>[];
    final symptoms = grounding['recent_symptoms'];
    final labs = grounding['lab_results'];
    final checkins = grounding['recent_pro2_surveys'];
    if (symptoms is List && symptoms.isEmpty) {
      parts.add('no recent symptom logs');
    }
    if (labs is List && labs.isEmpty) parts.add('no lab results on file');
    if (checkins is List && checkins.isEmpty) parts.add('no recent check-ins');
    if (parts.isEmpty) {
      return 'Data coverage looks reasonable for generating insights.';
    }
    return 'Currently missing: ${parts.join(', ')}. Adding these would improve accuracy.';
  }

  String _plainBandPhrase(String band) {
    return switch (band.toLowerCase()) {
      'low' => 'things look relatively calm based on your recent data',
      'moderate' => 'some signals are a bit off from your usual baseline',
      'high' => 'several signals are flagged — worth watching closely',
      _ => 'sitting in the $band range',
    };
  }

  String _riskHorizonInterpretation(
    FlareRiskScoreRecord latestScore, {
    required Map<String, Object?> readyOutlook,
  }) {
    final p7 = _outlookProbability(readyOutlook) ??
        _riskProbabilityFromSnapshot(latestScore, 'logistic_p_flare_7d');
    final p14 = _riskProbabilityFromSnapshot(
      latestScore,
      'logistic_p_flare_14d',
    );
    final p21 = _riskProbabilityFromSnapshot(
      latestScore,
      'logistic_p_flare_21d',
    );
    final segments = <String>[
      'Interpretation: this is the estimated chance of entering a flare-like window over about the next 7 days (${((p7 ?? 0) * 100).round()}%).',
    ];
    if (p14 != null || p21 != null) {
      final outlook = <String>[];
      if (p14 != null) outlook.add('14d ${(p14 * 100).round()}%');
      if (p21 != null) outlook.add('21d ${(p21 * 100).round()}%');
      segments.add('Longer horizon outlook: ${outlook.join(', ')}.');
    }
    return segments.join(' ');
  }

  Map<String, Object?> _globalFlareRiskState({
    required FlareRiskScoreRecord? latestScore,
    required List<Map<String, Object?>> outlook,
  }) {
    final ready7d = _readyUserFacingRiskPoint(
      latestScore: latestScore,
      outlook: outlook,
      horizonDays: 7,
    );
    if (ready7d == null) {
      return {
        'status': 'learning',
        'date_local': latestScore?.dateLocal,
        'horizon_days': 7,
        'user_facing_probability': null,
        'display_text': 'Learning',
        'source_table': latestScore == null ? null : 'flare_risk_scores',
        'internal_signal_index_available': latestScore != null,
      };
    }
    return {
      'status': 'ready',
      'date_local': latestScore?.dateLocal,
      'horizon_days': 7,
      'user_facing_probability': _outlookProbability(ready7d),
      'display_text': _outlookPercentText(ready7d),
      'band': ready7d['band'],
      'training_samples': ready7d['training_samples'],
      'source_table': latestScore == null ? null : 'flare_risk_scores',
      'internal_signal_index': latestScore?.riskScore.round(),
    };
  }

  Map<String, Object?>? _readyOutlookPoint(
    List<Map<String, Object?>> outlook, {
    required int horizonDays,
  }) {
    for (final point in outlook) {
      final horizon = (point['horizon_days'] as num?)?.toInt();
      final status = point['status']?.toString();
      final probability = _outlookProbability(point);
      if (horizon == horizonDays && status == 'ready' && probability != null) {
        return point;
      }
    }
    return null;
  }

  Map<String, Object?>? _readyUserFacingRiskPoint({
    required FlareRiskScoreRecord? latestScore,
    required List<Map<String, Object?>> outlook,
    required int horizonDays,
  }) {
    final snapshotPoint = _readyUserFacingRiskPointFromSnapshot(
      latestScore,
      horizonDays: horizonDays,
    );
    if (snapshotPoint != null) {
      return snapshotPoint;
    }
    return _readyOutlookPoint(outlook, horizonDays: horizonDays);
  }

  Map<String, Object?>? _readyUserFacingRiskPointFromSnapshot(
    FlareRiskScoreRecord? latestScore, {
    required int horizonDays,
  }) {
    if (latestScore == null) {
      return null;
    }
    final snapshot = latestScore.featureSnapshotJson;
    final coldStart =
        ((snapshot['logistic_${horizonDays}d_cold_start'] as num?) ?? 0)
            .toInt();
    final probability = _riskProbabilityFromSnapshot(
      latestScore,
      'logistic_p_flare_${horizonDays}d',
    );
    if (coldStart == 1 || probability == null) {
      return null;
    }
    return {
      'horizon_days': horizonDays,
      'label': _horizonLabel(horizonDays),
      'probability': double.parse(probability.toStringAsFixed(3)),
      'band': _probabilityBand(probability),
      'status': 'ready',
      'source': 'latest_score_snapshot',
    };
  }

  double? _outlookProbability(Map<String, Object?> outlook) {
    final raw = outlook['probability'];
    final value = (raw as num?)?.toDouble();
    if (value == null) return null;
    return value.clamp(0.0, 1.0);
  }

  String _outlookPercentText(Map<String, Object?> outlook) {
    final probability = _outlookProbability(outlook) ?? 0;
    return '${(probability * 100).round()}%';
  }

  // Returns the user-facing flare risk display value — the same string shown
  // on the UI home screen. Returns "Learning" when the outlook is not ready,
  // or "X%" when ready. Use this everywhere a score is surfaced in chat to
  // guarantee chat and UI are always consistent.
  String _flareRiskDisplay(Map<String, Object?>? ready7dOutlook) {
    if (ready7dOutlook == null) return 'Learning';
    return _outlookPercentText(ready7dOutlook);
  }

  String _learningFlareRiskReply({
    required bool hasSignalIndex,
    required String driverText,
    required String contextText,
  }) {
    final signalText = hasSignalIndex
        ? ' I do see early local signal data, but I will not present the internal signal index as a flare percentage.'
        : '';
    final driverSentence = driverText == 'no strong signals'
        ? ''
        : ' Early signals to keep logging: $driverText.';
    final contextSentence = contextText.trim().isEmpty ? '' : ' $contextText';
    return 'Your current flare-risk estimate is Learning.$signalText Gemma Flares needs enough personal history before showing a 7-day percentage.$driverSentence$contextSentence Keep watch data synced and log check-ins; this is a local estimate, not a diagnosis.';
  }

  String _readyFlareRiskReply({
    required Map<String, Object?> outlook,
    required int confidence,
    required String driverText,
    required String contextText,
    required String horizonText,
  }) {
    final band = outlook['band']?.toString() ?? 'unknown';
    return 'Your current 7-day flare risk is ${_outlookPercentText(outlook)} ($band), confidence $confidence/100. $horizonText The main signals driving it right now: $driverText. $contextText This is a local estimate — not a diagnosis.';
  }

  double? _riskProbabilityFromSnapshot(FlareRiskScoreRecord score, String key) {
    final raw = score.featureSnapshotJson[key];
    final value = (raw as num?)?.toDouble();
    if (value == null) return null;
    return value.clamp(0.0, 1.0);
  }

  bool _requiresSafetyNotice(String userMessage) {
    final lower = userMessage.toLowerCase();
    if (_isGreeting(lower)) {
      return false;
    }
    if (lower.contains('how am i')) {
      return true;
    }
    return _containsHealthTerms(lower);
  }

  bool _containsHealthTerms(String text) {
    final lower = _normalizeIntentText(text).toLowerCase();
    // 'sleep' requires word-boundary matching to avoid matching 'sleeping'
    // in non-health contexts (e.g. "my cat is sleeping").
    // Gerund forms like "sleeping all day" are covered by continuation signals.
    if (RegExp(r'\bsleep\b').hasMatch(lower)) return true;
    const healthTerms = [
      'risk',
      'score',
      'flare',
      'symptom',
      'headache',
      'migraine',
      'migrane',
      'pain',
      'stool',
      'bleeding',
      'hrv',
      'heart',
      'activity',
      'step',
      'lab',
      'crp',
      'esr',
      'calprotectin',
      'medicine',
      'medication',
      'doctor',
      'diagnosis',
      'diagnose',
      'inflammation',
      'gut',
      'ibd',
      'crohn',
      'colitis',
      'pattern',
      'baseline',
      'watch',
      'health',
      'nausea',
      'fatigue',
      'diarrhea',
      'bloating',
      'vomit',
      'fever',
      'urgency',
      'bowel',
      'joint',
      'dizzy',
      'dizziness',
      'lightheaded',
      'skin',
      'eye',
      'rash',
      'back pain',
      'urinary',
      'weight',
      'appetite',
      'dehydration',
      'remission',
      'biologic',
      'infusion',
      'injection',
      'prednisone',
      'steroid',
      'humira',
      'remicade',
      'stelara',
      'entyvio',
      'endoscopy',
      'colonoscopy',
      'biopsy',
      'ferritin',
      'hemoglobin',
      'albumin',
      'vitamin',
      'oxygen',
      'temperature',
      'wrist temp',
      'cramp',
      'surgery',
      'fistula',
      'abscess',
      'stricture',
      'obstruction',
      'mouth sore',
      'fissure',
      'malnutrition',
      'anemia',
      'constipat',
      'gas',
      'night sweat',
      'chills',
      'rectal',
      'perianal',
      'drainage',
      'tenesmus',
      'skyrizi',
      'rinvoq',
      'cimzia',
      'omvoh',
      'tremfya',
      'imuran',
      'pentasa',
      'jak inhibitor',
      'b12',
      'cough',
      'coughing',
      'sore throat',
      'throat pain',
      'congestion',
      'chest congestion',
      'runny nose',
      'shortness of breath',
      'breathless',
    ];
    return healthTerms.any(lower.contains);
  }

  /// Detects whether a message looks like a continuation of an ongoing symptom
  /// thread — trigger words ("after", "because of", "from") or frequency
  /// phrases ("X times", "all day"). Bare calendar words such as "today" or
  /// "yesterday" are intentionally not enough because they also appear in
  /// ordinary off-topic chatter during an active intake session.
  bool _containsSymptomContinuationSignals(String lower) {
    const triggerSignals = [
      'because of',
      'becausw of', // common typo
      'because',
      'after eating',
      'after drinking',
      'after',
      ' from ',
      ' due to ',
      'caused by',
      'trigger',
      'gluten',
      'dairy',
      'lactose',
      'coffee',
      'alcohol',
    ];
    const frequencySignals = [
      'times a day',
      'times this morning',
      'times today',
      'times yesterday',
      'times per day',
      'episodes',
      'all day',
      'all night',
      'all morning',
    ];
    // Numeric frequency: "5 times", "3 episodes", "twice"
    final hasNumericFrequency =
        RegExp(r'\b\d+\s*(?:times|episodes|x)\b').hasMatch(lower) ||
            lower.contains('twice') ||
            lower.contains('couple times');
    return triggerSignals.any(lower.contains) ||
        frequencySignals.any(lower.contains) ||
        hasNumericFrequency;
  }

  List<({String label, int points})> _driverContributions(
    Map<String, Object?> contributions,
  ) {
    const labels = {
      'hrv_points': 'lower heart rhythm variability',
      'resting_hr_points': 'higher resting heart rate',
      'sleep_points': 'reduced sleep',
      'symptom_points': 'recent symptoms',
      'steps_points': 'lower activity',
      'sparse_vitals_points': 'oxygen or temperature changes',
    };
    final drivers = <({String label, int points})>[];
    for (final entry in labels.entries) {
      final points = ((contributions[entry.key] as num?) ?? 0).round();
      if (points > 0) {
        drivers.add((label: entry.value, points: points));
      }
    }
    drivers.sort((left, right) => right.points.compareTo(left.points));
    return drivers;
  }

  String _stripRuntimeLoadingNotice(String text) {
    return text
        .replaceAll(
          RegExp(
            r'\n?\s*_?Gemma 4 is loading(?: in the background)?\s*(?:--|[-—])\s*full conversational analysis will be available shortly\._?\s*',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'\n?\s*_?Gemma 4 is loading in the background for full conversational answers\._?\s*',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
  }

  String _offsetDate(String dateStr, int days) {
    final date = DateTime.parse(
      '${dateStr}T00:00:00Z',
    ).add(Duration(days: days));
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  Map<String, Object?>? _buildHeartRhythmContext({
    required CosinorFeatureRecord? latestCosinor,
    required List<CosinorFeatureRecord> recentCosinor,
  }) {
    if (latestCosinor?.fitValid != true) {
      return null;
    }
    final baselineFits = recentCosinor
        .where((item) => item.fitValid)
        .where((item) => item.featureDate != latestCosinor!.featureDate)
        .toList(growable: false);
    final baselineMesor = _meanNullable(
      baselineFits.map((item) => item.mesor).whereType<double>(),
    );
    final baselineAmplitude = _meanNullable(
      baselineFits.map((item) => item.amplitude).whereType<double>(),
    );
    return {
      'mesor_ms': latestCosinor!.mesor == null
          ? null
          : double.parse(latestCosinor.mesor!.toStringAsFixed(1)),
      'amplitude_ms': latestCosinor.amplitude == null
          ? null
          : double.parse(latestCosinor.amplitude!.toStringAsFixed(1)),
      'peak_time_hours': latestCosinor.peakTimeHours == null
          ? null
          : double.parse(latestCosinor.peakTimeHours!.toStringAsFixed(1)),
      'r_squared': latestCosinor.rSquared == null
          ? null
          : double.parse(latestCosinor.rSquared!.toStringAsFixed(2)),
      'baseline_mesor_ms': baselineMesor == null
          ? null
          : double.parse(baselineMesor.toStringAsFixed(1)),
      'baseline_amplitude_ms': baselineAmplitude == null
          ? null
          : double.parse(baselineAmplitude.toStringAsFixed(1)),
      'mesor_delta_pct': baselineMesor == null ||
              latestCosinor.mesor == null ||
              baselineMesor == 0
          ? null
          : double.parse(
              (((latestCosinor.mesor! - baselineMesor) / baselineMesor) * 100)
                  .toStringAsFixed(1),
            ),
      'amplitude_delta_pct': baselineAmplitude == null ||
              latestCosinor.amplitude == null ||
              baselineAmplitude == 0
          ? null
          : double.parse(
              (((latestCosinor.amplitude! - baselineAmplitude) /
                          baselineAmplitude) *
                      100)
                  .toStringAsFixed(1),
            ),
    };
  }

  Map<String, Object?> _buildCheckInTrend(List<Pro2SurveyRecord> recentPro2) {
    final scores =
        recentPro2.map((item) => item.pro2Score).toList(growable: false);
    final cdPain =
        recentPro2.map((item) => item.cdAbdominalPain).whereType<int>();
    final cdStool =
        recentPro2.map((item) => item.cdStoolFrequency).whereType<int>();
    final ucBleeding =
        recentPro2.map((item) => item.ucRectalBleeding).whereType<int>();
    final ucStool =
        recentPro2.map((item) => item.ucStoolFrequency).whereType<int>();
    return {
      'count': recentPro2.length,
      'average_score': _meanNullable(scores),
      'average_cd_pain': _meanNullable(cdPain.map((value) => value.toDouble())),
      'average_cd_stool': _meanNullable(
        cdStool.map((value) => value.toDouble()),
      ),
      'average_uc_bleeding': _meanNullable(
        ucBleeding.map((value) => value.toDouble()),
      ),
      'average_uc_stool': _meanNullable(
        ucStool.map((value) => value.toDouble()),
      ),
      'surveys': recentPro2
          .map(
            (item) => {
              'date': item.surveyDate,
              'score': item.pro2Score,
              'is_flare': item.isFlare,
            },
          )
          .toList(growable: false),
    };
  }

  List<Map<String, Object?>> _buildOutlook({
    required List<LogisticModelStateRecord> modelStates,
    required DailyFeatureRecord? todayFeatures,
  }) {
    if (todayFeatures == null || modelStates.isEmpty) {
      return const [];
    }
    final numericFeatures = LogisticRiskService.extractFromRiskFeatures(
      todayFeatures.featureJson,
    );
    final outlook = <Map<String, Object?>>[];
    for (final horizon in LogisticRiskService.horizons) {
      final inflammatoryState = modelStates
          .where(
            (item) =>
                item.horizonDays == horizon && item.flareType == 'inflammatory',
          )
          .firstOrNull;
      final symptomaticState = modelStates
          .where(
            (item) =>
                item.horizonDays == horizon && item.flareType == 'symptomatic',
          )
          .firstOrNull;
      final inflammatoryProb = inflammatoryState != null &&
              inflammatoryState.trainingSamples >=
                  LogisticPrediction.minimumTrainingSamples
          ? LogisticRiskService.displayProbabilityFromLogit(
              _dotProduct(inflammatoryState.coefficientsJson, numericFeatures) +
                  inflammatoryState.intercept,
            )
          : null;
      final symptomaticProb = symptomaticState != null &&
              symptomaticState.trainingSamples >=
                  LogisticPrediction.minimumTrainingSamples
          ? LogisticRiskService.displayProbabilityFromLogit(
              _dotProduct(symptomaticState.coefficientsJson, numericFeatures) +
                  symptomaticState.intercept,
            )
          : null;
      if (inflammatoryProb == null && symptomaticProb == null) {
        continue;
      }
      final trainingSamples = math.max(
        inflammatoryState?.trainingSamples ?? 0,
        symptomaticState?.trainingSamples ?? 0,
      );
      final combined = (inflammatoryProb ?? 0) > (symptomaticProb ?? 0)
          ? (inflammatoryProb ?? 0)
          : (symptomaticProb ?? 0);
      final calibrated = LogisticRiskService.calibrateDisplayProbability(
        rawProbability: combined,
        trainingSamples: trainingSamples,
      );
      outlook.add({
        'horizon_days': horizon,
        'label': _horizonLabel(horizon),
        'probability': double.parse(calibrated.toStringAsFixed(3)),
        'band': _probabilityBand(calibrated),
        'status': LogisticRiskService.shouldUseLearningState(trainingSamples)
            ? 'learning'
            : 'ready',
        'training_samples': trainingSamples,
        'inflammatory_probability': inflammatoryProb == null
            ? null
            : double.parse(inflammatoryProb.toStringAsFixed(3)),
        'symptomatic_probability': symptomaticProb == null
            ? null
            : double.parse(symptomaticProb.toStringAsFixed(3)),
      });
    }
    return outlook;
  }

  double _dotProduct(
    Map<String, double> weights,
    Map<String, double> features,
  ) {
    var sum = 0.0;
    for (final entry in weights.entries) {
      sum += entry.value * (features[entry.key] ?? 0);
    }
    return sum;
  }

  double? _meanNullable(Iterable<double> values) {
    final list = values.toList(growable: false);
    if (list.isEmpty) {
      return null;
    }
    return list.fold<double>(0, (sum, value) => sum + value) / list.length;
  }

  String _horizonLabel(int horizon) {
    switch (horizon) {
      case 7:
        return 'Next 7 days';
      case 14:
        return 'Next 2 weeks';
      case 21:
        return 'Next 3 weeks';
      case 28:
        return 'Next 4 weeks';
      case 35:
        return 'Next 5 weeks';
      case 42:
        return 'Next 6 weeks';
      case 49:
        return 'Next 7 weeks';
      default:
        return 'Next $horizon days';
    }
  }

  String _probabilityBand(double probability) {
    if (probability >= 0.5) {
      return 'high';
    }
    if (probability >= 0.3) {
      return 'elevated';
    }
    if (probability >= 0.15) {
      return 'moderate';
    }
    return 'low';
  }

  String _procedureSummary(EndoscopyRecord record) {
    if (record.sesCdScore != null) {
      return 'SES-CD ${record.sesCdScore}';
    }
    if (record.mayoEndoscopicScore != null) {
      return 'Mayo ${record.mayoEndoscopicScore}';
    }
    if (record.biopsyResult == 'active_inflammation') {
      return 'Biopsy showed active inflammation';
    }
    return 'Procedure recorded';
  }

  String _labDisplayName(String labType) {
    switch (labType) {
      case 'crp':
        return 'C-Reactive Protein (CRP)';
      case 'esr':
        return 'Sedimentation Rate (ESR)';
      case 'fc':
      case 'fecal_calprotectin':
        return 'Fecal Calprotectin';
      case 'lactoferrin':
        return 'Lactoferrin';
      case 'hemoglobin':
        return 'Hemoglobin';
      case 'wbc':
        return 'White blood cells';
      case 'albumin':
        return 'Albumin';
      case 'vitamin_d':
        return 'Vitamin D';
      case 'ferritin':
        return 'Ferritin';
      case 'b12':
        return 'Vitamin B12';
      default:
        return labType.toUpperCase();
    }
  }
}

class ChatOutputSanitizerReport {
  const ChatOutputSanitizerReport({
    required this.cleanedText,
    required this.status,
    required this.reason,
    required this.sanitizerVersion,
  });

  final String cleanedText;
  final String status;
  final String reason;
  final String sanitizerVersion;
}

class ChatOutputSanitizer {
  const ChatOutputSanitizer._();

  static const sanitizerVersion = 'dart_chat_output_v2';

  static ChatOutputSanitizerReport inspect(
    String text, {
    required String userMessage,
    String? intent,
    LocalModelResponse? response,
    Map<String, Object?>? grounding,
  }) {
    final cleaned = clean(text);
    final reason = _rejectionReason(
      cleaned,
      original: text,
      userMessage: userMessage,
      intent: intent,
      response: response,
      grounding: grounding,
    );
    return ChatOutputSanitizerReport(
      cleanedText: reason == null ? cleaned : '',
      status: reason == null ? 'accepted' : 'rejected',
      reason: reason ?? 'passed_dart_quality_gate',
      sanitizerVersion: sanitizerVersion,
    );
  }

  static String clean(String text) {
    var value = text
        .replaceAll('\u0000', '')
        .replaceAll('\uFFFD', '')
        .replaceAll(
          RegExp(
            r'<\|tool_(call|response)\|>.*',
            caseSensitive: false,
            dotAll: true,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'<\|channel\|>.*?(<\|end\|>|$)',
            caseSensitive: false,
            dotAll: true,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'<channel>.*?(</channel>|$)',
            caseSensitive: false,
            dotAll: true,
          ),
          '',
        )
        .replaceAll(RegExp(r'</?s?html[^>]*>', caseSensitive: false), '')
        .replaceAll(
          RegExp(
            r'<start_of_turn>|<end_of_turn>|<bos>|<eos>',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'<\|system\|>|<\|user\|>|<\|assistant\|>|<\|im_start\|>|<\|im_end\|>',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'\[/?INST\]|<</?sys>>', caseSensitive: false), '')
        .replaceAll(
          RegExp(
            r'(^|\n)\s*(system|user|model|assistant)\s*\n',
            caseSensitive: false,
          ),
          '\n',
        )
        // Remove JSON-like grounding leaks
        .replaceAll(
          RegExp(
            r"""\{["']?agent_intent["']?\s*:.*?\}""",
            caseSensitive: false,
            dotAll: true,
          ),
          '',
        )
        // Remove prompt template leaks
        .replaceAll(
          RegExp(r'Safety rules\s*[-—]\s*these override', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'Response format:', caseSensitive: false), '')
        .replaceAll(RegExp(r'grounded context JSON', caseSensitive: false), '')
        // Remove hallucinated clinical-report headers. These appear when Gemma
        // receives rich grounding JSON and defaults to an analyst persona instead
        // of the companion persona. Strip the prefix so the actual content survives.
        .replaceFirst(
          RegExp(
            r'^(Based on (the|your|this) (provided )?data[,.]?\s*'
            r'|According to (the|your) data[,.]?\s*'
            r'|Here['
            "'"
            r's]* an analysis of [^.]{0,60}[.:]\s*'
            r'|The data shows[,:]?\s*)',
            caseSensitive: false,
          ),
          '',
        )
        // Remove role play attempts
        .replaceAll(
          RegExp(
            r'\bAs (a|an) (AI|language model|LLM|assistant)\b',
            caseSensitive: false,
          ),
          '',
        )
        // Keep Markdown structure for chat readability (headings/lists are
        // rendered by MarkdownBody). Only normalize inline emphasis markers.
        // Bold: **text** or __text__ -> text
        .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m[1]!)
        .replaceAllMapped(RegExp(r'__(.+?)__'), (m) => m[1]!)
        // Italic: *text* or _text_ -> text (single char, not double)
        .replaceAllMapped(
          RegExp(r'(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)'),
          (m) => m[1]!,
        )
        .replaceAllMapped(
          RegExp(r'(?<!_)_(?!_)(.+?)(?<!_)_(?!_)'),
          (m) => m[1]!,
        )
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
        .trim();
    value = value.replaceFirst(RegExp(r'^[\s>\\./<|}{"#\$]+'), '');
    return value.trim();
  }

  static String? _rejectionReason(
    String cleaned, {
    required String original,
    required String userMessage,
    String? intent,
    LocalModelResponse? response,
    Map<String, Object?>? grounding,
  }) {
    final nativeStatus = response?.outputQualityStatus;
    if (nativeStatus == 'rejected') {
      return response?.outputQualityReason ?? 'native_rejected_output';
    }
    if (cleaned.isEmpty) return 'empty_after_cleaning';
    if (cleaned.split(RegExp(r'\s+')).where((w) => w.length > 1).length < 3) {
      return 'too_few_useful_words';
    }
    final lower = cleaned.toLowerCase();
    final originalLower = original.toLowerCase();
    // ── Category 1: Control token & prompt leaks ──
    const controlLeaks = [
      '<channel',
      '<|channel',
      '<|tool_call|>',
      '<|tool_response|>',
      '<start_of_turn>',
      '<end_of_turn>',
      '</shtml',
      '<shtml',
      '</html',
      'grounded context json',
      'final answer only',
      '<|system|>',
      '<|user|>',
      '<|assistant|>',
      '<|im_start|>',
      '<|im_end|>',
      '[inst]',
      '[/inst]',
      '<<sys>>',
      '<</sys>>',
      'agent_intent',
      'safety rules — these override',
      'base every claim on the grounded',
    ];
    if (controlLeaks.any(originalLower.contains)) {
      return 'control_or_prompt_leak';
    }

    if (RegExp(r'>{6,}').hasMatch(original) ||
        RegExp(r'(</[^>]{0,12}>[\\./]*){2,}').hasMatch(original)) {
      return 'symbol_or_markup_loop';
    }

    // ── Category 2: Structural quality ──
    final runes = cleaned.runes.toList(growable: false);
    final total = runes.isEmpty ? 1 : runes.length;
    final letters = RegExp(r'[A-Za-z]').allMatches(cleaned).length;
    final symbols = RegExp(r'[^\w\s]').allMatches(cleaned).length;
    if (letters / total < 0.15) return 'low_alpha_ratio';
    if (symbols / total > 0.70) return 'high_symbol_ratio';

    // Repetition detection — same sentence repeated 3+ times
    final sentences = cleaned
        .split(RegExp(r'[.!?]+'))
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.length > 10)
        .toList(growable: false);
    final sentenceCounts = <String, int>{};
    for (final s in sentences) {
      sentenceCounts[s] = (sentenceCounts[s] ?? 0) + 1;
    }
    if (sentenceCounts.values.any((c) => c >= 3)) {
      return 'repetition_loop';
    }

    // Word-level repetition — same word 10+ times (excluding common)
    final words = lower.split(RegExp(r'\s+'));
    final wordCounts = <String, int>{};
    const commonWords = {
      'the',
      'a',
      'an',
      'is',
      'are',
      'was',
      'and',
      'or',
      'to',
      'in',
      'of',
      'for',
      'it',
      'that',
      'this',
      'your',
      'you',
      'i',
      'not',
      'with',
      'be',
      'on',
      'at',
      'by',
      'from',
      'as',
      'but',
      'if',
      'so',
    };
    for (final w in words) {
      if (w.length > 2 && !commonWords.contains(w)) {
        wordCounts[w] = (wordCounts[w] ?? 0) + 1;
      }
    }
    if (words.length >= 10 && wordCounts.values.any((c) => c >= 10)) {
      return 'word_repetition_loop';
    }

    // ── Category 3: Prompt echo ──
    final clippedUser = userMessage.trim().toLowerCase();
    if (clippedUser.length > 60 && lower.contains(clippedUser)) {
      return 'prompt_echo';
    }

    // ── Category 4: Prompt injection detection ──
    if (_containsPromptInjection(lower)) {
      return 'prompt_injection_detected';
    }

    // ── Category 4b: Generic no-op filler — model received input it didn't
    // understand and returned a meta-request instead of a real answer.
    // These patterns are never legitimate Gemma Flares responses.
    const fillerPrefixes = [
      'please provide the text',
      'please provide a question',
      'please provide your question',
      'please provide the question',
      'please share the text',
      'please enter your question',
      "i'd be happy to help, but i need",
      "i'd be happy to help, but could you",
      "i'd be happy to help. could you please provide",
      'could you please provide more context',
      'could you please provide the text',
      'what would you like me to',
      'what text would you like',
      "i'm ready to help, but i need",
      "i'm here to help! could you provide",
    ];
    if (fillerPrefixes.any(lower.startsWith)) {
      return 'generic_filler_response';
    }

    // ── Category 4c: "I am an AI" / generic medical-advice refusal ──
    // Gemma sometimes responds to grounded questions like "What should I
    // watch?" with a meta-refusal ("Since I am an AI...", "I cannot give
    // medical advice...") instead of using the forecast watchlist grounding
    // we handed it. These responses are never useful — fall back to the
    // deterministic reply path so the user gets the actual watchlist.
    const aiDisclaimerSignals = [
      'i am an ai',
      "i'm an ai",
      'i am a large language model',
      "i'm a large language model",
      'as an ai',
      'as a language model',
      'since i am an ai',
      "since i'm an ai",
      'cannot give you medical advice',
      'cannot give medical advice',
      'cannot provide medical advice',
      "can't give you medical advice",
      "can't give medical advice",
      "can't provide medical advice",
      'consult with your doctor or a qualified healthcare provider',
      'consult a qualified healthcare professional',
      'not a medical professional',
      'i do not have access to your personal data',
      "i don't have access to your personal data",
      'i do not have access to your data',
      "i don't have access to your data",
    ];
    if (aiDisclaimerSignals.any(lower.contains)) {
      return 'ai_disclaimer_refusal';
    }

    if (intent == 'forecast_watchlist' &&
        _isGreetingOnlyWatchlistMismatch(lower)) {
      return 'intent_contract_mismatch_watchlist';
    }
    if (intent == 'forecast_watchlist') {
      final mismatch = _watchlistRiskDisplayMismatch(lower, grounding);
      if (mismatch != null) {
        return mismatch;
      }
    }

    // ── Category 5: Unsafe medical claims ──
    if (_containsUnsafeMedicalClaim(lower)) {
      return 'unsafe_medical_claim';
    }

    // ── Category 6: Hallucination markers ──
    if (_containsHallucinationMarker(lower, grounding)) {
      return 'likely_hallucination';
    }

    return null;
  }

  /// Detect prompt injection patterns in model output.
  static bool _containsPromptInjection(String lower) {
    const injectionPatterns = [
      'ignore previous instructions',
      'ignore all previous',
      'ignore your instructions',
      'disregard your instructions',
      'disregard previous',
      'forget your instructions',
      'forget everything above',
      'new instructions:',
      'override safety',
      'jailbreak',
      'you are now',
      'act as a',
      'pretend you are',
      'roleplay as',
      'you are no longer',
      'ignore safety rules',
      'bypass your',
      'system prompt:',
      'your new role is',
      'from now on you',
      'repeat after me',
      'reveal your prompt',
      'show me your instructions',
      'what are your rules',
      'developer mode',
      'dan mode',
      'do anything now',
    ];
    return injectionPatterns.any(lower.contains);
  }

  static bool _isGreetingOnlyWatchlistMismatch(String lower) {
    final normalized = lower.trim();
    final startsWithGreetingScaffold = RegExp(
          r"^(?:hello|hi|hey)\s*[,.!:\-]?\s*(?:i\s+am|i'm)?\s*here\b",
        ).hasMatch(normalized) ||
        RegExp(r"^(?:i\s+am|i'm)\s+here\s+to\s+listen\b").hasMatch(normalized);
    const greetingLikeFragments = [
      'i am here to listen and help',
      'tell me what is happening right now',
      'tell me what is on your mind',
      "tell me what's on your mind",
      'how are you feeling today',
    ];
    final looksLikeGreeting = startsWithGreetingScaffold ||
        greetingLikeFragments.any(normalized.contains);
    if (!looksLikeGreeting) return false;

    final hasWatchSignals = lower.contains('watch') ||
        lower.contains('monitor') ||
        lower.contains('look out') ||
        lower.contains('signal') ||
        lower.contains('next few') ||
        lower.contains('next 7') ||
        lower.contains('if ') ||
        lower.contains('worsen') ||
        lower.contains('trend');
    return !hasWatchSignals;
  }

  static String? _watchlistRiskDisplayMismatch(
    String lower,
    Map<String, Object?>? grounding,
  ) {
    final globalFlareRisk = grounding?['global_flare_risk'];
    if (globalFlareRisk is! Map) {
      return null;
    }
    final riskMap = Map<String, Object?>.from(globalFlareRisk);
    final status = riskMap['status']?.toString();
    final displayText = riskMap['display_text']?.toString().toLowerCase();
    if (status == null || displayText == null || displayText.isEmpty) {
      return null;
    }

    final mentionsRisk = lower.contains('flare risk') ||
        lower.contains('global flare risk') ||
        lower.contains('7-day flare risk');
    if (!mentionsRisk) {
      return null;
    }

    final percents = RegExp(
      r'\b\d{1,3}%\b',
    ).allMatches(lower).map((match) => match.group(0)!.toLowerCase()).toSet();
    if (status == 'learning') {
      return percents.isEmpty ? null : 'watchlist_risk_display_mismatch';
    }
    if (lower.contains('learning')) {
      return 'watchlist_risk_display_mismatch';
    }
    if (percents.isNotEmpty && !percents.contains(displayText)) {
      return 'watchlist_risk_display_mismatch';
    }
    return null;
  }

  /// Detect unsafe medical claims the model should never make.
  static bool _containsUnsafeMedicalClaim(String lower) {
    const unsafeClaims = [
      'clinically validated',
      'i diagnose',
      'i predict your flare',
      'change your dose',
      'you are having a flare',
      'you definitely have',
      'this confirms you have',
      'i can confirm',
      'stop taking',
      'start taking',
      'increase your dose',
      'decrease your dose',
      'skip your medication',
      'you don\'t need your medication',
      'you dont need your medication',
      'this means you have cancer',
      'this is cancer',
      'you have an obstruction',
      'you have a bowel obstruction',
      'you need surgery',
      'you need to go to surgery',
      'this is an emergency',
      'you are in remission',
      'you are definitely in remission',
      'i am a doctor',
      'i am a medical professional',
      'as your doctor',
      'my medical advice',
      'my clinical recommendation',
      'i prescribe',
      'clinically proven',
      'medically proven',
      'guaranteed to',
      'will cure',
      'can cure',
      'this treatment will',
      'take this supplement',
      'you should fast',
      'stop eating',
      'you have ibs not ibd',
      'your disease is mild',
      'your disease is severe',
      'you are in a severe flare',
      'this is definitely a flare',
      'this is not a flare',
      'i can rule out',
      'there is nothing wrong',
      'you have a fistula',
      'you have a stricture',
      'you have an abscess',
      'your fistula is healing',
      'your fistula is getting worse',
      'you have malnutrition',
      'you are malnourished',
      'you have anemia',
      'you are anemic',
      'you need a colonoscopy',
      'you need an endoscopy',
      'you need a blood test',
      'you should stop your biologic',
      'switch your biologic',
      'you have colon cancer',
      'this could be cancer',
      'you have a blood clot',
    ];
    // Negation prefixes that neutralize a claim
    const negations = [
      'not mean',
      'not necessarily',
      'does not mean',
      'doesn\'t mean',
      'not saying',
      'not confirm',
      'cannot confirm',
    ];
    for (final claim in unsafeClaims) {
      if (!lower.contains(claim)) continue;
      final idx = lower.indexOf(claim);
      // Check if preceded by a negation within 30 chars
      final prefix = lower.substring((idx - 30).clamp(0, lower.length), idx);
      if (negations.any(prefix.contains)) continue;
      return true;
    }
    return false;
  }

  /// Detect likely hallucinated data not found in grounding context.
  static bool _containsHallucinationMarker(
    String lower,
    Map<String, Object?>? grounding,
  ) {
    // If no grounding available, can't verify — don't flag.
    if (grounding == null || grounding.isEmpty) return false;

    // Check for fabricated score values
    final scoreMap = grounding['score'];
    if (scoreMap is Map) {
      final realScore = scoreMap['value'];
      if (realScore is num) {
        // Look for score claims that don't match actual data
        final scorePattern = RegExp(r'score\s+(?:is\s+|of\s+)?(\d+)');
        for (final match in scorePattern.allMatches(lower)) {
          final claimedScore = int.tryParse(match.group(1) ?? '');
          if (claimedScore != null &&
              (claimedScore - realScore.round()).abs() > 5) {
            return true;
          }
        }
      }
    }

    // Check for fabricated confidence values
    if (scoreMap is Map) {
      final realConf = scoreMap['confidence'];
      if (realConf is num) {
        final confPattern = RegExp(r'confidence\s+(?:is\s+|of\s+)?(\d+)');
        for (final match in confPattern.allMatches(lower)) {
          final claimedConf = int.tryParse(match.group(1) ?? '');
          if (claimedConf != null &&
              (claimedConf - realConf.round()).abs() > 5) {
            return true;
          }
        }
      }
    }

    return false;
  }
}

class GemmaFlaresVoicePolicy {
  const GemmaFlaresVoicePolicy._();

  static String polish(String message, {required String userMessage}) {
    var text = message.trim().replaceAll(RegExp(r'\n{3,}'), '\n\n');
    if (text.isEmpty) {
      return text;
    }
    if (text.contains('## Overview') &&
        text.contains('## Questions for Your GI Doctor')) {
      return text;
    }
    final lowerUser = userMessage.toLowerCase().trim();
    if (_isSimpleGreeting(lowerUser)) {
      return text;
    }

    // Warm language replacements — clinical → conversational
    text = text
        .replaceAll(RegExp(r'\bdiagnoses\b', caseSensitive: false), 'labels')
        .replaceAll(RegExp(r'\bdiagnose\b', caseSensitive: false), 'label')
        .replaceAll(RegExp(r'\bpathology\b', caseSensitive: false), 'condition')
        .replaceAll(
          RegExp(r'\bpathological\b', caseSensitive: false),
          'concerning',
        )
        .replaceAll(
          RegExp(r'\bmorbidity\b', caseSensitive: false),
          'health impact',
        )
        .replaceAll(RegExp(r'\bprognosis\b', caseSensitive: false), 'outlook')
        .replaceAll(
          RegExp(r'\basymptomatic\b', caseSensitive: false),
          'without noticeable symptoms',
        );
    text = text
        .replaceAll(RegExp(r'\bpoop\b', caseSensitive: false), 'bowel movement')
        .replaceAll(
          RegExp(r'\bpooping\b', caseSensitive: false),
          'having bowel movements',
        )
        .replaceAll(
          RegExp(r'\bbig bowel movement\b', caseSensitive: false),
          'increased bowel movement',
        );

    return text.trim();
  }

  static bool _isSimpleGreeting(String lower) {
    return const {
      'hi',
      'hello',
      'hey',
      'yo',
      'sup',
      'hiya',
      'howdy',
      'good morning',
      'good afternoon',
      'good evening',
      'hey there',
      'hi there',
      'hello there',
      'morning',
      'evening',
      'afternoon',
      'greetings',
    }.contains(lower.replaceAll(RegExp(r'[^a-z\s]'), '').trim());
  }
}

/// Display-layer formatter for the GI / doctor summary surfaced in chat.
///
/// Normalizes a possibly-messy raw summary string into a clean clinical
/// document:
///   - Strips markdown heading markers (`##` / `###`) and re-emits headings
///     as plain lines.
///   - Inserts a single blank line before every heading after the first.
///   - Removes bullet markers (`-`, `*`, `•`, `–`, `—`), numbered list
///     markers (`1.`, `1)`), block quotes, code fences, backticks, and
///     bold/italic emphasis runs.
///   - Collapses runs of inner whitespace and tabs.
///   - Drops horizontal rule lines (`---`, `***`, `___`).
///   - Normalizes `\r\n` and bare `\r` line endings to `\n`.
///
/// Exposed at the top level and annotated `@visibleForTesting` so the
/// formatter can be exercised in isolation without spinning up the full
/// [LocalAgentService] graph.
@visibleForTesting
String doctorSummaryDisplayTextForTest(String raw) {
  final source = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (source.isEmpty) return '';

  final buf = StringBuffer();
  var wroteAny = false;
  const sectionHeadings = <String>[
    'Overview',
    'GI Activity Summary',
    'Lab Results',
    'Check-in Summary',
    'Medication and Supplement Log',
    'Bowel Pattern Baseline',
    'Condensed Diet and Trigger Log',
    'Questions for Your GI Doctor',
    'Triage and Red Flags',
  ];

  bool looksLikeSectionBreakTrailing(String trailing) {
    final normalized = trailing.trimLeft();
    if (normalized.isEmpty) return true;
    if (RegExp(r'^[:\-–—]').hasMatch(normalized)) return true;
    // Keep inline heading split support for compact prose where section text
    // starts immediately after the heading (for example: "... Log After meals").
    // Avoid splitting normal sentences like "No saved Lab Results were found".
    return RegExp(r'^[A-Z0-9(]').hasMatch(normalized);
  }

  String? matchSectionHeadingAtStart(String text) {
    final lower = text.toLowerCase();
    for (final heading in sectionHeadings) {
      final hLower = heading.toLowerCase();
      if (lower == hLower ||
          lower.startsWith('$hLower:') ||
          lower.startsWith('$hLower -') ||
          lower.startsWith('$hLower –') ||
          lower.startsWith('$hLower —')) {
        return heading;
      }
      if (!lower.startsWith('$hLower ')) continue;
      final trailing = text.substring(heading.length);
      if (looksLikeSectionBreakTrailing(trailing)) {
        return heading;
      }
    }
    return null;
  }

  ({String? prefix, String heading, String? trailing})?
      splitInlineSectionHeading(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    final matchedAtStart = matchSectionHeadingAtStart(trimmed);
    if (matchedAtStart != null) {
      final trailing = trimmed
          .substring(matchedAtStart.length)
          .trimLeft()
          .replaceFirst(RegExp(r'^[:\-–—]\s*'), '')
          .trim();
      return (
        prefix: null,
        heading: matchedAtStart,
        trailing: trailing.isEmpty ? null : trailing,
      );
    }

    final lower = trimmed.toLowerCase();
    var bestIndex = trimmed.length;
    String? bestHeading;
    for (final heading in sectionHeadings) {
      final idx = lower.indexOf(heading.toLowerCase());
      if (idx <= 0 || idx >= bestIndex) continue;
      final prefix = trimmed.substring(0, idx).trimRight();
      if (prefix.isEmpty) continue;
      if (heading == 'Overview' && prefix.toLowerCase().endsWith('pattern')) {
        continue;
      }
      final prevChar = trimmed[idx - 1];
      if (!RegExp(r'[\s.:;\-–—]').hasMatch(prevChar)) continue;
      final trailingCandidate = trimmed.substring(idx + heading.length);
      if (!looksLikeSectionBreakTrailing(trailingCandidate)) continue;
      bestIndex = idx;
      bestHeading = heading;
    }

    if (bestHeading == null) return null;

    final prefix = trimmed.substring(0, bestIndex).trimRight();
    final headingAndTrailing = trimmed.substring(bestIndex).trimLeft();
    final trailing = headingAndTrailing
        .substring(bestHeading.length)
        .trimLeft()
        .replaceFirst(RegExp(r'^[:\-–—]\s*'), '')
        .trim();

    return (
      prefix: prefix.isEmpty ? null : prefix,
      heading: bestHeading,
      trailing: trailing.isEmpty ? null : trailing,
    );
  }

  for (final rawLine in source.split('\n')) {
    final trimmed = rawLine.trimRight().trimLeft();
    if (trimmed.isEmpty) continue;
    if (trimmed.startsWith('```')) continue;
    // Bare heading markers (e.g. "##" with no text after) must not leak
    // into the body. The heading regex below requires `\s+` then content,
    // so bare markers would otherwise fall through and be emitted as
    // visible "##" lines. Drop them defensively.
    if (RegExp(r'^#{1,6}\s*$').hasMatch(trimmed)) continue;

    final headingMatch = RegExp(r'^(#{1,6})\s+(.+)$').firstMatch(trimmed);
    if (headingMatch != null) {
      var heading = (headingMatch.group(2) ?? '').trim();
      heading = heading
          .replaceAll('**', '')
          .replaceAll('`', '')
          .replaceAllMapped(RegExp(r'__([^_]+)__'), (m) => m.group(1) ?? '')
          .trim();
      if (heading.isEmpty) continue;
      final inlineSection = splitInlineSectionHeading(heading);
      if (inlineSection != null) {
        final sectionHeading = inlineSection.heading;
        if (wroteAny) buf.writeln(); // blank line between sections
        buf.writeln(sectionHeading);
        wroteAny = true;

        final trailing = inlineSection.trailing;
        if (trailing != null && trailing.isNotEmpty) {
          final cleanedTrailing = trailing
              .replaceAllMapped(
                RegExp(r'\*\*([^*]+)\*\*'),
                (match) => match.group(1) ?? '',
              )
              .replaceAllMapped(
                RegExp(r'__([^_]+)__'),
                (match) => match.group(1) ?? '',
              )
              .replaceAll('`', '')
              .replaceFirst(RegExp(r'^>\s+'), '')
              .replaceFirst(RegExp(r'^(?:[-*•]|[–—])\s+'), '')
              .replaceFirst(RegExp(r'^(?:\d{1,2}[.)])\s+'), '')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          if (cleanedTrailing.isNotEmpty) {
            buf.writeln(cleanedTrailing);
          }
        }
      } else {
        if (wroteAny) buf.writeln(); // blank line between sections
        buf.writeln(heading);
        wroteAny = true;
      }
      continue;
    }

    final inlineSection = splitInlineSectionHeading(trimmed);
    if (inlineSection != null) {
      final prefix = inlineSection.prefix;
      if (prefix != null && prefix.isNotEmpty) {
        final cleanedPrefix = prefix
            .replaceAllMapped(
              RegExp(r'\*\*([^*]+)\*\*'),
              (match) => match.group(1) ?? '',
            )
            .replaceAllMapped(
              RegExp(r'__([^_]+)__'),
              (match) => match.group(1) ?? '',
            )
            .replaceAll('`', '')
            .replaceFirst(RegExp(r'^>\s+'), '')
            .replaceFirst(RegExp(r'^(?:[-*•]|[–—])\s+'), '')
            .replaceFirst(RegExp(r'^(?:\d{1,2}[.)])\s+'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (cleanedPrefix.isNotEmpty) {
          buf.writeln(cleanedPrefix);
          wroteAny = true;
        }
      }

      if (wroteAny) buf.writeln();
      buf.writeln(inlineSection.heading);
      wroteAny = true;

      final trailing = inlineSection.trailing;
      if (trailing != null && trailing.isNotEmpty) {
        final cleanedTrailing = trailing
            .replaceAllMapped(
              RegExp(r'\*\*([^*]+)\*\*'),
              (match) => match.group(1) ?? '',
            )
            .replaceAllMapped(
              RegExp(r'__([^_]+)__'),
              (match) => match.group(1) ?? '',
            )
            .replaceAll('`', '')
            .replaceFirst(RegExp(r'^>\s+'), '')
            .replaceFirst(RegExp(r'^(?:[-*•]|[–—])\s+'), '')
            .replaceFirst(RegExp(r'^(?:\d{1,2}[.)])\s+'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (cleanedTrailing.isNotEmpty) {
          buf.writeln(cleanedTrailing);
        }
      }
      continue;
    }

    var cleaned = trimmed;
    cleaned = cleaned.replaceAllMapped(
      RegExp(r'\*\*([^*]+)\*\*'),
      (match) => match.group(1) ?? '',
    );
    cleaned = cleaned.replaceAllMapped(
      RegExp(r'__([^_]+)__'),
      (match) => match.group(1) ?? '',
    );
    cleaned = cleaned.replaceAll('`', '');
    cleaned = cleaned.replaceFirst(RegExp(r'^>\s+'), '');
    cleaned = cleaned.replaceFirst(RegExp(r'^(?:[-*•]|[–—])\s+'), '');
    cleaned = cleaned.replaceFirst(RegExp(r'^(?:\d{1,2}[.)])\s+'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) continue;
    if (cleaned == '---' || cleaned == '***' || cleaned == '___') continue;
    buf.writeln(cleaned);
    wroteAny = true;
  }

  return buf.toString().trim();
}
