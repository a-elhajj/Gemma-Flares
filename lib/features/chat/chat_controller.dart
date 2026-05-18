import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/app_services.dart';
import '../../core/database/wearable_sample_repository.dart';
import '../../core/services/diagnostic_log_service.dart';
import '../../core/services/gemma_task_service.dart';
import '../../core/services/guidance_service.dart';
import '../../core/services/lab_logging_service.dart';
import '../../core/services/local_agent_service.dart';
import '../../core/services/local_model_runtime.dart';
import '../../core/services/setup_state_service.dart';
import '../../core/services/symptom_logging_service.dart';

class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.text,
    this.isModel,
    this.evidence,
    this.pendingAction,
  });

  final String role;
  final String text;
  final bool? isModel;
  final Map<String, Object?>? evidence;
  final ChatPendingAction? pendingAction;
}

class ChatController extends ChangeNotifier {
  ChatController({
    LocalAgentService? localAgentService,
    LocalModelRuntime? runtime,
    WearableSampleRepository? repository,
    SymptomLoggingService? symptomLoggingService,
    LabLoggingService? labLoggingService,
    GuidanceService? guidanceService,
    DiagnosticLogService? diagnosticLogService,
  })  : _localAgentService = localAgentService ?? AppServices.localAgentService,
        _runtime = runtime ?? AppServices.localModelRuntime,
        _repository = repository ?? AppServices.wearableSampleRepository,
        _symptomLoggingService =
            symptomLoggingService ?? AppServices.symptomLoggingService,
        _labLoggingService = labLoggingService ?? AppServices.labLoggingService,
        _guidanceService = guidanceService ?? AppServices.guidanceService,
        _diagnosticLogService =
            diagnosticLogService ?? AppServices.diagnosticLogService;

  final LocalAgentService _localAgentService;
  final LocalModelRuntime _runtime;
  final WearableSampleRepository _repository;
  final SymptomLoggingService _symptomLoggingService;
  final LabLoggingService _labLoggingService;
  final GuidanceService _guidanceService;
  final DiagnosticLogService _diagnosticLogService;

  final List<ChatMessage> _messages = <ChatMessage>[];
  LocalModelRuntimeStatus? _runtimeStatus;
  SetupStatus? _setupStatus;
  bool _busy = false;
  bool _restored = false;
  bool _disposed = false;
  int _turnSequence = 0;
  static const _chatTurnTimeout = Duration(seconds: 75);

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  LocalModelRuntimeStatus? get runtimeStatus => _runtimeStatus;
  SetupStatus? get setupStatus => _setupStatus;
  bool get busy => _busy;
  bool get restored => _restored;

  @override
  void dispose() {
    _disposed = true;
    _turnSequence++;
    super.dispose();
  }

  void _safeNotifyListeners() {
    if (!_disposed) notifyListeners();
  }

  /// Truthy only when setup validated Gemma and runtime confirms it's loaded.
  /// This prevents UI from claiming "on-device" before the model is truly ready.
  bool get modelReady {
    final runtime = _runtimeStatus;
    final setup = _setupStatus;
    if (runtime == null || setup == null) return false;
    return setup.hasValidatedModel &&
        runtime.isBackendLinked &&
        runtime.isBundledModelPresent &&
        runtime.isModelLoaded;
  }

  Future<void> initialize({bool restoreHistory = true}) async {
    await Future.wait([
      refreshRuntime(),
      if (restoreHistory) restoreHistoryFromStore(),
    ]);
  }

  Future<void> refreshRuntime() async {
    final results = await Future.wait<Object?>([
      _runtime.getRuntimeStatus(),
      AppServices.setupStateService
          .loadStatus()
          .then<Object?>((value) => value)
          .catchError((_) => null),
    ]);
    _runtimeStatus = results[0] as LocalModelRuntimeStatus;
    _setupStatus = results[1] as SetupStatus?;
    _safeNotifyListeners();
  }

