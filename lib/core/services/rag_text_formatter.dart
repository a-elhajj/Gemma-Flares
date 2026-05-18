// =============================================================================
// RagTextFormatter — canonical plaintext serialization for all RAG data types.
// =============================================================================
// Every method here is a PURE FUNCTION: same input → same output, no I/O.
//
// Design invariants:
//   • Every field that is non-null appears VERBATIM in the output.
//   • Output format is stable: changing it invalidates existing embeddings.
//     Increment schema version comments if the format changes.
//   • Field headers use fixed strings so tests can grep for them.
//   • Null fields are omitted from the block, not rendered as "null".
//   • Chunk ID is deterministic: callers can reconstruct it from inputs.
//
// Round-trip guarantee: if formatSymptom(symptom).contains(X), then
// the original symptom data contained X (no lossy transforms).
// =============================================================================

import 'package:gemma_flares/core/database/wearable_sample_repository.dart'
    show
        SymptomRecord,
        LabValueRecord,
        Pro2SurveyRecord,
        IntakeEventRecord,
        EndoscopyRecord;
import 'package:gemma_flares/core/services/profile_service.dart'
    show UserProfile;

import 'food_entry.dart';

// ---------------------------------------------------------------------------
// Collection routing constants (must match VectorStore / VectorIndexService)
// ---------------------------------------------------------------------------

abstract class RagCollection {
  static const messages = 'messages';
  static const symptoms = 'symptoms';
  static const summaries = 'summaries';
  static const labs = 'labs';
  static const procedures = 'procedures';
  static const checkins = 'checkins';
  static const knowledge = 'knowledge';
  static const profile = 'profile';
  static const food = 'food';
  static const modelEvents = 'model_events';
  static const medications = 'medications';
  static const healthSync = 'health_sync';
  static const giExports = 'gi_exports';
}

// ---------------------------------------------------------------------------
// RagTextFormatter
// ---------------------------------------------------------------------------

class RagTextFormatter {
  const RagTextFormatter._();

  // ── Schema version markers (increment on format change) ───────────────────
  static const _symptomSchemaV = 'symptom_rag_v1';
  static const _labSchemaV = 'lab_rag_v1';
  static const _checkinSchemaV = 'checkin_rag_v1';
  static const _procedureSchemaV = 'procedure_rag_v1';
  static const _medicationSchemaV = 'medication_rag_v1';
  static const _healthSchemaV = 'health_rag_v1';
  static const _profileSchemaV = 'profile_rag_v1';
  static const _foodSchemaV = 'food_rag_v1';
  static const _modelEventSchemaV = 'model_event_rag_v1';

  // ══════════════════════════════════════════════════════════════════════════
  // SYMPTOM
  // ══════════════════════════════════════════════════════════════════════════

  static String formatSymptom(int id, SymptomRecord s) {
    final buf = StringBuffer();
    final chunkId = symptomChunkId(id);
    buf.writeln('=== Symptom Record [id=$id] schema=$_symptomSchemaV ===');
    buf.writeln('chunk_id: $chunkId');
    buf.writeln('type: ${s.symptomType}');
    if (s.severity != null) buf.writeln('severity: ${s.severity}/10');
    buf.writeln('logged_at: ${s.loggedAt.toUtc().toIso8601String()}');
    if (s.durationMinutes != null) {
      buf.writeln('duration_minutes: ${s.durationMinutes}');
    }
    if (s.mealRelation != null) buf.writeln('meal_relation: ${s.mealRelation}');
    if (s.notes != null && s.notes!.isNotEmpty) {
      buf.writeln('notes: ${s.notes}');
    }
    if (s.sourceTranscript != null && s.sourceTranscript!.isNotEmpty) {
      buf.writeln('source_transcript: ${s.sourceTranscript}');
    }
    buf.writeln('extraction_method: ${s.extractionMethod}');
    if (s.extractionConfidence != null) {
      buf.writeln(
          'extraction_confidence: ${(s.extractionConfidence! * 100).round()}%');
    }
    return buf.toString().trim();
  }

  static String symptomChunkId(int id) => 'symptom_tx_$id';

  static Map<String, Object?> symptomMetadata(int id, SymptomRecord s) => {
        'source_type': 'symptom',
        'symptom_id': id,
        'symptom_type': s.symptomType,
        'severity': s.severity,
        'logged_at': s.loggedAt.toUtc().toIso8601String(),
        'meal_relation': s.mealRelation,
        'schema': _symptomSchemaV,
      };

