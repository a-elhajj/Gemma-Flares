import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/gemma_task_service.dart';
import 'package:gemma_flares/core/services/ibd_checkin_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/setup_state_service.dart';
import 'package:gemma_flares/core/services/symptom_parser_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test(
    'symptom extraction accepts valid Gemma JSON and records an audit row',
    () async {
      final harness = await _Harness.create(
        runtime: _FakeRuntime(
          responses: const [
            LocalModelResponse(
              status: 'success',
              outputText: '''
{"symptom_type":"cramping","severity_1_to_10":6,"duration_minutes":45,"meal_relation":"after_dinner","notes":"Cramping after dinner and skipped medication.","confidence":0.88,"intake_events":[{"event_type":"medication_skipped","confidence":0.91,"notes":"Skipped meds yesterday"}],"uncertainty_notes":[]}''',
              runtimeName: 'test-gemma',
            ),
          ],
        ),
      );

      final result = await harness.service.extractSymptom(
        transcript: 'Cramping after dinner, six out of ten, skipped meds.',
        loggedAt: DateTime.parse('2026-04-16T20:00:00Z'),
        deterministicDraft: const SymptomParserService()
            .parse(
              transcript:
                  'Cramping after dinner, six out of ten, skipped meds.',
              loggedAt: DateTime.parse('2026-04-16T20:00:00Z'),
            )
            .structuredSymptom,
      );

      expect(result.usedModelOutput, isTrue);
      expect(result.structuredSymptom.symptomType, 'cramping');
      expect(result.structuredSymptom.severity1To10, 6);
      expect(result.structuredSymptom.mealRelation, 'after_dinner');
      expect(result.intakeEvents.single.eventType, 'medication_skipped');

      final runs = await harness.repository.getGemmaTaskRuns();
      expect(runs.single.taskType, 'symptom_extract');
      expect(runs.single.validationStatus, 'valid_json');
      expect(runs.single.outputHash, isNotNull);

      await harness.dispose();
    },
  );

  test('invalid Gemma symptom JSON falls back to deterministic parsing',
      () async {
    final runtime = _FakeRuntime(
      responses: const [
        LocalModelResponse(
          status: 'success',
          outputText:
              '{"symptom_type":"cramping","severity_1_to_10":99,"confidence":0.9}',
          runtimeName: 'test-gemma',
        ),
        LocalModelResponse(
          status: 'success',
          outputText:
              '{"symptom_type":"not_supported","severity_1_to_10":99,"confidence":0.9}',
          runtimeName: 'test-gemma',
        ),
      ],
    );
    final harness = await _Harness.create(runtime: runtime);

    final result = await harness.service.extractSymptom(
      transcript: 'Mild cramping after lunch.',
      loggedAt: DateTime.parse('2026-04-16T12:00:00Z'),
    );

    expect(runtime.generateCalls, 2);
    expect(result.usedModelOutput, isFalse);
    expect(result.extractionMethod, 'deterministic');
    expect(result.structuredSymptom.symptomType, 'cramping');

    final runs = await harness.repository.getGemmaTaskRuns();
    expect(runs.single.validationStatus, 'invalid_json');
    expect(runs.single.usedModelOutput, isFalse);

    await harness.dispose();
  });

  test(
    'expanded symptom ontology accepts mucus and incontinence types',
    () async {
      final harness = await _Harness.create(
        runtime: _FakeRuntime(
          responses: const [
            LocalModelResponse(
              status: 'success',
              outputText: '''
{"symptoms":[{"symptom_type":"mucus_stool","severity_1_to_10":5,"duration_minutes":60,"meal_relation":"after_meal","notes":"mucus with stool","confidence":0.9},{"symptom_type":"fecal_incontinence","severity_1_to_10":7,"duration_minutes":30,"notes":"stool leakage","confidence":0.86}],"intake_events":[],"uncertainty_notes":[]}''',
              runtimeName: 'test-gemma',
            ),
          ],
        ),
      );

      final result = await harness.service.extractSymptom(
        transcript: 'Mucus with stool and one leakage accident after eating.',
        loggedAt: DateTime.parse('2026-04-16T20:00:00Z'),
      );

      expect(result.usedModelOutput, isTrue);
      expect(result.structuredSymptom.symptomType, 'mucus_stool');
      expect(
        result.allSymptoms.map((s) => s.symptomType),
        contains('fecal_incontinence'),
      );
      expect(result.validationErrors, isEmpty);

      await harness.dispose();
    },
  );

  test(
    'lab extraction normalizes supported labs and saves review metadata',
    () async {
      final harness = await _Harness.create(
        runtime: _FakeRuntime(
          responses: const [
            LocalModelResponse(
              status: 'success',
              outputText: '''
{"drawn_date":"2026-04-10","lab_name":"Example Lab","ordering_provider":"GI Clinic","labs":[{"lab_type":"fecal_calprotectin","value_numeric":420,"unit":"ug/g","reference_high":150,"abnormal_flag":true,"confidence":0.94,"source_text_snippet":"Calprotectin 420 ug/g"},{"lab_type":"crp","value_numeric":12.5,"unit":"mg/L","reference_high":5,"abnormal_flag":true,"confidence":0.91,"source_text_snippet":"CRP 12.5 mg/L"}]}''',
              runtimeName: 'test-gemma',
            ),
          ],
        ),
      );

      final result = await harness.service.extractLabsFromText(
        reportText:
            'Example Lab 2026-04-10 Calprotectin 420 ug/g CRP 12.5 mg/L',
      );

      expect(result.usedModelOutput, isTrue);
      expect(result.candidates.map((item) => item.labType), contains('fc'));
      expect(result.candidates.map((item) => item.labType), contains('crp'));
      expect(result.candidates.first.drawnDate, '2026-04-10');
      expect(result.reviewId, isNotNull);

      final reviews = await harness.repository.getGemmaExtractionReviews();
      expect(reviews.single.reviewType, 'lab_text_extract');
      expect(reviews.single.reviewStatus, 'pending_user_confirm');

      await harness.dispose();
    },
  );

  test(
    'lab extraction fallback prefers analyte result text over table thresholds and alias collisions',
    () async {
      final harness = await _Harness.create(
        runtime: const UnavailableGemmaRuntime(),
      );

      final result = await harness.service.extractLabsFromText(
        reportText: '''
CAL
CALPROTECTIN TEST
To measure intestinal inflammation
Result
320ug/g
Interpretation Positive - Indicates active intestinal inflammation
Calprotectin Level
Interpretation
(ug/g)
< 50
50-200
S
Normal
(likely IBS)
Borderline/mild inflammation
Abnormal
(suggests IBD)
''',
      );

      expect(result.usedModelOutput, isFalse);
      expect(result.candidates.map((item) => item.labType), contains('fc'));
      expect(
        result.candidates.map((item) => item.labType),
        isNot(contains('sodium')),
      );
      final fc = result.candidates.firstWhere(
        (candidate) => candidate.labType == 'fc',
      );
      expect(fc.valueNumeric, 320);
      expect(fc.unit, 'μg/g');
      expect(
        result.validationErrors,
        isNot(contains('Lab value for sodium is out of range.')),
      );

      await harness.dispose();
    },
  );

  test(
    'lab extraction fallback still supports real short-alias chemistry rows',
    () async {
      final harness = await _Harness.create(
        runtime: const UnavailableGemmaRuntime(),
      );

      final result = await harness.service.extractLabsFromText(
        reportText: '''
Basic Metabolic Panel
Collected 2026-05-09
Na 138 mmol/L
K 4.2 mmol/L
Cl 102 mmol/L
CO2 24 mmol/L
''',
      );

      expect(result.usedModelOutput, isFalse);
      expect(result.candidates.map((item) => item.labType), contains('sodium'));
      expect(
        result.candidates.map((item) => item.labType),
        contains('potassium'),
      );
      expect(
        result.candidates.map((item) => item.labType),
        contains('chloride'),
      );
      expect(result.candidates.map((item) => item.labType), contains('co2'));
      expect(
        result.candidates
            .firstWhere((candidate) => candidate.labType == 'sodium')
            .valueNumeric,
        138,
      );

      await harness.dispose();
    },
  );

  test(
    'lab extraction fallback avoids phantom chemistry matches inside narrative OCR noise',
    () async {
      final harness = await _Harness.create(
        runtime: const UnavailableGemmaRuntime(),
      );

      final result = await harness.service.extractLabsFromText(
        reportText: '''
Interpretation Positive - Indicates active intestinal inflammation
Normal range shown below
S
Borderline
Abnormal
Clinical note only, no chemistry panel attached.
''',
      );

      expect(result.usedModelOutput, isFalse);
      expect(result.candidates, isEmpty);

      await harness.dispose();
    },
  );

  test(
    'lab extraction fallback prefers CRP result line over reference range',
    () async {
      final harness = await _Harness.create(
        runtime: const UnavailableGemmaRuntime(),
      );

      final result = await harness.service.extractLabsFromText(
        reportText: '''
C-Reactive Protein
Result
12.5 mg/L
Reference range
< 5.0 mg/L
''',
      );

      expect(result.usedModelOutput, isFalse);
      final crp = result.candidates.firstWhere(
        (candidate) => candidate.labType == 'crp',
      );
      expect(crp.valueNumeric, 12.5);
      expect(crp.unit, 'mg/L');

      await harness.dispose();
    },
  );

  test(
    'doctor summary uses deterministic fallback when Gemma is unavailable',
    () async {
      final harness = await _Harness.create(
        runtime: const UnavailableGemmaRuntime(),
      );
      await harness.repository.upsertFlareRiskScore(
        FlareRiskScoreRecord(
          dateLocal: '2026-04-15',
          riskScore: 44,
          riskBand: 'moderate',
          confidenceScore: 80,
          contributionJson: const {'symptom_points': 12},
          featureSnapshotJson: const {},
          modelVersion: 'risk_v2_context_adjusted',
          createdAt: DateTime.parse('2026-04-16T08:00:00Z'),
        ),
      );
      await harness.repository.insertPro2Survey(
        Pro2SurveyRecord(
          surveyDate: '2026-04-15',
          diseaseType: 'UC',
          ucRectalBleeding: 1,
          ucStoolFrequency: 2,
          pro2Score: 3,
          isFlare: true,
          scoreVersion: Pro2SurveyRecord.ucV1BleedingStool,
          notes: IbdCheckInService.encodeNotes(
            diseaseType: 'UC',
            dailyCore: const {
              'rectal_bleeding_0_3': 1,
              'bathroom_frequency_0_3': 2,
            },
            dailyDetails: const {'urgency_0_3': 2},
            completedSections: const ['core', 'daily_details'],
          ),
          createdAt: DateTime.parse('2026-04-15T08:00:00Z'),
        ),
      );

      final result = await harness.service.createDoctorSummary(days: 7);

      expect(result.usedModelOutput, isFalse);
      expect(result.summaryText, contains('## Overview'));
      expect(result.summaryText, contains('## GI Activity Summary'));
      expect(result.summaryText, contains('## Check-in Summary'));
      expect(result.summaryText, isNot(contains('## Check-In Evidence')));
      expect(result.summaryId, isNotNull);

      final saved = await harness.repository.getDoctorSummaries();
      expect(saved.single.summaryRangeDays, 7);
      expect(saved.single.contextSummaryJson['checkin_summary'], isA<Map>());
      expect(result.summaryText, contains('Check-in'));

      await harness.dispose();
    },
  );

  test(
    'doctor summary preserves severe chat check-in fields and flags score conflicts',
    () async {
      final harness = await _Harness.create(
        runtime: const UnavailableGemmaRuntime(),
      );
      await harness.repository.upsertFlareRiskScore(
        FlareRiskScoreRecord(
          dateLocal: '2026-04-16',
          riskScore: 29,
          riskBand: 'moderate',
          confidenceScore: 43,
          contributionJson: const {'symptom_points': 10},
          featureSnapshotJson: const {},
          modelVersion: 'risk_v2_context_adjusted',
          createdAt: DateTime.parse('2026-04-16T08:00:00Z'),
        ),
      );
      await harness.repository.insertSymptom(
        SymptomRecord(
          loggedAt: DateTime.parse('2026-04-16T07:30:00Z'),
          symptomType: 'bloating',
          severity: 6,
          durationMinutes: 120,
          mealRelation: 'after_meal',
          notes: 'happens every day and lasts all day',
          sourceTranscript:
              'bloating, happens every day, eating food, lasts all day',
          extractionMethod: 'deterministic',
          extractionConfidence: 0.8,
          createdAt: DateTime.parse('2026-04-16T07:30:00Z'),
        ),
      );
      await harness.repository.insertPro2Survey(
        Pro2SurveyRecord(
          surveyDate: '2026-04-16',
          diseaseType: 'UC',
          ucRectalBleeding: 2,
          ucStoolFrequency: 3,
          pro2Score: 5,
          isFlare: true,
          scoreVersion: Pro2SurveyRecord.ucV1BleedingStool,
          notes: IbdCheckInService.encodeNotes(
            diseaseType: 'UC',
            dailyCore: const {
              'abdominal_pain': 3,
              'stool_frequency': 3,
              'rectal_bleeding': 2,
              'general_wellbeing': 2,
              'urgency': 3,
            },
            completedSections: const ['core'],
            source: 'gemma_chat_checkin',
          ),
          createdAt: DateTime.parse('2026-04-16T08:00:00Z'),
        ),
      );

      final result = await harness.service.createDoctorSummary(days: 7);

      expect(result.usedModelOutput, isFalse);
      expect(result.summaryText, contains('high-concern GI symptoms'));
      expect(result.summaryText, contains('bleeding moderate (2/3)'));
      expect(result.summaryText, contains('urgency severe (3/3)'));
      expect(result.summaryText, contains('extra bathroom trips 5+ extra'));
      expect(result.summaryText, contains('Interpret this cautiously'));
      expect(result.summaryText, isNot(contains('Confidence:')));
      expect(
        result.summaryText.toLowerCase(),
        isNot(contains('confidence 43')),
      );
      expect(result.summaryText.toLowerCase(), isNot(contains('risk score')));
      expect(result.summaryText, isNot(contains('/100')));
      expect(
        result.summaryText,
        contains(
          'Check-in totals: 1 day(s) with bleeding, 1 day(s) with urgency',
        ),
      );
      expect(result.summaryText, contains('## Check-in Summary'));
      expect(result.summaryText, contains('## Triage and Red Flags'));
      expect(result.summaryText, contains('Bloating: 1 saved entries across'));
      expect(result.summaryText, contains('After meals: 1 occurrence(s)'));
      expect(result.summaryText, isNot(contains('Check-ins with bleeding: 0')));
      expect(result.contextSummaryJson['clinical_safety'], isA<Map>());

      await harness.dispose();
    },
  );

  test(
    'doctor summary safety guard prepends severe evidence to model output',
    () async {
      final harness = await _Harness.create(
        runtime: _FakeRuntime(
          responses: const [
            LocalModelResponse(
              status: 'success',
              outputText:
                  '## Overview\nCurrent Gemma Flares risk score: 29/100 — MODERATE.',
              runtimeName: 'test-gemma',
            ),
          ],
        ),
      );
      await harness.repository.upsertFlareRiskScore(
        FlareRiskScoreRecord(
          dateLocal: '2026-04-16',
          riskScore: 29,
          riskBand: 'moderate',
          confidenceScore: 43,
          contributionJson: const {},
          featureSnapshotJson: const {},
          modelVersion: 'risk_v2_context_adjusted',
          createdAt: DateTime.parse('2026-04-16T08:00:00Z'),
        ),
      );
      await harness.repository.insertPro2Survey(
        Pro2SurveyRecord(
          surveyDate: '2026-04-16',
          diseaseType: 'UC',
          ucRectalBleeding: 2,
          ucStoolFrequency: 3,
          pro2Score: 5,
          isFlare: true,
          scoreVersion: Pro2SurveyRecord.ucV1BleedingStool,
          notes: IbdCheckInService.encodeNotes(
            diseaseType: 'UC',
            dailyCore: const {
              'abdominal_pain': 3,
              'stool_frequency': 3,
              'rectal_bleeding': 2,
              'general_wellbeing': 2,
              'urgency': 3,
            },
            completedSections: const ['core'],
            source: 'gemma_chat_checkin',
          ),
          createdAt: DateTime.parse('2026-04-16T08:00:00Z'),
        ),
      );

      final result = await harness.service.createDoctorSummary(days: 7);

      expect(result.usedModelOutput, isTrue);
      expect(result.summaryText, startsWith('## Clinical Safety Priority'));
      expect(result.summaryText, contains('visible rectal bleeding (2/3)'));
      expect(result.summaryText, contains('severe urgency (3/3)'));
      expect(result.summaryText, contains('Flare-risk caveat'));
      expect(
        result.summaryText,
        contains('Current 7-day flare-risk estimate is Learning.'),
      );
      expect(result.summaryText.toLowerCase(), isNot(contains('risk score')));
      expect(result.summaryText, isNot(contains('/100')));
      expect(result.summaryText, isNot(contains('Confidence:')));

      await harness.dispose();
    },
  );

  test(
    'doctor summary strips /100 model score and uses 7-day flare-risk percent when available',
    () async {
      final harness = await _Harness.create(
        runtime: _FakeRuntime(
          responses: const [
            LocalModelResponse(
              status: 'success',
              outputText:
                  '## Overview\nCurrent Gemma Flares risk score: 29/100 — MODERATE.',
              runtimeName: 'test-gemma',
            ),
          ],
        ),
      );
      await harness.repository.upsertFlareRiskScore(
        FlareRiskScoreRecord(
          dateLocal: '2026-04-16',
          riskScore: 29,
          riskBand: 'moderate',
          confidenceScore: 43,
          contributionJson: const {},
          featureSnapshotJson: const {
            'logistic_p_flare_7d': 0.27,
            'logistic_7d_cold_start': 0,
          },
          modelVersion: 'risk_v2_context_adjusted',
          createdAt: DateTime.parse('2026-04-16T08:00:00Z'),
        ),
      );

      final result = await harness.service.createDoctorSummary(days: 7);

      expect(
        result.summaryText,
        contains('Current 7-day flare risk is 27% - MODERATE.'),
      );
      expect(result.summaryText.toLowerCase(), isNot(contains('risk score')));
      expect(result.summaryText, isNot(contains('/100')));

      await harness.dispose();
    },
  );

  test(
    'doctor summary semantically de-duplicates duplicate lab result lines',
    () async {
      final harness = await _Harness.create(
        runtime: _FakeRuntime(
          responses: const [
            LocalModelResponse(
              status: 'success',
              outputText:
                  '## Lab Results\nFC: 382.0 ug/g (ref <50.0 ug/g) [2026-04-16]',
              runtimeName: 'test-gemma',
            ),
          ],
        ),
      );

      await harness.repository.upsertLabValue(
        LabValueRecord(
          drawnDate: '2026-04-16',
          labType: 'fc',
          labName: 'Fecal Calprotectin',
          valueNumeric: 382.0,
          unit: 'ug/g',
          referenceHigh: 50.0,
          createdAt: DateTime.parse('2026-04-16T08:00:00Z'),
          updatedAt: DateTime.parse('2026-04-16T08:00:00Z'),
        ),
      );

      final result = await harness.service.createDoctorSummary(days: 30);
      expect(
        'Fecal Calprotectin: 382.0 ug/g'.allMatches(result.summaryText).length,
        1,
      );

      await harness.dispose();
    },
  );

  test(
    'doctor summary high-concern question avoids visible-blood phrasing without bleeding evidence',
    () async {
      final harness = await _Harness.create(
        runtime: const UnavailableGemmaRuntime(),
      );

      await harness.repository.upsertFlareRiskScore(
        FlareRiskScoreRecord(
          dateLocal: '2026-04-16',
          riskScore: 38,
          riskBand: 'moderate',
          confidenceScore: 70,
          contributionJson: const {'stool_frequency_points': 16},
          featureSnapshotJson: const {},
          modelVersion: 'risk_v2_context_adjusted',
          createdAt: DateTime.parse('2026-04-16T08:00:00Z'),
        ),
      );
      await harness.repository.insertPro2Survey(
        Pro2SurveyRecord(
          surveyDate: '2026-04-16',
          diseaseType: 'CD',
          cdAbdominalPain: 3,
          cdStoolFrequency: 3,
          pro2Score: 8,
          isFlare: true,
          notes: IbdCheckInService.encodeNotes(
            diseaseType: 'CD',
            dailyCore: const {
              'abdominal_pain_0_3': 3,
              'loose_stool_bucket': 3,
              'rectal_bleeding_0_3': 0,
            },
            dailyDetails: const {
              'urgency_0_3': 3,
              'fatigue_0_3': 2,
              'general_wellbeing_0_3': 2,
            },
            completedSections: const ['core', 'daily_details'],
            source: 'test_checkin',
          ),
          createdAt: DateTime.parse('2026-04-16T08:00:00Z'),
        ),
      );

      final result = await harness.service.createDoctorSummary(days: 7);

      expect(result.summaryText, contains('Given the saved severe symptoms'));
      expect(
        result.summaryText,
        isNot(contains('Given the saved severe symptoms and visible blood')),
      );

      await harness.dispose();
    },
  );

  test(
    'doctor summary missing days are based on setup-to-today app use span',
    () async {
      final harness = await _Harness.create(
        runtime: const UnavailableGemmaRuntime(),
      );
      await harness.repository.upsertAppSettingJson(
        key: SetupStateService.setupStatusKey,
        value: {
          'completed': true,
          'completed_at': '2026-04-14T10:00:00Z',
          'profile_validated_at': '2026-04-14T09:00:00Z',
          'model_validated_at': '2026-04-14T09:30:00Z',
          'health_validated_at': '2026-04-14T09:45:00Z',
          'schema_version': SetupStatus.currentSchemaVersion,
        },
      );
      await harness.repository.upsertDailySummary(
        DailySummaryRecord(
          dateLocal: '2026-04-14',
          summaryJson: const {'source': 'test'},
          syncQualityScore: 1,
          recomputedAt: DateTime.parse('2026-04-14T12:00:00Z'),
        ),
      );
      await harness.repository.upsertDailySummary(
        DailySummaryRecord(
          dateLocal: '2026-04-16',
          summaryJson: const {'source': 'test'},
          syncQualityScore: 1,
          recomputedAt: DateTime.parse('2026-04-16T08:00:00Z'),
        ),
      );

      final result = await harness.service.createDoctorSummary(days: 30);

      expect(
        result.summaryText,
        contains('1 of 3 app-use day(s) may be missing local summaries'),
      );
      expect(
        result.contextSummaryJson['data_limits'],
        containsPair('app_use_days', 3),
      );
      expect(
        result.contextSummaryJson['data_limits'],
        containsPair('missing_days', 1),
      );

      await harness.dispose();
    },
  );

  test(
    'doctor summary omits complete-coverage line when no app-use days are missing',
    () async {
      final harness = await _Harness.create(
        runtime: const UnavailableGemmaRuntime(),
      );
      await harness.repository.upsertAppSettingJson(
        key: SetupStateService.setupStatusKey,
        value: {
          'completed': true,
          'completed_at': '2026-04-14T10:00:00Z',
          'schema_version': SetupStatus.currentSchemaVersion,
        },
      );
      await harness.repository.upsertDailySummary(
        DailySummaryRecord(
          dateLocal: '2026-04-14',
          summaryJson: const {'source': 'test'},
          syncQualityScore: 1,
          recomputedAt: DateTime.parse('2026-04-14T12:00:00Z'),
        ),
      );
      await harness.repository.upsertDailySummary(
        DailySummaryRecord(
          dateLocal: '2026-04-15',
          summaryJson: const {'source': 'test'},
          syncQualityScore: 1,
          recomputedAt: DateTime.parse('2026-04-15T12:00:00Z'),
        ),
      );
      await harness.repository.upsertDailySummary(
        DailySummaryRecord(
          dateLocal: '2026-04-16',
          summaryJson: const {'source': 'test'},
          syncQualityScore: 1,
          recomputedAt: DateTime.parse('2026-04-16T08:00:00Z'),
        ),
      );

      final result = await harness.service.createDoctorSummary(days: 30);

      expect(result.summaryText, isNot(contains('Local summaries cover all')));
      expect(
        result.summaryText,
        isNot(contains('0 of 3 app-use day(s) may be missing local summaries')),
      );

      await harness.dispose();
    },
  );

  test('doctor summary keeps sparse-context fallback concise', () async {
    final harness = await _Harness.create(
      runtime: const UnavailableGemmaRuntime(),
    );

    final result = await harness.service.createDoctorSummary(days: 30);

    expect(
      result.summaryText,
      contains('No local summaries, symptoms, labs, or check-ins are saved'),
    );
    expect(
      result.summaryText,
      isNot(contains('Objective data gaps: No saved labs such as CBC')),
    );
    expect(
      result.summaryText,
      isNot(contains('Clinical history not documented here:')),
    );
    expect(result.summaryText.length, lessThan(1400));

    await harness.dispose();
  });

  test('prompt budget compacts long fields before runtime generation',
      () async {
    final runtime = _FakeRuntime(
      responses: const [
        LocalModelResponse(
          status: 'success',
          outputText:
              '{"drawn_date":"2026-04-10","labs":[{"lab_type":"crp","value_numeric":7,"unit":"mg/L","reference_high":5,"abnormal_flag":true,"confidence":0.8,"source_text_snippet":"CRP 7"}]}',
          runtimeName: 'test-gemma',
        ),
      ],
    );
    final harness = await _Harness.create(
      runtime: runtime,
      promptBudget: const GemmaPromptBudget(maxPromptChars: 300),
    );

    await harness.service.extractLabsFromText(
      reportText: 'CRP 7 mg/L on 2026-04-10 ${List.filled(2000, 'x').join()}',
    );

    expect(runtime.lastRequest, isNotNull);
    expect(runtime.lastRequest!.groundedContext['compact_notice'], isNotNull);

    await harness.dispose();
  });

  test(
    'doctor summary humanizes numeric symptom durations when no phrase exists',
    () async {
      final harness = await _Harness.create(
        runtime: const UnavailableGemmaRuntime(),
      );
      await harness.repository.insertSymptom(
        SymptomRecord(
          loggedAt: DateTime.parse('2026-04-16T07:30:00Z'),
          symptomType: 'pain',
          severity: 8,
          durationMinutes: 120,
          mealRelation: 'before_dinner',
          notes: 'sharp pain before dinner',
          sourceTranscript: 'sharp pain before dinner for 2 hours',
          extractionMethod: 'deterministic',
          extractionConfidence: 0.8,
          createdAt: DateTime.parse('2026-04-16T07:30:00Z'),
        ),
      );

      final result = await harness.service.createDoctorSummary(days: 7);

      expect(
        result.summaryText,
        contains('Pain: 1 saved entries across 2026-04-16'),
      );
      expect(result.summaryText, contains('Before dinner: 1 occurrence(s)'));
      expect(result.summaryText, isNot(contains('duration 120 min')));
      expect(result.summaryText, isNot(contains('before_dinner')));

      await harness.dispose();
    },
  );

  test('doctor summary does not duplicate check-ins across sections', () async {
    final harness = await _Harness.create(
      runtime: const UnavailableGemmaRuntime(),
    );
    await harness.repository.insertPro2Survey(
      Pro2SurveyRecord(
        surveyDate: '2026-04-16',
        diseaseType: 'UC',
        ucRectalBleeding: 1,
        ucStoolFrequency: 2,
        pro2Score: 3,
        isFlare: true,
        scoreVersion: Pro2SurveyRecord.ucV1BleedingStool,
        notes: IbdCheckInService.encodeNotes(
          diseaseType: 'UC',
          dailyCore: const {
            'rectal_bleeding_0_3': 1,
            'bathroom_frequency_0_3': 2,
          },
          completedSections: const ['core'],
        ),
        createdAt: DateTime.parse('2026-04-16T08:00:00Z'),
      ),
    );

    final result = await harness.service.createDoctorSummary(days: 30);

    expect('## Check-in Summary'.allMatches(result.summaryText).length, 1);
    expect(result.summaryText, isNot(contains('## Check-In Evidence')));
    expect(result.summaryText, contains('## GI Activity Summary'));
    await harness.dispose();
  });

  test(
    'doctor summary omits low-signal older check-ins and weekly-compresses',
    () async {
      final harness = await _Harness.create(
        runtime: const UnavailableGemmaRuntime(),
      );
      await harness.repository.insertPro2Survey(
        Pro2SurveyRecord(
          surveyDate: '2026-04-16',
          diseaseType: 'UC',
          ucRectalBleeding: 2,
          ucStoolFrequency: 3,
          pro2Score: 5,
          isFlare: true,
          scoreVersion: Pro2SurveyRecord.ucV1BleedingStool,
          notes: IbdCheckInService.encodeNotes(
            diseaseType: 'UC',
            dailyCore: const {
              'rectal_bleeding_0_3': 2,
              'bathroom_frequency_0_3': 3,
            },
            completedSections: const ['core'],
          ),
          createdAt: DateTime.parse('2026-04-16T08:00:00Z'),
        ),
      );
      await harness.repository.insertPro2Survey(
        Pro2SurveyRecord(
          surveyDate: '2026-04-05',
          diseaseType: 'UC',
          ucRectalBleeding: 0,
          ucStoolFrequency: 0,
          pro2Score: 0,
          isFlare: false,
          scoreVersion: Pro2SurveyRecord.ucV1BleedingStool,
          notes: IbdCheckInService.encodeNotes(
            diseaseType: 'UC',
            dailyCore: const {
              'rectal_bleeding_0_3': 0,
              'bathroom_frequency_0_3': 0,
            },
            completedSections: const ['core'],
          ),
          createdAt: DateTime.parse('2026-04-05T08:00:00Z'),
        ),
      );

      final result = await harness.service.createDoctorSummary(days: 30);

      expect(
        result.summaryText,
        contains(
          'Low-signal check-ins and low-signal days were omitted or weekly-compressed',
        ),
      );
      expect(result.summaryText, isNot(contains('2026-04-05: score 0')));
      expect(result.summaryText, contains('Week of'));
      await harness.dispose();
    },
  );

  test('doctor summary groups repeated symptom types', () async {
    final harness = await _Harness.create(
      runtime: const UnavailableGemmaRuntime(),
    );
    await harness.repository.insertSymptom(
      SymptomRecord(
        loggedAt: DateTime.parse('2026-04-15T07:30:00Z'),
        symptomType: 'pain',
        severity: 7,
        durationMinutes: 30,
        mealRelation: 'before_dinner',
        notes: 'pain after meals',
        sourceTranscript: 'pain after meals',
        extractionMethod: 'deterministic',
        extractionConfidence: 0.8,
        createdAt: DateTime.parse('2026-04-15T07:30:00Z'),
      ),
    );
    await harness.repository.insertSymptom(
      SymptomRecord(
        loggedAt: DateTime.parse('2026-04-16T07:30:00Z'),
        symptomType: 'pain',
        severity: 8,
        durationMinutes: 45,
        mealRelation: 'after_meal',
        notes: 'worse pain',
        sourceTranscript: 'worse pain',
        extractionMethod: 'deterministic',
        extractionConfidence: 0.8,
        createdAt: DateTime.parse('2026-04-16T07:30:00Z'),
      ),
    );

    final result = await harness.service.createDoctorSummary(days: 30);

    expect(
      result.summaryText,
      contains('Pain: 2 saved entries across 2026-04-15 to 2026-04-16'),
    );
    expect(result.summaryText, contains('Logged symptom: 2026-04-15'));
    await harness.dispose();
  });

  test('doctor summary medication block includes profile medications',
      () async {
    final harness = await _Harness.create(
      runtime: const UnavailableGemmaRuntime(),
    );
    await harness.repository.upsertAppSettingJson(
      key: 'user_profile',
      value: {
        'date_of_birth': null,
        'biological_sex': null,
        'height_cm': null,
        'weight_kg': null,
        'height_unit_preference': 'cm',
        'weight_unit_preference': 'kg',
        'disease_type': 'CD',
        'cd_disease_location': null,
        'cd_disease_behavior': null,
        'cd_perianal_involvement': null,
        'uc_disease_extent': null,
        'diagnosis_year': null,
        'had_surgery': null,
        'surgery_type': null,
        'surgery_year': null,
        'medications': [
          {
            'name': 'Adalimumab',
            'dose': '40 mg',
            'frequency': 'q2w',
            'start_date': '2025-01-01',
          },
          {
            'name': 'Vitamin D3',
            'dose': '2000 IU',
            'frequency': 'daily',
            'start_date': null,
          },
        ],
        'other_conditions': const [],
        'device_type': null,
        'watch_series': null,
      },
    );

    final result = await harness.service.createDoctorSummary(days: 30);

    expect(result.summaryText, contains('## Medication and Supplement Log'));
    expect(
      result.summaryText,
      contains(
        'Profile medication: Adalimumab (dose 40 mg, frequency q2w, start 2025-01-01)',
      ),
    );
    expect(
      result.summaryText,
      contains(
        'Profile medication: Vitamin D3 (dose 2000 IU, frequency daily)',
      ),
    );

    await harness.dispose();
  });

  test(
    'deterministic lab parsing handles conversational ESR phrasing',
    () async {
      final harness = await _Harness.create(
        runtime: const UnavailableGemmaRuntime(),
      );

      final result = await harness.service.extractLabsFromText(
        reportText: 'ESR came back at 42 - log that please',
      );

      expect(result.usedModelOutput, isFalse);
      final esr = result.candidates.firstWhere(
        (candidate) => candidate.labType == 'esr',
      );
      expect(esr.valueNumeric, 42);

      await harness.dispose();
    },
  );

  test(
    'deterministic lab parsing handles comparator phrasing over value',
    () async {
      final harness = await _Harness.create(
        runtime: const UnavailableGemmaRuntime(),
      );

      final result = await harness.service.extractLabsFromText(
        reportText: 'Fecal calprotectin is over 1800 - my GI is concerned',
      );

      expect(result.usedModelOutput, isFalse);
      final fc = result.candidates.firstWhere(
        (candidate) => candidate.labType == 'fc',
      );
      expect(fc.valueNumeric, 1800);

      await harness.dispose();
    },
  );

  test(
    'deterministic lab parsing prefers latest value in from-to trends',
    () async {
      final harness = await _Harness.create(
        runtime: const UnavailableGemmaRuntime(),
      );

      final result = await harness.service.extractLabsFromText(
        reportText:
            'CRP went from 4 to 18 in three weeks - is that significant?',
      );

      expect(result.usedModelOutput, isFalse);
      final crp = result.candidates.firstWhere(
        (candidate) => candidate.labType == 'crp',
      );
      expect(crp.valueNumeric, 18);

      await harness.dispose();
    },
  );
}