  Future<void> restoreHistoryFromStore() async {
    try {
      final rows = await _repository.getRecentConversations(limit: 8);
      final restoredMessages = <ChatMessage>[];
      for (final c in rows.reversed) {
        restoredMessages.add(ChatMessage(role: 'user', text: c.userMessage));
        restoredMessages.add(
          ChatMessage(
            role: 'assistant',
            text: _cleanRestoredAssistantMessage(c.assistantMessage),
            isModel: c.toolTraceJson['used_model_output'] == true,
            evidence: evidenceFromTrace(c.toolTraceJson),
          ),
        );
      }
      _messages
        ..clear()
        ..addAll(restoredMessages);
      _restored = true;
      _safeNotifyListeners();
    } catch (_) {
      _restored = true;
      _safeNotifyListeners();
    }
  }

  Future<void> send(String prompt) async {
    final text = prompt.trim();
    if (text.isEmpty || _busy || _disposed) return;

    _busy = true;
    final turnId = ++_turnSequence;
    _messages.add(ChatMessage(role: 'user', text: text));
    _safeNotifyListeners();

    try {
      final reply = await _localAgentService.ask(text).timeout(
            _chatTurnTimeout,
            onTimeout: () => const LocalAgentReply(
              status: 'timeout',
              message:
                  'The local model took too long, so I stopped waiting. Please try again with a shorter message or close other apps if your phone feels low on memory.',
              runtimeName: 'timeout_guard',
              toolTraceJson: {
                'used_model_output': false,
                'agent_intent': 'runtime_timeout',
                'tools_called': ['chat_timeout_guard'],
                'model_generation_status': 'timeout',
                'model_fallback_reason': 'chat_turn_timeout',
              },
              groundedSummaryJson: {},
            ),
          );
      if (turnId != _turnSequence || _disposed) return;
      _messages.add(
        ChatMessage(
          role: 'assistant',
          text: reply.message,
          isModel: reply.toolTraceJson['used_model_output'] == true,
          evidence: evidenceFromTrace(reply.toolTraceJson),
          pendingAction: reply.pendingAction,
        ),
      );
    } catch (_) {
      if (turnId != _turnSequence || _disposed) return;
      _messages.add(
        const ChatMessage(
          role: 'assistant',
          text: 'Something went wrong — please try again.',
        ),
      );
    } finally {
      if (turnId == _turnSequence && !_disposed) {
        _busy = false;
        _safeNotifyListeners();
      }
    }
  }

  /// Generates a GI summary for the given date range and adds it to the chat.
  /// Called after the user picks a range from the date-picker dialog.
  Future<void> sendGiSummaryRequest({
    DateTime? startDate,
    DateTime? endDate,
    bool allDates = false,
  }) async {
    if (_busy || _disposed) return;

    final userLabel = allDates
        ? 'Create a GI summary for all my data.'
        : (startDate != null && endDate != null)
            ? 'Create a GI summary from ${_fmtDate(startDate)} to ${_fmtDate(endDate)}.'
            : 'Create a GI summary for the last 30 days.';

    _busy = true;
    final turnId = ++_turnSequence;
    _messages.add(ChatMessage(role: 'user', text: userLabel));
    _safeNotifyListeners();

    try {
      final reply = await _localAgentService
          .generateGiSummary(
            startDate: startDate,
            endDate: endDate,
            allDates: allDates,
            userMessage: userLabel,
          )
          .timeout(
            const Duration(seconds: 90),
            onTimeout: () => const LocalAgentReply(
              status: 'timeout',
              message:
                  'The GI summary took too long. Please try again — close other apps if your phone feels slow.',
              runtimeName: 'timeout_guard',
              toolTraceJson: {
                'used_model_output': false,
                'agent_intent': 'doctor_summary',
                'tools_called': ['chat_timeout_guard'],
                'model_generation_status': 'timeout',
                'model_fallback_reason': 'gi_summary_timeout',
              },
              groundedSummaryJson: {},
            ),
          );
      if (turnId != _turnSequence || _disposed) return;
      _messages.add(ChatMessage(
        role: 'assistant',
        text: reply.message,
        isModel: reply.toolTraceJson['used_model_output'] == true,
        evidence: evidenceFromTrace(reply.toolTraceJson),
        pendingAction: reply.pendingAction,
      ));
    } catch (_) {
      if (turnId != _turnSequence || _disposed) return;
      _messages.add(const ChatMessage(
        role: 'assistant',
        text:
            'Something went wrong generating the GI summary — please try again.',
      ));
    } finally {
      if (turnId == _turnSequence && !_disposed) {
        _busy = false;
        _safeNotifyListeners();
      }
    }
  }

