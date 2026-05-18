import '../database/wearable_sample_repository.dart';
import 'analytics_refresh_service.dart';
import 'rag_index_service.dart';
import 'rag_memory_service.dart';
import 'risk_engine_service.dart';
import 'profile_service.dart';
import 'text_normalization_service.dart';

class MedicationLoggingDraft {
  const MedicationLoggingDraft({
    required this.eventType,
    required this.medicationName,
    this.dose,
    this.schedule,
    this.notes,
    required this.loggedAt,
    required this.sourceTranscript,
    required this.confidence,
    this.requiresClarification = false,
    this.clarificationPrompt,
  });

  final String eventType;
  final String medicationName;
  final String? dose;
  final String? schedule;
  final String? notes;
  final DateTime loggedAt;
  final String sourceTranscript;
  final double confidence;
  final bool requiresClarification;
  final String? clarificationPrompt;

  MedicationLoggingDraft copyWith({
    String? eventType,
    String? medicationName,
    String? dose,
    String? schedule,
    String? notes,
    DateTime? loggedAt,
    String? sourceTranscript,
    double? confidence,
    bool? requiresClarification,
    String? clarificationPrompt,
  }) {
    return MedicationLoggingDraft(
      eventType: eventType ?? this.eventType,
      medicationName: medicationName ?? this.medicationName,
      dose: dose ?? this.dose,
      schedule: schedule ?? this.schedule,
      notes: notes ?? this.notes,
      loggedAt: loggedAt ?? this.loggedAt,
      sourceTranscript: sourceTranscript ?? this.sourceTranscript,
      confidence: confidence ?? this.confidence,
      requiresClarification:
          requiresClarification ?? this.requiresClarification,
      clarificationPrompt: clarificationPrompt ?? this.clarificationPrompt,
    );
  }

  Map<String, Object?> toMetadataJson({
    double? finalConfidence,
    bool? isDuplicate,
    int? duplicateOfId,
    String? adherenceIndicator,
  }) {
    return {
      // === SCHEMA VERSIONING (for future evolution) ===
      'schema_version': 2,

      // === MEDICATION CORE FIELDS ===
      'medication_name': medicationName,
      if ((dose ?? '').trim().isNotEmpty) 'dose': dose?.trim(),
      if ((schedule ?? '').trim().isNotEmpty) 'schedule': schedule?.trim(),
      if ((notes ?? '').trim().isNotEmpty) 'notes': notes?.trim(),

      // === SOURCE & TRANSCRIPT ===
      'source_transcript': sourceTranscript,
      'source_type': 'user_voice_or_manual',

      // === CONFIDENCE TRACKING (parsing → user confirmation) ===
      'initial_parsing_confidence': confidence,
      'final_user_confidence': finalConfidence ?? confidence,
      'requires_clarification': requiresClarification,
      if (clarificationPrompt != null)
        'clarification_prompt': clarificationPrompt,

      // === REVIEW & CONFIRMATION ===
      'user_confirmed': true,
      'manually_edited': false, // Set to true if user modifies parsed fields
      // === DUPLICATE DETECTION ===
      'is_duplicate_of': isDuplicate ?? false,
      if (isDuplicate == true && duplicateOfId != null)
        'duplicate_of_event_id': duplicateOfId,

      // === ADHERENCE INDICATOR (for streak tracking) ===
      if (adherenceIndicator != null) 'adherence_indicator': adherenceIndicator,
      // Values: 'on_time', 'late', 'skipped', 'missed_dose', 'extra_dose'

      // === TIMESTAMPS & CONTEXT ===
      'event_type': eventType,
    };
  }
}

class MedicationLoggingResult {
  const MedicationLoggingResult({
    required this.savedEvent,
    required this.updatedRiskScore,
    required this.ragIndexed,
    this.ragStatus = '',
    this.ragTransactionId = '',
    this.ragVerified = false,
    this.isDuplicate = false,
    this.duplicateOfId,
  });

