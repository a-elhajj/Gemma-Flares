// =============================================================================
// rag_test_harness.dart — shared fixtures and helpers for all RAG round-trip tests.
// =============================================================================
// Provides:
//   • Pre-built test data factories for every indexed data type.
//   • A pre-wired (embedding + store + index + query) service triple.
//   • Assertion helpers for round-trip content verification.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart'
    show
        SymptomRecord,
        LabValueRecord,
        Pro2SurveyRecord,
        IntakeEventRecord,
        EndoscopyRecord;
import 'package:gemma_flares/core/services/deterministic_embedding_service.dart';
import 'package:gemma_flares/core/services/food_entry.dart';
import 'package:gemma_flares/core/services/profile_service.dart'
    show UserProfile, MedicationEntry;
import 'package:gemma_flares/core/services/rag_index_service.dart';
import 'package:gemma_flares/core/services/rag_query_service.dart';
import 'package:gemma_flares/core/services/rag_store.dart';
import 'package:gemma_flares/core/services/setup_state_service.dart';

// ---------------------------------------------------------------------------
// Service triple — used by every test group
// ---------------------------------------------------------------------------

class RagTestHarness {
  RagTestHarness({int embeddingDimensions = 64})
      : embedding =
            DeterministicEmbeddingService(dimensions: embeddingDimensions),
        store = InMemoryVectorStore() {
    index = RagIndexService(embedding: embedding, store: store);
    query = RagQueryService(
      embedding: embedding,
      store: store,
      // Fix now to a known time for deterministic time-decay tests.
      now: () => DateTime.utc(2026, 5, 15, 12, 0, 0),
    );
  }

  final DeterministicEmbeddingService embedding;
  final InMemoryVectorStore store;
  late final RagIndexService index;
  late final RagQueryService query;

  // ── Core assertion: embed text and check it's retrievable ─────────────────

  Future<void> assertRoundTrip({
    required String queryText,
    required List<String> expectedSubstrings,
    String description = '',
    bool caseSensitive = false,
    RagQueryConfig config = const RagQueryConfig(),
  }) async {
    final ok = await query.verifyRoundTrip(
      queryText,
      expectedSubstrings,
      caseSensitive: caseSensitive,
      config: config,
    );
    expect(
      ok,
      isTrue,
      reason: description.isNotEmpty
          ? '$description — could not find: $expectedSubstrings'
          : 'Round-trip failed for query "$queryText". '
              'Missing one or more of: $expectedSubstrings',
    );
  }

  // ── Check exact existence by chunk ID ─────────────────────────────────────

  Future<void> assertChunkExists(String collection, String chunkId) async {
    final found = await query.exists(
      collection: collection,
      chunkId: chunkId,
    );
    expect(found, isTrue,
        reason: 'Chunk $chunkId not found in collection $collection');
  }

  Future<void> assertChunkNotExists(String collection, String chunkId) async {
    final found = await query.exists(collection: collection, chunkId: chunkId);
    expect(found, isFalse,
        reason: 'Chunk $chunkId unexpectedly found in collection $collection');
  }

  /// Retrieve chunk by ID and verify it contains [expectedSubstrings].
  Future<void> assertChunkContains(
    String collection,
    String chunkId,
    List<String> expectedSubstrings, {
    bool caseSensitive = false,
  }) async {
    final match = await query.getById(collection: collection, chunkId: chunkId);
    expect(match, isNotNull, reason: 'Chunk $chunkId not found in $collection');
    for (final expected in expectedSubstrings) {
      final text = caseSensitive ? match!.text : match!.text.toLowerCase();
      final q = caseSensitive ? expected : expected.toLowerCase();
      expect(text, contains(q),
          reason: 'Chunk $chunkId does not contain "$expected"');
    }
  }
}

// ---------------------------------------------------------------------------
// Data factories
// ---------------------------------------------------------------------------