  // ══════════════════════════════════════════════════════════════════════════
  // LAB RESULT
  // ══════════════════════════════════════════════════════════════════════════

  static String formatLabResult(int id, LabValueRecord r) {
    final buf = StringBuffer();
    buf.writeln('=== Lab Result [id=$id] schema=$_labSchemaV ===');
    buf.writeln('drawn_date: ${r.drawnDate}');
    buf.writeln('lab_type: ${r.labType}');
    buf.writeln('value: ${r.valueNumeric} ${r.unit}');
    if (r.referenceHigh != null) {
      buf.writeln('reference_high: ${r.referenceHigh} ${r.unit}');
      final ratio = r.valueNumeric / r.referenceHigh!;
      buf.writeln(
          'abnormal: ${r.valueNumeric > r.referenceHigh! ? 'yes (${(ratio * 100).round()}% of limit)' : 'no'}');
    }
    if (r.labName != null && r.labName!.isNotEmpty) {
      buf.writeln('lab_name: ${r.labName}');
    }
    if (r.orderingProvider != null && r.orderingProvider!.isNotEmpty) {
      buf.writeln('ordering_provider: ${r.orderingProvider}');
    }
    if (r.notes != null && r.notes!.isNotEmpty) {
      buf.writeln('notes: ${r.notes}');
    }
    return buf.toString().trim();
  }

  static String labChunkId(int id) => 'lab_tx_$id';

  static Map<String, Object?> labMetadata(int id, LabValueRecord r) => {
        'source_type': 'lab_value',
        'lab_id': id,
        'lab_type': r.labType,
        'drawn_date': r.drawnDate,
        'value_numeric': r.valueNumeric,
        'unit': r.unit,
        'reference_high': r.referenceHigh,
        'lab_name': r.labName,
        'schema': _labSchemaV,
      };

  // ══════════════════════════════════════════════════════════════════════════
  // ENDOSCOPY / PROCEDURE RECORD
  // ══════════════════════════════════════════════════════════════════════════

  static String formatEndoscopyRecord(int id, EndoscopyRecord r) {
    final buf = StringBuffer();
    buf.writeln(
        '=== Endoscopy / Procedure Record [id=$id] schema=$_procedureSchemaV ===');
    buf.writeln('procedure_date: ${r.procedureDate}');
    buf.writeln('procedure_type: ${r.procedureType}');
    if (r.mayoEndoscopicScore != null) {
      buf.writeln('mayo_endoscopic_score: ${r.mayoEndoscopicScore}');
    }
    if (r.sesCdScore != null) buf.writeln('ses_cd_score: ${r.sesCdScore}');
    if (r.rutgeertsScore != null && r.rutgeertsScore!.isNotEmpty) {
      buf.writeln('rutgeerts_score: ${r.rutgeertsScore}');
    }
    if (r.findingsText != null && r.findingsText!.isNotEmpty) {
      buf.writeln('findings: ${r.findingsText}');
    }
    buf.writeln('biopsies_taken: ${r.biopsiesTaken}');
    if (r.biopsyResult != null && r.biopsyResult!.isNotEmpty) {
      buf.writeln('biopsy_result: ${r.biopsyResult}');
    }
    if (r.provider != null && r.provider!.isNotEmpty) {
      buf.writeln('provider: ${r.provider}');
    }
    if (r.notes != null && r.notes!.isNotEmpty) {
      buf.writeln('notes: ${r.notes}');
    }
    return buf.toString().trim();
  }

  static String endoscopyChunkId(int id) => 'endoscopy_tx_$id';

  static Map<String, Object?> endoscopyMetadata(int id, EndoscopyRecord r) => {
        'source_type': 'endoscopy_record',
        'procedure_id': id,
        'procedure_date': r.procedureDate,
        'procedure_type': r.procedureType,
        'mayo_endoscopic_score': r.mayoEndoscopicScore,
        'ses_cd_score': r.sesCdScore,
        'biopsies_taken': r.biopsiesTaken,
        'schema': _procedureSchemaV,
      };

  // ══════════════════════════════════════════════════════════════════════════
  // CHECK-IN SURVEY (PRO-2 / IBS-SSS)
  // ══════════════════════════════════════════════════════════════════════════