  final IntakeEventRecord savedEvent;
  final FlareRiskScoreRecord? updatedRiskScore;
  final bool ragIndexed;
  final String ragStatus; // 'verified', 'written_to_corpus', 'failed', etc.
  final String ragTransactionId; // e.g. 'med_tx_123'
  final bool ragVerified; // true if RAG query confirmed retrieval
  final bool isDuplicate; // true if detected as duplicate within 5 min
  final int? duplicateOfId; // ID of original event if duplicate detected
}

class MedicationLoggingService {
  MedicationLoggingService({
    required WearableSampleRepository repository,
    required ProfileService profileService,
    RiskEngineService? riskEngineService,
    AnalyticsRefreshService? analyticsRefreshService,
    RagIndexService? ragIndexService,
    RagMemoryService? ragMemoryService,
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _profileService = profileService,
        _riskEngineService = riskEngineService,
        _analyticsRefreshService = analyticsRefreshService,
        _ragIndexService = ragIndexService,
        _ragMemoryService = ragMemoryService,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final WearableSampleRepository _repository;
  final ProfileService _profileService;
  final RiskEngineService? _riskEngineService;
  final AnalyticsRefreshService? _analyticsRefreshService;
  final RagIndexService? _ragIndexService;
  final RagMemoryService? _ragMemoryService;
  final DateTime Function() _nowProvider;

  Future<MedicationLoggingDraft> buildDraftFromText({
    required String transcript,
    DateTime? loggedAt,
  }) async {
    final text = transcript.trim();
    final normalizedText = TextNormalizationService.normalizeForIntent(text);
    final lower = normalizedText.toLowerCase();
    final eventType = _eventTypeFor(lower);
    final dose = _extractDose(text);
    final schedule = _extractSchedule(lower);
    final medicationName = await _extractMedicationName(normalizedText, lower);
    final now = loggedAt?.toUtc() ?? _nowProvider();

    final needsClarification = medicationName.trim().isEmpty;
    final clarificationPrompt = needsClarification
        ? 'Please add the medication name before saving.'
        : null;

    return MedicationLoggingDraft(
      eventType: eventType,
      medicationName: medicationName,
      dose: dose,
      schedule: schedule,
      notes: text.isEmpty ? null : text,
      loggedAt: _inferTimestamp(now: now, lower: lower),
      sourceTranscript: text,
      confidence: needsClarification ? 0.5 : 0.9,
      requiresClarification: needsClarification,
      clarificationPrompt: clarificationPrompt,
    );
  }

  Future<MedicationLoggingResult> saveConfirmedDraft(
    MedicationLoggingDraft draft,
  ) async {
    final medicationName = draft.medicationName.trim();
    if (medicationName.isEmpty) {
      throw ArgumentError('Medication name is required.');
    }

    final noteParts = <String>[
      '${_eventLabel(draft.eventType)}: $medicationName',
      if ((draft.dose ?? '').trim().isNotEmpty)
        'dose ${(draft.dose ?? '').trim()}',
      if ((draft.schedule ?? '').trim().isNotEmpty)
        'timing ${(draft.schedule ?? '').trim()}',
      if ((draft.notes ?? '').trim().isNotEmpty)
        'details ${(draft.notes ?? '').trim()}',
    ];
    final notes = noteParts.join(' | ');

    // === DUPLICATE DETECTION (within 5 minutes) ===
    final recentDuplicate = await _detectRecentDuplicate(
      medicationName: medicationName,
      eventType: draft.eventType,
      loggedAt: draft.loggedAt,
    );

    // === DETERMINE ADHERENCE INDICATOR (for RAG/UI) ===
    final adherenceIndicator = _inferAdherenceIndicator(
      eventType: draft.eventType,
      schedule: draft.schedule,
      loggedAt: draft.loggedAt,
    );

    final record = IntakeEventRecord(
      eventType: draft.eventType,
      loggedAt: draft.loggedAt.toUtc(),
      dateLocal: _dateOnly(draft.loggedAt.toUtc()),
      source: 'medication_review_confirmed',
      confidence: draft.confidence.clamp(0.0, 1.0).toDouble(),
      notes: notes,
      metadataJson: draft.toMetadataJson(
        finalConfidence: draft.confidence,
        isDuplicate: recentDuplicate != null,
        duplicateOfId: recentDuplicate?.id,
        adherenceIndicator: adherenceIndicator,
      ),
      createdAt: _nowProvider().toUtc(),
    );

    final id = await _repository.upsertIntakeEvent(record);

    final saved = IntakeEventRecord(
      id: id,
      eventType: record.eventType,
      loggedAt: record.loggedAt,
      dateLocal: record.dateLocal,
      source: record.source,
      confidence: record.confidence,
      notes: record.notes,
      metadataJson: record.metadataJson,
      createdAt: record.createdAt,
    );

    final (ragIndexed, ragStatus, ragTxId, ragVerified) = await _indexForRag(
      id,
      saved,
    );

    if (_analyticsRefreshService != null) {
      await _analyticsRefreshService.refreshForIntakeEvent(
        loggedAt: draft.loggedAt,
      );
    } else {
      final latestSummary = await _repository.getLatestDailySummary();
      final riskEngineService = _riskEngineService;
      if (latestSummary != null && riskEngineService != null) {
        await riskEngineService.recomputeDates([latestSummary.dateLocal]);
      }
    }

    final updatedRiskScore = await _repository.getLatestFlareRiskScore();
    return MedicationLoggingResult(
      savedEvent: saved,
      updatedRiskScore: updatedRiskScore,
      ragIndexed: ragIndexed,
      ragStatus: ragStatus,
      ragTransactionId: ragTxId,
      ragVerified: ragVerified,
      isDuplicate: recentDuplicate != null,
      duplicateOfId: recentDuplicate?.id,
    );
  }

  String _eventTypeFor(String lower) {
    if (_containsAny(lower, const [
      'missed',
      'skipped',
      'forgot',
      'did not take',
      "didn't take",
      'didnt take',
    ])) {
      return 'medication_skipped';
    }
    return 'medication_taken';
  }

  DateTime _inferTimestamp({required DateTime now, required String lower}) {
    if (lower.contains('yesterday')) {
      return now.subtract(const Duration(days: 1));
    }
    return now;
  }

  Future<String> _extractMedicationName(String text, String lower) async {
    final profile = await _profileService.loadProfile();
    final profileMeds = profile.medications
        .map((item) => item.name.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);

    for (final med in profileMeds) {
      if (lower.contains(med.toLowerCase())) {
        return med;
      }
    }

    if (RegExp(
      r'\b(vitamin|vitamins|supplement|supplements)\b',
    ).hasMatch(lower)) {
      final vitaminMatch = RegExp(
        r'\b(vitamin\s+[a-z0-9]+|vitamins?|supplements?|b12|b-12|d3|vitamin\s+d3?)\b',
        caseSensitive: false,
      ).firstMatch(text);
      final raw = vitaminMatch?.group(1)?.trim();
      if (raw != null && raw.isNotEmpty) return _titleCase(raw);
      return 'Vitamins/supplements';
    }

    final shorthandSupplement = RegExp(
      r'\b(b12|b-12|d3|omega\s*3|iron|folate|multivitamin|probiotic)\b',
      caseSensitive: false,
    ).firstMatch(text);
    final shorthandRaw = shorthandSupplement?.group(1)?.trim();
    if (shorthandRaw != null && shorthandRaw.isNotEmpty) {
      return _titleCase(shorthandRaw);
    }

    final direct = RegExp(
      r'(?:log|logged|record|track|started|start|took|take|taken|taking|missed|skipped|skip|forgot|had|got|received|did)\s+(?:my\s+|the\s+|a\s+|an\s+)?([a-zA-Z0-9\- ]{2,48})',
      caseSensitive: false,
    ).firstMatch(text);
    if (direct != null) {
      final raw = direct.group(1) ?? '';
      final clipped = raw
          .split(
            RegExp(
              r'\b(?:for|because|due to|after|before|with)\b',
              caseSensitive: false,
            ),
          )
          .first
          .replaceAll(RegExp(r'\b(my|the|a|an)\b', caseSensitive: false), '')
          .replaceAll(
            RegExp(
              r'\b(took|take|taken|taking|missed|skipped|skip|forgot|had|got|received|did|started|start|log|logged|record|track)\b',
              caseSensitive: false,
            ),
            '',
          )
          .replaceAll(
            RegExp(
              r'\b(this|last|today|yesterday|morning|afternoon|evening|night|tonight|daily|weekly|shot|injection|infusion|dose|pill|tablet|capsule|vitamin|supplement)\b',
              caseSensitive: false,
            ),
            '',
          )
          .replaceAll(
            RegExp(
              r'\b\d+(?:\.\d+)?\s?(mg|mcg|g|ml|units?|iu|tablets?|capsules?|pills?)\b',
              caseSensitive: false,
            ),
            '',
          )
          .trim();
      if (clipped.isNotEmpty) {
        return _titleCase(clipped);
      }
    }

    if (lower.contains('biologic')) return 'Biologic';
    if (lower.contains('infusion')) return 'Infusion medication';
    if (lower.contains('injection') || lower.contains('shot')) {
      return 'Injection medication';
    }

    return '';
  }

  String? _extractDose(String text) {
    final match = RegExp(
      r'\b(\d+(?:\.\d+)?\s?(?:mg|mcg|g|ml|units?|iu|tablets?|capsules?|pills?))\b',
      caseSensitive: false,
    ).firstMatch(text);
    return match?.group(1)?.trim();
  }

  String? _extractSchedule(String lower) {
    if (lower.contains('yesterday')) return 'yesterday';
    if (lower.contains('this morning') || lower.contains('morning')) {
      return 'morning';
    }
    if (lower.contains('afternoon')) return 'afternoon';
    if (lower.contains('this evening') || lower.contains('evening')) {
      return 'evening';
    }
    if (lower.contains('night') || lower.contains('bedtime')) return 'night';
    if (lower.contains('daily') || lower.contains('every day')) return 'daily';
    if (lower.contains('weekly')) return 'weekly';
    return null;
  }

  /// Returns (ragIndexed, ragStatus, ragTransactionId, ragVerified).
  /// Refactored to support detailed RAG status tracking for MedicationLoggingResult.
  Future<(bool, String, String, bool)> _indexForRag(
    int id,
    IntakeEventRecord event,
  ) async {
    (bool, String, String, bool)? memoryResult;
    final ragMemory = _ragMemoryService;
    if (ragMemory != null) {
      try {
        final transactionId = 'med_tx_$id';
        final result = await ragMemory.writeAndVerify(
          transactionId: transactionId,
          sourceType: 'intake_event',
          sourceId: '$id',
          text: _medicationMemoryText(id, event),
          metadata: {
            'event_type': event.eventType,
            'date_local': event.dateLocal,
            'logged_at': event.loggedAt.toUtc().toIso8601String(),
            'source': event.source,
            'confidence': event.confidence,
            'medication_name':
                (event.metadataJson['medication_name'] ?? '').toString(),
            'dose': (event.metadataJson['dose'] ?? '').toString(),
            'adherence_indicator':
                (event.metadataJson['adherence_indicator'] ?? '').toString(),
          },
        );
        final indexed = result.status == RagMemoryStatus.verified ||
            result.status == RagMemoryStatus.writtenToCorpus;
        final verified = result.status == RagMemoryStatus.verified;
        memoryResult = (indexed, result.status, transactionId, verified);
      } catch (e) {
        memoryResult = (false, RagMemoryStatus.failed, '', false);
      }
    }

    final ragCorpus = _ragIndexService;
    if (ragCorpus == null) {
      return memoryResult ?? (false, 'not_configured', '', false);
    }
    try {
      final vectorResult = await ragCorpus.indexMedication(id, event);
      if (memoryResult != null) {
        return (
          memoryResult.$1 || vectorResult.isSuccess,
          memoryResult.$2,
          memoryResult.$3,
          memoryResult.$4
        );
      }
      return (vectorResult.isSuccess, 'indexed_vector', '', false);
    } catch (_) {
      return memoryResult ?? (false, 'corpus_write_failed', '', false);
    }
  }

  String _medicationMemoryText(int id, IntakeEventRecord event) {
    final medName =
        (event.metadataJson['medication_name'] ?? '').toString().trim();
    final dose = (event.metadataJson['dose'] ?? '').toString().trim();
    final schedule = (event.metadataJson['schedule'] ?? '').toString().trim();
    final confidence = event.confidence;
    final adherence =
        (event.metadataJson['adherence_indicator'] ?? '').toString().trim();

    // Structured, query-friendly format for Gemma RAG retrieval
    return [
      '=== Medication Event $id ===',
      'Event type: ${event.eventType} (${event.eventType == 'medication_taken' ? 'TAKEN' : 'SKIPPED'})',
      'Logged at: ${event.loggedAt.toUtc().toIso8601String()}',
      'Date local: ${event.dateLocal}',
      '',
      '--- Medication Details ---',
      if (medName.isNotEmpty) 'Medication: $medName',
      if (dose.isNotEmpty) 'Dose: $dose',
      if (schedule.isNotEmpty) 'Schedule/Timing: $schedule',
      '',
      '--- Confidence & Adherence ---',
      'Confidence score: ${(confidence * 100).toStringAsFixed(0)}%',
      if (adherence.isNotEmpty) 'Adherence indicator: $adherence',
      '',
      '--- Source & Review ---',
      'Source: ${event.source}',
      if ((event.notes ?? '').trim().isNotEmpty) 'User notes: ${event.notes}',
      '',
      '--- Full Context ---',
      'Metadata: ${event.metadataJson.toString()}',
    ].join('\n');
  }

  /// Detects if same medication was logged recently (within 5 minutes).
  /// Prevents accidental duplicate entries from repeated voice input or clicks.
  /// Returns the duplicate event record if found, null otherwise.
  Future<IntakeEventRecord?> _detectRecentDuplicate({
    required String medicationName,
    required String eventType,
    required DateTime loggedAt,
  }) async {
    try {
      // Get medication events from the last 5 minutes
      final fiveMinutesAgo = loggedAt.subtract(const Duration(minutes: 5));
      final recent = await _repository.getIntakeEventsBetween(
        start: fiveMinutesAgo,
        end: loggedAt,
      );

      // Filter for exact match: same med name, same event type, within 5 min
      for (final event in recent) {
        final metaMedName =
            (event.metadataJson['medication_name'] ?? '').toString().trim();
        final isExactMatch =
            metaMedName.toLowerCase() == medicationName.toLowerCase() &&
                event.eventType == eventType;
        final isWithinFiveMin =
            loggedAt.difference(event.loggedAt).inMinutes < 5;

        if (isExactMatch && isWithinFiveMin) {
          return event;
        }
      }
      return null;
    } catch (_) {
      // If duplicate detection fails, allow save to proceed
      return null;
    }
  }

  /// Infers adherence indicator from event type and schedule context.
  /// Supports "on_time", "late", "skipped", "missed_dose", "extra_dose".
  /// Can be enhanced later with profile medication schedules.
  String? _inferAdherenceIndicator({
    required String eventType,
    String? schedule,
    DateTime? loggedAt,
  }) {
    if (eventType == 'medication_skipped') {
      return 'skipped';
    }
    // For taken events, could expand later to detect "late" vs "on_time"
    // by comparing loggedAt against profile schedule
    if (eventType == 'medication_taken') {
      return 'on_time'; // Default; can be refined with profile schedules
    }
    return null;
  }

  bool _containsAny(String lower, List<String> needles) {
    for (final needle in needles) {
      if (lower.contains(needle)) return true;
    }
    return false;
  }

  String _dateOnly(DateTime date) {
    final utc = date.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')}';
  }

  String _eventLabel(String eventType) {
    return eventType == 'medication_skipped'
        ? 'Skipped medication'
        : 'Took medication';
  }

  String _titleCase(String value) {
    return value
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .map((part) => part[0].toUpperCase() + part.substring(1).toLowerCase())
        .join(' ');
  }
}
