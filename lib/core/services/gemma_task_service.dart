import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../database/wearable_sample_repository.dart';
import 'diagnostic_log_service.dart';
import 'ibd_checkin_service.dart';
import 'local_model_runtime.dart';
import 'profile_service.dart';
import 'setup_state_service.dart';
import 'symptom_parser_service.dart';

class StructuredIntakeDraft {
  const StructuredIntakeDraft({
    required this.eventType,
    required this.confidence,
    this.notes,
    this.metadataJson = const {},
  });

  final String eventType;
  final double confidence;
  final String? notes;
  final Map<String, Object?> metadataJson;

  Map<String, Object?> toJson() => {
        'event_type': eventType,
        'confidence': confidence,
        'notes': notes,
        'metadata_json': metadataJson,
      };
}

/// Result of GemmaTaskService.classifyIsHealthSymptom.
class HealthSymptomClassification {
  const HealthSymptomClassification({
    required this.isHealthSymptom,
    required this.reason,
    required this.usedModelOutput,
  });

  /// True when the classifier accepted the input (or when it failed open).
  final bool isHealthSymptom;

  /// Short tag indicating why this decision was made. Useful for telemetry.
  /// Examples: "physical pain symptom", "model_unavailable_failed_open".
  final String reason;

  /// True when Gemma actually classified; false when we failed open due to
  /// model unavailable / timeout / unparseable output.
  final bool usedModelOutput;
}

class GemmaSymptomExtractionResult {
  const GemmaSymptomExtractionResult({
    required this.status,
    required this.structuredSymptom,
    required this.intakeEvents,
    required this.needsReview,
    required this.validationErrors,
    required this.usedModelOutput,
    required this.extractionMethod,
    this.additionalSymptoms = const [],
    this.taskRunId,
    this.reviewId,
    this.rawJson = const {},
  });

  final String status;

  /// Primary (first) extracted symptom — always present.
  final StructuredSymptom structuredSymptom;

  /// Any additional symptoms extracted from the same message (index 1+).
  final List<StructuredSymptom> additionalSymptoms;
  final List<StructuredIntakeDraft> intakeEvents;
  final bool needsReview;
  final List<String> validationErrors;
  final bool usedModelOutput;
  final String extractionMethod;
  final int? taskRunId;
  final int? reviewId;
  final Map<String, Object?> rawJson;

  /// All symptoms: primary + additional.
  List<StructuredSymptom> get allSymptoms => [
        structuredSymptom,
        ...additionalSymptoms,
      ];
}

class GemmaLabCandidate {
  const GemmaLabCandidate({
    required this.labType,
    required this.valueNumeric,
    required this.unit,
    required this.drawnDate,
    required this.confidence,
    this.referenceHigh,
    this.labName,
    this.orderingProvider,
    this.abnormalFlag,
    this.sourceTextSnippet,
  });

  final String labType;
  final double valueNumeric;
  final String unit;
  final String drawnDate;
  final double confidence;
  final double? referenceHigh;
  final String? labName;
  final String? orderingProvider;
  final bool? abnormalFlag;
  final String? sourceTextSnippet;

  Map<String, Object?> toJson() => {
        'lab_type': labType,
        'value_numeric': valueNumeric,
        'unit': unit,
        'drawn_date': drawnDate,
        'reference_high': referenceHigh,
        'lab_name': labName,
        'ordering_provider': orderingProvider,
        'abnormal_flag': abnormalFlag,
        'confidence': confidence,
        'source_text_snippet': sourceTextSnippet,
      };

  LabValueRecord toLabValueRecord(DateTime now) => LabValueRecord(
        drawnDate: drawnDate,
        labType: labType,
        valueNumeric: valueNumeric,
        unit: unit,
        referenceHigh: referenceHigh,
        labName: labName,
        orderingProvider: orderingProvider,
        notes: abnormalFlag == null
            ? sourceTextSnippet
            : [
                if (abnormalFlag == true) 'Flagged abnormal on source report.',
                if (sourceTextSnippet != null) sourceTextSnippet,
              ].join(' '),
        createdAt: now,
        updatedAt: now,
      );
}

class GemmaLabExtractionResult {
  const GemmaLabExtractionResult({
    required this.status,
    required this.candidates,
    required this.validationErrors,
    required this.usedModelOutput,
    required this.needsReview,
    this.taskRunId,
    this.reviewId,
  });

  final String status;
  final List<GemmaLabCandidate> candidates;
  final List<String> validationErrors;
  final bool usedModelOutput;
  final bool needsReview;
  final int? taskRunId;
  final int? reviewId;
}

class GemmaCheckInExtractionResult {
  const GemmaCheckInExtractionResult({
    required this.status,
    required this.confidence,
    required this.usedModelOutput,
    this.bellyPain,
    this.stoolFrequencyToday,
    this.rectalBleeding,
    this.urgency,
    this.nocturnalStools,
    this.fatigue,
    this.fever,
    this.missedMedication,
    this.freeTextNotes,
    this.taskRunId,
  });

  final String status;
  final int? bellyPain;
  final int? stoolFrequencyToday;
  final bool? rectalBleeding;
  final bool? urgency;
  final bool? nocturnalStools;
  final bool? fatigue;
  final bool? fever;
  final bool? missedMedication;
  final String? freeTextNotes;
  final double confidence;
  final bool usedModelOutput;
  final int? taskRunId;

  Map<String, Object?> toPayloadJson() => {
        'belly_pain': bellyPain,
        'stool_frequency_today': stoolFrequencyToday,
        'rectal_bleeding': rectalBleeding,
        'urgency': urgency,
        'nocturnal_stools': nocturnalStools,
        'fatigue': fatigue,
        'fever': fever,
        'missed_medication': missedMedication,
        'free_text_notes': freeTextNotes,
        'confidence': confidence,
        'used_model_output': usedModelOutput,
      };
}

class DoctorSummaryResult {
  const DoctorSummaryResult({
    required this.status,
    required this.summaryText,
    required this.contextSummaryJson,
    required this.usedModelOutput,
    this.taskRunId,
    this.summaryId,
  });

  final String status;
  final String summaryText;
  final Map<String, Object?> contextSummaryJson;
  final bool usedModelOutput;
  final int? taskRunId;
  final int? summaryId;
}

class GemmaPromptBudget {
  const GemmaPromptBudget({
    this.maxPromptChars = 16000,
    this.maxStringChars = 1200,
    this.maxListItems = 30,
  });

  final int maxPromptChars;
  final int maxStringChars;
  final int maxListItems;

  bool fits({
    required String systemPrompt,
    required String userPrompt,
    required Map<String, Object?> groundedContext,
  }) {
    final context = jsonEncode(groundedContext);
    return systemPrompt.length + userPrompt.length + context.length <=
        maxPromptChars;
  }

  Map<String, Object?> compact(Map<String, Object?> value) {
    return value.map((key, item) => MapEntry(key, _compactValue(item)));
  }

  Object? _compactValue(Object? value) {
    if (value is String) {
      if (value.length <= maxStringChars) return value;
      return '${value.substring(0, maxStringChars)}...';
    }
    if (value is List) {
      return value
          .take(maxListItems)
          .map(_compactValue)
          .toList(growable: false);
    }
    if (value is Map) {
      return value.map(
        (key, item) => MapEntry(key.toString(), _compactValue(item)),
      );
    }
    return value;
  }
}

class GemmaTaskService {
  GemmaTaskService({
    required WearableSampleRepository repository,
    required LocalModelRuntime runtime,
    SymptomParserService deterministicParser = const SymptomParserService(),
    DiagnosticLogService? diagnosticLogService,
    GemmaPromptBudget promptBudget = const GemmaPromptBudget(),
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _runtime = runtime,
        _deterministicParser = deterministicParser,
        _diagnosticLogService = diagnosticLogService,
        _promptBudget = promptBudget,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  static const symptomPromptVersion = 'symptom_extract_v2';
  static const labPromptVersion = 'lab_text_extract_v1';
  static const checkInPromptVersion = 'checkin_extract_v1';
  static const doctorSummaryPromptVersion = 'doctor_summary_v1';
  static const schemaVersion = 'gemma_task_schema_v1';
  static const modelId = 'gemma-4-e2b';

  final WearableSampleRepository _repository;
  final LocalModelRuntime _runtime;
  final SymptomParserService _deterministicParser;
  final DiagnosticLogService? _diagnosticLogService;
  final GemmaPromptBudget _promptBudget;
  final DateTime Function() _nowProvider;

  /// Yes/no classifier: is [transcript] describing a health symptom suitable
  /// for the symptom log? Returns `true` if so, `false` to reject as non-health.
  ///
  /// Fails open: if Gemma is unavailable, times out, or returns an unparseable
  /// answer, returns `true` so the caller's normal extraction path can run. The
  /// gate is opt-in for callers that want stricter input filtering.
  Future<HealthSymptomClassification> classifyIsHealthSymptom({
    required String transcript,
  }) async {
    final trimmed = transcript.trim();
    if (trimmed.isEmpty) {
      return const HealthSymptomClassification(
        isHealthSymptom: false,
        reason: 'empty_input',
        usedModelOutput: false,
      );
    }

    final status = await _ensureRuntimeLoaded('symptom_classify');
    if (!status.isModelLoaded) {
      return const HealthSymptomClassification(
        isHealthSymptom: true,
        reason: 'model_unavailable_failed_open',
        usedModelOutput: false,
      );
    }

    const systemPrompt =
        '''You decide if a user message describes a physical health symptom they are experiencing right now or recently — pain, GI, fatigue, fever, bleeding, dizziness, urinary, joint, skin, sleep, appetite, mental-health distress, medication side effects, or any bodily symptom.

Reply in this exact two-line format and nothing else:
ANSWER: YES
or
ANSWER: NO
REASON: <short phrase>

Examples that are symptoms (ANSWER: YES):
- "stomach pain after lunch"
- "loose stools all morning"
- "really exhausted today"
- "headache 3/10"
- "bloody stool"
- "felt nauseous after taking my meds"
- "chest tightness"
- "anxious all evening"
- "dizzy when I stood up"
- "stuffy nose and sore throat"

Examples that are NOT symptoms (ANSWER: NO):
- "buy groceries"
- "remind me to call mom"
- "what is my flare risk today"
- "log workout"
- "the weather is nice"
- "show my labs"
- "summarize this week"
- "I love pizza"

Accept typos and synonyms. If the text is clearly a body experience or feeling, answer YES even if spelled wrong.''';
    final userPrompt = 'User text: "${trimmed.replaceAll('"', "'")}"';

    final response = await _generateBounded(
      LocalModelRequest(
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        groundedContext: const {'task': 'symptom_classify'},
        maxTokens: 32,
        temperature: 0.0,
        taskType: 'symptom_classify',
        modelRole: 'utility_fast',
        contextPolicy: 'minimal',
        privacyMode: 'local_only',
      ),
    );

    if (response.status == 'timeout' ||
        response.status == 'failed' ||
        response.status == 'unavailable') {
      return HealthSymptomClassification(
        isHealthSymptom: true,
        reason: 'model_${response.status}_failed_open',
        usedModelOutput: false,
      );
    }

    final answer = _parseClassifierAnswer(response.outputText);
    if (answer == null) {
      return const HealthSymptomClassification(
        isHealthSymptom: true,
        reason: 'unparseable_failed_open',
        usedModelOutput: false,
      );
    }
    return HealthSymptomClassification(
      isHealthSymptom: answer.$1,
      reason: answer.$2,
      usedModelOutput: true,
    );
  }

  /// Parses the classifier's "ANSWER: YES/NO\nREASON: ..." format. Returns
  /// (isSymptom, reason) on success, null on failure.
  (bool, String)? _parseClassifierAnswer(String text) {
    final lines = text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    bool? isSymptom;
    var reason = 'classifier_decision';
    for (final line in lines) {
      final upper = line.toUpperCase();
      if (upper.startsWith('ANSWER:')) {
        final rest = upper.substring('ANSWER:'.length).trim();
        if (rest.startsWith('YES')) isSymptom = true;
        if (rest.startsWith('NO')) isSymptom = false;
      } else if (upper.startsWith('REASON:')) {
        final r = line.substring('REASON:'.length).trim();
        if (r.isNotEmpty) reason = r;
      }
    }
    if (isSymptom == null) return null;
    return (isSymptom, reason);
  }

  Future<GemmaSymptomExtractionResult> extractSymptom({
    required String transcript,
    required DateTime loggedAt,
    StructuredSymptom? deterministicDraft,
  }) async {
    final fallbackDraft = deterministicDraft ??
        _deterministicParser
            .parse(transcript: transcript, loggedAt: loggedAt)
            .structuredSymptom;
    final sourceHash = _hash(transcript);
    final inputSummary = {
      'source_kind': 'speech_transcript',
      'source_hash': sourceHash,
      'transcript_chars': transcript.length,
      'deterministic_symptom_type': fallbackDraft.symptomType,
      'deterministic_has_severity': fallbackDraft.severity1To10 != null,
    };
    final systemPrompt =
        '''You are Gemma 4 running locally inside Gemma Flares. Extract ALL IBD symptoms mentioned in the transcript.
Return JSON only. Do not diagnose. Do not give medical advice.

CRITICAL OUTPUT RULE: ALWAYS use the "symptoms" array wrapper — never output a flat object.
- One symptom → {"symptoms":[{...one entry...}],...}
- Two symptoms → {"symptoms":[{...first...},{...second...}],...}
Every distinct symptom the user mentions must be its own entry in the array.

Word-variant recognition (non-exhaustive — use your understanding):
- "bloated", "bloating", "gassy and bloated" → symptom_type: "bloating"
- "stomach pain", "belly hurts", "gut ache", "tummy sore", "stomach cramps" → symptom_type: "pain"
- "the runs", "loose stools", "going a lot", "bathroom urgency" → symptom_type: "diarrhea"
- "nauseous", "feel sick", "queasy" → symptom_type: "nausea"
- "exhausted", "wiped out", "no energy", "tired all day", "tired", "fatigued", "drained", "low energy" → symptom_type: "fatigue"
- "rushing to the bathroom", "can't hold it" → symptom_type: "urgency"
- "blood in stool", "bloody stool", "blood when wiping" → symptom_type: "blood"
- "mucus in stool", "pus in stool", "slimy stool" → symptom_type: "mucus_stool"
- "fecal incontinence", "poop accident", "stool leakage" → symptom_type: "fecal_incontinence"
- "mouth ulcers", "canker sores" → symptom_type: "mouth_sores"
- "night sweats", "woke up drenched" → symptom_type: "night_sweats"
- "joint pain", "joints hurt" → symptom_type: "joint_pain"
- "fistula drainage", "perianal abscess" → symptom_type: "fistula"
- "fissure", "anal tear" → symptom_type: "anal_fissure"
- "headache", "migraine" → symptom_type: "headache_migraine"
- "no appetite", "lost appetite" → symptom_type: "appetite_loss"

Scale rules:
- "3/3" or "3 out of 3" means the MAXIMUM on a 0-3 scale — map to severity_1_to_10: 10.
- "3/10" or "3 out of 10" means 3 on a 0-10 scale — map to severity_1_to_10: 3.
- "2/3" means 2 on the 0-3 scale — map to severity_1_to_10: 7.
- "4 poops in 1 hour" means symptom_type "diarrhea", notes "4 times in 1 hour", duration_minutes: 60.
- Preserve the user's intent — do not invent severity if not given.

Duration synonym rules (convert to duration_minutes):
- "all day" or "the whole day" → duration_minutes: 1440
- "all morning" → duration_minutes: 360
- "all night" or "all evening" → duration_minutes: 480
- "a few hours" or "several hours" → duration_minutes: 180
- "an hour" or "about an hour" → duration_minutes: 60
- "half an hour" or "30 minutes" → duration_minutes: 30
- "all week" or "for days" → do NOT set duration_minutes; put "ongoing for days" in notes
- "lasts all day" → duration_minutes: 1440 (NOT 720)

Frequency and trigger rules (put in notes field — there is no separate frequency field):
- "daily", "every day", "every morning" → notes: "daily"
- "after eating gluten", "food trigger", "after meals" → notes: include trigger detail
- Preserve the user's exact words for frequency and trigger in the notes field.''';
    final userPrompt = '''Transcript: "$transcript"
Deterministic draft (single best guess — you may find more symptoms than this):
${jsonEncode(_symptomToJson(fallbackDraft))}

Extract EVERY symptom mentioned. If two symptoms are present, output two entries. Return exactly:
{"symptoms":[{"symptom_type":"pain|cramping|diarrhea|urgency|nausea|bloating|fatigue|blood|mucus_stool|fever|night_sweats|mouth_sores|constipation|fecal_incontinence|weight_loss|appetite_loss|fistula|joint_pain|skin|eye|anal_fissure|obstruction|vomiting|dehydration|malnutrition|dizziness|back_pain|urinary_urgency|headache_migraine|other_health_symptom|other","severity_1_to_10":1-10|null,"duration_minutes":number|null,"meal_relation":"after_lunch|before_lunch|after_dinner|before_dinner|after_breakfast|before_breakfast|after_meal|before_meal|null","notes":"short note","confidence":0.0-1.0}],"intake_events":[{"event_type":"medication_taken|medication_skipped|caffeine|alcohol|water|meal","confidence":0.0-1.0,"notes":"short note"}],"uncertainty_notes":["short note"]}''';

    final generated = await _generateJsonTask(
      taskType: 'symptom_extract',
      promptVersion: symptomPromptVersion,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      groundedContext: {'task': 'symptom_extract'},
      maxTokens: 180,
      temperature: 0.1,
      inputSummaryJson: inputSummary,
      fallbackOutputJson: _symptomToJson(fallbackDraft),
      validate: _validateSymptomJson,
    );

    final rawParsed = generated.json;
    // Support both old single-symptom format and new multi-symptom array format
    final List<Map<String, Object?>> parsedSymptoms;
    final Map<String, Object?> parsedForValidation;
    if (rawParsed != null && rawParsed['symptoms'] is List) {
      final symptomList = rawParsed['symptoms'] as List;
      parsedSymptoms = symptomList
          .whereType<Map>()
          .map((m) => Map<String, Object?>.from(m))
          .toList(growable: false);
      // For validation: check the first symptom entry
      parsedForValidation = parsedSymptoms.isNotEmpty
          ? parsedSymptoms.first
          : _symptomToJson(fallbackDraft);
    } else if (rawParsed != null) {
      // Legacy single-symptom response
      parsedSymptoms = [rawParsed];
      parsedForValidation = rawParsed;
    } else {
      parsedSymptoms = [_symptomToJson(fallbackDraft)];
      parsedForValidation = _symptomToJson(fallbackDraft);
    }

    final validationErrors = _validateSymptomJson(parsedForValidation);
    final usedModelOutput =
        generated.usedModelOutput && validationErrors.isEmpty;

    final primarySymptom = usedModelOutput && parsedSymptoms.isNotEmpty
        ? _symptomFromJson(parsedSymptoms.first, fallbackDraft, loggedAt)
        : fallbackDraft;

    final additionalSymptoms = usedModelOutput && parsedSymptoms.length > 1
        ? parsedSymptoms
            .skip(1)
            .map((s) => _symptomFromJson(s, fallbackDraft, loggedAt))
            .toList(growable: false)
        : const <StructuredSymptom>[];

    final intakeEvents = usedModelOutput
        ? _intakeDraftsFromJson(rawParsed ?? {})
        : const <StructuredIntakeDraft>[];

    final reviewId = await _repository.insertGemmaExtractionReview(
      GemmaExtractionReviewRecord(
        taskRunId: generated.taskRunId,
        reviewType: 'symptom_extract',
        sourceKind: 'speech_transcript',
        sourceHash: sourceHash,
        extractedJson: {
          'symptom': _symptomToJson(primarySymptom),
          'additional_symptoms':
              additionalSymptoms.map(_symptomToJson).toList(growable: false),
          'intake_events': intakeEvents
              .map((event) => event.toJson())
              .toList(growable: false),
        },
        userConfirmedJson: const {},
        reviewStatus:
            usedModelOutput ? 'pending_user_confirm' : 'fallback_used',
        createdAt: _nowProvider(),
      ),
    );

    return GemmaSymptomExtractionResult(
      status: usedModelOutput ? 'success' : 'fallback',
      structuredSymptom: primarySymptom,
      additionalSymptoms: additionalSymptoms,
      intakeEvents: intakeEvents,
      needsReview:
          validationErrors.isNotEmpty || primarySymptom.severity1To10 == null,
      validationErrors: validationErrors,
      usedModelOutput: usedModelOutput,
      extractionMethod:
          usedModelOutput ? 'gemma4_e2b_structured' : 'deterministic',
      taskRunId: generated.taskRunId,
      reviewId: reviewId,
      rawJson: parsedForValidation,
    );
  }

  Future<GemmaLabExtractionResult> extractLabsFromText({
    required String reportText,
  }) async {
    final cleaned = reportText.trim();
    final sourceHash = _hash(cleaned);
    if (cleaned.isEmpty) {
      return const GemmaLabExtractionResult(
        status: 'empty_input',
        candidates: [],
        validationErrors: ['Lab report text is empty.'],
        usedModelOutput: false,
        needsReview: true,
      );
    }

    final deterministic = _deterministicLabCandidates(cleaned);
    final inputSummary = {
      'source_kind': 'lab_report_text',
      'source_hash': sourceHash,
      'text_chars': cleaned.length,
      'deterministic_candidate_count': deterministic.length,
    };
    final systemPrompt =
        '''You are Gemma 4 running locally inside Gemma Flares. Extract IBD-related lab values from OCR or pasted lab-report text.
Return JSON only. Preserve units. Do not diagnose.''';
    final userPrompt = '''Lab report text:
${_truncate(cleaned, 1300)}

Extract lab values when present, including inflammatory markers, CBC, chemistry/CMP, liver, kidney, electrolytes, nutrients, thyroid, stool, and vitamin tests.
Return exactly:
{"drawn_date":"YYYY-MM-DD|null","lab_name":"string|null","ordering_provider":"string|null","labs":[{"lab_type":"canonical_lowercase_lab_key","value_numeric":number,"unit":"string","reference_high":number|null,"abnormal_flag":true|false|null,"confidence":0.0-1.0,"source_text_snippet":"short source phrase"}]}''';

    final generated = await _generateJsonTask(
      taskType: 'lab_text_extract',
      promptVersion: labPromptVersion,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      groundedContext: {'task': 'lab_text_extract'},
      maxTokens: 220,
      temperature: 0.0,
      inputSummaryJson: inputSummary,
      fallbackOutputJson: {
        'labs': deterministic.map((item) => item.toJson()).toList(),
      },
      validate: _validateLabJson,
    );

    final fromModel = generated.json == null
        ? const <GemmaLabCandidate>[]
        : _labCandidatesFromJson(generated.json!, _todayDate());
    final candidates = fromModel.isNotEmpty ? fromModel : deterministic;
    final validationErrors = candidates
        .expand((candidate) => _validateLabCandidate(candidate))
        .toList(growable: false);
    final usedModelOutput = generated.usedModelOutput &&
        fromModel.isNotEmpty &&
        validationErrors.isEmpty;
    final reviewId = await _repository.insertGemmaExtractionReview(
      GemmaExtractionReviewRecord(
        taskRunId: generated.taskRunId,
        reviewType: 'lab_text_extract',
        sourceKind: 'lab_report_text',
        sourceHash: sourceHash,
        extractedJson: {
          'labs': candidates.map((item) => item.toJson()).toList(),
        },
        userConfirmedJson: const {},
        reviewStatus:
            candidates.isEmpty ? 'no_candidates' : 'pending_user_confirm',
        createdAt: _nowProvider(),
      ),
    );

    return GemmaLabExtractionResult(
      status: candidates.isEmpty
          ? 'no_candidates'
          : usedModelOutput
              ? 'success'
              : 'fallback_or_review',
      candidates: candidates,
      validationErrors: validationErrors,
      usedModelOutput: usedModelOutput,
      needsReview: true,
      taskRunId: generated.taskRunId,
      reviewId: reviewId,
    );
  }

  Future<GemmaCheckInExtractionResult> extractCheckIn({
    required String transcript,
    required DateTime loggedAt,
  }) async {
    final sourceHash = _hash(transcript);
    final systemPrompt =
        '''You are Gemma 4 running locally inside Gemma Flares. Extract IBD check-in fields from a user message.
Return JSON only. Do not diagnose.

Scale rules:
- Default scale is 0-3 (IBD standard) unless the user says "out of 10".
- "3/3" = max pain on the 0-3 scale (belly_pain: 3).
- "3/10" = 3 on a 0-10 scale; convert: belly_pain = round(3/10 * 3) = 1.
- "2/3" = 2 on the 0-3 scale (belly_pain: 2).
- "4 poops in 1 hour" = stool_frequency_today: 4, free_text_notes: "4 in 1 hour".''';

    final userPrompt = '''Message: "$transcript"

Extract check-in fields. Return exactly:
{"belly_pain":0-3|null,"stool_frequency_today":number|null,"rectal_bleeding":true|false|null,"urgency":true|false|null,"nocturnal_stools":true|false|null,"fatigue":true|false|null,"fever":true|false|null,"missed_medication":true|false|null,"free_text_notes":"anything not captured above or null","confidence":0.0-1.0}''';

    final generated = await _generateJsonTask(
      taskType: 'log_checkin',
      promptVersion: checkInPromptVersion,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      groundedContext: {'task': 'checkin_extract'},
      maxTokens: 140,
      temperature: 0.1,
      inputSummaryJson: {
        'source_kind': 'chat_message',
        'source_hash': sourceHash,
        'transcript_chars': transcript.length,
      },
      fallbackOutputJson: {'confidence': 0.0},
      validate: _validateCheckInJson,
    );

    final parsed = generated.json ?? {};
    final usedModelOutput =
        generated.usedModelOutput && _validateCheckInJson(parsed).isEmpty;

    return GemmaCheckInExtractionResult(
      status: usedModelOutput ? 'success' : 'fallback',
      bellyPain: _toInt(parsed['belly_pain']),
      stoolFrequencyToday: _toInt(parsed['stool_frequency_today']),
      rectalBleeding: parsed['rectal_bleeding'] as bool?,
      urgency: parsed['urgency'] as bool?,
      nocturnalStools: parsed['nocturnal_stools'] as bool?,
      fatigue: parsed['fatigue'] as bool?,
      fever: parsed['fever'] as bool?,
      missedMedication: parsed['missed_medication'] as bool?,
      freeTextNotes: parsed['free_text_notes'] as String?,
      confidence: _toDouble(parsed['confidence']) ?? 0.0,
      usedModelOutput: usedModelOutput,
      taskRunId: generated.taskRunId,
    );
  }

  List<String> _validateCheckInJson(Map<String, Object?> json) {
    if (json.isEmpty) return ['Empty check-in response'];
    return const [];
  }

  int? _toInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value);
    return null;
  }