class _Harness {
  const _Harness({
    required this.tempRoot,
    required this.database,
    required this.repository,
    required this.service,
  });

  final Directory tempRoot;
  final AppDatabase database;
  final WearableSampleRepository repository;
  final GemmaTaskService service;

  static Future<_Harness> create({
    required LocalModelRuntime runtime,
    GemmaPromptBudget promptBudget = const GemmaPromptBudget(),
    DateTime? now,
  }) async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_gemma_task_test',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final repository = WearableSampleRepository(database: database);
    final service = GemmaTaskService(
      repository: repository,
      runtime: runtime,
      promptBudget: promptBudget,
      nowProvider: () => now ?? DateTime.parse('2026-04-16T08:00:00Z'),
    );
    return _Harness(
      tempRoot: tempRoot,
      database: database,
      repository: repository,
      service: service,
    );
  }

  Future<void> dispose() async {
    await database.close();
    await tempRoot.delete(recursive: true);
  }
}

class _FakeRuntime implements LocalModelRuntime {
  _FakeRuntime({required this.responses});

  final List<LocalModelResponse> responses;
  int generateCalls = 0;
  LocalModelRequest? lastRequest;

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    return const LocalModelRuntimeStatus(
      status: 'ready',
      runtimeName: 'test-gemma',
      backendStyle: 'test',
      modelId: 'gemma-4-e2b',
      quantization: 'q4_0',
      expectedModelFilename: 'Models/litert-lm/test',
      isBackendLinked: true,
      isBundledModelPresent: true,
      isModelLoaded: true,
      reason: 'ready',
    );
  }

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) =>
      getRuntimeStatus();

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    lastRequest = request;
    final index = generateCalls;
    generateCalls += 1;
    if (responses.isEmpty) {
      return const LocalModelResponse(
        status: 'unavailable',
        outputText: '',
        runtimeName: 'test-gemma',
        reason: 'no response queued',
      );
    }
    return responses[index.clamp(0, responses.length - 1)];
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) =>
      getRuntimeStatus();
}