class TestSymptoms {
  static SymptomRecord abdominalPain({int severity = 7}) => SymptomRecord(
        id: 101,
        loggedAt: DateTime.utc(2026, 5, 14, 9, 30),
        symptomType: 'abdominal_pain',
        severity: severity,
        durationMinutes: 45,
        mealRelation: 'after_meal',
        notes: 'Sharp cramping lower right quadrant',
        sourceTranscript: null,
        extractionMethod: 'manual',
        extractionConfidence: 0.95,
        createdAt: DateTime.utc(2026, 5, 14, 9, 31),
      );

  static SymptomRecord diarrhea({int? severity}) => SymptomRecord(
        id: 102,
        loggedAt: DateTime.utc(2026, 5, 14, 7, 15),
        symptomType: 'diarrhea',
        severity: severity,
        durationMinutes: null,
        mealRelation: null,
        notes: '4 episodes since midnight',
        sourceTranscript: 'I had diarrhea four times since last night',
        extractionMethod: 'gemma4_e2b_structured',
        extractionConfidence: 0.88,
        createdAt: DateTime.utc(2026, 5, 14, 7, 16),
      );

  static SymptomRecord bloating({int severity = 5}) => SymptomRecord(
        id: 103,
        loggedAt: DateTime.utc(2026, 5, 13, 18, 0),
        symptomType: 'bloating',
        severity: severity,
        durationMinutes: 120,
        mealRelation: 'during_meal',
        notes: null,
        sourceTranscript: null,
        extractionMethod: 'manual',
        extractionConfidence: null,
        createdAt: DateTime.utc(2026, 5, 13, 18, 1),
      );

  static SymptomRecord nausea() => SymptomRecord(
        id: 104,
        loggedAt: DateTime.utc(2026, 5, 15, 6, 0),
        symptomType: 'nausea',
        severity: 3,
        durationMinutes: 30,
        mealRelation: 'before_meal',
        notes: 'Mild nausea in morning, resolved after eating',
        sourceTranscript: null,
        extractionMethod: 'manual',
        extractionConfidence: 1.0,
        createdAt: DateTime.utc(2026, 5, 15, 6, 1),
      );

  /// Edge case: all nullable fields are null.
  static SymptomRecord minimalSymptom() => SymptomRecord(
        id: 200,
        loggedAt: DateTime.utc(2026, 5, 10),
        symptomType: 'fatigue',
        severity: null,
        durationMinutes: null,
        mealRelation: null,
        notes: null,
        sourceTranscript: null,
        extractionMethod: 'deterministic',
        extractionConfidence: null,
        createdAt: DateTime.utc(2026, 5, 10),
      );

  /// Edge case: very long notes (>1000 chars).
  static SymptomRecord longNotes() {
    final notes = 'Severe cramping. ' * 60; // 1020 chars
    return SymptomRecord(
      id: 201,
      loggedAt: DateTime.utc(2026, 5, 12),
      symptomType: 'abdominal_pain',
      severity: 9,
      durationMinutes: 240,
      mealRelation: 'unrelated',
      notes: notes,
      sourceTranscript: null,
      extractionMethod: 'manual',
      extractionConfidence: 1.0,
      createdAt: DateTime.utc(2026, 5, 12),
    );
  }

  /// Edge case: severity=0 (no pain).
  static SymptomRecord zeroSeverity() => SymptomRecord(
        id: 202,
        loggedAt: DateTime.utc(2026, 5, 11),
        symptomType: 'abdominal_pain',
        severity: 0,
        durationMinutes: 0,
        mealRelation: null,
        notes: 'Checking in — no pain today',
        sourceTranscript: null,
        extractionMethod: 'manual',
        extractionConfidence: 1.0,
        createdAt: DateTime.utc(2026, 5, 11),
      );

  /// Edge case: Unicode notes.
  static SymptomRecord unicodeNotes() => SymptomRecord(
        id: 203,
        loggedAt: DateTime.utc(2026, 5, 13),
        symptomType: 'abdominal_pain',
        severity: 6,
        durationMinutes: null,
        mealRelation: null,
        notes: 'Douleur abdominale sévère — très inconfortable 😣',
        sourceTranscript: null,
        extractionMethod: 'manual',
        extractionConfidence: 0.9,
        createdAt: DateTime.utc(2026, 5, 13),
      );
}