  static String _fmtDate(DateTime dt) {
    const months = [
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

  Future<void> clearChat() async {
    if (_messages.isEmpty) return;
    await _repository.clearConversations();
    await _localAgentService.resetSession(reason: 'user_cleared_chat');
    _turnSequence++;
    _messages.clear();
    _safeNotifyListeners();
  }

  Future<void> confirmPendingAction(ChatMessage message) async {
    final action = message.pendingAction;
    if (action == null || _busy) return;
    if (action.type == 'lab_review') {
      await _confirmPendingLabAction(message);
      return;
    }
    if (action.type != 'symptom_review') return;

    // Resolve source text and pre-extracted symptom list from the review card.
    // NEVER re-run Gemma extraction on confirm — use whatever was already shown.
    final source = (action.payloadJson['source_text'] as String? ?? '').trim();
    final rawAll = action.payloadJson['all_symptoms'];
    final allSymptoms = (rawAll is List)
        ? rawAll.whereType<Map<String, Object?>>().toList(growable: false)
        : const <Map<String, Object?>>[];

    // Require at least a source transcript or a pre-extracted symptom list.
    if (source.isEmpty && allSymptoms.isEmpty) return;

    _busy = true;
    _safeNotifyListeners();
    try {
      final now = DateTime.now().toUtc();
      final String confirmText;
      final Map<String, Object?> toolResults;

      if (allSymptoms.isNotEmpty) {
        // Multi- or single-symptom: save directly from the pre-extracted payload.
        // This is the primary path — guarantees what was shown is what gets saved.
        final effectiveSource = source.isNotEmpty
            ? source
            : (action.payloadJson['user_facing_description'] as String? ?? '');
        final ids = await _symptomLoggingService.saveAllFromPayload(
          allSymptoms: allSymptoms,
          sourceTranscript: effectiveSource,
          loggedAt: now,
        );
        final typeLabels = allSymptoms
            .map((s) => s['symptom_type']?.toString() ?? 'symptom')
            .join(', ');
        confirmText = ids.length == 1
            ? 'Saved to your timeline ($typeLabels).'
            : 'Saved ${ids.length} symptoms ($typeLabels) to your timeline.';
        toolResults = {
          'symptom_ids': ids,
          'symptom_types': typeLabels,
          'symptom_count': ids.length,
          'logged_at': now.toIso8601String(),
          'save_path': 'payload',
        };
        _refreshGuidance('chat_symptom_confirmed');
        await _diagnosticLogService.info(
          'chat_symptom_review_confirmed',
          category: DiagnosticLogService.categoryChat,
          message:
              'Chat symptom review confirmed — saved ${ids.length} symptom(s) from payload.',
          metadata: {'symptom_count': ids.length, 'symptom_types': typeLabels},
        );
      } else {
        // Fallback: single-symptom legacy path (no all_symptoms in payload).
        // Rare — only triggers for very old-format pending actions.
        final result = await _symptomLoggingService.saveTranscript(
          transcript: source,
          preferGemma: true,
        );
        confirmText =
            'Saved to your timeline (${result.savedSymptom.symptomType}).';
        toolResults = {
          'symptom_id': result.savedSymptom.id,
          'symptom_type': result.savedSymptom.symptomType,
          'logged_at': result.savedSymptom.loggedAt.toUtc().toIso8601String(),
          'symptom_indexed_for_rag': result.symptomIndexedForRag,
          'intake_event_count': result.savedIntakeEvents.length,
          'intake_indexed_for_rag': result.intakeIndexedForRag,
          'save_path': 'transcript_reparse',
        };
        _refreshGuidance('chat_symptom_confirmed');
        await _diagnosticLogService.info(
          'chat_symptom_review_confirmed',
          category: DiagnosticLogService.categoryChat,
          message: 'Chat symptom review was confirmed and saved locally.',
          metadata: {
            'symptom_id': result.savedSymptom.id,
            'symptom_type': result.savedSymptom.symptomType,
          },
        );
      }

      _messages.remove(message);
      _messages.add(
        ChatMessage(
          role: 'assistant',
          text: confirmText,
          isModel: false,
          evidence: {
            'used_model_output': false,
            'agent_intent': 'symptom_review_confirmed',
            'tools_called': [
              'save_symptom_note',
              'index_symptom_for_rag',
              'recompute_risk',
            ],
            'tool_results': toolResults,
            'pending_action_type': 'symptom_review',
            'open_symptoms_action': true,
          },
        ),
      );
      // Reset session so the next "log a symptom" starts fresh.
      unawaited(_localAgentService.resetSession(reason: 'symptom_confirmed'));
    } catch (_) {
      _messages.add(
        const ChatMessage(
          role: 'assistant',
          text:
              "I couldn't save that symptom note. Please try again from the Check-In or voice log screen.",
          isModel: false,
        ),
      );
    } finally {
      _busy = false;
      _safeNotifyListeners();
    }
  }

  Future<void> _confirmPendingLabAction(ChatMessage message) async {
    final action = message.pendingAction;
    if (action == null || action.type != 'lab_review' || _busy) return;
    final candidates = _labCandidatesFromPendingAction(action);
    if (candidates.isEmpty) return;

    _busy = true;
    _safeNotifyListeners();
    try {
      final result = await _labLoggingService.saveCandidates(
        candidates: candidates,
        reviewId: action.reviewId,
        source: 'chat_lab_review',
      );
      _refreshGuidance('chat_labs_confirmed');
      await _diagnosticLogService.info(
        'chat_lab_review_confirmed',
        category: DiagnosticLogService.categoryChat,
        message: 'Chat lab review was confirmed and saved locally.',
        metadata: {
          'saved_lab_count': result.savedLabs.length,
          'lab_ids': result.savedLabs.map((lab) => lab.id).toList(),
          'review_id': action.reviewId,
          'tool_audit_id': result.toolAuditId,
        },
      );
      _messages.remove(message);
      _messages.add(
        ChatMessage(
          role: 'assistant',
          text: _labSaveConfirmationText(result),
          isModel: false,
          evidence: {
            'used_model_output': false,
            'agent_intent': 'lab_review_confirmed',
            'tools_called': [
              'ingest_lab_panel',
              'index_lab_for_rag',
              'refresh_risk_context',
            ],
            'tool_results': {
              'saved_lab_count': result.savedLabs.length,
              'lab_ids': result.savedLabs.map((lab) => lab.id).toList(),
              'lab_types': result.savedLabs.map((lab) => lab.labType).toList(),
              'rag_indexed_by_lab_id': result.ragIndexedByLabId,
              'rag_validated_by_lab_id': result.ragValidatedByLabId,
              'rag_validation_status_by_lab_id':
                  result.ragValidationStatusByLabId,
              'rag_validation_snippet_by_lab_id':
                  result.ragValidationSnippetByLabId,
              'analytics_refresh_status': result.analyticsRefreshStatus,
              'tool_audit_id': result.toolAuditId,
            },
            'pending_action_type': 'lab_review',
          },
        ),
      );
    } catch (_) {
      _messages.add(
        const ChatMessage(
          role: 'assistant',
          text:
              "I couldn't save those lab values. Please try again from the lab import screen.",
          isModel: false,
        ),
      );
    } finally {
      _busy = false;
      _safeNotifyListeners();
    }
  }

  Future<void> handleLabImportSaved(LabLoggingResult result) async {
    final txIds = result.ragTransactionIdByLabId.values
        .where((tx) => tx.trim().isNotEmpty)
        .toList(growable: false);
    await _diagnosticLogService.info(
      'chat_lab_import_saved',
      category: DiagnosticLogService.categoryChat,
      message:
          'Lab import completed and confirmation was posted in chat thread.',
      metadata: {
        'saved_lab_count': result.savedLabs.length,
        'lab_ids': result.savedLabs.map((lab) => lab.id).toList(),
        'rag_transaction_ids': txIds,
        'rag_validated_by_lab_id': result.ragValidatedByLabId,
        'rag_validation_status_by_lab_id': result.ragValidationStatusByLabId,
      },
    );
    _messages.add(
      ChatMessage(
        role: 'assistant',
        text: _labSaveConfirmationText(result),
        isModel: false,
        evidence: {
          'used_model_output': false,
          'agent_intent': 'lab_import_saved',
          'tools_called': [
            'ingest_lab_panel',
            'index_lab_for_rag',
            'validate_rag_transaction_extract',
            'refresh_risk_context',
          ],
          'tool_results': {
            'saved_lab_count': result.savedLabs.length,
            'lab_ids': result.savedLabs.map((lab) => lab.id).toList(),
            'rag_transaction_id_by_lab_id': result.ragTransactionIdByLabId,
            'rag_indexed_by_lab_id': result.ragIndexedByLabId,
            'rag_validated_by_lab_id': result.ragValidatedByLabId,
            'rag_validation_status_by_lab_id':
                result.ragValidationStatusByLabId,
            'rag_validation_snippet_by_lab_id':
                result.ragValidationSnippetByLabId,
            'analytics_refresh_status': result.analyticsRefreshStatus,
            'tool_audit_id': result.toolAuditId,
          },
        },
      ),
    );
    _safeNotifyListeners();
  }

  String _labSaveConfirmationText(LabLoggingResult result) {
    final savedLabels = result.savedLabs
        .map((lab) => '${lab.labType} ${lab.valueNumeric} ${lab.unit}')
        .join(', ');
    final indexedCount =
        result.ragIndexedByLabId.values.where((indexed) => indexed).length;
    final validatedCount = result.ragValidatedByLabId.values
        .where((validated) => validated)
        .length;
    final txIds = result.ragTransactionIdByLabId.values
        .where((tx) => tx.trim().isNotEmpty)
        .toList(growable: false);
    final validationLine = txIds.isEmpty
        ? 'Memory validation is not available for this save mode.'
        : validatedCount == txIds.length
            ? 'Saved and validated in local memory (${txIds.join(', ')}).'
            : 'Saved locally. Memory validation confirmed $validatedCount/${txIds.length} transaction${txIds.length == 1 ? '' : 's'} (${txIds.join(', ')}).';
    return 'Saved ${result.savedLabs.length} lab value${result.savedLabs.length == 1 ? '' : 's'}: $savedLabels. RAG memory indexed $indexedCount/${result.savedLabs.length}. $validationLine Risk context: ${result.analyticsRefreshStatus}.';
  }

  List<GemmaLabCandidate> _labCandidatesFromPendingAction(
    ChatPendingAction action,
  ) {
    final rawCandidates = action.payloadJson['candidate_labs'];
    if (rawCandidates is! List) return const [];
    return rawCandidates.whereType<Map>().map((raw) {
      final json = Map<String, Object?>.from(raw);
      return GemmaLabCandidate(
        labType: json['lab_type']?.toString() ?? 'unknown',
        valueNumeric: (json['value_numeric'] as num?)?.toDouble() ?? 0,
        unit: json['unit']?.toString() ?? '',
        drawnDate: json['drawn_date']?.toString() ?? '',
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
        referenceHigh: (json['reference_high'] as num?)?.toDouble(),
        labName: json['lab_name']?.toString(),
        orderingProvider: json['ordering_provider']?.toString(),
        abnormalFlag: json['abnormal_flag'] as bool?,
        sourceTextSnippet: json['source_text_snippet']?.toString(),
      );
    }).toList(growable: false);
  }

  String? editPendingAction(ChatMessage message) {
    final source = message.pendingAction?.payloadJson['source_text'] as String?;
    if (source == null) return null;
    _messages.remove(message);
    _safeNotifyListeners();
    return source;
  }

  Future<void> cancelPendingAction(ChatMessage message) async {
    final action = message.pendingAction;
    _messages.remove(message);
    _safeNotifyListeners();
    await _diagnosticLogService.info(
      'chat_symptom_review_cancelled',
      category: DiagnosticLogService.categoryChat,
      message: 'Chat symptom review was cancelled before save.',
      metadata: {'pending_action_type': action?.type},
    );
  }

  void _refreshGuidance(String reason) {
    unawaited(_refreshGuidanceSafely(reason));
  }

  Future<void> _refreshGuidanceSafely(String reason) async {
    try {
      await _guidanceService.refreshLatestGuidance(reason: reason);
    } catch (_) {
      // Symptom save already succeeded; guidance can retry later.
    }
  }

  static Map<String, Object?> evidenceFromTrace(Map<String, Object?> trace) {
    return {
      'tools_called': trace['tools_called'],
      'tool_results': trace['tool_results'],
      'used_model_output': trace['used_model_output'],
      'gemma_task_run_id': trace['gemma_task_run_id'],
      'agent_intent': trace['agent_intent'],
      'model_generation_status': trace['model_generation_status'],
      'model_fallback_reason': trace['model_fallback_reason'],
      'active_runtime_profile': trace['active_runtime_profile'],
      'estimated_prompt_tokens': trace['estimated_prompt_tokens'],
      'prompt_budget': trace['prompt_budget'],
      'generation_latency_ms': trace['generation_latency_ms'],
      'native_decode_rc': trace['native_decode_rc'],
      'failure_stage': trace['failure_stage'],
      'output_quality_status': trace['output_quality_status'],
      'output_quality_reason': trace['output_quality_reason'],
      'native_output_quality_status': trace['native_output_quality_status'],
      'native_output_quality_reason': trace['native_output_quality_reason'],
      'prompt_template_version': trace['prompt_template_version'],
      'sanitizer_version': trace['sanitizer_version'],
      'raw_output_hash': trace['raw_output_hash'],
      'generated_token_count': trace['generated_token_count'],
      'stop_reason': trace['stop_reason'],
      'sampler_profile': trace['sampler_profile'],
      'chat_template_source': trace['chat_template_source'],
      'pending_action_type': trace['pending_action_type'],
      'open_symptoms_action': trace['open_symptoms_action'],
      'model_role_used': trace['model_role_used'],
      'model_id_used': trace['model_id_used'],
      'engine_used': trace['engine_used'],
      'context_policy_used': trace['context_policy_used'],
      'answer_evidence_hash': trace['answer_evidence_hash'],
      'local_only_verified': trace['local_only_verified'],
    };
  }

  String _cleanRestoredAssistantMessage(String text) {
    final cleaned = text
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
    final report = ChatOutputSanitizer.inspect(
      cleaned,
      userMessage: 'restored chat history',
    );
    return report.status == 'accepted'
        ? report.cleanedText
        : 'That earlier local model answer was hidden because it contained invalid runtime text.';
  }
}
