import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/ibd_checkin_service.dart';

void main() {
  test('encodes disease-specific Crohn check-in evidence and red flags', () {
    final notes = IbdCheckInService.encodeNotes(
      diseaseType: 'CD',
      dailyCore: const {'abdominal_pain_0_3': 3, 'loose_stool_bucket': 3},
      dailyDetails: const {
        'urgency_0_3': 2,
        'bloating_0_3': 1,
        'fatigue_0_3': 2,
        'blood_0_3': 3,
        'perianal_symptom_0_3': 0,
      },
      completedSections: const ['core', 'daily_details'],
    );
    final survey = Pro2SurveyRecord(
      surveyDate: '2026-04-19',
      diseaseType: 'CD',
      cdAbdominalPain: 3,
      cdStoolFrequency: 3,
      pro2Score: 9,
      isFlare: true,
      scoreVersion: Pro2SurveyRecord.cdV2Pain2Stool1,
      notes: notes,
      createdAt: DateTime.utc(2026, 4, 19),
    );

    final evidence = IbdCheckInService.evidenceForSurvey(survey);

    expect(evidence['completion_score'], 0.8);
    expect(evidence['summary'], contains('belly pain severe'));
    expect(evidence['red_flags'], contains('heavy_bleeding'));
    expect((evidence['core'] as Map)['loose_stool_bucket'], 3);
  });

  test('summarizes seven-day check-ins and tolerates legacy rows', () {
    final modern = Pro2SurveyRecord(
      surveyDate: '2026-04-19',
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
      createdAt: DateTime.utc(2026, 4, 19),
    );
    final legacy = Pro2SurveyRecord(
      surveyDate: '2026-04-18',
      diseaseType: 'CD',
      cdAbdominalPain: 1,
      cdStoolFrequency: 0,
      pro2Score: 2,
      isFlare: false,
      scoreVersion: Pro2SurveyRecord.cdV2Pain2Stool1,
      createdAt: DateTime.utc(2026, 4, 18),
    );

    final summary = IbdCheckInService.sevenDaySummary([legacy, modern]);

    expect(summary['completed_days'], 2);
    expect(summary['days_with_bleeding'], 1);
    expect(summary['days_with_urgency'], 1);
    expect((summary['latest'] as Map)['date'], '2026-04-19');
  });
}