class TestLabs {
  static LabValueRecord crp({double value = 12.5}) => LabValueRecord(
        id: 301,
        drawnDate: '2026-05-10',
        labType: 'crp',
        valueNumeric: value,
        unit: 'mg/L',
        referenceHigh: 5.0,
        labName: 'Quest Diagnostics',
        orderingProvider: 'Dr. Smith',
        notes: 'Fasting sample',
        createdAt: DateTime.utc(2026, 5, 10),
        updatedAt: DateTime.utc(2026, 5, 10),
      );

  static LabValueRecord calprotectin() => LabValueRecord(
        id: 302,
        drawnDate: '2026-04-25',
        labType: 'fc',
        valueNumeric: 287.0,
        unit: 'µg/g',
        referenceHigh: 150.0,
        labName: 'LabCorp',
        orderingProvider: null,
        notes: null,
        createdAt: DateTime.utc(2026, 4, 25),
        updatedAt: DateTime.utc(2026, 4, 25),
      );

  static LabValueRecord albumin() => LabValueRecord(
        id: 303,
        drawnDate: '2026-05-01',
        labType: 'albumin',
        valueNumeric: 3.8,
        unit: 'g/dL',
        referenceHigh: null, // no reference high for albumin
        labName: null,
        orderingProvider: 'Dr. Jones',
        notes: null,
        createdAt: DateTime.utc(2026, 5, 1),
        updatedAt: DateTime.utc(2026, 5, 1),
      );

  static LabValueRecord normalCrp() => LabValueRecord(
        id: 304,
        drawnDate: '2026-03-15',
        labType: 'crp',
        valueNumeric: 1.2,
        unit: 'mg/L',
        referenceHigh: 5.0,
        labName: 'Hospital Lab',
        orderingProvider: null,
        notes: 'Normal range',
        createdAt: DateTime.utc(2026, 3, 15),
        updatedAt: DateTime.utc(2026, 3, 15),
      );

  /// Edge case: zero value (test for boundary).
  static LabValueRecord zeroValue() => LabValueRecord(
        id: 400,
        drawnDate: '2026-05-01',
        labType: 'crp',
        valueNumeric: 0.0,
        unit: 'mg/L',
        referenceHigh: 5.0,
        labName: null,
        orderingProvider: null,
        notes: null,
        createdAt: DateTime.utc(2026, 5, 1),
        updatedAt: DateTime.utc(2026, 5, 1),
      );

  /// Edge case: extremely high value.
  static LabValueRecord extremeValue() => LabValueRecord(
        id: 401,
        drawnDate: '2026-05-05',
        labType: 'crp',
        valueNumeric: 289.6,
        unit: 'mg/L',
        referenceHigh: 5.0,
        labName: 'ER Lab',
        orderingProvider: 'Dr. Emergency',
        notes: 'Acute phase response — possible flare',
        createdAt: DateTime.utc(2026, 5, 5),
        updatedAt: DateTime.utc(2026, 5, 5),
      );

  /// Edge case: future drawn date (clock skew or data entry error).
  static LabValueRecord futureDate() => LabValueRecord(
        id: 402,
        drawnDate: '2027-01-01',
        labType: 'esr',
        valueNumeric: 45.0,
        unit: 'mm/h',
        referenceHigh: 30.0,
        labName: null,
        orderingProvider: null,
        notes: 'Data entry error — future date',
        createdAt: DateTime.utc(2026, 5, 15),
        updatedAt: DateTime.utc(2026, 5, 15),
      );
}

class TestCheckIns {
  static Pro2SurveyRecord cdModerate() => Pro2SurveyRecord(
        id: 501,
        surveyDate: '2026-05-15',
        diseaseType: 'CD',
        cdAbdominalPain: 2,
        cdStoolFrequency: 2,
        ucRectalBleeding: null,
        ucStoolFrequency: null,
        pro2Score: 6.0,
        isFlare: false,
        scoreVersion: Pro2SurveyRecord.cdV2Pain2Stool1,
        notes: null,
        createdAt: DateTime.utc(2026, 5, 15),
      );

