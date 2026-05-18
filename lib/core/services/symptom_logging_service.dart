import '../database/wearable_sample_repository.dart';
import 'analytics_refresh_service.dart';
import 'rag_index_service.dart';
import 'gemma_task_service.dart';
import 'rag_memory_service.dart';
import 'risk_engine_service.dart';
import 'symptom_parser_service.dart';
import 'symptom_taxonomy_service.dart';

/// Thrown by [SymptomLoggingService.saveTranscript] when the optional health
/// gate is enabled and the Gemma classifier judges the input as non-health.
/// Callers should catch this and surface an inline error to the user.
class NonHealthSymptomException implements Exception {
  const NonHealthSymptomException({required this.reason});

  /// Short tag from the classifier (e.g. "not a body experience").
  final String reason;

  /// User-facing copy for inline error UI.
  String get userMessage =>
      'Not a recognized symptom — try again or pick from the list.';

  @override
  String toString() => 'NonHealthSymptomException($reason)';
}

class SymptomLoggingResult {
  const SymptomLoggingResult({
    required this.parseResult,
    required this.savedSymptom,
    required this.updatedRiskScore,
    this.savedIntakeEvents = const [],
    this.gemmaTaskRunId,
    this.extractionReviewId,
    this.symptomIndexedForRag = false,
    this.intakeIndexedForRag = const <int, bool>{},
  });

  final SymptomParseResult parseResult;
  final SymptomRecord savedSymptom;
  final FlareRiskScoreRecord? updatedRiskScore;
  final List<IntakeEventRecord> savedIntakeEvents;
  final int? gemmaTaskRunId;
  final int? extractionReviewId;
  final bool symptomIndexedForRag;
  final Map<int, bool> intakeIndexedForRag;
}