  static String formatCheckIn(int id, Pro2SurveyRecord s) {
    final buf = StringBuffer();
    buf.writeln('=== Check-in Survey [id=$id] schema=$_checkinSchemaV ===');
    buf.writeln('survey_date: ${s.surveyDate}');
    buf.writeln('disease_type: ${s.diseaseType}');
    buf.writeln('pro2_score: ${s.pro2Score.toStringAsFixed(1)}');
    buf.writeln('is_flare: ${s.isFlare}');
    buf.writeln('score_version: ${s.scoreVersion}');

    if (s.diseaseType == 'CD' || s.diseaseType == 'UC') {
      if (s.cdAbdominalPain != null) {
        buf.writeln('abdominal_pain_0_3: ${s.cdAbdominalPain}');
      }
      if (s.cdStoolFrequency != null) {
        buf.writeln('stool_frequency_0_4: ${s.cdStoolFrequency}');
      }
      if (s.ucRectalBleeding != null) {
        buf.writeln('rectal_bleeding_0_3: ${s.ucRectalBleeding}');
      }
      if (s.ucStoolFrequency != null) {
        buf.writeln('uc_stool_frequency_0_3: ${s.ucStoolFrequency}');
      }
    }

    if (s.notes != null && s.notes!.isNotEmpty) {
      buf.writeln('notes_json: ${s.notes}');
    }

    return buf.toString().trim();
  }

  static String checkinChunkId(int id) => 'checkin_tx_$id';

  static Map<String, Object?> checkinMetadata(int id, Pro2SurveyRecord s) => {
        'source_type': 'checkin_survey',
        'survey_id': id,
        'survey_date': s.surveyDate,
        'disease_type': s.diseaseType,
        'pro2_score': s.pro2Score,
        'is_flare': s.isFlare,
        'score_version': s.scoreVersion,
        'schema': _checkinSchemaV,
      };

  // ══════════════════════════════════════════════════════════════════════════
  // MEDICATION / INTAKE EVENT
  // ══════════════════════════════════════════════════════════════════════════

  static String formatMedication(int id, IntakeEventRecord e) {
    final meta = Map<String, Object?>.from(e.metadataJson);

    final buf = StringBuffer();
    buf.writeln('=== Medication Event [id=$id] schema=$_medicationSchemaV ===');
    buf.writeln('event_type: ${e.eventType}');
    buf.writeln('logged_at: ${e.loggedAt.toUtc().toIso8601String()}');
    buf.writeln('date_local: ${e.dateLocal}');
    buf.writeln('source: ${e.source}');
    buf.writeln('confidence: ${(e.confidence * 100).round()}%');

    final medName = meta['medication_name'];
    if (medName != null) {
      buf.writeln('medication_name: $medName');
    }

    final dose = meta['dose'];
    if (dose != null) buf.writeln('dose: $dose');

    final schedule = meta['schedule'];
    if (schedule != null) buf.writeln('schedule: $schedule');

    final adherence = meta['adherence_indicator'];
    if (adherence != null) buf.writeln('adherence_indicator: $adherence');

    if (e.notes != null && e.notes!.isNotEmpty) {
      buf.writeln('notes: ${e.notes}');
    }

    return buf.toString().trim();
  }

  static String medicationChunkId(int id) => 'med_tx_$id';

  static Map<String, Object?> medicationMetadata(int id, IntakeEventRecord e) {
    final meta = e.metadataJson;
    return {
      'source_type': 'intake_event',
      'intake_id': id,
      'event_type': e.eventType,
      'date_local': e.dateLocal,
      'logged_at': e.loggedAt.toUtc().toIso8601String(),
      'source': e.source,
      'confidence': e.confidence,
      'medication_name': meta['medication_name'],
      'dose': meta['dose'],
      'adherence_indicator': meta['adherence_indicator'],
      'schema': _medicationSchemaV,
    };
  }

  // ══════════════════════════════════════════════════════════════════════════
  // HEALTH SYNC (HealthKit metrics for a given date)
  // ══════════════════════════════════════════════════════════════════════════