  static Pro2SurveyRecord cdFlare() => Pro2SurveyRecord(
        id: 502,
        surveyDate: '2026-05-14',
        diseaseType: 'CD',
        cdAbdominalPain: 3,
        cdStoolFrequency: 4,
        ucRectalBleeding: null,
        ucStoolFrequency: null,
        pro2Score: 11.0,
        isFlare: true,
        scoreVersion: Pro2SurveyRecord.cdV2Pain2Stool1,
        notes: '{"schema_version":"ibd_checkin_v1","disease_type":"CD"}',
        createdAt: DateTime.utc(2026, 5, 14),
      );

  static Pro2SurveyRecord ucMild() => Pro2SurveyRecord(
        id: 503,
        surveyDate: '2026-05-13',
        diseaseType: 'UC',
        cdAbdominalPain: null,
        cdStoolFrequency: null,
        ucRectalBleeding: 1,
        ucStoolFrequency: 2,
        pro2Score: 3.0,
        isFlare: false,
        scoreVersion: Pro2SurveyRecord.ucV1BleedingStool,
        notes: null,
        createdAt: DateTime.utc(2026, 5, 13),
      );

  static Pro2SurveyRecord ibsSevere() => Pro2SurveyRecord(
        id: 504,
        surveyDate: '2026-05-12',
        diseaseType: 'IBS',
        cdAbdominalPain: null,
        cdStoolFrequency: null,
        ucRectalBleeding: null,
        ucStoolFrequency: null,
        pro2Score: 310.0,
        isFlare: true,
        scoreVersion: Pro2SurveyRecord.ibsSssV1,
        notes: '{"pain_severity":80,"pain_days":6}',
        createdAt: DateTime.utc(2026, 5, 12),
      );

  /// Edge case: perfect score (no symptoms).
  static Pro2SurveyRecord cdRemission() => Pro2SurveyRecord(
        id: 600,
        surveyDate: '2026-05-01',
        diseaseType: 'CD',
        cdAbdominalPain: 0,
        cdStoolFrequency: 0,
        ucRectalBleeding: null,
        ucStoolFrequency: null,
        pro2Score: 0.0,
        isFlare: false,
        scoreVersion: Pro2SurveyRecord.cdV2Pain2Stool1,
        notes: null,
        createdAt: DateTime.utc(2026, 5, 1),
      );
}

class TestMedications {
  static IntakeEventRecord mesalamineTaken() => IntakeEventRecord(
        id: 701,
        eventType: 'medication_taken',
        loggedAt: DateTime.utc(2026, 5, 15, 8, 0),
        dateLocal: '2026-05-15',
        source: 'medication_review_confirmed',
        confidence: 0.95,
        notes: 'Took Mesalamine | dose 1.2g | timing morning | on schedule',
        metadataJson: {
          'schema_version': 2,
          'medication_name': 'Mesalamine',
          'dose': '1.2g',
          'schedule': 'morning',
          'adherence_indicator': 'on_time',
          'user_confirmed': true,
          'event_type': 'medication_taken',
        },
        createdAt: DateTime.utc(2026, 5, 15, 8, 1),
      );

  static IntakeEventRecord prednisoloneSkipped() => IntakeEventRecord(
        id: 702,
        eventType: 'medication_skipped',
        loggedAt: DateTime.utc(2026, 5, 14, 20, 0),
        dateLocal: '2026-05-14',
        source: 'user_manual',
        confidence: 1.0,
        notes: 'Skipped Prednisolone | dose 20mg | timing evening | forgot',
        metadataJson: {
          'schema_version': 2,
          'medication_name': 'Prednisolone',
          'dose': '20mg',
          'schedule': 'evening',
          'adherence_indicator': 'missed_dose',
          'user_confirmed': true,
          'event_type': 'medication_skipped',
        },
        createdAt: DateTime.utc(2026, 5, 14, 20, 1),
      );