class SymptomLoggingService {
  SymptomLoggingService({
    required WearableSampleRepository repository,
    required SymptomParserService parser,
    required RiskEngineService riskEngineService,
    AnalyticsRefreshService? analyticsRefreshService,
    GemmaTaskService? gemmaTaskService,
    SymptomTaxonomyService? taxonomyService,
    RagIndexService? ragIndexService,
    RagMemoryService? ragMemoryService,
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _parser = parser,
        _riskEngineService = riskEngineService,
        _analyticsRefreshService = analyticsRefreshService,
        _gemmaTaskService = gemmaTaskService,
        _taxonomyService = taxonomyService,
        _ragIndexService = ragIndexService,
        _ragMemoryService = ragMemoryService,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final WearableSampleRepository _repository;
  final SymptomParserService _parser;
  final RiskEngineService _riskEngineService;
  final AnalyticsRefreshService? _analyticsRefreshService;
  final GemmaTaskService? _gemmaTaskService;
  final SymptomTaxonomyService? _taxonomyService;
  final RagIndexService? _ragIndexService;
  final RagMemoryService? _ragMemoryService;
  final DateTime Function() _nowProvider;

  Future<SymptomLoggingResult> saveTranscript({
    required String transcript,
    DateTime? loggedAt,
    bool preferGemma = true,
    bool enforceHealthGate = false,
  }) async {
    final effectiveLoggedAt = loggedAt?.toUtc() ?? _nowProvider();

    // Optional health-domain gate: ask Gemma whether the text is actually a
    // symptom before extracting/saving. Fails open when Gemma is unavailable
    // so we don't lock the user out of logging when the model can't load.
    if (enforceHealthGate && _gemmaTaskService != null) {
      final classification = await _gemmaTaskService.classifyIsHealthSymptom(
          transcript: transcript);
      if (classification.usedModelOutput && !classification.isHealthSymptom) {
        throw NonHealthSymptomException(reason: classification.reason);
      }
    }

    var parseResult = _parser.parse(
      transcript: transcript,
      loggedAt: effectiveLoggedAt,
    );
    GemmaSymptomExtractionResult? gemmaResult;
    if (preferGemma && _gemmaTaskService != null) {
      gemmaResult = await _gemmaTaskService.extractSymptom(
        transcript: transcript,
        loggedAt: effectiveLoggedAt,
        deterministicDraft: parseResult.structuredSymptom,
      );
      final symptom = gemmaResult.structuredSymptom;
      parseResult = SymptomParseResult(
        status: gemmaResult.status,
        structuredSymptom: symptom,
        needsClarification:
            gemmaResult.needsReview || symptom.severity1To10 == null,
        clarificationQuestion: gemmaResult.validationErrors.isNotEmpty
            ? gemmaResult.validationErrors.join(' ')
            : symptom.severity1To10 == null
                ? 'Would you say it was mild, moderate, or severe?'
                : null,
      );
    }
    final canonicalSymptomType = await _canonicalizeSymptomType(
      parseResult.structuredSymptom.symptomType,
    );
    final symptom = SymptomRecord(
      loggedAt: effectiveLoggedAt,
      symptomType: canonicalSymptomType,
      severity: parseResult.structuredSymptom.severity1To10,
      durationMinutes: parseResult.structuredSymptom.durationMinutes,
      mealRelation: parseResult.structuredSymptom.mealRelation,
      notes: parseResult.structuredSymptom.notes,
      sourceTranscript: parseResult.structuredSymptom.sourceTranscript,
      extractionMethod: gemmaResult?.extractionMethod ?? 'deterministic',
      extractionConfidence: parseResult.structuredSymptom.extractionConfidence,
      createdAt: _nowProvider(),
    );

    final insertedId = await _repository.insertSymptom(symptom);
    final symptomIndexedForRag = await _indexSymptomForRag(insertedId, symptom);
    final savedIntakeEvents = <IntakeEventRecord>[];
    final intakeIndexedForRag = <int, bool>{};
    for (final draft
        in gemmaResult?.intakeEvents ?? const <StructuredIntakeDraft>[]) {
      final event = IntakeEventRecord(
        eventType: draft.eventType,
        loggedAt: effectiveLoggedAt,
        dateLocal: _dateOnly(effectiveLoggedAt),
        source: 'gemma4_e2b_structured',
        confidence: draft.confidence,
        notes: draft.notes,
        metadataJson: draft.metadataJson,
        createdAt: _nowProvider(),
      );
      final id = await _repository.upsertIntakeEvent(event);
      intakeIndexedForRag[id] = await _indexIntakeForRag(id, event);
      savedIntakeEvents.add(
        IntakeEventRecord(
          id: id,
          eventType: event.eventType,
          loggedAt: event.loggedAt,
          dateLocal: event.dateLocal,
          source: event.source,
          confidence: event.confidence,
          notes: event.notes,
          metadataJson: event.metadataJson,
          createdAt: event.createdAt,
        ),
      );
    }
    if (gemmaResult?.reviewId != null) {
      await _gemmaTaskService?.confirmExtractionReview(
        reviewId: gemmaResult!.reviewId!,
        userConfirmedJson: {
          'symptom_id': insertedId,
          'symptom_type': symptom.symptomType,
          'severity': symptom.severity,
          'user_facing_description':
              parseResult.structuredSymptom.userFacingDescription,
          'uncertainty_notes': parseResult.structuredSymptom.uncertaintyNotes,
          'safety_flags': parseResult.structuredSymptom.safetyFlags,
          'source_transcript': parseResult.structuredSymptom.sourceTranscript,
          'intake_event_count': savedIntakeEvents.length,
        },
      );
    }
    if (_analyticsRefreshService != null) {
      await _analyticsRefreshService.refreshForSymptom(
        loggedAt: effectiveLoggedAt,
      );
    } else {
      final latestSummary = await _repository.getLatestDailySummary();
      if (latestSummary != null) {
        await _riskEngineService.recomputeDates([latestSummary.dateLocal]);
      }
    }
    final updatedRiskScore = await _repository.getLatestFlareRiskScore();

    return SymptomLoggingResult(
      parseResult: parseResult,
      savedSymptom: SymptomRecord(
        id: insertedId,
        loggedAt: symptom.loggedAt,
        symptomType: symptom.symptomType,
        severity: symptom.severity,
        durationMinutes: symptom.durationMinutes,
        mealRelation: symptom.mealRelation,
        notes: symptom.notes,
        sourceTranscript: symptom.sourceTranscript,
        extractionMethod: symptom.extractionMethod,
        extractionConfidence: symptom.extractionConfidence,
        createdAt: symptom.createdAt,
      ),
      updatedRiskScore: updatedRiskScore,
      savedIntakeEvents: savedIntakeEvents,
      gemmaTaskRunId: gemmaResult?.taskRunId,
      extractionReviewId: gemmaResult?.reviewId,
      symptomIndexedForRag: symptomIndexedForRag,
      intakeIndexedForRag: Map.unmodifiable(intakeIndexedForRag),
    );
  }

  /// Saves every entry from the `all_symptoms` list that was already extracted
  /// and stored in the pending-action payload, without re-running Gemma.
  /// Returns the list of inserted IDs, one per symptom in insertion order.
  Future<List<int>> saveAllFromPayload({
    required List<Map<String, Object?>> allSymptoms,
    required String sourceTranscript,
    required DateTime loggedAt,
  }) async {
    final now = _nowProvider();
    final ids = <int>[];
    for (final s in allSymptoms) {
      final rawType = s['symptom_type']?.toString() ?? 'unknown';
      final canonicalType = await _canonicalizeSymptomType(rawType);
      final record = SymptomRecord(
        loggedAt: loggedAt,
        symptomType: canonicalType,
        severity: (s['severity'] as num?)?.toInt(),
        durationMinutes: (s['duration_minutes'] as num?)?.toInt(),
        mealRelation: s['meal_relation']?.toString(),
        notes: s['notes']?.toString(),
        sourceTranscript: sourceTranscript,
        extractionMethod: 'gemma4_multi_symptom_payload',
        extractionConfidence: 1.0,
        createdAt: now,
      );
      final id = await _repository.insertSymptom(record);
      await _indexSymptomForRag(id, record);
      ids.add(id);
    }
    if (ids.isNotEmpty) {
      if (_analyticsRefreshService != null) {
        await _analyticsRefreshService.refreshForSymptom(loggedAt: loggedAt);
      } else {
        final latestSummary = await _repository.getLatestDailySummary();
        if (latestSummary != null) {
          await _riskEngineService.recomputeDates([latestSummary.dateLocal]);
        }
      }
    }
    return ids;
  }

  String _dateOnly(DateTime date) {
    final utc = date.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')}';
  }

  Future<String> _canonicalizeSymptomType(String symptomType) async {
    final taxonomyService = _taxonomyService;
    if (taxonomyService == null) return symptomType;
    return taxonomyService.canonicalizeId(symptomType);
  }

  Future<bool> _indexSymptomForRag(int id, SymptomRecord symptom) async {
    var indexed = false;
    final ragMemory = _ragMemoryService;
    if (ragMemory != null) {
      try {
        final result = await ragMemory.writeAndVerify(
          transactionId: 'symptom_tx_$id',
          sourceType: 'symptom',
          sourceId: '$id',
          text: _symptomMemoryText(id, symptom),
          metadata: {
            'symptom_type': symptom.symptomType,
            'logged_at': symptom.loggedAt.toUtc().toIso8601String(),
            'severity': symptom.severity,
            'source': 'symptom_logging_service',
          },
        );
        indexed = result.status == RagMemoryStatus.verified ||
            result.status == RagMemoryStatus.writtenToCorpus ||
            result.status == RagMemoryStatus.loadedInRag;
      } catch (_) {}
    }

    final ragCorpus = _ragIndexService;
    if (ragCorpus == null) return indexed;
    try {
      final result = await ragCorpus.indexSymptom(id, symptom);
      return indexed || result.isSuccess;
    } catch (_) {
      // Keep symptom save reliable even when the native corpus bridge is down.
      return indexed;
    }
  }

  Future<bool> _indexIntakeForRag(int id, IntakeEventRecord event) async {
    var indexed = false;
    final ragMemory = _ragMemoryService;
    if (ragMemory != null) {
      try {
        final result = await ragMemory.writeAndVerify(
          transactionId: 'intake_tx_$id',
          sourceType: 'intake_event',
          sourceId: '$id',
          text: _intakeMemoryText(id, event),
          metadata: {
            'event_type': event.eventType,
            'date_local': event.dateLocal,
            'logged_at': event.loggedAt.toUtc().toIso8601String(),
            'source': event.source,
          },
        );
        indexed = result.status == RagMemoryStatus.verified ||
            result.status == RagMemoryStatus.writtenToCorpus ||
            result.status == RagMemoryStatus.loadedInRag;
      } catch (_) {}
    }

    final ragCorpus = _ragIndexService;
    if (ragCorpus == null) return indexed;
    try {
      final result = await ragCorpus.indexIntakeEvent(id: id, event: event);
      return indexed || result.isSuccess;
    } catch (_) {
      // Keep symptom/intake save reliable when native corpus indexing is down.
      return indexed;
    }
  }

  String _symptomMemoryText(int id, SymptomRecord symptom) {
    return [
      'Symptom id: $id',
      'Logged at: ${symptom.loggedAt.toUtc().toIso8601String()}',
      'Type: ${symptom.symptomType}',
      if (symptom.severity != null) 'Severity: ${symptom.severity}',
      if (symptom.durationMinutes != null)
        'Duration minutes: ${symptom.durationMinutes}',
      if (symptom.mealRelation != null)
        'Meal relation: ${symptom.mealRelation}',
      if ((symptom.notes ?? '').trim().isNotEmpty) 'Notes: ${symptom.notes}',
      if ((symptom.sourceTranscript ?? '').trim().isNotEmpty)
        'Transcript: ${symptom.sourceTranscript}',
    ].join('\n');
  }

  String _intakeMemoryText(int id, IntakeEventRecord event) {
    return [
      'Intake event id: $id',
      'Event type: ${event.eventType}',
      'Logged at: ${event.loggedAt.toUtc().toIso8601String()}',
      'Date local: ${event.dateLocal}',
      'Source: ${event.source}',
      'Confidence: ${event.confidence}',
      if ((event.notes ?? '').trim().isNotEmpty) 'Notes: ${event.notes}',
      if (event.metadataJson.isNotEmpty)
        'Metadata: ${event.metadataJson.toString()}',
    ].join('\n');
  }
}