  static String formatHealthSync({
    required String dateLocal,
    required Map<String, Object?> metrics,
    double? riskScore,
    String? riskBand,
    String? reason,
  }) {
    final buf = StringBuffer();
    buf.writeln('=== Health Sync [$dateLocal] schema=$_healthSchemaV ===');
    buf.writeln('date_local: $dateLocal');
    if (reason != null) buf.writeln('reason: $reason');
    if (riskScore != null) {
      buf.writeln(
          'flare_risk_score: ${riskScore.toStringAsFixed(1)}% band=${riskBand ?? 'unknown'}');
    }
    buf.writeln('--- Metrics ---');
    for (final entry in metrics.entries) {
      if (entry.value != null) {
        buf.writeln('${entry.key}: ${entry.value}');
      }
    }
    return buf.toString().trim();
  }

  static String healthSyncChunkId(String dateLocal) =>
      'health_sync_tx_$dateLocal';

  static Map<String, Object?> healthSyncMetadata({
    required String dateLocal,
    required Map<String, Object?> metrics,
    double? riskScore,
    String? riskBand,
    String? reason,
  }) =>
      {
        'source_type': 'apple_health_sync',
        'date_local': dateLocal,
        'reason': reason,
        'risk_score': riskScore,
        'risk_band': riskBand,
        'metric_count': metrics.length,
        'schema': _healthSchemaV,
      };

  // ══════════════════════════════════════════════════════════════════════════
  // USER PROFILE
  // ══════════════════════════════════════════════════════════════════════════

  static String formatProfile(UserProfile p) {
    final buf = StringBuffer();
    buf.writeln('=== User Profile schema=$_profileSchemaV ===');
    if (p.diseaseType != null) buf.writeln('disease_type: ${p.diseaseType}');
    if (p.diagnosisYear != null) {
      buf.writeln('diagnosis_year: ${p.diagnosisYear}');
    }
    if (p.biologicalSex != null) {
      buf.writeln('biological_sex: ${p.biologicalSex}');
    }
    if (p.dateOfBirth != null) buf.writeln('date_of_birth: ${p.dateOfBirth}');
    if (p.heightCm != null) buf.writeln('height_cm: ${p.heightCm}');
    if (p.weightKg != null) buf.writeln('weight_kg: ${p.weightKg}');
    if (p.cdDiseaseLocation != null) {
      buf.writeln('cd_disease_location: ${p.cdDiseaseLocation}');
    }
    if (p.cdDiseaseBehavior != null) {
      buf.writeln('cd_disease_behavior: ${p.cdDiseaseBehavior}');
    }
    if (p.cdPerianalInvolvement == true) buf.writeln('cd_perianal: yes');
    if (p.ucDiseaseExtent != null) {
      buf.writeln('uc_disease_extent: ${p.ucDiseaseExtent}');
    }
    if (p.hadSurgery == true) {
      buf.writeln('had_surgery: yes');
      if (p.surgeryType != null) buf.writeln('surgery_type: ${p.surgeryType}');
      if (p.surgeryYear != null) buf.writeln('surgery_year: ${p.surgeryYear}');
    }
    if (p.medications.isNotEmpty) {
      buf.writeln('--- Medications ---');
      for (final med in p.medications) {
        final parts = [med.name];
        if (med.dose != null) parts.add(med.dose!);
        if (med.frequency != null) parts.add(med.frequency!);
        buf.writeln('medication: ${parts.join(' | ')}');
      }
    }
    if (p.otherConditions.isNotEmpty) {
      buf.writeln('other_conditions: ${p.otherConditions.join(', ')}');
    }
    return buf.toString().trim();
  }

  static const profileChunkId = 'profile_rag_v1';

  static Map<String, Object?> profileMetadata(UserProfile p) => {
        'source_type': 'user_profile',
        'disease_type': p.diseaseType,
        'diagnosis_year': p.diagnosisYear,
        'had_surgery': p.hadSurgery,
        'medication_count': p.medications.length,
        'schema': _profileSchemaV,
      };

  // ══════════════════════════════════════════════════════════════════════════
  // FOOD ENTRY
  // ══════════════════════════════════════════════════════════════════════════