  static IntakeEventRecord biologicInfusion() => IntakeEventRecord(
        id: 703,
        eventType: 'medication_taken',
        loggedAt: DateTime.utc(2026, 5, 8, 14, 0),
        dateLocal: '2026-05-08',
        source: 'manual',
        confidence: 1.0,
        notes: null,
        metadataJson: {
          'schema_version': 2,
          'medication_name': 'Vedolizumab',
          'dose': '300mg IV',
          'schedule': 'every_8_weeks',
          'adherence_indicator': 'on_time',
          'user_confirmed': true,
          'event_type': 'medication_taken',
        },
        createdAt: DateTime.utc(2026, 5, 8, 14, 1),
      );

  /// Edge case: metadataJson is empty.
  static IntakeEventRecord emptyMetadata() => IntakeEventRecord(
        id: 800,
        eventType: 'medication_taken',
        loggedAt: DateTime.utc(2026, 5, 1),
        dateLocal: '2026-05-01',
        source: 'manual',
        confidence: 0.5,
        notes: null,
        metadataJson: const {},
        createdAt: DateTime.utc(2026, 5, 1),
      );
}

class TestHealthData {
  static Map<String, Object?> allMetrics() => {
        'steps': 8432,
        'resting_hr': 62,
        'heart_rate': 74,
        'hrv_sdnn': 42.5,
        'active_energy_kcal': 385.0,
        'exercise_minutes': 35,
        'sleep_hours': 7.2,
        'spo2': 98,
        'respiratory_rate': 14,
        'walking_hr_avg': 88,
        'dietary_water_ml': 2100,
        'dietary_caffeine_mg': 180,
      };

  static Map<String, Object?> partialMetrics() => {
        'steps': 3200,
        'resting_hr': 78,
      };

  static Map<String, Object?> heartHealthFocus() => {
        'resting_hr': 55,
        'hrv_sdnn': 58.3,
        'heart_rate': 68,
        'heart_rate_recovery_1min': 22,
        'atrial_fibrillation_burden_pct': 0.0,
      };
}

class TestProfiles {
  static UserProfile crohnsMale() => UserProfile(
        dateOfBirth: '1985-03-15',
        biologicalSex: 'male',
        heightCm: 178.0,
        weightKg: 75.0,
        diseaseType: 'CD',
        cdDiseaseLocation: 'L3',
        cdDiseaseBehavior: 'B1',
        cdPerianalInvolvement: false,
        ucDiseaseExtent: null,
        diagnosisYear: 2018,
        hadSurgery: false,
        surgeryType: null,
        surgeryYear: null,
        medications: [
          const MedicationEntry(
            name: 'Mesalamine',
            dose: '1.2g',
            frequency: 'twice daily',
            startDate: '2019-01-15',
          ),
          const MedicationEntry(
            name: 'Vedolizumab',
            dose: '300mg IV',
            frequency: 'every 8 weeks',
          ),
        ],
        otherConditions: ['primary_sclerosing_cholangitis'],
      );

  static UserProfile ucFemale() => UserProfile(
        dateOfBirth: '1992-07-22',
        biologicalSex: 'female',
        heightCm: 165.0,
        weightKg: 62.5,
        diseaseType: 'UC',
        cdDiseaseLocation: null,
        cdDiseaseBehavior: null,
        cdPerianalInvolvement: null,
        ucDiseaseExtent: 'E2',
        diagnosisYear: 2021,
        hadSurgery: false,
        surgeryType: null,
        surgeryYear: null,
        medications: [
          const MedicationEntry(
              name: 'Mesalamine', dose: '4.8g', frequency: 'daily'),
        ],
        otherConditions: [],
      );

  static UserProfile emptyProfile() => const UserProfile();

  static UserProfile postSurgery() => UserProfile(
        dateOfBirth: '1975-11-08',
        biologicalSex: 'male',
        diseaseType: 'CD',
        diagnosisYear: 2005,
        hadSurgery: true,
        surgeryType: 'ileocolonic_resection',
        surgeryYear: 2012,
        medications: [],
        otherConditions: ['short_bowel_syndrome'],
      );
}