  double? _toDouble(Object? value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  Future<void> confirmExtractionReview({
    required int reviewId,
    required Map<String, Object?> userConfirmedJson,
  }) {
    return _repository.updateGemmaExtractionReviewConfirmation(
      id: reviewId,
      userConfirmedJson: userConfirmedJson,
      reviewStatus: 'confirmed',
      confirmedAt: _nowProvider(),
    );
  }

  Future<Map<String, Object?>> buildDoctorSummaryContext({
    int days = 30,
    DateTime? startDate,
    DateTime? endDate,
    bool allDates = false,
  }) async {
    final now = _nowProvider();
    final today = _dateOnly(now);

    // Determine window bounds from the most-specific source wins:
    //  custom startDate+endDate > allDates flag > days param.
    final String start;
    final bool skipEvidenceAdjustment;
    if (startDate != null && endDate != null) {
      // User picked an explicit range — respect it exactly.
      start = _dateOnly(startDate.isBefore(endDate) ? startDate : endDate);
      skipEvidenceAdjustment = true;
    } else if (allDates) {
      // Load everything back to the earliest possible app data.
      start = '2020-01-01';
      skipEvidenceAdjustment = false;
    } else {
      start = _dateOnly(now.subtract(Duration(days: days - 1)));
      skipEvidenceAdjustment = false;
    }
    final String endBound = (startDate != null && endDate != null)
        ? _dateOnly(endDate.isAfter(startDate) ? endDate : startDate)
        : today;

    var effectiveStart = start;
    var effectiveEnd = endBound;
    var effectiveDays = _inclusiveDays(effectiveStart, effectiveEnd);

    final summaryScores = await _loadSummaryRiskScores(start: start);
    final futures = await Future.wait([
      _repository.getDailySummaries(),
      _repository.getSymptomsBetween(
        start: DateTime.parse('${start}T00:00:00Z'),
        end: DateTime.parse('${endBound}T23:59:59Z'),
      ),
      _repository.getLabValuesInRange(start, endBound),
      _repository.getEndoscopyRecordsInRange(start, endBound),
      _repository.getPro2SurveysInRange(start, endBound),
      _repository.getDailyContextFeatures(),
      _repository.getLatestBaselineSnapshot(),
      _repository.getAppSettingMap(SetupStateService.setupStatusKey),
      _repository.getAppSettingMap(ProfileService.profileKey),
    ]);
    final allSummaries = futures[0] as List<DailySummaryRecord>;
    final initialSymptoms = futures[1] as List<SymptomRecord>;
    final initialLabs = futures[2] as List<LabValueRecord>;
    final initialProcedures = futures[3] as List<EndoscopyRecord>;
    final initialCheckIns = futures[4] as List<Pro2SurveyRecord>;
    final allContext = futures[5] as List<DailyContextFeatureRecord>;

    final latestEvidenceDate = _latestDoctorSummaryEvidenceDate(
      today: today,
      summaries: allSummaries,
      scores: summaryScores,
      symptoms: initialSymptoms,
      labs: initialLabs,
      procedures: initialProcedures,
      checkIns: initialCheckIns,
      context: allContext,
    );
    // Skip auto-adjustment when the caller has pinned an explicit date range.
    if (!skipEvidenceAdjustment &&
        latestEvidenceDate != null &&
        latestEvidenceDate.compareTo(endBound) < 0) {
      effectiveEnd = latestEvidenceDate;
      if (allDates) {
        // Keep effectiveStart at the beginning; don't slide the window.
        effectiveDays = _inclusiveDays(effectiveStart, effectiveEnd);
      } else {
        effectiveStart = _dateOnly(
          DateTime.parse('${effectiveEnd}T00:00:00Z')
              .subtract(Duration(days: days - 1)),
        );
        effectiveDays = days;
      }
    }

    var summaries = allSummaries
        .where(
          (item) =>
              item.dateLocal.compareTo(effectiveStart) >= 0 &&
              item.dateLocal.compareTo(effectiveEnd) <= 0,
        )
        .toList(growable: false);
    var scores = summaryScores
        .where(
          (item) =>
              item.dateLocal.compareTo(effectiveStart) >= 0 &&
              item.dateLocal.compareTo(effectiveEnd) <= 0,
        )
        .toList(growable: false);
    var symptoms = initialSymptoms.where((item) {
      final date = _dateOnly(item.loggedAt);
      return date.compareTo(effectiveStart) >= 0 &&
          date.compareTo(effectiveEnd) <= 0;
    }).toList(growable: false);
    var labs = initialLabs
        .where(
          (item) =>
              item.drawnDate.compareTo(effectiveStart) >= 0 &&
              item.drawnDate.compareTo(effectiveEnd) <= 0,
        )
        .toList(growable: false);
    var procedures = initialProcedures
        .where(
          (item) =>
              item.procedureDate.compareTo(effectiveStart) >= 0 &&
              item.procedureDate.compareTo(effectiveEnd) <= 0,
        )
        .toList(growable: false);
    var checkIns = initialCheckIns
        .where(
          (item) =>
              item.surveyDate.compareTo(effectiveStart) >= 0 &&
              item.surveyDate.compareTo(effectiveEnd) <= 0,
        )
        .toList(growable: false);
    var context = allContext
        .where(
          (item) =>
              item.dateLocal.compareTo(effectiveStart) >= 0 &&
              item.dateLocal.compareTo(effectiveEnd) <= 0,
        )
        .toList(growable: false);

    if (effectiveStart != start || effectiveEnd != today) {
      final shiftedScores = await _loadSummaryRiskScores(start: effectiveStart);
      scores = shiftedScores
          .where((row) => row.dateLocal.compareTo(effectiveEnd) <= 0)
          .toList(growable: false);
      symptoms = await _repository.getSymptomsBetween(
        start: DateTime.parse('${effectiveStart}T00:00:00Z'),
        end: DateTime.parse('${effectiveEnd}T23:59:59Z'),
      );
      labs = await _repository.getLabValuesInRange(
        effectiveStart,
        effectiveEnd,
      );
      procedures = await _repository.getEndoscopyRecordsInRange(
        effectiveStart,
        effectiveEnd,
      );
      checkIns = await _repository.getPro2SurveysInRange(
        effectiveStart,
        effectiveEnd,
      );
      context = allContext
          .where(
            (item) =>
                item.dateLocal.compareTo(effectiveStart) >= 0 &&
                item.dateLocal.compareTo(effectiveEnd) <= 0,
          )
          .toList(growable: false);
    }

    final symptomJson =
        symptoms.map(_symptomRecordToDoctorSummaryJson).toList(growable: false);
    final checkInJson = checkIns
        .map(IbdCheckInService.evidenceForSurvey)
        .toList(growable: false);
    final checkInSummary = IbdCheckInService.sevenDaySummary(checkIns);
    final baseline = futures[6] as BaselineSnapshotRecord?;
    final setupJson = futures[7] as Map<String, Object?>?;
    final profileJson = futures[8] as Map<String, Object?>?;
    final profile = profileJson == null
        ? UserProfile.empty
        : UserProfile.fromJson(profileJson);
    final appUseStart = _appUseStartDate(
      setupJson: setupJson,
      summaries: allSummaries,
      scores: summaryScores,
      symptoms: symptoms,
      labs: labs,
      checkIns: checkIns,
      fallbackStart: effectiveStart,
    );
    final appUseDays = _inclusiveDays(appUseStart, effectiveEnd);
    final summariesSinceAppUse = allSummaries
        .where((item) => item.dateLocal.compareTo(appUseStart) >= 0)
        .toList(growable: false);
    final latestScore =
        scores.isEmpty ? null : _scoreToDoctorSummaryJson(scores.last);
    final safetyContext = _doctorSummarySafetyContext(
      latestScore: latestScore,
      symptoms: symptomJson,
      labs: labs,
      checkIns: checkInJson,
      checkInSummary: checkInSummary,
    );
    final symptomGroups = _aggregateSymptomGroups(
      symptomJson.whereType<Map<String, Object?>>().toList(growable: false),
    );
    final checkInAggregation = _aggregateCheckIns(
      checkInJson.whereType<Map<String, Object?>>().toList(growable: false),
      today: today,
    );
    final labAggregation = _aggregateLabs(labs);
    final clinicianSections = _buildClinicianSections(
      symptoms: symptomJson.whereType<Map<String, Object?>>().toList(
            growable: false,
          ),
      checkIns: checkInJson.whereType<Map<String, Object?>>().toList(
            growable: false,
          ),
      profile: profile,
    );

    return {
      'range_start': effectiveStart,
      'range_end': effectiveEnd,
      'range_days': effectiveDays,
      'latest_score': latestScore,
      'score_trend': scores
          .map(
            (score) => {
              'date': score.dateLocal,
              'score': score.riskScore.round(),
              'band': score.riskBand,
            },
          )
          .toList(growable: false),
      'top_recent_contributors': scores.isEmpty
          ? const []
          : _topContributors(scores.last.contributionJson),
      'symptoms': symptomJson,
      'labs': labs.map((lab) => _labToJson(lab)).toList(growable: false),
      'procedures': procedures
          .map(
            (item) => {
              'date': item.procedureDate,
              'type': item.procedureType,
              'findings_present': item.findingsText?.isNotEmpty == true,
            },
          )
          .toList(growable: false),
      'check_ins': checkInJson,
      'checkin_summary': checkInSummary,
      'symptom_groups': symptomGroups,
      'checkin_aggregation': checkInAggregation,
      'lab_aggregation': labAggregation,
      'clinician_sections': clinicianSections,
      'clinical_safety': safetyContext,
      'context_reasons': context
          .map((item) => item.featureJson['context_attribution_reason'])
          .whereType<String>()
          .toSet()
          .toList(growable: false),
      'summary_count': summaries.length,
      'baseline_state': baseline?.readinessState,
      'risk_trend_7d': scores.reversed
          .take(7)
          .map(
            (s) => {
              'date': s.dateLocal,
              'score': s.riskScore.round(),
              'band': s.riskBand,
            },
          )
          .toList(growable: false),
      'score_contributors_plain': scores.isEmpty
          ? const []
          : _topContributors(scores.last.contributionJson)
              .map(
                (c) => _humanizeContributorName(c['name'] as String? ?? ''),
              )
              .where((name) => name.isNotEmpty)
              .toList(growable: false),
      'data_limits': {
        'app_use_start_date': appUseStart,
        'app_use_days': appUseDays,
        'summary_days_present_since_setup': summariesSinceAppUse.length,
        'missing_days': (appUseDays - summariesSinceAppUse.length).clamp(
          0,
          appUseDays,
        ),
        'has_labs': labs.isNotEmpty,
        'has_check_ins': checkIns.isNotEmpty,
        'check_in_completion': checkIns.length,
      },
      'user_profile': profile.toJson(),
    };
  }

  String? _latestDoctorSummaryEvidenceDate({
    required String today,
    required List<DailySummaryRecord> summaries,
    required List<FlareRiskScoreRecord> scores,
    required List<SymptomRecord> symptoms,
    required List<LabValueRecord> labs,
    required List<EndoscopyRecord> procedures,
    required List<Pro2SurveyRecord> checkIns,
    required List<DailyContextFeatureRecord> context,
  }) {
    final dates = <String>[
      ...summaries.map((item) => item.dateLocal),
      ...scores.map((item) => item.dateLocal),
      ...symptoms.map((item) => _dateOnly(item.loggedAt)),
      ...labs.map((item) => item.drawnDate),
      ...procedures.map((item) => item.procedureDate),
      ...checkIns.map((item) => item.surveyDate),
      ...context.map((item) => item.dateLocal),
    ]
        .where((date) => _isDate(date) && date.compareTo(today) <= 0)
        .toList(growable: false);
    if (dates.isEmpty) return null;
    dates.sort();
    return dates.last;
  }

  Future<List<FlareRiskScoreRecord>> _loadSummaryRiskScores({
    required String start,
  }) async {
    for (final version in const [
      'risk_v2_context_adjusted',
      'risk_v1',
    ]) {
      final rows = await _repository.getFlareRiskScores(modelVersion: version);
      final filtered = rows
          .where((row) => row.dateLocal.compareTo(start) >= 0)
          .toList(growable: false);
      if (filtered.isNotEmpty) return filtered;
    }
    return const [];
  }

  Future<DoctorSummaryResult> createDoctorSummary({
    int days = 30,
    DateTime? startDate,
    DateTime? endDate,
    bool allDates = false,
  }) async {
    final context = await buildDoctorSummaryContext(
      days: days,
      startDate: startDate,
      endDate: endDate,
      allDates: allDates,
    );
    final systemPrompt =
        '''You are Gemma Flares, an on-device IBD copilot generating a compact clinician-first GI visit summary.
  Use ONLY grounded context JSON. Do not invent data.

  Required sections in this exact order:
  ## Overview
  ## GI Activity Summary
  ## Lab Results
  ## Check-in Summary
  ## Medication and Supplement Log
  ## Bowel Pattern Baseline
  ## Condensed Diet and Trigger Log
  ## Questions for Your GI Doctor
  ## Triage and Red Flags

  Critical constraints:
  - Do not create a separate "Check-In Evidence" section.
  - Do not duplicate check-ins across sections.
  - Keep check-ins only in "Check-in Summary".
  - Group symptoms by symptom type and trend, not date-by-date dumps.
  - Preserve severe/high-concern evidence and risk-score conflict caveats.
  - Do not mention confidence scores anywhere.
  - Do not use bullets, numbered lists, or markdown list syntax.
  - Do not indent any lines (no leading spaces or tabs).
  - Separate every section with exactly one blank line.
  - Keep wording concise and clinician-facing.
  - If context.checkin_aggregation.compression_note exists, include it once in Check-in Summary.
  - For labs: emphasize abnormal/elevated or trend-changing findings; keep stable normals compact.
  - Questions should be data-specific and can be fewer when high-signal triggers are absent.
  - Triage and red flags must remain present even during low-signal periods.

  Safety constraints:
  - No diagnosis.
  - No medication changes.
  - No fabricated persistence claims.''';
    final userPrompt =
        'Generate the full GI summary using the required section contract and no duplicated content.';
    final generated = await _generateTextTask(
      taskType: 'doctor_summary',
      promptVersion: doctorSummaryPromptVersion,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      groundedContext: context,
      maxTokens: 900,
      temperature: 0.2,
      inputSummaryJson: {
        'range_days': context['range_days'] ?? days,
        'range_start': context['range_start'],
        'range_end': context['range_end'],
        'all_dates': allDates,
        'symptom_count': (context['symptoms'] as List?)?.length ?? 0,
        'lab_count': (context['labs'] as List?)?.length ?? 0,
      },
    );
    final draftSummary = generated.outputText.trim().isEmpty
        ? _fallbackDoctorSummary(context)
        : generated.outputText.trim();
    final guardedSummary = generated.usedModelOutput
        ? _applyDoctorSummarySafetyGuard(draftSummary, context)
        : draftSummary;
    final summary = _normalizeDoctorSummaryForExport(
      _removeDoctorSummaryConfidenceText(guardedSummary),
      context,
    );
    final summaryId = await _repository.insertDoctorSummary(
      DoctorSummaryRecord(
        taskRunId: generated.taskRunId,
        summaryRangeDays: (context['range_days'] as num?)?.toInt() ?? days,
        summaryText: summary,
        contextSummaryJson: context,
        createdAt: _nowProvider(),
      ),
    );
    return DoctorSummaryResult(
      status: generated.usedModelOutput ? 'success' : 'fallback',
      summaryText: summary,
      contextSummaryJson: context,
      usedModelOutput: generated.usedModelOutput,
      taskRunId: generated.taskRunId,
      summaryId: summaryId,
    );
  }

  Future<_GeneratedText> _generateTextTask({
    required String taskType,
    required String promptVersion,
    required String systemPrompt,
    required String userPrompt,
    required Map<String, Object?> groundedContext,
    required int maxTokens,
    required double temperature,
    required Map<String, Object?> inputSummaryJson,
  }) async {
    final started = _nowProvider();
    var compactContext = _promptBudget.compact(groundedContext);
    if (!_promptBudget.fits(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      groundedContext: compactContext,
    )) {
      compactContext = {
        'compact_notice': 'Context was shortened to fit mobile prompt budget.',
        ..._promptBudget.compact(compactContext),
      };
    }
    final status = await _ensureRuntimeLoaded(taskType);
    LocalModelResponse response;
    if (!status.isModelLoaded) {
      response = LocalModelResponse(
        status: 'unavailable',
        outputText: '',
        runtimeName: status.runtimeName,
        reason: status.reason,
        fallbackReason: status.status,
      );
    } else {
      response = await _generateBounded(
        LocalModelRequest(
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          groundedContext: compactContext,
          maxTokens: maxTokens,
          temperature: temperature,
          taskType: taskType,
          modelRole: _modelRoleForTask(taskType),
          contextPolicy: _contextPolicyForTask(taskType),
          privacyMode: 'local_only',
        ),
      );
    }
    final usedModelOutput = _responseHasAcceptedQuality(response) &&
        response.outputText.trim().isNotEmpty;
    final latencyMs = _nowProvider().difference(started).inMilliseconds;
    final taskRunId = await _recordTaskRun(
      taskType: taskType,
      promptVersion: promptVersion,
      runtimeName: response.runtimeName,
      status: response.status,
      usedModelOutput: usedModelOutput,
      validationStatus: usedModelOutput ? 'valid_text' : 'fallback',
      validationErrors:
          usedModelOutput ? const [] : [response.reason ?? response.status],
      inputSummaryJson: inputSummaryJson,
      outputSummaryJson: {
        'output_chars': response.outputText.length,
        'reason': response.reason,
      },
      outputText: response.outputText,
      latencyMs: latencyMs,
    );
    return _GeneratedText(
      outputText: response.outputText,
      usedModelOutput: usedModelOutput,
      taskRunId: taskRunId,
    );
  }

  String _modelRoleForTask(String taskType) {
    return switch (taskType) {
      'doctor_summary' => 'doctor_summary',
      'symptom_extract' => 'structured_extraction',
      'lab_text_extract' => 'structured_extraction',
      _ => 'daily_fast',
    };
  }

  String _contextPolicyForTask(String taskType) {
    return switch (taskType) {
      'doctor_summary' => 'large_128k',
      'symptom_extract' => 'compact',
      'lab_text_extract' => 'compact',
      _ => 'standard',
    };
  }

  Future<_GeneratedJson> _generateJsonTask({
    required String taskType,
    required String promptVersion,
    required String systemPrompt,
    required String userPrompt,
    required Map<String, Object?> groundedContext,
    required int maxTokens,
    required double temperature,
    required Map<String, Object?> inputSummaryJson,
    required Map<String, Object?> fallbackOutputJson,
    required List<String> Function(Map<String, Object?> json) validate,
  }) async {
    final started = _nowProvider();
    var compactContext = _promptBudget.compact(groundedContext);
    if (!_promptBudget.fits(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      groundedContext: compactContext,
    )) {
      compactContext = {'compact_notice': 'Prompt budget applied.'};
    }
    final status = await _ensureRuntimeLoaded(taskType);
    LocalModelResponse response;
    if (!status.isModelLoaded) {
      response = LocalModelResponse(
        status: 'unavailable',
        outputText: '',
        runtimeName: status.runtimeName,
        reason: status.reason,
        fallbackReason: status.status,
      );
    } else {
      response = await _generateBounded(
        LocalModelRequest(
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          groundedContext: compactContext,
          maxTokens: maxTokens,
          temperature: temperature,
          taskType: taskType,
          modelRole: _modelRoleForTask(taskType),
          contextPolicy: _contextPolicyForTask(taskType),
          privacyMode: 'local_only',
        ),
      );
    }
    var decoded = _decodeJsonObject(response.outputText);
    var validationErrors =
        decoded == null ? ['Model did not return JSON.'] : validate(decoded);

    if (status.isModelLoaded && validationErrors.isNotEmpty) {
      final repair = await _generateBounded(
        LocalModelRequest(
          systemPrompt:
              '$systemPrompt\nRepair the previous answer. Return valid JSON only.',
          userPrompt:
              'Previous answer:\n${response.outputText}\nValidation errors: ${validationErrors.join('; ')}',
          groundedContext: compactContext,
          maxTokens: maxTokens,
          temperature: 0.0,
          taskType: taskType,
          modelRole: _modelRoleForTask(taskType),
          contextPolicy: _contextPolicyForTask(taskType),
          privacyMode: 'local_only',
        ),
      );
      final repaired = _decodeJsonObject(repair.outputText);
      final repairedErrors = repaired == null
          ? ['Repair did not return JSON.']
          : validate(repaired);
      if (repaired != null && repairedErrors.isEmpty) {
        response = repair;
        decoded = repaired;
        validationErrors = const [];
      }
    }

    final usedModelOutput = _responseHasAcceptedQuality(response) &&
        decoded != null &&
        validationErrors.isEmpty;
    final latencyMs = _nowProvider().difference(started).inMilliseconds;
    final taskRunId = await _recordTaskRun(
      taskType: taskType,
      promptVersion: promptVersion,
      runtimeName: response.runtimeName,
      status: response.status,
      usedModelOutput: usedModelOutput,
      validationStatus:
          validationErrors.isEmpty ? 'valid_json' : 'invalid_json',
      validationErrors: validationErrors,
      inputSummaryJson: inputSummaryJson,
      outputSummaryJson: usedModelOutput ? decoded : fallbackOutputJson,
      outputText: response.outputText,
      latencyMs: latencyMs,
    );
    return _GeneratedJson(
      json: usedModelOutput ? decoded : null,
      usedModelOutput: usedModelOutput,
      taskRunId: taskRunId,
    );
  }

  Future<LocalModelResponse> _generateBounded(LocalModelRequest request) async {
    try {
      return await _runtime
          .generate(request)
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      return const LocalModelResponse(
        status: 'timeout',
        outputText: '',
        runtimeName: 'gemma4-timeout',
        reason: 'local_model_timeout',
        fallbackReason: 'timeout',
      );
    } catch (error) {
      return LocalModelResponse(
        status: 'failed',
        outputText: '',
        runtimeName: 'gemma4-error',
        reason: error.toString(),
        fallbackReason: 'runtime_error',
      );
    }
  }

  Future<int> _recordTaskRun({
    required String taskType,
    required String promptVersion,
    required String runtimeName,
    required String status,
    required bool usedModelOutput,
    required String validationStatus,
    required List<String> validationErrors,
    required Map<String, Object?> inputSummaryJson,
    required Map<String, Object?> outputSummaryJson,
    required String outputText,
    required int latencyMs,
  }) async {
    final id = await _repository.insertGemmaTaskRun(
      GemmaTaskRunRecord(
        taskType: taskType,
        promptVersion: promptVersion,
        schemaVersion: schemaVersion,
        modelId: modelId,
        runtimeName: runtimeName,
        status: status,
        usedModelOutput: usedModelOutput,
        validationStatus: validationStatus,
        validationErrorsJson: validationErrors,
        inputSummaryJson: inputSummaryJson,
        outputSummaryJson: outputSummaryJson,
        outputHash: outputText.trim().isEmpty ? null : _hash(outputText),
        latencyMs: latencyMs,
        createdAt: _nowProvider(),
      ),
    );
    await _diagnosticLogService?.info(
      'gemma_task_completed',
      category: DiagnosticLogService.categoryModelRuntime,
      message: 'A local Gemma structured task completed.',
      metadata: {
        'task_type': taskType,
        'status': status,
        'validation_status': validationStatus,
        'used_model_output': usedModelOutput,
        'latency_ms': latencyMs,
      },
    );
    return id;
  }

  bool _responseHasAcceptedQuality(LocalModelResponse response) {
    return response.status == 'success' &&
        response.outputQualityStatus != 'rejected';
  }

  Future<LocalModelRuntimeStatus> _ensureRuntimeLoaded(String taskType) async {
    final status = await _runtime.getRuntimeStatus();
    if (status.isModelLoaded ||
        !status.isBundledModelPresent ||
        !status.isBackendLinked) {
      return status;
    }
    return _runtime.loadBundledModel(profile: _profileForTask(taskType));
  }

  String _profileForTask(String taskType) {
    if (taskType == 'doctor_summary') {
      return 'phone_large';
    }
    if (taskType == 'symptom_extract' || taskType == 'lab_text_extract') {
      return 'phone_safe';
    }
    return 'phone_standard';
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

  List<String> _validateSymptomJson(Map<String, Object?> json) {
    if (json['symptoms'] is List) {
      final wrappedErrors = <String>[];
      final symptomEntries = (json['symptoms'] as List)
          .whereType<Map>()
          .map((item) => Map<String, Object?>.from(item))
          .toList(growable: false);
      if (symptomEntries.isEmpty) {
        wrappedErrors.add('symptoms must include at least one entry.');
      }
      for (final entry in symptomEntries) {
        wrappedErrors.addAll(_validateSymptomJson(entry));
      }
      final uncertaintyNotes = json['uncertainty_notes'];
      if (uncertaintyNotes != null && uncertaintyNotes is! List) {
        wrappedErrors.add('uncertainty_notes must be a list when present.');
      }
      return wrappedErrors;
    }

    final errors = <String>[];
    final symptomType = json['symptom_type'];
    if (symptomType is! String || !_allowedSymptoms.contains(symptomType)) {
      errors.add('Unsupported symptom_type.');
    }
    final severity = json['severity_1_to_10'];
    if (severity != null &&
        (severity is! num || severity < 1 || severity > 10)) {
      errors.add('severity_1_to_10 must be 1..10 or null.');
    }
    final duration = json['duration_minutes'];
    if (duration != null &&
        (duration is! num || duration < 0 || duration > 10080)) {
      errors.add('duration_minutes is out of range.');
    }
    final meal = json['meal_relation'];
    if (meal != null &&
        (meal is! String || !_allowedMealRelations.contains(meal))) {
      errors.add('Unsupported meal_relation.');
    }
    final confidence = json['confidence'];
    if (confidence != null &&
        (confidence is! num || confidence < 0 || confidence > 1)) {
      errors.add('confidence must be 0..1.');
    }
    final uncertaintyNotes = json['uncertainty_notes'];
    if (uncertaintyNotes != null && uncertaintyNotes is! List) {
      errors.add('uncertainty_notes must be a list when present.');
    }
    return errors;
  }

  List<String> _validateLabJson(Map<String, Object?> json) {
    final labs = json['labs'];
    if (labs is! List) return ['labs must be a list.'];
    return labs
        .whereType<Map>()
        .expand(
          (item) => _validateLabCandidate(
            _labCandidateFromMap(Map<String, Object?>.from(item), _todayDate()),
          ),
        )
        .toList(growable: false);
  }

  List<String> _validateLabCandidate(GemmaLabCandidate candidate) {
    final errors = <String>[];
    if (!_labDefinitions.containsKey(candidate.labType)) {
      errors.add('Unsupported lab type ${candidate.labType}.');
    }
    if (candidate.valueNumeric <= 0 ||
        candidate.valueNumeric >
            (_labDefinitions[candidate.labType]?.maxValue ?? 100000)) {
      errors.add('Lab value for ${candidate.labType} is out of range.');
    }
    if (!_isDate(candidate.drawnDate) ||
        candidate.drawnDate.compareTo(_todayDate()) > 0) {
      errors.add('Lab date for ${candidate.labType} is invalid or future.');
    }
    if (candidate.unit.trim().isEmpty) {
      errors.add('Lab unit for ${candidate.labType} is missing.');
    }
    return errors;
  }

  StructuredSymptom _symptomFromJson(
    Map<String, Object?> json,
    StructuredSymptom fallback,
    DateTime loggedAt,
  ) {
    final symptomType = json['symptom_type'] as String? ?? fallback.symptomType;
    final severity =
        (json['severity_1_to_10'] as num?)?.round() ?? fallback.severity1To10;
    final durationMinutes =
        (json['duration_minutes'] as num?)?.round() ?? fallback.durationMinutes;
    final mealRelation =
        json['meal_relation'] as String? ?? fallback.mealRelation;
    final notes = (json['notes'] as String?)?.trim().isNotEmpty == true
        ? (json['notes'] as String).trim()
        : fallback.notes;
    return StructuredSymptom(
      symptomType: symptomType,
      severity1To10: severity,
      onsetTime: fallback.onsetTime,
      loggedTime: loggedAt.toUtc(),
      durationMinutes: durationMinutes,
      mealRelation: mealRelation,
      notes: notes,
      sourceTranscript: fallback.sourceTranscript,
      extractionConfidence: ((json['confidence'] as num?)?.toDouble() ??
              fallback.extractionConfidence)
          .clamp(0.0, 0.99)
          .toDouble(),
      userFacingDescription: _symptomDescription(
        symptomType: symptomType,
        severity: severity,
        mealRelation: mealRelation,
        durationMinutes: durationMinutes,
        fallback: fallback.userFacingDescription,
      ),
      uncertaintyNotes: _uncertaintyNotesFromJson(json, fallback),
      safetyFlags: _safetyFlagsForSymptom(
        transcript: fallback.sourceTranscript,
        symptomType: symptomType,
        severity: severity,
        fallback: fallback.safetyFlags,
      ),
    );
  }

  List<String> _uncertaintyNotesFromJson(
    Map<String, Object?> json,
    StructuredSymptom fallback,
  ) {
    final raw = json['uncertainty_notes'];
    if (raw is! List) return fallback.uncertaintyNotes;
    final values = raw
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .take(4)
        .toSet()
        .toList(growable: false);
    return values.isEmpty ? fallback.uncertaintyNotes : values;
  }

  List<String> _safetyFlagsForSymptom({
    required String transcript,
    required String symptomType,
    required int? severity,
    required List<String> fallback,
  }) {
    final lower = transcript.toLowerCase();
    final flags = <String>{...fallback};
    if (symptomType == 'blood' || lower.contains('bleed')) {
      flags.add('bleeding_reported');
    }
    if ((severity ?? 0) >= 8) {
      flags.add('severe_symptom');
    }
    if (lower.contains('black stool') ||
        lower.contains('passed out') ||
        lower.contains('fainted') ||
        lower.contains('dehydr') ||
        lower.contains("can't keep") ||
        lower.contains('unable to keep') ||
        lower.contains('fever')) {
      flags.add('urgent_review');
    }
    return flags.toList(growable: false);
  }

  String _symptomDescription({
    required String symptomType,
    required int? severity,
    required String? mealRelation,
    required int? durationMinutes,
    required String fallback,
  }) {
    final label = switch (symptomType) {
      'pain' => 'Pain',
      'cramping' => 'Cramping',
      'diarrhea' => 'Loose stools',
      'urgency' => 'Urgency',
      'nausea' => 'Nausea',
      'bloating' => 'Bloating',
      'fatigue' => 'Fatigue',
      'blood' => 'Blood in stool',
      'mucus_stool' => 'Mucus/pus in stool',
      'fever' => 'Fever/chills',
      'night_sweats' => 'Night sweats',
      'mouth_sores' => 'Mouth sores',
      'constipation' => 'Constipation',
      'fecal_incontinence' => 'Bowel leakage',
      'weight_loss' => 'Weight loss',
      'appetite_loss' => 'Appetite loss',
      'fistula' => 'Fistula or drainage',
      'joint_pain' => 'Joint pain',
      'skin' => 'Skin symptoms',
      'eye' => 'Eye symptoms',
      'anal_fissure' => 'Anal fissure pain',
      'obstruction' => 'Obstructive symptoms',
      'vomiting' => 'Vomiting',
      'dehydration' => 'Dehydration symptoms',
      'malnutrition' => 'Malnutrition symptoms',
      'dizziness' => 'Dizziness/lightheadedness',
      'back_pain' => 'Back pain',
      'urinary_urgency' => 'Urinary urgency',
      'headache_migraine' => 'Headache/migraine',
      'other_health_symptom' => 'Other health symptom',
      _ => 'Symptom note',
    };
    final parts = <String>[label];
    if (severity != null) {
      parts.add('around $severity/10');
    }
    if (mealRelation != null) {
      parts.add(mealRelation.replaceAll('_', ' '));
    }
    if (durationMinutes != null) {
      parts.add(
        durationMinutes >= 60 && durationMinutes % 60 == 0
            ? 'for ${durationMinutes ~/ 60} hour${durationMinutes == 60 ? '' : 's'}'
            : 'for $durationMinutes minutes',
      );
    }
    final description = parts.join(' ').trim();
    return description.isEmpty ? fallback : description;
  }

  List<StructuredIntakeDraft> _intakeDraftsFromJson(Map<String, Object?> json) {
    final raw = json['intake_events'];
    if (raw is! List) return const [];
    final drafts = <StructuredIntakeDraft>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final map = Map<String, Object?>.from(item);
      final type = map['event_type'] as String?;
      if (type == null || !_allowedIntakeEvents.contains(type)) continue;
      drafts.add(
        StructuredIntakeDraft(
          eventType: type,
          confidence: ((map['confidence'] as num?)?.toDouble() ?? 0.65)
              .clamp(0.0, 1.0)
              .toDouble(),
          notes: map['notes'] as String?,
          metadataJson: {'extracted_by': 'gemma4_e2b_structured'},
        ),
      );
    }
    return drafts;
  }

  List<GemmaLabCandidate> _labCandidatesFromJson(
    Map<String, Object?> json,
    String fallbackDate,
  ) {
    final labs = json['labs'];
    if (labs is! List) return const [];
    final date = _normalizeDate(json['drawn_date'] as String?) ?? fallbackDate;
    return labs
        .whereType<Map>()
        .map(
          (item) => _labCandidateFromMap(
            Map<String, Object?>.from(item),
            date,
            labName: json['lab_name'] as String?,
            orderingProvider: json['ordering_provider'] as String?,
          ),
        )
        .where((candidate) => _validateLabCandidate(candidate).isEmpty)
        .toList(growable: false);
  }

  GemmaLabCandidate _labCandidateFromMap(
    Map<String, Object?> map,
    String fallbackDate, {
    String? labName,
    String? orderingProvider,
  }) {
    final rawType = (map['lab_type'] as String? ?? '').toLowerCase();
    final type = _normalizeLabType(rawType);
    final definition = _labDefinitions[type];
    final unit = _normalizeLabUnit(
      type,
      map['unit'] as String? ?? definition?.unit ?? '',
    );
    return GemmaLabCandidate(
      labType: type,
      valueNumeric: ((map['value_numeric'] as num?) ?? 0).toDouble(),
      unit: unit,
      drawnDate: _normalizeDate(map['drawn_date'] as String?) ?? fallbackDate,
      referenceHigh: (map['reference_high'] as num?)?.toDouble() ??
          definition?.referenceHigh,
      labName: labName,
      orderingProvider: orderingProvider,
      abnormalFlag: map['abnormal_flag'] as bool?,
      confidence: ((map['confidence'] as num?)?.toDouble() ?? 0.65)
          .clamp(0.0, 1.0)
          .toDouble(),
      sourceTextSnippet: map['source_text_snippet'] as String?,
    );
  }

  List<GemmaLabCandidate> _deterministicLabCandidates(String text) {
    final candidates = <GemmaLabCandidate>[];
    final date = _extractDate(text) ?? _todayDate();
    for (final entry in _labDefinitions.entries) {
      final candidate = _bestDeterministicLabCandidate(
        entry.key,
        entry.value,
        text,
        date,
      );
      if (candidate != null) {
        candidates.add(candidate);
      }
    }
    return candidates;
  }

  GemmaLabCandidate? _bestDeterministicLabCandidate(
    String labType,
    _LabDefinition definition,
    String text,
    String date,
  ) {
    final labelRegex = RegExp(
      '(?<![A-Za-z])(?:${definition.pattern})(?![A-Za-z])',
      caseSensitive: false,
    );
    _DeterministicLabValueHit? bestHit;
    for (final labelMatch in labelRegex.allMatches(text)) {
      final windowStart = labelMatch.start;
      final windowEnd = math.min(text.length, labelMatch.end + 220);
      final window = text.substring(labelMatch.end, windowEnd);
      for (final valueMatch in _labValuePattern.allMatches(window)) {
        final rawValue = (valueMatch.group(1) ?? '').trim();
        final numericText = rawValue
            .replaceFirst(RegExp(r'^[<>]=?\s*'), '')
            .replaceAll(',', '');
        final value = double.tryParse(numericText);
        if (value == null) continue;
        final valueStart = labelMatch.end + valueMatch.start;
        final valueEnd = labelMatch.end + valueMatch.end;
        final afterValue = text.substring(
          valueEnd,
          math.min(text.length, valueEnd + 8),
        );
        if (RegExp(r'^\s*[-–—]\s*[0-9]').hasMatch(afterValue)) {
          continue;
        }
        final rawUnit = (valueMatch.group(2) ?? '').trim();
        final normalizedUnit = _normalizeLabUnit(
          labType,
          rawUnit.isEmpty ? definition.unit : rawUnit,
        );
        final labelText = text.substring(labelMatch.start, labelMatch.end);
        final snippetEnd = math.min(text.length, valueEnd + 48);
        final snippet = text.substring(windowStart, snippetEnd);
        final score = _scoreDeterministicLabValueHit(
          fullText: text,
          definition: definition,
          labelText: labelText,
          snippet: snippet,
          rawValue: rawValue,
          rawUnit: rawUnit,
          labelStart: labelMatch.start,
          valueStart: valueStart,
          valueEnd: valueEnd,
          labelEnd: labelMatch.end,
        );
        if (bestHit == null || score > bestHit.score) {
          bestHit = _DeterministicLabValueHit(
            score: score,
            valueNumeric: value,
            unit: normalizedUnit,
            sourceTextSnippet: _truncate(snippet, 120),
          );
        }
      }
    }
    if (bestHit == null || bestHit.score < 1) {
      return null;
    }
    return GemmaLabCandidate(
      labType: labType,
      valueNumeric: bestHit.valueNumeric,
      unit: bestHit.unit,
      drawnDate: date,
      referenceHigh: definition.referenceHigh,
      confidence: bestHit.score >= 10 ? 0.72 : 0.6,
      sourceTextSnippet: bestHit.sourceTextSnippet,
    );
  }

  int _scoreDeterministicLabValueHit({
    required String fullText,
    required _LabDefinition definition,
    required String labelText,
    required String snippet,
    required String rawValue,
    required String rawUnit,
    required int labelStart,
    required int valueStart,
    required int valueEnd,
    required int labelEnd,
  }) {
    var score = 0;
    final normalizedSnippet = snippet.toLowerCase();
    final normalizedUnit = _normalizeLabUnit(
      _normalizeLabType(labelText.toLowerCase()),
      rawUnit,
    ).toLowerCase();
    final expectedUnit = definition.unit.toLowerCase();
    final distance = valueStart - labelEnd;
    final labelLine = _lineAt(fullText, labelStart).trim();
    final valueLine = _lineAt(fullText, valueStart).trim();
    final valuePrefix = fullText
        .substring(math.max(labelEnd, valueStart - 28), valueStart)
        .toLowerCase();
    final valueSuffix = fullText
        .substring(valueEnd, math.min(fullText.length, valueEnd + 16))
        .toLowerCase();

    score += math.max(0, 6 - (distance ~/ 32));

    if (labelLine.isNotEmpty &&
        valueLine.isNotEmpty &&
        labelLine == valueLine) {
      score += 6;
    }
    if (valueLine.toLowerCase().startsWith('result')) {
      score += 10;
    }
    if (labelLine.toLowerCase().startsWith('result')) {
      score += 4;
    }

    if (normalizedSnippet.contains('result')) {
      score += 8;
    }
    if (normalizedSnippet.contains('came back at') ||
        normalizedSnippet.contains('came back')) {
      score += 7;
    }
    if (normalizedSnippet.contains('went from') &&
        normalizedSnippet.contains(' to ')) {
      score += 6;
    }
    if (normalizedSnippet.contains('up from') &&
        normalizedSnippet.contains(' to ')) {
      score += 6;
    }
    if (normalizedSnippet.contains(' is over ') ||
        normalizedSnippet.contains(' above ') ||
        normalizedSnippet.contains(' greater than ')) {
      score += 4;
    }
    if (RegExp(r'\b(?:is|was|at)\s+[<>]?[0-9]').hasMatch(normalizedSnippet)) {
      score += 5;
    }
    if (normalizedSnippet.contains('value')) {
      score += 4;
    }
    if (normalizedSnippet.contains('interpretation')) {
      score -= 2;
    }
    if (rawValue.startsWith('<')) {
      score -= 6;
    }
    if (rawValue.startsWith('>')) {
      score += 2;
    }
    if (valuePrefix.contains(' to ') ||
        valuePrefix.trim().startsWith('to ') ||
        valuePrefix.contains(' now ')) {
      score += 7;
    }
    if (valuePrefix.contains('from ')) {
      score -= 2;
    }
    if (valueSuffix.trim().startsWith('to ')) {
      score -= 2;
    }
    if (_isCompatibleLabUnit(expectedUnit, normalizedUnit)) {
      score += 7;
    } else if (rawUnit.isNotEmpty) {
      score -= labelText.trim().length <= 2 ? 8 : 4;
    }
    if (_looksLikeReferenceRangeLine(valueLine)) {
      score -= 8;
    }
    if (_looksLikeReferenceRangeBlock(normalizedSnippet)) {
      score -= 5;
    }
    if (_isShortAliasLabel(labelText) &&
        !_hasStrongShortAliasContext(
          labelLine: labelLine,
          valueLine: valueLine,
          labelText: labelText,
          rawUnit: rawUnit,
          distance: distance,
        )) {
      score -= 12;
    }
    return score;
  }

  bool _isShortAliasLabel(String labelText) {
    final cleaned = labelText.trim();
    return cleaned.length <= 3 && !cleaned.contains(' ');
  }

  bool _hasStrongShortAliasContext({
    required String labelLine,
    required String valueLine,
    required String labelText,
    required String rawUnit,
    required int distance,
  }) {
    final normalizedLabel = labelText.trim().toLowerCase();
    final normalizedLabelLine = labelLine.trim().toLowerCase();
    final normalizedValueLine = valueLine.trim().toLowerCase();
    final startsLine = normalizedLabelLine.startsWith(normalizedLabel);
    final hasInlineValue = RegExp(
      '^${RegExp.escape(normalizedLabel)}(?:\\s*[:=-]?\\s*)[<>]?[0-9]',
      caseSensitive: false,
    ).hasMatch(normalizedLabelLine);
    final hasConversationalValue = RegExp(
      '^${RegExp.escape(normalizedLabel)}(?:\\s+(?:came\\s+back\\s+at|is|was|at|went\\s+from\\s+[<>]?[0-9]+(?:\\.[0-9]+)?\\s+to|up\\s+from\\s+[<>]?[0-9]+(?:\\.[0-9]+)?\\s+to))\\s*[<>]?[0-9]',
      caseSensitive: false,
    ).hasMatch(normalizedLabelLine);
    final hasResultValue = normalizedValueLine.startsWith('result') ||
        normalizedValueLine.startsWith('value');
    final hasUnit = rawUnit.trim().isNotEmpty;
    return hasInlineValue ||
        hasConversationalValue ||
        (startsLine && hasUnit && distance <= 32) ||
        (startsLine && hasResultValue) ||
        (hasUnit && distance <= 12);
  }

  bool _looksLikeReferenceRangeLine(String line) {
    final trimmed = line.trim().toLowerCase();
    if (trimmed.isEmpty) return false;
    if (RegExp(
      r'^[<>]=?\s*[0-9]+(?:\.[0-9]+)?(?:\s*[-–—]\s*[0-9]+(?:\.[0-9]+)?)?$',
    ).hasMatch(trimmed)) {
      return true;
    }
    if (RegExp(
      r'^[0-9]+(?:\.[0-9]+)?\s*[-–—]\s*[0-9]+(?:\.[0-9]+)?$',
    ).hasMatch(trimmed)) {
      return true;
    }
    return trimmed == 'normal' ||
        trimmed == 'abnormal' ||
        trimmed == 'borderline' ||
        trimmed == 'positive' ||
        trimmed == 'negative';
  }

  bool _looksLikeReferenceRangeBlock(String snippet) {
    return snippet.contains('interpretation') ||
        snippet.contains('reference range') ||
        snippet.contains('normal') ||
        snippet.contains('abnormal') ||
        snippet.contains('borderline');
  }

  String _lineAt(String text, int offset) {
    if (text.isEmpty) return '';
    final safeOffset = offset.clamp(0, text.length - 1);
    final start = text.lastIndexOf('\n', safeOffset) + 1;
    final end = text.indexOf('\n', safeOffset);
    if (end == -1) {
      return text.substring(start);
    }
    return text.substring(start, end);
  }

  bool _isCompatibleLabUnit(String expectedUnit, String actualUnit) {
    if (expectedUnit.isEmpty || actualUnit.isEmpty) return true;
    final normalizedExpected = _canonicalizeLabUnit(expectedUnit);
    final normalizedActual = _canonicalizeLabUnit(actualUnit);
    if (normalizedExpected == normalizedActual) return true;
    const compatiblePairs = {
      'mg/l': {'mg/dl'},
      'mg/dl': {'mg/l'},
      'ug/g': {'μg/g'},
      'μg/g': {'ug/g'},
    };
    return compatiblePairs[normalizedExpected]?.contains(normalizedActual) ??
        false;
  }

  String _canonicalizeLabUnit(String unit) {
    return unit
        .toLowerCase()
        .replaceAll('µ', 'μ')
        .replaceAll('mcg', 'ug')
        .replaceAll(RegExp(r'\s+'), '');
  }

  String _applyDoctorSummarySafetyGuard(
    String summary,
    Map<String, Object?> context,
  ) {
    final safety =
        context['clinical_safety'] as Map<String, Object?>? ?? const {};
    if (safety['high_concern_symptoms'] != true) return summary;
    if (summary.contains('## Clinical Safety Priority')) return summary;

    final prioritySignals =
        (safety['priority_signals'] as List?)?.whereType<String>().toList() ??
            const [];
    final erRedFlags =
        (safety['er_red_flags'] as List?)?.whereType<String>().toList() ??
            const [];
    final buf = StringBuffer()
      ..writeln('## Clinical Safety Priority')
      ..writeln(
        safety['priority_summary'] ??
            'Recent raw check-in data contains high-concern GI symptoms.',
      )
      ..writeln(
        safety['triage_note'] ??
            'Same-day clinical follow-up may be appropriate based on the raw symptom data.',
      );
    if (safety['risk_score_conflict'] == true) {
      buf.writeln(
        'Flare-risk caveat: the current risk label may understate today\'s raw check-in severity; do not use the label alone for triage.',
      );
    }
    if (prioritySignals.isNotEmpty) {
      buf.writeln('Priority signals: ${prioritySignals.take(6).join("; ")}.');
    }
    if (erRedFlags.isNotEmpty) {
      buf.writeln(
        'Urgent/emergency triggers to watch for: ${erRedFlags.take(7).join("; ")}.',
      );
    }
    buf
      ..writeln()
      ..writeln(summary.trim());
    return buf.toString().trim();
  }

  String _removeDoctorSummaryConfidenceText(String summary) {
    final lines = summary
        .split('\n')
        .map(
          (line) => line
              .replaceAll(
                RegExp(
                  r'\s*(?:with\s+)?Confidence:\s*[^.\n]*(?:\.|$)',
                  caseSensitive: false,
                ),
                '',
              )
              .replaceAll(
                RegExp(
                  r'\s*with confidence\s+\d+(?:\.\d+)?\s*/\s*100',
                  caseSensitive: false,
                ),
                '',
              )
              .replaceAll(
                RegExp(
                  r'\s*confidence\s+(?:score\s+)?(?:is\s+)?\d+(?:\.\d+)?\s*(?:%|/100)?',
                  caseSensitive: false,
                ),
                '',
              )
              .trimRight(),
        )
        .where(
          (line) => !RegExp(
            r'^\s*confidence\s*:',
            caseSensitive: false,
          ).hasMatch(line),
        )
        .toList(growable: false);
    return lines.join('\n').trim();
  }

  String _normalizeDoctorSummaryForExport(
    String summary,
    Map<String, Object?> context,
  ) {
    final modelSections = _parseDoctorSummarySections(summary);
    final fallbackSections = _parseDoctorSummarySections(
      _fallbackDoctorSummary(context),
    );

    const required = <String>[
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

    final merged = <String, List<String>>{};

    // Preserve any non-contract preface section (for example safety guard).
    for (final entry in modelSections.entries) {
      if (required.contains(entry.key)) continue;
      if (entry.value.isEmpty) continue;
      merged[entry.key] = entry.value;
    }

    for (final heading in required) {
      final fromModel = modelSections[heading] ?? const <String>[];
      final fromFallback = fallbackSections[heading] ?? const <String>[];
      final useModel = fromModel.isNotEmpty &&
          !_isWeakDoctorSummarySection(heading, fromModel);
      final selected = useModel ? fromModel : fromFallback;
      merged[heading] = selected.isNotEmpty
          ? selected
          : <String>[_doctorSummaryEmptyLineFor(heading, context)];
    }

    merged['Questions for Your GI Doctor'] =
        merged['Questions for Your GI Doctor']!.isEmpty
            ? <String>[
                _doctorSummaryEmptyLineFor(
                    'Questions for Your GI Doctor', context),
              ]
            : merged['Questions for Your GI Doctor']!;

    merged['Overview'] = _normalizeDoctorSummaryOverviewLines(
      merged['Overview'] ?? const <String>[],
      context,
    );

    // Hard requirement: if labs exist, ensure lab name + value lines appear.
    final labs = (context['labs'] as List?)
            ?.whereType<Map<String, Object?>>()
            .toList() ??
        const <Map<String, Object?>>[];
    if (labs.isNotEmpty) {
      final deterministicLabLines = labs.take(12).map((lab) {
        final name =
            '${lab['lab_name'] ?? lab['lab_type'] ?? 'Lab'}'.trim().isEmpty
                ? 'Lab'
                : '${lab['lab_name'] ?? lab['lab_type']}'.trim();
        final value = lab['value_numeric'];
        final unit = '${lab['unit'] ?? ''}'.trim();
        final drawn = '${lab['drawn_date'] ?? ''}'.trim();
        final refHigh = lab['reference_high'];
        final refText = refHigh == null
            ? ''
            : ' (ref <${'$refHigh'.trim()}${unit.isEmpty ? '' : ' $unit'})';
        final elevated = lab['elevated'] == true ? ' (elevated)' : '';
        final valueText = value == null ? 'n/a' : '$value';
        final dateText = drawn.isEmpty ? '' : ' [$drawn]';
        return '$name: $valueText${unit.isEmpty ? '' : ' $unit'}$refText$elevated$dateText';
      }).toList(growable: false);

      final existing = merged['Lab Results'] ?? const <String>[];
      merged['Lab Results'] = _dedupeLabResultLines([
        ...deterministicLabLines,
        ...existing,
      ]);
    }

    final buf = StringBuffer();
    var first = true;
    for (final heading in merged.keys) {
      final lines = merged[heading] ?? const <String>[];
      final nonEmpty = lines.where((l) => l.trim().isNotEmpty).toList();
      if (nonEmpty.isEmpty) continue;
      if (!first) buf.writeln();
      buf.writeln('## $heading');
      buf.writeln(nonEmpty.join('\n'));
      first = false;
    }

    return buf.toString().trim();
  }

  String _doctorSummaryEmptyLineFor(
    String heading,
    Map<String, Object?> context,
  ) {
    final labs = context['labs'];
    final symptoms = context['symptoms'];
    final checkIns = context['check_ins'];
    switch (heading) {
      case 'Overview':
        return 'No additional overview details are available yet.';
      case 'GI Activity Summary':
        return symptoms is List && symptoms.isEmpty
            ? 'No symptoms are recorded yet in this window.'
            : 'No additional GI activity details are available yet.';
      case 'Lab Results':
        return labs is List && labs.isEmpty
            ? 'No lab results are recorded yet in this window.'
            : 'No additional lab result details are available yet.';
      case 'Check-in Summary':
        return checkIns is List && checkIns.isEmpty
            ? 'No check-ins are recorded yet in this window.'
            : 'No additional check-in details are available yet.';
      case 'Medication and Supplement Log':
        return 'No medication or supplement logs are recorded yet in this window.';
      case 'Bowel Pattern Baseline':
        return 'No bowel-pattern baseline is available yet in this window.';
      case 'Condensed Diet and Trigger Log':
        return 'No diet or trigger patterns are recorded yet in this window.';
      case 'Questions for Your GI Doctor':
        return 'What objective testing or monitoring would best help interpret my recent symptoms and trends in the context of my history?';
      case 'Triage and Red Flags':
        return 'If symptoms worsen or red flags appear, contact your GI team or seek urgent evaluation.';
      default:
        return 'No additional details were provided in this section.';
    }
  }

  bool _isWeakDoctorSummarySection(String heading, List<String> lines) {
    if (lines.isEmpty) return true;
    final normalized = lines
        .map(
          (line) => line
              .trim()
              .toLowerCase()
              .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim(),
        )
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (normalized.isEmpty) return true;

    if (heading == 'GI Activity Summary' && normalized.length == 1) {
      return normalized.first == 'pattern' ||
          normalized.first == 'overview' ||
          normalized.first == 'pattern overview';
    }

    return false;
  }

  List<String> _normalizeDoctorSummaryOverviewLines(
    List<String> lines,
    Map<String, Object?> context,
  ) {
    final cleaned = lines.map((line) => line.trim()).where((line) {
      if (line.isEmpty) return false;
      final lower = line.toLowerCase();
      if (lower.contains('risk score')) return false;
      if (RegExp(r'\b\d{1,3}\s*/\s*100\b').hasMatch(line)) {
        return false;
      }
      if (lower.startsWith('no risk score has been calculated yet')) {
        return false;
      }
      return true;
    }).toList(growable: true);

    final latest = context['latest_score'] as Map<String, Object?>?;
    final flareRiskLine = _doctorSummaryFlareRiskOverviewLine(latest);
    if (flareRiskLine != null &&
        !cleaned.any(
          (line) => line.trim().toLowerCase() == flareRiskLine.toLowerCase(),
        )) {
      cleaned.insert(0, flareRiskLine);
    }

    if (cleaned.isEmpty) {
      cleaned.add(_doctorSummaryEmptyLineFor('Overview', context));
    }

    return _dedupePreserveOrder(cleaned);
  }

  String? _doctorSummaryFlareRiskOverviewLine(Map<String, Object?>? latest) {
    final flareRiskDisplay =
        latest == null ? null : _doctorSummaryFlareRiskDisplayValue(latest);
    if (flareRiskDisplay == null) {
      return 'Current 7-day flare-risk estimate is Learning.';
    }
    final band = '${latest?['risk_band'] ?? ''}'.trim();
    final bandSuffix =
        band.isEmpty ? '' : ' - ${band.toUpperCase().replaceAll('_', ' ')}';
    return 'Current 7-day flare risk is $flareRiskDisplay$bandSuffix.';
  }

  String? _doctorSummaryFlareRiskDisplayValue(Map<String, Object?> latest) {
    final directPercent = _toInt(latest['flare_risk_percent']) ??
        _toInt(latest['risk_percent']) ??
        _toInt(latest['probability_7d_percent']);
    if (directPercent != null) {
      final bounded = directPercent.clamp(0, 100);
      return '$bounded%';
    }

    final featureSnapshot =
        latest['feature_snapshot'] as Map<String, Object?>? ?? const {};
    final isColdStart =
        (_toInt(featureSnapshot['logistic_7d_cold_start']) ?? 0) > 0;
    final logisticStatus =
        '${featureSnapshot['logistic_7d_status'] ?? ''}'.toLowerCase().trim();
    final probabilityRaw = _toDouble(featureSnapshot['logistic_p_flare_7d']) ??
        _toDouble(featureSnapshot['p_flare_7d']) ??
        _toDouble(featureSnapshot['flare_probability_7d']) ??
        _toDouble(featureSnapshot['global_flare_probability_7d']);

    if (probabilityRaw == null ||
        !probabilityRaw.isFinite ||
        isColdStart ||
        logisticStatus == 'learning') {
      return null;
    }

    final percent =
        probabilityRaw <= 1.0 ? probabilityRaw * 100.0 : probabilityRaw;
    final bounded = percent.clamp(0.0, 100.0).round();
    return '$bounded%';
  }

  Map<String, List<String>> _parseDoctorSummarySections(String input) {
    final normalized =
        input.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
    final lines = normalized.split('\n').map((l) => l.trimRight()).toList();

    final sections = <String, List<String>>{};
    String? activeHeading;

    for (final raw in lines) {
      final trimmedLeft = raw.trimLeft();
      if (trimmedLeft.isEmpty) continue;
      if (trimmedLeft.startsWith('```')) continue;

      final headingMatch = RegExp(r'^(#{1,6})\s+(.+)$').firstMatch(trimmedLeft);
      if (headingMatch != null) {
        final headingText = (headingMatch.group(2) ?? '').trim();
        final canonical =
            _canonicalDoctorSummaryHeading(headingText) ?? headingText;
        activeHeading = canonical;
        sections.putIfAbsent(activeHeading, () => <String>[]);
        continue;
      }

      // Also accept plain headings without markdown markers.
      final plainCanonical = _canonicalDoctorSummaryHeading(trimmedLeft);
      if (plainCanonical != null &&
          (sections[plainCanonical]?.isNotEmpty != true)) {
        activeHeading = plainCanonical;
        sections.putIfAbsent(activeHeading, () => <String>[]);
        continue;
      }

      final cleaned = _cleanDoctorSummaryLine(trimmedLeft);
      if (cleaned.isEmpty) continue;
      final resolvedHeading = activeHeading ?? 'Overview';
      sections.putIfAbsent(resolvedHeading, () => <String>[]).add(cleaned);
    }

    return sections.map((key, value) {
      final canonical = _canonicalDoctorSummaryHeading(key) ?? key.trim();
      return MapEntry(canonical, _dedupePreserveOrder(value));
    });
  }

  String _cleanDoctorSummaryLine(String input) {
    var line = input.trimLeft();
    line = line.replaceFirst(RegExp(r'^(?:[-*•]|[–—])\s+'), '');
    line = line.replaceFirst(RegExp(r'^(?:\d{1,2}[.)])\s+'), '');
    line = line.replaceAll('**', '').replaceAll('`', '');
    line = line.replaceAll(RegExp(r'\s+'), ' ').trim();
    return line;
  }

  String? _canonicalDoctorSummaryHeading(String input) {
    final canonical = input.trim().toLowerCase();
    const mapping = <String, String>{
      'overview': 'Overview',
      'gi activity summary': 'GI Activity Summary',
      'gi activity & symptoms': 'GI Activity Summary',
      'gi activity and symptoms': 'GI Activity Summary',
      'lab results': 'Lab Results',
      'labs': 'Lab Results',
      'check-in summary': 'Check-in Summary',
      'check in summary': 'Check-in Summary',
      'medication and supplement log': 'Medication and Supplement Log',
      'medication and supplement logging': 'Medication and Supplement Log',
      'medication and supplement log.': 'Medication and Supplement Log',
      'medication and supplement log:': 'Medication and Supplement Log',
      'medication and supplement': 'Medication and Supplement Log',
      'bowel pattern baseline': 'Bowel Pattern Baseline',
      'condensed diet and trigger log': 'Condensed Diet and Trigger Log',
      'questions for your gi doctor': 'Questions for Your GI Doctor',
      'triage and red flags': 'Triage and Red Flags',
      'clinical safety priority': 'Clinical Safety Priority',
    };
    return mapping[canonical];
  }

  List<String> _dedupePreserveOrder(List<String> lines) {
    final seen = <String>{};
    final out = <String>[];
    for (final line in lines) {
      final normalized = line.trim();
      if (normalized.isEmpty) continue;
      if (seen.add(normalized)) out.add(normalized);
    }
    return out;
  }

  List<String> _dedupeLabResultLines(List<String> lines) {
    final seen = <String>{};
    final out = <String>[];
    for (final line in lines) {
      final normalized = line.trim();
      if (normalized.isEmpty) continue;
      final semanticKey = _labResultSemanticKey(normalized);
      final dedupeKey = semanticKey ?? 'raw:${normalized.toLowerCase()}';
      if (seen.add(dedupeKey)) {
        out.add(normalized);
      }
    }
    return out;
  }

  String? _labResultSemanticKey(String line) {
    final lower = line.toLowerCase();
    if (lower.startsWith('no saved lab results')) return null;
    final nameMatch = RegExp(r'^([^:]{1,120}):\s*(.+)$').firstMatch(line);
    if (nameMatch == null) return null;

    final canonicalName = _canonicalLabSummaryName(nameMatch.group(1) ?? '');
    if (canonicalName.isEmpty) return null;
    final tail = nameMatch.group(2) ?? '';

    final valueMatch = RegExp(r'([<>]?\s*-?\d+(?:\.\d+)?)').firstMatch(tail);
    final value = valueMatch == null
        ? null
        : _normalizeLabValueToken(valueMatch.group(1) ?? '');
    final dateMatch = RegExp(r'\[(\d{4}-\d{2}-\d{2})\]').firstMatch(line);
    final date = dateMatch?.group(1);

    if ((value == null || value.isEmpty) && (date == null || date.isEmpty)) {
      return null;
    }
    return '$canonicalName|${value ?? 'na'}|${date ?? 'na'}';
  }

  String _canonicalLabSummaryName(String raw) {
    final normalized =
        raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
    if (normalized.isEmpty) return normalized;
    if (normalized == 'fc' ||
        normalized == 'fecal calprotectin' ||
        normalized == 'faecal calprotectin') {
      return 'fecal_calprotectin';
    }
    if (normalized == 'crp' || normalized == 'c reactive protein') {
      return 'crp';
    }
    if (normalized == 'esr' || normalized == 'erythrocyte sedimentation rate') {
      return 'esr';
    }
    return normalized;
  }

  String _normalizeLabValueToken(String raw) {
    var token = raw.trim().replaceAll(' ', '');
    if (token.isEmpty) return token;
    var comparator = '';
    if (token.startsWith('<') || token.startsWith('>')) {
      comparator = token.substring(0, 1);
      token = token.substring(1);
    }
    final parsed = double.tryParse(token);
    if (parsed == null) return '$comparator$token';
    final compact =
        parsed.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');
    return '$comparator$compact';
  }

  List<String> _doctorQuestions({
    required bool highConcern,
    required bool riskScoreConflict,
    required List<Object?> labs,
    required Map<String, Object?> checkInSummary,
    required Map<String, Object?>? latest,
    required List<Object?> symptoms,
    required List<String> missingClinicalData,
    required List<String> objectiveGaps,
  }) {
    final questions = <String>[];
    final bleedingDays = _toInt(checkInSummary['days_with_bleeding']) ?? 0;
    final urgencyDays = _toInt(checkInSummary['days_with_urgency']) ?? 0;
    final redFlagDays = _toInt(checkInSummary['days_with_red_flags']) ?? 0;
    final elevatedLabs = labs
        .whereType<Map<String, Object?>>()
        .where((lab) => lab['elevated'] == true)
        .map((lab) => lab['lab_name'] ?? lab['lab_type'])
        .whereType<Object>()
        .map((value) => '$value')
        .toSet()
        .toList(growable: false);
    final symptomTypes = symptoms
        .whereType<Map<String, Object?>>()
        .map((symptom) => symptom['type'])
        .whereType<Object>()
        .map((value) => _humanSymptomLabel('$value').toLowerCase())
        .toSet()
        .toList(growable: false);
    final hasBleedingSignal = bleedingDays > 0 ||
        symptomTypes.any((type) {
          final lower = type.toLowerCase();
          return lower.contains('blood') || lower.contains('bleeding');
        });

    if (highConcern) {
      questions.add(
        hasBleedingSignal
            ? 'Given the saved severe symptoms and visible blood, should I be assessed today or sent to urgent/emergency care based on my full history and vitals?'
            : 'Given the saved severe symptoms, should I be assessed today or sent to urgent/emergency care based on my full history and vitals?',
      );
    }
    if (bleedingDays > 0) {
      questions.add(
        'I have $bleedingDays day(s) with rectal bleeding in this app-use window; what evaluation or monitoring threshold should guide next steps?',
      );
    }
    if (urgencyDays > 0) {
      questions.add(
        'I have $urgencyDays day(s) with urgency; does that pattern suggest active rectal/colonic inflammation, infection, or another explanation in my case?',
      );
    }
    if (redFlagDays > 0) {
      questions.add(
        '$redFlagDays day(s) included red-flag symptoms; which of these should trigger same-day contact versus emergency care for me?',
      );
    }
    if (objectiveGaps.isNotEmpty && highConcern) {
      questions.add(
        'Because no objective evaluation is saved with these high-concern symptoms, should we check CBC, CMP, CRP, fecal calprotectin, and stool infectious testing such as C. difficile if clinically appropriate?',
      );
    }
    if (elevatedLabs.isNotEmpty) {
      questions.add(
        'These saved labs are flagged elevated (${elevatedLabs.take(4).join(", ")}); how do they change the interpretation of my symptoms?',
      );
    }
    if (symptomTypes.isNotEmpty) {
      questions.add(
        'My logged symptom pattern includes ${symptomTypes.take(4).join(", ")}; what pattern would make you change treatment timing or order endoscopic evaluation?',
      );
    }
    if (riskScoreConflict) {
      questions.add(
        'My current risk label is not high, but the raw check-in is severe; which raw findings should override the label when I decide whether to contact the clinic?',
      );
    } else {
      final flareRiskDisplay =
          latest == null ? null : _doctorSummaryFlareRiskDisplayValue(latest);
      if (flareRiskDisplay != null) {
        questions.add(
          'My current 7-day flare risk is $flareRiskDisplay; should I move up follow-up or add objective testing?',
        );
      }
    }
    if (missingClinicalData.isNotEmpty) {
      questions.add(
        'The app does not document ${missingClinicalData.take(3).join(", ")}; which of these should I track daily before my next visit?',
      );
    }

    if (questions.isEmpty) {
      questions.add(
        'Based on the limited saved data in this summary, what specific symptoms, labs, or timing details should I track before follow-up?',
      );
    }
    return questions.take(6).toList(growable: false);
  }

  Map<String, Object?> _doctorSummarySafetyContext({
    required Map<String, Object?>? latestScore,
    required List<Map<String, Object?>> symptoms,
    required List<LabValueRecord> labs,
    required List<Map<String, Object?>> checkIns,
    required Map<String, Object?> checkInSummary,
  }) {
    final prioritySignals = <String>[];
    final redFlagDates = <String>{};

    for (final checkIn in checkIns) {
      final date = checkIn['date'] as String? ?? 'unknown date';
      final core = Map<String, Object?>.from(checkIn['core'] as Map? ?? {});
      final details = Map<String, Object?>.from(
        checkIn['details'] as Map? ?? {},
      );
      final bleeding = _toInt(core['rectal_bleeding_0_3']) ??
          _toInt(details['blood_0_3']) ??
          0;
      final urgency = _toInt(details['urgency_0_3']) ?? 0;
      final ucPain = _toInt(details['belly_or_rectal_pain_0_3']) ?? 0;
      final cdPain = _toInt(core['abdominal_pain_0_3']) ?? 0;
      final stool = _toInt(core['bathroom_frequency_0_3']) ??
          _toInt(core['loose_stool_bucket']) ??
          0;
      final wellbeing = _toInt(details['general_wellbeing_0_3']) ?? 0;
      final redFlags =
          (checkIn['red_flags'] as List?)?.whereType<String>().toList() ??
              const [];

      if (bleeding >= 2) {
        prioritySignals.add('$date: visible rectal bleeding ($bleeding/3)');
      }
      if (urgency >= 3) {
        prioritySignals.add('$date: severe urgency ($urgency/3)');
      }
      if (stool >= 3) {
        prioritySignals.add(
          '$date: 5+ extra bathroom trips or severe stool frequency ($stool/3)',
        );
      }
      if (cdPain >= 3 || ucPain >= 3) {
        prioritySignals.add('$date: severe abdominal/rectal pain');
      }
      if (wellbeing >= 2) {
        prioritySignals.add(
          '$date: poor or very poor wellbeing ($wellbeing/3)',
        );
      }
      if (redFlags.isNotEmpty) {
        prioritySignals.add('$date: red flags ${redFlags.join(", ")}');
        redFlagDates.add(date);
      }
    }

    for (final symptom in symptoms) {
      final type = (symptom['type'] as String? ?? '').toLowerCase();
      final severity = _toInt(symptom['severity']);
      final date = symptom['date'] as String? ?? 'unknown date';
      if ((type.contains('blood') || type.contains('bleeding')) &&
          (severity == null || severity >= 4)) {
        prioritySignals.add(
          '$date: logged bleeding symptom${severity != null ? " (severity $severity/10)" : ""}',
        );
      }
      if ((type.contains('pain') || type.contains('cramp')) &&
          (severity ?? 0) >= 7) {
        prioritySignals.add(
          '$date: severe logged pain/cramping (severity $severity/10)',
        );
      }
      if (type.contains('urgency') && (severity == null || severity >= 7)) {
        prioritySignals.add(
          '$date: logged severe urgency${severity != null ? " (severity $severity/10)" : ""}',
        );
      }
    }

    final uniqueSignals = prioritySignals.toSet().toList(growable: false);
    final hasHighConcern = uniqueSignals.isNotEmpty ||
        ((_toInt(checkInSummary['days_with_bleeding']) ?? 0) > 0 &&
            (_toInt(checkInSummary['days_with_urgency']) ?? 0) > 0);
    final latestRiskScore = _toInt(latestScore?['risk_score']);
    final latestBand =
        (latestScore?['risk_band'] as String? ?? '').toLowerCase();
    final riskScoreConflict = hasHighConcern &&
        (latestRiskScore == null ||
            latestRiskScore < 60 ||
            latestBand == 'low' ||
            latestBand == 'moderate');

    return {
      'high_concern_symptoms': hasHighConcern,
      'risk_score_conflict': riskScoreConflict,
      'priority_summary': hasHighConcern
          ? 'Recent raw check-in data contains high-concern GI symptoms. These raw findings should take priority over a reassuring risk label.'
          : 'No high-concern symptom cluster was detected in the saved on-device check-ins.',
      'priority_signals': uniqueSignals,
      'red_flag_dates': redFlagDates.toList(growable: false)..sort(),
      'triage_note': hasHighConcern
          ? 'Same-day GI-team contact is appropriate for severe pain, increased stool frequency, visible blood, severe urgency, or poor wellbeing. Emergency evaluation is appropriate if ER red flags are present.'
          : 'Use routine follow-up unless symptoms worsen or red flags appear.',
      'er_red_flags': const [
        'Large-volume rectal bleeding or mostly blood in the toilet',
        'Black tarry stool or vomiting blood',
        'Severe or worsening abdominal pain that does not let up',
        'Fever with bloody diarrhea or severe abdominal pain',
        'Dizziness, fainting, confusion, racing heart, or dehydration',
        'Inability to keep liquids down',
        'Marked abdominal swelling or distension',
      ],
      'missing_clinical_data': const [
        'Fever/chills',
        'Nocturnal stools',
        'Dizziness, syncope, hydration status',
        'Weight loss',
        'Recent antibiotics or C. difficile exposure',
        'Travel, sick contacts, or foodborne exposure',
        'NSAID use',
        'Current IBD medication list and missed doses',
        'IBD subtype, disease extent, and prior flare pattern',
      ],
      'objective_data_gaps': [
        if (labs.isEmpty)
          'No saved labs such as CBC, CMP, CRP, fecal calprotectin, or stool infectious testing',
        if (checkIns.isEmpty) 'No saved check-ins in this summary window',
      ],
    };
  }

  Map<String, Object?> _aggregateSymptomGroups(
    List<Map<String, Object?>> symptoms,
  ) {
    if (symptoms.isEmpty) {
      return {'groups': const <Map<String, Object?>>[], 'total_count': 0};
    }
    final grouped = <String, List<Map<String, Object?>>>{};
    for (final symptom in symptoms) {
      final key = (symptom['type'] as String? ?? 'other').toLowerCase();
      grouped.putIfAbsent(key, () => <Map<String, Object?>>[]).add(symptom);
    }

    final groups = <Map<String, Object?>>[];
    for (final entry in grouped.entries) {
      final rows = entry.value;
      rows.sort((a, b) => '${a['date'] ?? ''}'.compareTo('${b['date'] ?? ''}'));
      final severities = rows
          .map((row) => _toInt(row['severity']))
          .whereType<int>()
          .toList(growable: false);
      final notes = rows
          .map((row) => row['notes'] as String?)
          .whereType<String>()
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .take(3)
          .toList(growable: false);
      final firstDate = '${rows.first['date'] ?? ''}';
      final lastDate = '${rows.last['date'] ?? ''}';

      String trend = 'stable';
      if (severities.length >= 2) {
        final first = severities.first;
        final last = severities.last;
        if (last >= first + 2) {
          trend = 'worsening';
        } else if (first >= last + 2) {
          trend = 'improving';
        }
      }

      groups.add({
        'symptom_type': entry.key,
        'label': _humanSymptomLabel(entry.key),
        'count': rows.length,
        'date_span': '$firstDate to $lastDate',
        'severity_min': severities.isEmpty
            ? null
            : severities.reduce((a, b) => a < b ? a : b),
        'severity_max': severities.isEmpty
            ? null
            : severities.reduce((a, b) => a > b ? a : b),
        'trend': trend,
        'sample_phrases': notes,
      });
    }
    groups.sort(
      (a, b) => (_toInt(b['count']) ?? 0).compareTo(_toInt(a['count']) ?? 0),
    );
    return {'groups': groups, 'total_count': symptoms.length};
  }

  Map<String, Object?> _aggregateCheckIns(
    List<Map<String, Object?>> checkIns, {
    required String today,
  }) {
    if (checkIns.isEmpty) {
      return {
        'included_daily': const <Map<String, Object?>>[],
        'weekly_buckets': const <Map<String, Object?>>[],
        'omitted_low_signal_days': 0,
        'compression_note': null,
      };
    }

    final ordered = [...checkIns]
      ..sort((a, b) => _checkInDate(a).compareTo(_checkInDate(b)));
    final daySignals = <Map<String, Object?>>[];
    for (var i = 0; i < ordered.length; i++) {
      final row = ordered[i];
      final date = _checkInDate(row);
      final score = _toInt(row['score'] ?? row['pro2_score']) ?? 0;
      final bleeding = _toInt(_checkInField(row, 'rectal_bleeding_0_3')) ?? 0;
      final urgency = _toInt(_checkInField(row, 'urgency_0_3')) ?? 0;
      final stool = _toInt(_checkInField(row, 'bathroom_frequency_0_3')) ??
          _toInt(_checkInField(row, 'loose_stool_bucket')) ??
          0;
      final pain = _toInt(_checkInField(row, 'abdominal_pain_0_3')) ??
          _toInt(_checkInField(row, 'belly_or_rectal_pain_0_3')) ??
          0;
      final redFlags =
          (row['red_flags'] as List?)?.whereType<String>().toList() ??
              const <String>[];
      final highSignal = row['is_flare'] == true ||
          score >= 5 ||
          bleeding >= 2 ||
          urgency >= 2 ||
          stool >= 2 ||
          pain >= 2 ||
          redFlags.isNotEmpty;
      var worsening = false;
      if (i > 0) {
        final prev = daySignals[i - 1];
        worsening = score > (_toInt(prev['score']) ?? 0) ||
            bleeding > (_toInt(prev['bleeding']) ?? 0) ||
            urgency > (_toInt(prev['urgency']) ?? 0) ||
            stool > (_toInt(prev['stool']) ?? 0);
      }
      daySignals.add({
        'date': date,
        'score': score,
        'bleeding': bleeding,
        'urgency': urgency,
        'stool': stool,
        'pain': pain,
        'high_signal': highSignal,
        'worsening': worsening,
        'line': _formatCheckInComponents(row),
      });
    }

    final includeByIndex = <int>{};
    for (var i = 0; i < daySignals.length; i++) {
      final day = daySignals[i];
      final daysAgo = _daysAgoFrom(today, '${day['date']}');
      final highSignal = day['high_signal'] == true;
      final worsening = day['worsening'] == true;
      if (daysAgo <= 6) {
        includeByIndex.add(i);
        continue;
      }
      if (daysAgo <= 29) {
        if (highSignal || worsening) {
          includeByIndex.add(i);
        }
      }
    }
    for (var i = 0; i < daySignals.length; i++) {
      if (daySignals[i]['high_signal'] == true ||
          daySignals[i]['worsening'] == true) {
        if (i - 1 >= 0) {
          final currentDate = '${daySignals[i]['date']}';
          final prevDate = '${daySignals[i - 1]['date']}';
          if ((_daysAgoFrom(currentDate, prevDate)).abs() <= 1) {
            includeByIndex.add(i - 1);
          }
        }
        if (i + 1 < daySignals.length) {
          final currentDate = '${daySignals[i]['date']}';
          final nextDate = '${daySignals[i + 1]['date']}';
          if ((_daysAgoFrom(currentDate, nextDate)).abs() <= 1) {
            includeByIndex.add(i + 1);
          }
        }
      }
    }

    final includedDaily = <Map<String, Object?>>[];
    final weekly = <String, Map<String, Object?>>{};
    var omittedLowSignal = 0;
    for (var i = 0; i < daySignals.length; i++) {
      final day = daySignals[i];
      final date = '${day['date']}';
      final daysAgo = _daysAgoFrom(today, date);
      final includeDaily = includeByIndex.contains(i) && daysAgo <= 29;
      if (includeDaily) {
        includedDaily.add(day);
        continue;
      }

      final weekStart = _weekStart(date);
      final bucket = weekly.putIfAbsent(
        weekStart,
        () => {
          'week_start': weekStart,
          'days': 0,
          'high_signal_days': 0,
          'max_score': 0,
        },
      );
      bucket['days'] = (_toInt(bucket['days']) ?? 0) + 1;
      if (day['high_signal'] == true) {
        bucket['high_signal_days'] =
            (_toInt(bucket['high_signal_days']) ?? 0) + 1;
      } else {
        omittedLowSignal += 1;
      }
      final score = _toInt(day['score']) ?? 0;
      if (score > (_toInt(bucket['max_score']) ?? 0)) {
        bucket['max_score'] = score;
      }
    }

    includedDaily.sort((a, b) => '${b['date']}'.compareTo('${a['date']}'));
    final weeklyBuckets = weekly.values.toList(growable: false)
      ..sort((a, b) => '${b['week_start']}'.compareTo('${a['week_start']}'));

    final hasCompression = omittedLowSignal > 0 || weeklyBuckets.isNotEmpty;
    return {
      'included_daily': includedDaily,
      'weekly_buckets': weeklyBuckets,
      'omitted_low_signal_days': omittedLowSignal,
      'compression_note': hasCompression
          ? 'Low-signal check-ins and low-signal days were omitted or weekly-compressed to keep the summary clinically focused.'
          : null,
    };
  }

  Map<String, Object?> _aggregateLabs(List<LabValueRecord> labs) {
    if (labs.isEmpty) {
      return {
        'abnormal_or_changed': const <Map<String, Object?>>[],
        'stable_or_normal_count': 0,
        'stable_summary': null,
      };
    }

    final grouped = <String, List<LabValueRecord>>{};
    for (final lab in labs) {
      grouped.putIfAbsent(lab.labType, () => <LabValueRecord>[]).add(lab);
    }

    final abnormalOrChanged = <Map<String, Object?>>[];
    var stableOrNormalCount = 0;
    for (final entry in grouped.entries) {
      final values = [...entry.value]
        ..sort((a, b) => a.drawnDate.compareTo(b.drawnDate));
      final latest = values.last;
      final prev = values.length > 1 ? values[values.length - 2] : null;
      final elevated = latest.referenceHigh != null
          ? latest.valueNumeric > latest.referenceHigh!
          : false;
      final delta =
          prev == null ? null : latest.valueNumeric - prev.valueNumeric;
      final pctDelta = prev == null || prev.valueNumeric == 0
          ? null
          : (delta! / prev.valueNumeric) * 100;
      final changed = pctDelta != null && pctDelta.abs() >= 20;

      if (elevated || changed) {
        abnormalOrChanged.add({
          'lab_type': latest.labType,
          'lab_name': _cleanLabLabel(latest.labName, latest.labType),
          'drawn_date': latest.drawnDate,
          'value_numeric': latest.valueNumeric,
          'unit': latest.unit,
          'reference_high': latest.referenceHigh,
          'elevated': elevated,
          'delta': delta,
          'delta_pct': pctDelta,
        });
      } else {
        stableOrNormalCount += 1;
      }
    }

    return {
      'abnormal_or_changed': abnormalOrChanged,
      'stable_or_normal_count': stableOrNormalCount,
      'stable_summary': stableOrNormalCount > 0
          ? '$stableOrNormalCount stable/normal lab series were compacted.'
          : null,
    };
  }

  Map<String, Object?> _buildClinicianSections({
    required List<Map<String, Object?>> symptoms,
    required List<Map<String, Object?>> checkIns,
    required UserProfile profile,
  }) {
    final medicationSignals = <String, int>{};
    final triggers = <String, int>{};

    var bowelDays = 0;
    var stoolTotal = 0;
    var bleedingDays = 0;
    var urgencyDays = 0;

    for (final checkIn in checkIns) {
      final stool = _toInt(_checkInField(checkIn, 'bathroom_frequency_0_3')) ??
          _toInt(_checkInField(checkIn, 'loose_stool_bucket'));
      final bleeding = _toInt(_checkInField(checkIn, 'rectal_bleeding_0_3')) ??
          _toInt(_checkInField(checkIn, 'blood_0_3'));
      final urgency = _toInt(_checkInField(checkIn, 'urgency_0_3'));
      if (stool != null) {
        bowelDays += 1;
        stoolTotal += stool;
      }
      if ((bleeding ?? 0) > 0) bleedingDays += 1;
      if ((urgency ?? 0) > 0) urgencyDays += 1;

      final notes = '${checkIn['notes'] ?? ''}'.toLowerCase();
      if (notes.contains('missed medication') ||
          notes.contains('skipped medication') ||
          notes.contains('missed dose')) {
        medicationSignals.update(
          'Missed medication reported',
          (v) => v + 1,
          ifAbsent: () => 1,
        );
      }
    }

    for (final symptom in symptoms) {
      final meal =
          '${symptom['meal_relation'] ?? symptom['trigger_or_meal_relation'] ?? ''}'
              .trim();
      if (meal.isNotEmpty && meal != 'null') {
        final key = meal.replaceAll('_', ' ');
        triggers.update(key, (v) => v + 1, ifAbsent: () => 1);
      }
      final notes = '${symptom['notes'] ?? ''}'.toLowerCase();
      if (notes.contains('after eating') || notes.contains('trigger')) {
        triggers.update(
          'food-related trigger phrase',
          (v) => v + 1,
          ifAbsent: () => 1,
        );
      }
      if (notes.contains('supplement')) {
        medicationSignals.update(
          'Supplement mention',
          (v) => v + 1,
          ifAbsent: () => 1,
        );
      }
      if (notes.contains('medication') || notes.contains('meds')) {
        medicationSignals.update(
          'Medication mention',
          (v) => v + 1,
          ifAbsent: () => 1,
        );
      }
    }

    final medLines = medicationSignals.entries
        .map((entry) => '${entry.key}: ${entry.value} day(s)')
        .toList(growable: true)
      ..sort();
    final profileMedicationLines = profile.medications
        .where((item) => item.name.trim().isNotEmpty)
        .map((item) {
      final detailParts = <String>[];
      if ((item.dose ?? '').trim().isNotEmpty) {
        detailParts.add('dose ${(item.dose ?? '').trim()}');
      }
      if ((item.frequency ?? '').trim().isNotEmpty) {
        detailParts.add('frequency ${(item.frequency ?? '').trim()}');
      }
      if ((item.startDate ?? '').trim().isNotEmpty) {
        detailParts.add('start ${(item.startDate ?? '').trim()}');
      }
      final details = detailParts.isEmpty ? '' : ' (${detailParts.join(', ')})';
      return 'Profile medication: ${item.name.trim()}$details';
    }).toList(growable: false);
    medLines.addAll(profileMedicationLines);
    final triggerLines = triggers.entries
        .map(
          (entry) =>
              '${_humanTriggerLabel(entry.key)}: ${entry.value} occurrence(s)',
        )
        .toList(growable: false)
      ..sort();

    return {
      'medication_and_supplement_log': medLines,
      'bowel_pattern_baseline': {
        'days_with_stool_data': bowelDays,
        'average_stool_bucket':
            bowelDays == 0 ? null : (stoolTotal / bowelDays).toStringAsFixed(1),
        'days_with_bleeding': bleedingDays,
        'days_with_urgency': urgencyDays,
      },
      'trigger_patterns': triggerLines,
    };
  }

  Object? _checkInField(Map<String, Object?> checkIn, String key) {
    final core = Map<String, Object?>.from(checkIn['core'] as Map? ?? const {});
    final details = Map<String, Object?>.from(
      checkIn['details'] as Map? ?? const {},
    );
    return core[key] ?? details[key];
  }

  String _checkInDate(Map<String, Object?> checkIn) {
    return '${checkIn['survey_date'] ?? checkIn['date'] ?? '1970-01-01'}';
  }

  int _daysAgoFrom(String today, String date) {
    final a = DateTime.parse('${today}T00:00:00Z');
    final b = DateTime.tryParse('${date}T00:00:00Z');
    if (b == null) return 9999;
    return a.difference(b).inDays;
  }

  String _weekStart(String date) {
    final dt = DateTime.tryParse('${date}T00:00:00Z');
    if (dt == null) return date;
    final monday = dt.subtract(Duration(days: dt.weekday - 1));
    return _dateOnly(monday);
  }

  String _fallbackDoctorSummary(Map<String, Object?> context) {
    final latest = context['latest_score'] as Map<String, Object?>?;
    final symptomGroups = (context['symptom_groups']
            as Map<String, Object?>?)?['groups'] as List? ??
        const [];
    final checkInAggregation =
        context['checkin_aggregation'] as Map<String, Object?>? ?? const {};
    final labs = (context['labs'] as List?) ?? const [];
    final labAggregation =
        context['lab_aggregation'] as Map<String, Object?>? ?? const {};
    final clinicianSections =
        context['clinician_sections'] as Map<String, Object?>? ?? const {};
    final checkInSummary =
        context['checkin_summary'] as Map<String, Object?>? ?? const {};
    final limits = context['data_limits'] as Map<String, Object?>? ?? const {};
    final safety =
        context['clinical_safety'] as Map<String, Object?>? ?? const {};
    final highConcern = safety['high_concern_symptoms'] == true;
    final riskScoreConflict = safety['risk_score_conflict'] == true;
    final erRedFlags =
        (safety['er_red_flags'] as List?)?.whereType<String>().toList() ??
            const [];
    final includedDaily =
        (checkInAggregation['included_daily'] as List?) ?? const [];
    final weeklyBuckets =
        (checkInAggregation['weekly_buckets'] as List?) ?? const [];
    final compressionNote = checkInAggregation['compression_note'] as String?;
    final medsLines =
        (clinicianSections['medication_and_supplement_log'] as List?) ??
            const [];
    final bowelBaseline =
        clinicianSections['bowel_pattern_baseline'] as Map<String, Object?>? ??
            const {};
    final triggerLines =
        (clinicianSections['trigger_patterns'] as List?) ?? const [];
    final summaryCount = _toInt(context['summary_count']) ?? 0;
    final isSparseContext = latest == null &&
        summaryCount == 0 &&
        symptomGroups.isEmpty &&
        labs.isEmpty &&
        includedDaily.isEmpty &&
        weeklyBuckets.isEmpty;

    final buf = StringBuffer();

    buf.writeln('## Overview');
    if (highConcern) {
      buf.writeln(
        safety['priority_summary'] ??
            'Recent raw check-in data contains high-concern GI symptoms.',
      );
    }
    final flareRiskLine = _doctorSummaryFlareRiskOverviewLine(latest);
    if (flareRiskLine != null) {
      buf.writeln(flareRiskLine);
    }
    if (riskScoreConflict) {
      buf.writeln(
        'Interpret this cautiously: the current risk label may understate today\'s raw check-in severity.',
      );
    }
    final missingDays = _toInt(limits['missing_days']) ?? 0;
    final appUseDays = _toInt(limits['app_use_days']) ?? 0;
    final appUseStartDate =
        '${limits['app_use_start_date'] ?? context['range_start'] ?? 'unknown'}';
    if (isSparseContext) {
      buf.writeln(
        'No local summaries, symptoms, labs, or check-ins are saved in this app-use window since $appUseStartDate.',
      );
    } else if (appUseDays > 0) {
      if (missingDays > 0) {
        buf.writeln(
          '$missingDays of $appUseDays app-use day(s) may be missing local summaries since $appUseStartDate.',
        );
      }
    }
    buf.writeln();

    buf.writeln('## GI Activity Summary');
    if (symptomGroups.isEmpty) {
      buf.writeln('No saved symptom groups were found in this window.');
    } else {
      buf.writeln('Symptom trend overview:');
      for (final item in symptomGroups.take(8)) {
        if (item is! Map<String, Object?>) continue;
        final symptomType =
            item['label'] ?? _humanSymptomLabel('${item['symptom_type']}');
        final count = item['count'] ?? 0;
        final span = item['date_span'] ?? 'unknown span';
        final trend = item['trend'] ?? 'stable';
        final minSeverity = item['severity_min'];
        final maxSeverity = item['severity_max'];
        final severityText = minSeverity == null || maxSeverity == null
            ? ''
            : 'severity $minSeverity-$maxSeverity/10, ';
        buf.writeln(
          '$symptomType: $count saved entries across $span; ${severityText}trend $trend.',
        );
      }
      final recentSymptoms = (context['symptoms'] as List?)
              ?.whereType<Map<String, Object?>>()
              .toList(growable: false) ??
          const <Map<String, Object?>>[];
      final sortedRecent = [...recentSymptoms]
        ..sort((a, b) => '${b['date']}'.compareTo('${a['date']}'));
      if (sortedRecent.isNotEmpty) {
        buf.writeln('Recent logged symptoms:');
        for (final symptom in sortedRecent.take(8)) {
          final line =
              symptom['clinical_line'] ?? _formatSymptomForSummary(symptom);
          buf.writeln('Logged symptom: $line');
        }
      }
    }
    buf.writeln();

    buf.writeln('## Lab Results');
    if (labs.isEmpty) {
      buf.writeln('No saved lab results were found in this window.');
      if (highConcern) {
        buf.writeln(
          'Because high-concern symptoms are present, this on-device record cannot distinguish IBD activity from infection, medication issues, anemia/dehydration, or other causes without objective clinical evaluation.',
        );
      }
    } else {
      final flagged =
          (labAggregation['abnormal_or_changed'] as List?) ?? const [];
      for (final item in flagged.take(8)) {
        if (item is! Map<String, Object?>) continue;
        final delta = (item['delta'] as num?)?.toDouble();
        final deltaPct = (item['delta_pct'] as num?)?.toDouble();
        final deltaText = delta == null
            ? ''
            : ' (delta ${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)}${item['unit'] ?? ''}${deltaPct == null ? '' : ', ${deltaPct.toStringAsFixed(0)}%'})';
        final ref = item['reference_high'] == null
            ? ''
            : ' (ref <${item['reference_high']} ${item['unit']})';
        final flag = item['elevated'] == true ? ' — ELEVATED' : '';
        buf.writeln(
          '${item['lab_name']}: ${item['value_numeric']} ${item['unit']}$ref$flag$deltaText [${item['drawn_date']}]',
        );
      }
      final stableSummary = labAggregation['stable_summary'] as String?;
      if (stableSummary != null && stableSummary.isNotEmpty) {
        buf.writeln(stableSummary);
      }
    }
    buf.writeln();

    buf.writeln('## Check-in Summary');
    if (includedDaily.isEmpty && weeklyBuckets.isEmpty) {
      buf.writeln('No saved check-in data was found in this window.');
    } else {
      for (final item in includedDaily.take(14)) {
        if (item is! Map<String, Object?>) continue;
        buf.writeln(
          '${item['date']}: score ${item['score']} (${item['high_signal'] == true ? 'high-signal' : 'contextual'}) — ${item['line']}',
        );
      }
      for (final item in weeklyBuckets.take(12)) {
        if (item is! Map<String, Object?>) continue;
        buf.writeln(
          'Week of ${item['week_start']}: ${item['days']} day(s), ${item['high_signal_days']} high-signal day(s), max score ${item['max_score']}',
        );
      }
      if (compressionNote != null) {
        buf.writeln(compressionNote);
      }
      buf.writeln(
        'Check-in totals: ${checkInSummary['days_with_bleeding'] ?? 0} day(s) with bleeding, ${checkInSummary['days_with_urgency'] ?? 0} day(s) with urgency, ${checkInSummary['days_with_red_flags'] ?? 0} day(s) with red flags.',
      );
    }
    buf.writeln();

    buf.writeln('## Medication and Supplement Log');
    if (medsLines.isEmpty) {
      buf.writeln(
        'No structured medication or supplement exposures were found in this window.',
      );
    } else {
      for (final line in medsLines.take(8)) {
        buf.writeln(line);
      }
    }
    buf.writeln();

    buf.writeln('## Bowel Pattern Baseline');
    final stoolDays = _toInt(bowelBaseline['days_with_stool_data']) ?? 0;
    if (stoolDays == 0) {
      buf.writeln(
        'No bowel-pattern baseline was derivable from saved check-ins in this window.',
      );
    } else {
      buf.writeln(
        'Stool-data days: $stoolDays; average stool bucket: ${bowelBaseline['average_stool_bucket'] ?? 'n/a'}; bleeding days: ${bowelBaseline['days_with_bleeding'] ?? 0}; urgency days: ${bowelBaseline['days_with_urgency'] ?? 0}.',
      );
    }
    buf.writeln();

    buf.writeln('## Condensed Diet and Trigger Log');
    if (triggerLines.isEmpty) {
      buf.writeln(
        'No recurring meal-related or trigger patterns were detected from saved notes in this window.',
      );
    } else {
      for (final line in triggerLines.take(8)) {
        buf.writeln(line);
      }
    }
    buf.writeln();

    buf.writeln('## Questions for Your GI Doctor');
    final questions = _doctorQuestions(
      highConcern: highConcern,
      riskScoreConflict: riskScoreConflict,
      labs: labs,
      checkInSummary: checkInSummary,
      latest: latest,
      symptoms: (context['symptoms'] as List?) ?? const [],
      missingClinicalData: (safety['missing_clinical_data'] as List?)
              ?.whereType<String>()
              .toList() ??
          const [],
      objectiveGaps: (safety['objective_data_gaps'] as List?)
              ?.whereType<String>()
              .toList() ??
          const [],
    );
    for (final q in questions) {
      buf.writeln(q);
    }
    buf.writeln();

    buf.writeln('## Triage and Red Flags');
    buf.writeln(
      safety['triage_note'] ??
          'If symptoms worsen or red flags appear, contact your GI team or seek urgent evaluation.',
    );
    if (erRedFlags.isNotEmpty) {
      for (final flag in erRedFlags.take(7)) {
        buf.writeln('$flag.');
      }
    }
    return buf.toString().trim();
  }

  Map<String, Object?> _symptomRecordToDoctorSummaryJson(
    SymptomRecord symptom,
  ) =>
      {
        'date': _dateOnly(symptom.loggedAt),
        'type': symptom.symptomType,
        'severity': symptom.severity,
        'duration_minutes': symptom.durationMinutes,
        'trigger_or_meal_relation': symptom.mealRelation,
        'meal_relation': symptom.mealRelation,
        'notes': symptom.notes,
        'source_transcript': symptom.sourceTranscript,
        'frequency_or_context': _extractFrequencyContext(
          symptom.notes,
          symptom.sourceTranscript,
        ),
        'extraction_method': symptom.extractionMethod,
        'extraction_confidence': symptom.extractionConfidence,
        'clinical_line': _formatSymptomForSummary({
          'date': _dateOnly(symptom.loggedAt),
          'type': symptom.symptomType,
          'severity': symptom.severity,
          'duration_minutes': symptom.durationMinutes,
          'trigger_or_meal_relation': symptom.mealRelation,
          'notes': symptom.notes,
          'source_transcript': symptom.sourceTranscript,
          'frequency_or_context': _extractFrequencyContext(
            symptom.notes,
            symptom.sourceTranscript,
          ),
        }),
      };

  String _formatSymptomForSummary(Map<String, Object?> symptom) {
    final parts = <String>[
      '${symptom["date"] ?? "Unknown date"}: ${symptom["type"] ?? "symptom"}',
    ];
    if (symptom['severity'] != null) {
      parts.add('severity ${symptom["severity"]}/10');
    }
    final durationLabel = _doctorSummaryDurationLabel(symptom);
    if (durationLabel != null) {
      parts.add('duration $durationLabel');
    }
    final trigger =
        _doctorSummaryTriggerLabel(symptom['trigger_or_meal_relation']) ??
            _doctorSummaryTriggerLabel(symptom['meal_relation']);
    if (trigger != null) {
      parts.add('trigger/meal relation $trigger');
    }
    final frequency = symptom['frequency_or_context'];
    if (frequency != null && '$frequency'.trim().isNotEmpty) {
      parts.add('frequency/context $frequency');
    }
    final notes = symptom['notes'];
    if (notes != null && '$notes'.trim().isNotEmpty) {
      parts.add('notes "${_truncate('$notes', 140)}"');
    }
    final transcript = symptom['source_transcript'];
    if (transcript != null && '$transcript'.trim().isNotEmpty) {
      parts.add('patient words "${_truncate('$transcript', 160)}"');
    }
    return parts.join('; ');
  }

  String? _doctorSummaryDurationLabel(Map<String, Object?> symptom) {
    final text = [
      symptom['notes'],
      symptom['source_transcript'],
    ].whereType<String>().map((value) => value.toLowerCase()).join(' ');
    for (final phrase in const [
      'all day',
      'the whole day',
      'all morning',
      'all night',
      'all evening',
      'a few hours',
      'several hours',
      'about an hour',
      'an hour',
      'half an hour',
      '30 minutes',
    ]) {
      if (text.contains(phrase)) return phrase;
    }

    final duration = _toInt(symptom['duration_minutes']);
    if (duration == null || duration <= 0) return null;
    if (duration == 1440) return 'all day';
    if (duration == 360) return 'about 6 hours';
    if (duration == 480) return 'about 8 hours';
    if (duration < 60) return '$duration minute${duration == 1 ? '' : 's'}';
    final hours = duration / 60;
    final wholeHours = duration ~/ 60;
    if (duration % 60 == 0) {
      return 'about $wholeHours hour${wholeHours == 1 ? '' : 's'}';
    }
    return 'about ${hours.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '')} hours';
  }

  String? _doctorSummaryTriggerLabel(Object? raw) {
    final value = '$raw'.trim();
    if (value.isEmpty || value == 'null') return null;
    return _humanTriggerLabel(value);
  }

  String _humanSymptomLabel(String raw) {
    final value = raw.trim().toLowerCase();
    return switch (value) {
      'abdominal_pain' => 'Abdominal pain',
      'pain' => 'Pain',
      'diarrhea' => 'Loose stools / diarrhea',
      'urgency' => 'Urgency',
      'fatigue' => 'Fatigue',
      'bloating' => 'Bloating',
      'nausea' => 'Nausea',
      'rectal_bleeding' => 'Rectal bleeding',
      'blood' => 'Blood in stool',
      'cramping' => 'Cramping',
      'mucus_stool' => 'Mucus/pus in stool',
      'fever' => 'Fever/chills',
      'night_sweats' => 'Night sweats',
      'mouth_sores' => 'Mouth sores',
      'constipation' => 'Constipation',
      'fecal_incontinence' => 'Bowel leakage',
      'weight_loss' => 'Weight loss',
      'appetite_loss' => 'Appetite loss',
      'fistula' => 'Fistula or drainage',
      'joint_pain' => 'Joint pain',
      'skin' => 'Skin symptoms',
      'eye' => 'Eye symptoms',
      'anal_fissure' => 'Anal fissure pain',
      'obstruction' => 'Obstructive symptoms',
      'vomiting' => 'Vomiting',
      'dehydration' => 'Dehydration symptoms',
      'malnutrition' => 'Malnutrition symptoms',
      'dizziness' => 'Dizziness/lightheadedness',
      'back_pain' => 'Back pain',
      'urinary_urgency' => 'Urinary urgency',
      'headache_migraine' => 'Headache/migraine',
      'other_health_symptom' => 'Other health symptom',
      _ => value
          .replaceAll('_', ' ')
          .split(' ')
          .where((part) => part.isNotEmpty)
          .map((part) => part[0].toUpperCase() + part.substring(1))
          .join(' '),
    };
  }

  String _humanTriggerLabel(String raw) {
    final value = raw.trim().toLowerCase().replaceAll('_', ' ');
    return switch (value) {
      'after meal' => 'After meals',
      'before meal' => 'Before meals',
      'none' => 'No meal link recorded',
      'food-related trigger phrase' => 'Food-related notes',
      'symptom burden' => 'Symptom burden',
      'poor sleep' => 'Poor sleep',
      'normal day load' => 'Normal day load',
      _ => value.isEmpty ? value : value[0].toUpperCase() + value.substring(1),
    };
  }

  String _formatCheckInComponents(Map<String, Object?> checkIn) {
    final core = Map<String, Object?>.from(checkIn['core'] as Map? ?? {});
    final details = Map<String, Object?>.from(checkIn['details'] as Map? ?? {});
    final diseaseType =
        (checkIn['disease_type'] as String? ?? '').toUpperCase();
    final parts = <String>[];
    final pain = diseaseType == 'UC'
        ? _toInt(details['belly_or_rectal_pain_0_3'])
        : _toInt(core['abdominal_pain_0_3']);
    final stool = _toInt(core['bathroom_frequency_0_3']) ??
        _toInt(core['loose_stool_bucket']);
    final bleeding =
        _toInt(core['rectal_bleeding_0_3']) ?? _toInt(details['blood_0_3']);
    final urgency = _toInt(details['urgency_0_3']);
    final wellbeing = _toInt(details['general_wellbeing_0_3']);
    if (pain != null) parts.add('pain ${_pro2SeverityLabel(pain)} ($pain/3)');
    if (stool != null) {
      parts.add(
        diseaseType == 'UC'
            ? 'extra bathroom trips ${_ucStoolLabel(stool)} ($stool/3)'
            : 'loose stool bucket ${_cdStoolLabel(stool)} ($stool/3)',
      );
    }
    if (bleeding != null) {
      parts.add('bleeding ${_pro2SeverityLabel(bleeding)} ($bleeding/3)');
    }
    if (urgency != null) {
      parts.add('urgency ${_pro2SeverityLabel(urgency)} ($urgency/3)');
    }
    if (wellbeing != null) {
      parts.add('wellbeing ${_wellbeingLabel(wellbeing)} ($wellbeing/3)');
    }
    return parts.isEmpty ? 'components not available' : parts.join(', ');
  }

  String? _extractFrequencyContext(String? notes, String? transcript) {
    final combined = [
      notes,
      transcript,
    ].whereType<String>().map((value) => value.toLowerCase()).join(' ');
    if (combined.trim().isEmpty) return null;
    const phrases = [
      'once',
      'twice',
      'three times',
      'daily',
      'every day',
      'all day',
      'intermittent',
      'waves',
      'after meals',
      '5+',
      '3-4',
      '1-2',
    ];
    for (final phrase in phrases) {
      if (combined.contains(phrase)) return phrase;
    }
    return null;
  }

  String _pro2SeverityLabel(int value) => switch (value) {
        <= 0 => 'none',
        1 => 'mild',
        2 => 'moderate',
        _ => 'severe',
      };

  String _wellbeingLabel(int value) => switch (value) {
        <= 0 => 'well',
        1 => 'slightly below par',
        2 => 'poor',
        _ => 'very poor',
      };

  String _ucStoolLabel(int value) => switch (value) {
        <= 0 => 'none extra/usual',
        1 => '1-2 extra',
        2 => '3-4 extra',
        _ => '5+ extra',
      };

  String _cdStoolLabel(int value) => switch (value) {
        <= 0 => 'none',
        1 => '1-3',
        2 => '4-6',
        _ => '7+',
      };

  Map<String, Object?> _symptomToJson(StructuredSymptom symptom) => {
        'symptom_type': symptom.symptomType,
        'severity_1_to_10': symptom.severity1To10,
        'duration_minutes': symptom.durationMinutes,
        'meal_relation': symptom.mealRelation,
        'notes': symptom.notes,
        'confidence': symptom.extractionConfidence,
        'user_facing_description': symptom.userFacingDescription,
        'uncertainty_notes': symptom.uncertaintyNotes,
        'safety_flags': symptom.safetyFlags,
      };

  Map<String, Object?> _scoreToDoctorSummaryJson(FlareRiskScoreRecord score) =>
      {
        'date_local': score.dateLocal,
        'risk_score': score.riskScore.round(),
        'risk_band': score.riskBand,
        'contributions': score.contributionJson,
        'feature_snapshot': score.featureSnapshotJson,
      };

  String _appUseStartDate({
    required Map<String, Object?>? setupJson,
    required List<DailySummaryRecord> summaries,
    required List<FlareRiskScoreRecord> scores,
    required List<SymptomRecord> symptoms,
    required List<LabValueRecord> labs,
    required List<Pro2SurveyRecord> checkIns,
    required String fallbackStart,
  }) {
    final candidates = <String>[];
    for (final key in const [
      'completed_at',
      'profile_validated_at',
      'model_validated_at',
      'health_validated_at',
    ]) {
      final parsed = DateTime.tryParse('${setupJson?[key] ?? ''}')?.toUtc();
      if (parsed != null) candidates.add(_dateOnly(parsed));
    }
    candidates.addAll(summaries.map((item) => item.dateLocal));
    candidates.addAll(scores.map((item) => item.dateLocal));
    candidates.addAll(symptoms.map((item) => _dateOnly(item.loggedAt)));
    candidates.addAll(labs.map((item) => item.drawnDate));
    candidates.addAll(checkIns.map((item) => item.surveyDate));
    candidates.removeWhere((date) => !_isDate(date));
    if (candidates.isEmpty) return fallbackStart;
    candidates.sort();
    return candidates.first;
  }

  int _inclusiveDays(String startDate, String endDate) {
    final start = DateTime.parse('${startDate}T00:00:00Z');
    final end = DateTime.parse('${endDate}T00:00:00Z');
    final days = end.difference(start).inDays + 1;
    return days < 1 ? 1 : days;
  }

  Map<String, Object?> _labToJson(LabValueRecord lab) => {
        'drawn_date': lab.drawnDate,
        'lab_type': lab.labType,
        'lab_name': _cleanLabLabel(lab.labName, lab.labType),
        'value_numeric': lab.valueNumeric,
        'unit': lab.unit,
        'reference_high': lab.referenceHigh,
        'ordering_provider': lab.orderingProvider,
        'notes': lab.notes,
        'elevated': lab.referenceHigh == null
            ? null
            : lab.valueNumeric > lab.referenceHigh!,
      };

  String _cleanLabLabel(String? rawName, String labType) {
    final candidate = (rawName ?? '').trim();
    if (candidate.isEmpty) return labType.toUpperCase();
    return candidate;
  }

  List<Map<String, Object?>> _topContributors(Map<String, Object?> json) {
    final items = json.entries
        .where((entry) => entry.key.endsWith('_points'))
        .map(
          (entry) => {
            'name': entry.key,
            'points': ((entry.value as num?) ?? 0).round(),
          },
        )
        .where((entry) => (entry['points'] as int) > 0)
        .toList(growable: false);
    items.sort((a, b) => (b['points'] as int).compareTo(a['points'] as int));
    return items.take(5).toList(growable: false);
  }

  /// Converts a raw contributor key (e.g. "crp_points") to a human-readable label.
  String _humanizeContributorName(String key) {
    const map = {
      'crp_points': 'Elevated CRP (inflammation marker)',
      'esr_points': 'Elevated ESR (sedimentation rate)',
      'fc_points': 'Elevated fecal calprotectin',
      'bleeding_points': 'Rectal bleeding reported',
      'urgency_points': 'Bowel urgency episodes',
      'stool_frequency_points': 'Increased stool frequency',
      'pain_points': 'Abdominal pain score',
      'fatigue_points': 'Fatigue severity',
      'hrv_points': 'Low heart rate variability (HRV)',
      'sleep_points': 'Poor sleep quality',
      'checkin_points': 'PRO-2 check-in scores',
      'missing_data_points': 'Missing daily check-in data',
      'symptom_points': 'Symptom severity burden from saved entries',
      'logged_symptom_points': 'Symptom severity burden from saved entries',
    };
    final fallback = key.replaceAll('_points', '').replaceAll('_', ' ');
    if (fallback == 'total' ||
        fallback == 'symptom' ||
        fallback == 'logged symptom') {
      return '';
    }
    return map[key] ?? fallback;
  }

  String? _extractDate(String text) {
    final iso = RegExp(
      r'\b(20\d{2})[-/](\d{1,2})[-/](\d{1,2})\b',
    ).firstMatch(text);
    if (iso != null) {
      return _dateParts(iso.group(1)!, iso.group(2)!, iso.group(3)!);
    }
    final us = RegExp(r'\b(\d{1,2})/(\d{1,2})/(20\d{2})\b').firstMatch(text);
    if (us != null) {
      return _dateParts(us.group(3)!, us.group(1)!, us.group(2)!);
    }
    return null;
  }

  String? _normalizeDate(String? value) {
    if (value == null || value == 'null') return null;
    if (_isDate(value)) return value;
    return _extractDate(value);
  }

  String _dateParts(String year, String month, String day) =>
      '${year.padLeft(4, '0')}-${month.padLeft(2, '0')}-${day.padLeft(2, '0')}';

  bool _isDate(String value) =>
      RegExp(r'^20\d{2}-\d{2}-\d{2}$').hasMatch(value);

  String _dateOnly(DateTime date) =>
      '${date.toUtc().year.toString().padLeft(4, '0')}-'
      '${date.toUtc().month.toString().padLeft(2, '0')}-'
      '${date.toUtc().day.toString().padLeft(2, '0')}';

  String _todayDate() => _dateOnly(_nowProvider());

  String _normalizeLabType(String raw) {
    if (raw == 'fecal_calprotectin' || raw == 'calprotectin') return 'fc';
    if (raw == 'vitamin d' || raw == 'vitamind') return 'vitamin_d';
    if (raw == 'vitamin c' || raw == 'vitaminc') return 'vitamin_c';
    if (raw == '25-hydroxyvitamin d' || raw == '25 oh vitamin d') {
      return 'vitamin_d';
    }
    if (raw == 'white_blood_cells' || raw == 'white blood cells') return 'wbc';
    if (raw == 'platelets') return 'platelet';
    if (raw == 'creatinine serum') return 'creatinine';
    if (raw == 'blood urea nitrogen') return 'bun';
    if (raw == 'alk phos') return 'alkaline_phosphatase';
    if (raw == 'alkaline phosphatase') return 'alkaline_phosphatase';
    if (raw == 'total bilirubin') return 'bilirubin';
    if (raw == 'total protein') return 'total_protein';
    if (raw == 't4 free' || raw == 'free t4') return 'free_t4';
    if (raw == 't3 free' || raw == 'free t3') return 'free_t3';
    return raw;
  }

  String _normalizeLabUnit(String labType, String raw) {
    final cleaned = raw.trim().replaceAll('µ', 'μ');
    if (cleaned.isEmpty) return _labDefinitions[labType]?.unit ?? '';
    if (labType == 'fc' && cleaned.toLowerCase() == 'ug/g') return 'μg/g';
    return cleaned;
  }

  String _truncate(String value, int max) =>
      value.length <= max ? value : '${value.substring(0, max)}...';

  String _hash(String value) => sha256.convert(utf8.encode(value)).toString();

  static const _allowedSymptoms = {
    'pain',
    'cramping',
    'diarrhea',
    'urgency',
    'nausea',
    'bloating',
    'fatigue',
    'blood',
    'mucus_stool',
    'fever',
    'night_sweats',
    'mouth_sores',
    'constipation',
    'fecal_incontinence',
    'weight_loss',
    'appetite_loss',
    'fistula',
    'joint_pain',
    'skin',
    'eye',
    'anal_fissure',
    'obstruction',
    'vomiting',
    'dehydration',
    'malnutrition',
    'dizziness',
    'back_pain',
    'urinary_urgency',
    'headache_migraine',
    'other_health_symptom',
    'other',
  };

  static const _allowedMealRelations = {
    'after_lunch',
    'before_lunch',
    'after_dinner',
    'before_dinner',
    'after_breakfast',
    'before_breakfast',
    'after_meal',
    'before_meal',
  };

  static const _allowedIntakeEvents = {
    'medication_taken',
    'medication_skipped',
    'caffeine',
    'alcohol',
    'water',
    'meal',
  };

  static const _labDefinitions = <String, _LabDefinition>{
    'crp': _LabDefinition('mg/dL', 5, 200, r'CRP|C[- ]?Reactive Protein'),
    'esr': _LabDefinition('mm/h', 30, 200, r'ESR|Sed(?:imentation)? Rate'),
    'fc': _LabDefinition(
      'μg/g',
      150,
      10000,
      r'Fecal Calprotectin|Calprotectin',
    ),
    'hemoglobin': _LabDefinition('g/dL', null, 30, r'Hemoglobin|Hgb'),
    'hematocrit': _LabDefinition('%', null, 80, r'Hematocrit|Hct'),
    'mcv': _LabDefinition('fL', null, 150, r'MCV'),
    'mch': _LabDefinition('pg', null, 60, r'MCH'),
    'mchc': _LabDefinition('g/dL', null, 45, r'MCHC'),
    'rdw': _LabDefinition('%', null, 40, r'RDW'),
    'albumin': _LabDefinition('g/dL', null, 8, r'Albumin'),
    'wbc': _LabDefinition('×10⁹/L', null, 100, r'WBC|White Blood Cells?'),
    'rbc': _LabDefinition('×10⁶/μL', null, 10, r'RBC|Red Blood Cells?'),
    'platelet': _LabDefinition('×10⁹/L', null, 1500, r'Platelets?|PLT'),
    'neutrophils': _LabDefinition('%', null, 100, r'Neutrophils?'),
    'lymphocytes': _LabDefinition('%', null, 100, r'Lymphocytes?'),
    'monocytes': _LabDefinition('%', null, 100, r'Monocytes?'),
    'eosinophils': _LabDefinition('%', null, 100, r'Eosinophils?'),
    'basophils': _LabDefinition('%', null, 100, r'Basophils?'),
    'ferritin': _LabDefinition('ng/mL', null, 5000, r'Ferritin'),
    'iron': _LabDefinition('μg/dL', null, 1000, r'Iron'),
    'tibc': _LabDefinition('μg/dL', null, 1000, r'TIBC'),
    'transferrin_saturation': _LabDefinition(
      '%',
      null,
      100,
      r'Transferrin Saturation|Iron Saturation',
    ),
    'vitamin_d': _LabDefinition('ng/mL', null, 300, r'Vitamin D|25[- ]?OH'),
    'vitamin_c': _LabDefinition('mg/dL', null, 10, r'Vitamin C|Ascorbic Acid'),
    'b12': _LabDefinition('pg/mL', null, 3000, r'B12|Vitamin B12'),
    'folate': _LabDefinition('ng/mL', null, 100, r'Folate'),
    'alt': _LabDefinition('U/L', null, 1000, r'ALT'),
    'ast': _LabDefinition('U/L', null, 1000, r'AST'),
    'alkaline_phosphatase': _LabDefinition(
      'U/L',
      null,
      2000,
      r'Alkaline Phosphatase|Alk Phos|ALP',
    ),
    'bilirubin': _LabDefinition('mg/dL', null, 50, r'Bilirubin'),
    'total_protein': _LabDefinition('g/dL', null, 15, r'Total Protein'),
    'creatinine': _LabDefinition('mg/dL', null, 30, r'Creatinine'),
    'bun': _LabDefinition('mg/dL', null, 200, r'BUN|Blood Urea Nitrogen'),
    'egfr': _LabDefinition('mL/min/1.73m2', null, 200, r'eGFR|GFR'),
    'sodium': _LabDefinition('mmol/L', null, 220, r'Sodium|Na'),
    'potassium': _LabDefinition('mmol/L', null, 20, r'Potassium|K'),
    'chloride': _LabDefinition('mmol/L', null, 180, r'Chloride|Cl'),
    'co2': _LabDefinition('mmol/L', null, 80, r'CO2|Bicarbonate'),
    'calcium': _LabDefinition('mg/dL', null, 30, r'Calcium'),
    'magnesium': _LabDefinition('mg/dL', null, 20, r'Magnesium'),
    'phosphorus': _LabDefinition('mg/dL', null, 30, r'Phosphorus|Phosphate'),
    'glucose': _LabDefinition('mg/dL', null, 1000, r'Glucose'),
    'a1c': _LabDefinition('%', null, 25, r'A1C|HbA1c'),
    'tsh': _LabDefinition('mIU/L', null, 200, r'TSH'),
    'free_t4': _LabDefinition('ng/dL', null, 20, r'Free T4|T4 Free'),
    'free_t3': _LabDefinition('pg/mL', null, 30, r'Free T3|T3 Free'),
    'lipase': _LabDefinition('U/L', null, 5000, r'Lipase'),
    'amylase': _LabDefinition('U/L', null, 5000, r'Amylase'),
    'stool_culture': _LabDefinition('', null, 1, r'Stool Culture'),
    'c_diff': _LabDefinition(
      '',
      null,
      1,
      r'C\.?(?: diff| difficile)|Clostridioides',
    ),
  };

  static final RegExp _labValuePattern = RegExp(
    r'((?:[<>]=?\s*)?[0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)\s*([A-Za-zμµ/%^0-9.]+(?:/[A-Za-z0-9μµ]+)?)?',
    caseSensitive: false,
  );
}

class _LabDefinition {
  const _LabDefinition(
    this.unit,
    this.referenceHigh,
    this.maxValue,
    this.pattern,
  );

  final String unit;
  final double? referenceHigh;
  final double maxValue;
  final String pattern;
}

class _DeterministicLabValueHit {
  const _DeterministicLabValueHit({
    required this.score,
    required this.valueNumeric,
    required this.unit,
    required this.sourceTextSnippet,
  });

  final int score;
  final double valueNumeric;
  final String unit;
  final String sourceTextSnippet;
}

class _GeneratedJson {
  const _GeneratedJson({
    required this.json,
    required this.usedModelOutput,
    required this.taskRunId,
  });

  final Map<String, Object?>? json;
  final bool usedModelOutput;
  final int taskRunId;
}

class _GeneratedText {
  const _GeneratedText({
    required this.outputText,
    required this.usedModelOutput,
    required this.taskRunId,
  });

  final String outputText;
  final bool usedModelOutput;
  final int taskRunId;
}