  static String formatFoodEntry(String id, FoodEntry f) {
    final buf = StringBuffer();
    buf.writeln('=== Food Entry [$id] schema=$_foodSchemaV ===');
    buf.writeln('food_name: ${f.foodName}');
    buf.writeln('logged_at: ${f.loggedAt.toUtc().toIso8601String()}');
    if (f.mealType != null) buf.writeln('meal_type: ${f.mealType}');
    if (f.description != null && f.description!.isNotEmpty) {
      buf.writeln('description: ${f.description}');
    }
    if (f.calories != null) buf.writeln('calories_kcal: ${f.calories}');
    if (f.portionGrams != null) {
      final unit = f.portionUnit ?? 'g';
      buf.writeln('portion: ${f.portionGrams}$unit');
    }
    if (f.proteinGrams != null) buf.writeln('protein_g: ${f.proteinGrams}');
    if (f.carbGrams != null) buf.writeln('carb_g: ${f.carbGrams}');
    if (f.fatGrams != null) buf.writeln('fat_g: ${f.fatGrams}');
    if (f.fiberGrams != null) buf.writeln('fiber_g: ${f.fiberGrams}');
    if (f.sugarGrams != null) buf.writeln('sugar_g: ${f.sugarGrams}');
    if (f.sodiumMg != null) buf.writeln('sodium_mg: ${f.sodiumMg}');

    // Dietary flags (only log non-null)
    final flags = <String>[];
    if (f.isGlutenFree == true) flags.add('gluten_free');
    if (f.isLactoseFree == true) flags.add('lactose_free');
    if (f.isDairyFree == true) flags.add('dairy_free');
    if (f.isHighFiber == true) flags.add('high_fiber');
    if (f.isHighFat == true) flags.add('high_fat');
    if (f.isSpicy == true) flags.add('spicy');
    if (flags.isNotEmpty) buf.writeln('dietary_flags: ${flags.join(', ')}');

    if (f.allergens.isNotEmpty) {
      buf.writeln('allergens: ${f.allergens.join(', ')}');
    }
    if (f.triggerSuspected) buf.writeln('trigger_suspected: yes');
    if (f.notes != null && f.notes!.isNotEmpty) {
      buf.writeln('notes: ${f.notes}');
    }
    buf.writeln('source: ${f.source}');

    return buf.toString().trim();
  }

  static String foodChunkId(String id) => 'food_tx_$id';
  static String foodChunkIdFromInt(int id) => 'food_tx_$id';

  static Map<String, Object?> foodMetadata(String id, FoodEntry f) => {
        'source_type': 'food_entry',
        'food_id': id,
        'food_name': f.foodName,
        'meal_type': f.mealType,
        'logged_at': f.loggedAt.toUtc().toIso8601String(),
        'calories': f.calories,
        'trigger_suspected': f.triggerSuspected,
        'allergens': f.allergens,
        'schema': _foodSchemaV,
      };

  // ══════════════════════════════════════════════════════════════════════════
  // MODEL INSTALLATION CONFIRMATION
  // ══════════════════════════════════════════════════════════════════════════

  static String formatModelInstallation({
    required String engineProvider, // 'litert-lm'
    required String modelId,
    required String? runtimeProfile,
    required String? backend,
    required DateTime installedAt,
    required bool validated,
    Map<String, Object?> extra = const {},
  }) {
    final buf = StringBuffer();
    buf.writeln('=== Model Installation schema=$_modelEventSchemaV ===');
    buf.writeln('engine_provider: $engineProvider');
    buf.writeln('model_id: $modelId');
    buf.writeln('installed_at: ${installedAt.toUtc().toIso8601String()}');
    buf.writeln('validated: $validated');
    if (runtimeProfile != null) buf.writeln('runtime_profile: $runtimeProfile');
    if (backend != null) buf.writeln('backend: $backend');
    for (final e in extra.entries) {
      if (e.value != null) buf.writeln('${e.key}: ${e.value}');
    }
    return buf.toString().trim();
  }

  static String modelInstallChunkId(String engineProvider, String modelId) =>
      'model_install_${engineProvider}_${modelId.replaceAll(RegExp(r'\W'), '_')}';

  static Map<String, Object?> modelInstallMetadata({
    required String engineProvider,
    required String modelId,
    required DateTime installedAt,
    required bool validated,
    String? runtimeProfile,
    String? backend,
  }) =>
      {
        'source_type': 'model_installation',
        'engine_provider': engineProvider,
        'model_id': modelId,
        'installed_at': installedAt.toUtc().toIso8601String(),
        'validated': validated,
        'runtime_profile': runtimeProfile,
        'backend': backend,
        'schema': _modelEventSchemaV,
      };
}