class TestFood {
  static FoodEntry oatmeal() => FoodEntry(
        id: 901,
        loggedAt: DateTime.utc(2026, 5, 15, 8, 30),
        foodName: 'Oatmeal with blueberries',
        description: 'Rolled oats, plain, topped with 1/4 cup blueberries',
        mealType: 'breakfast',
        calories: 320.0,
        portionGrams: 250.0,
        portionUnit: 'g',
        isGlutenFree: false,
        isLactoseFree: true,
        isDairyFree: true,
        isHighFiber: true,
        isHighFat: false,
        isSpicy: false,
        fiberGrams: 8.5,
        proteinGrams: 12.0,
        fatGrams: 5.0,
        carbGrams: 58.0,
        sugarGrams: 6.0,
        sodiumMg: 45.0,
        allergens: [],
        notes: 'Felt good — no bloating after',
        triggerSuspected: false,
        source: 'manual',
      );

  static FoodEntry pizzaTrigger() => FoodEntry(
        id: 902,
        loggedAt: DateTime.utc(2026, 5, 14, 19, 30),
        foodName: 'Deep dish pizza',
        description: '2 slices pepperoni',
        mealType: 'dinner',
        calories: 680.0,
        portionGrams: null,
        portionUnit: 'slice',
        isGlutenFree: false,
        isLactoseFree: false,
        isDairyFree: false,
        isHighFiber: false,
        isHighFat: true,
        isSpicy: true,
        fiberGrams: 2.0,
        proteinGrams: 28.0,
        fatGrams: 32.0,
        carbGrams: 72.0,
        sugarGrams: 8.0,
        sodiumMg: 1240.0,
        allergens: [Allergen.gluten, Allergen.dairy],
        notes: 'Triggered severe cramping 2h later',
        triggerSuspected: true,
        source: 'manual',
        createdAt: DateTime.utc(2026, 5, 14, 19, 31),
      );

  static FoodEntry salad() => FoodEntry(
        id: 903,
        loggedAt: DateTime.utc(2026, 5, 15, 12, 30),
        foodName: 'Green salad',
        description: 'Mixed greens, cucumber, olive oil dressing',
        mealType: 'lunch',
        calories: 180.0,
        portionGrams: 300.0,
        portionUnit: 'g',
        isGlutenFree: true,
        isLactoseFree: true,
        isDairyFree: true,
        isHighFiber: true,
        isHighFat: false,
        isSpicy: false,
        fiberGrams: 6.0,
        proteinGrams: 4.0,
        fatGrams: 9.0,
        carbGrams: 12.0,
        sugarGrams: 4.0,
        sodiumMg: 180.0,
        allergens: [],
        notes: null,
        triggerSuspected: false,
        source: 'manual',
      );

  /// Edge case: minimal food entry (no macros, no flags).
  static FoodEntry minimalFood() => FoodEntry(
        id: 1000,
        loggedAt: DateTime.utc(2026, 5, 10),
        foodName: 'Unknown snack',
        source: 'manual',
      );

  /// Edge case: all allergens present.
  static FoodEntry allergenBomb() => FoodEntry(
        id: 1001,
        loggedAt: DateTime.utc(2026, 5, 9),
        foodName: 'Mixed allergen dish',
        mealType: 'dinner',
        allergens: [
          Allergen.gluten,
          Allergen.dairy,
          Allergen.nuts,
          Allergen.soy,
          Allergen.eggs,
          Allergen.fish,
          Allergen.shellfish,
          Allergen.wheat,
          Allergen.sesame,
        ],
        triggerSuspected: true,
        source: 'manual',
        createdAt: DateTime.utc(2026, 5, 9),
      );
}

class TestProcedures {
  static EndoscopyRecord colonoscopyUc() => EndoscopyRecord(
        id: 1101,
        procedureDate: '2026-04-10',
        procedureType: 'colonoscopy',
        mayoEndoscopicScore: 2,
        sesCdScore: null,
        rutgeertsScore: null,
        findingsText: 'Active UC, left-sided. Friable mucosa. No pseudopolyps.',
        biopsiesTaken: true,
        biopsyResult:
            'Chronic active colitis, consistent with UC. No dysplasia.',
        provider: 'Dr. Rivera, GI Associates',
        notes: 'Patient tolerated procedure well. Next scope in 12 months.',
        createdAt: DateTime.utc(2026, 4, 10, 14, 30),
      );

  static EndoscopyRecord colonoscopyCd() => EndoscopyRecord(
        id: 1102,
        procedureDate: '2026-03-05',
        procedureType: 'colonoscopy',
        mayoEndoscopicScore: null,
        sesCdScore: 12,
        rutgeertsScore: null,
        findingsText:
            'Deep ulcers in terminal ileum. Skip lesions in ascending colon.',
        biopsiesTaken: true,
        biopsyResult:
            'Transmural inflammation. Granulomas present. CD confirmed.',
        provider: 'Dr. Chen',
        notes: null,
        createdAt: DateTime.utc(2026, 3, 5, 10, 0),
      );

  static EndoscopyRecord ileoscopyPostSurgery() => EndoscopyRecord(
        id: 1103,
        procedureDate: '2025-11-20',
        procedureType: 'ileoscopy',
        mayoEndoscopicScore: null,
        sesCdScore: null,
        rutgeertsScore: 'i2',
        findingsText: 'Mild anastomotic inflammation.',
        biopsiesTaken: false,
        biopsyResult: null,
        provider: null,
        notes: 'Post-ileocolonic resection surveillance.',
        createdAt: DateTime.utc(2025, 11, 20),
      );

  /// Edge: minimal procedure — no optional fields.
  static EndoscopyRecord minimalProcedure() => EndoscopyRecord(
        id: 1200,
        procedureDate: '2026-01-15',
        procedureType: 'flexible_sigmoidoscopy',
        biopsiesTaken: false,
        createdAt: DateTime.utc(2026, 1, 15),
      );

  /// Edge: procedure with extremely long findings text (>4000 chars).
  static EndoscopyRecord longFindings() {
    final findings =
        'Extensive mucosal inflammation with severe ulceration. ' * 80;
    return EndoscopyRecord(
      id: 1201,
      procedureDate: '2026-05-01',
      procedureType: 'colonoscopy',
      mayoEndoscopicScore: 3,
      biopsiesTaken: true,
      biopsyResult: 'High-grade dysplasia detected.',
      findingsText: findings,
      createdAt: DateTime.utc(2026, 5, 1),
    );
  }

  /// Edge: Unicode provider name and notes.
  static EndoscopyRecord unicodeProvider() => EndoscopyRecord(
        id: 1202,
        procedureDate: '2026-02-14',
        procedureType: 'gastroscopy',
        biopsiesTaken: false,
        provider: 'Dr. Müller — Hôpital Universitaire',
        notes: 'Findings: muqueuse gastrique œsophagienne 🔬',
        createdAt: DateTime.utc(2026, 2, 14),
      );

  /// Edge: same date as a lab result (tests cross-collection isolation).
  static EndoscopyRecord sameDateAsLab() => EndoscopyRecord(
        id: 1203,
        procedureDate: '2026-05-10',
        procedureType: 'colonoscopy',
        biopsiesTaken: true,
        findingsText: 'Normal mucosa. No active disease.',
        createdAt: DateTime.utc(2026, 5, 10),
      );
}

class TestModelEvents {
  static SetupStatus completedSetup() => SetupStatus(
        completed: true,
        completedAt: DateTime.utc(2026, 5, 15, 10, 0),
        profileValidatedAt: DateTime.utc(2026, 5, 15, 9, 45),
        modelValidatedAt: DateTime.utc(2026, 5, 15, 9, 55),
        healthValidatedAt: DateTime.utc(2026, 5, 15, 9, 50),
        healthEnabled: true,
        healthLastBackfillAt: DateTime.utc(2026, 5, 15, 9, 50),
        healthImportedSamples: 1420,
        modelRuntimeProfile: 'phone_safe',
        modelBackend: 'gpu',
      );

  static SetupStatus modelValidatedOnly() => SetupStatus(
        modelValidatedAt: DateTime.utc(2026, 5, 15, 9, 55),
        modelRuntimeProfile: 'phone_extended',
        modelBackend: 'cpu',
      );
}
