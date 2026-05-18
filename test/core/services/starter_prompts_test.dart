import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/prompt_templates.dart' as prompts;

/// Starter prompt preset recognition and intent classification tests.
///
/// Validates that the new starter prompts (medication note, food trigger,
/// HRV trend, activity pattern, prep for visit) are correctly:
/// 1. Recognized as presets with typo tolerance
/// 2. Mapped to the correct task contracts
/// 3. Routed to Gemma with appropriate data filtering
/// 4. Do NOT include score/confidence in grounding unless explicitly asked
void main() {
  group('Starter prompt preset recognition', () {
    group('medication_note preset matches', () {
      final cases = <String>[
        'Medication note',
        'medication note',
        'MEDICATION NOTE',
        'medicaton note',
        'medication not',
        'med note',
        'medication notes',
        'mediation note',
        'medication note please',
        'medication-note',
      ];

      for (final input in cases) {
        test('recognizes "$input" as medication_note', () {
          final preset = prompts.presetForUserText(input);
          expect(preset, isNotNull, reason: 'Should match medication_note');
          expect(preset!.id, equals('medication_note'));
          expect(preset.intent, equals('medication_context'));
          expect(preset.taskContract, equals('medicationNote'));
        });
      }
    });

    group('food_trigger preset matches', () {
      final cases = <String>[
        'Food trigger',
        'food trigger',
        'FOOD TRIGGER',
        'food trigegr',
        'food-trigger',
        'food triggers',
        'food trigers',
        'food trigger analysis',
        'food trigger please',
        'food triggger',
      ];

      for (final input in cases) {
        test('recognizes "$input" as food_trigger', () {
          final preset = prompts.presetForUserText(input);
          expect(preset, isNotNull, reason: 'Should match food_trigger');
          expect(preset!.id, equals('food_trigger'));
          expect(preset.intent, equals('food_trigger_analysis'));
          expect(preset.taskContract, equals('foodTrigger'));
        });
      }
    });

    group('hrv_trend preset matches', () {
      final cases = <String>[
        'HRV trend',
        'hrv trend',
        'HRV TREND',
        'hrv trned',
        'HRV trends',
        'hrv-trend',
        'HRV tren',
        'hrv trend please',
        'HRV trend analysis',
        'hrvtrend',
      ];

      for (final input in cases) {
        test('recognizes "$input" as hrv_trend', () {
          final preset = prompts.presetForUserText(input);
          expect(preset, isNotNull, reason: 'Should match hrv_trend');
          expect(preset!.id, equals('hrv_trend'));
          expect(preset.intent, equals('hrv_trend_analysis'));
          expect(preset.taskContract, equals('hrvTrend'));
        });
      }
    });

    group('activity_pattern preset matches', () {
      final cases = <String>[
        'Activity pattern',
        'activity pattern',
        'ACTIVITY PATTERN',
        'activty pattern',
        'activity patern',
        'activity patterns',
        'activity-pattern',
        'activity pattern analysis',
        'activity pattern please',
        'activty patern',
      ];

      for (final input in cases) {
        test('recognizes "$input" as activity_pattern', () {
          final preset = prompts.presetForUserText(input);
          expect(preset, isNotNull, reason: 'Should match activity_pattern');
          expect(preset!.id, equals('activity_pattern'));
          expect(preset.intent, equals('activity_pattern_analysis'));
          expect(preset.taskContract, equals('activityPattern'));
        });
      }
    });

    group('prep_for_visit preset matches', () {
      final cases = <String>[
        'Prep for visit',
        'prep for visit',
        'PREP FOR VISIT',
        'prep for vist',
        'prep for visit please',
        'prep-for-visit',
        'prep for visit now',
        'prepforvisit',
        'prep 4 visit',
        'prep for appointment',
      ];

      for (final input in cases) {
        test('recognizes "$input" as prep_for_visit', () {
          final preset = prompts.presetForUserText(input);
          expect(preset, isNotNull, reason: 'Should match prep_for_visit');
          expect(preset!.id, equals('prep_for_visit'));
          expect(preset.intent, equals('visit_preparation'));
          expect(preset.taskContract, equals('prepForVisit'));
        });
      }
    });
  });

  group('Keyword coverage for new presets', () {
    test('medication_note has correct keyword coverage logic', () {
      // This tests the _keywordCoverage function indirectly via preset matching
      final withMedicationAndNote = prompts.presetForUserText(
        'medication note',
      );
      expect(withMedicationAndNote?.id, equals('medication_note'));

      final withMedAndLog = prompts.presetForUserText('med log dose');
      // Should still match medication_note if close enough
      expect(
        withMedAndLog?.id,
        anyOf(equals('medication_note'), isNull),
        reason: 'med + log + dose should match or be ambiguous',
      );
    });

    test('food_trigger has correct keyword coverage logic', () {
      final withFoodAndTrigger = prompts.presetForUserText(
        'food trigger pattern',
      );
      expect(withFoodAndTrigger?.id, equals('food_trigger'));

      final withMealAndSymptom = prompts.presetForUserText('meal symptom');
      // Should match food_trigger or be ambiguous
      expect(
        withMealAndSymptom?.id,
        anyOf(equals('food_trigger'), isNull),
        reason: 'meal + symptom should match or be ambiguous',
      );
    });

    test('hrv_trend has correct keyword coverage logic', () {
      final withHrvAndTrend = prompts.presetForUserText('HRV trend analysis');
      expect(withHrvAndTrend?.id, equals('hrv_trend'));

      final withHeartAndVariability = prompts.presetForUserText(
        'heart variability rhythm',
      );
      // Should match hrv_trend or be ambiguous
      expect(
        withHeartAndVariability?.id,
        anyOf(equals('hrv_trend'), isNull),
        reason: 'heart + variability + rhythm should match or be ambiguous',
      );
    });

    test('activity_pattern has correct keyword coverage logic', () {
      final withActivityAndPattern = prompts.presetForUserText(
        'activity pattern',
      );
      expect(withActivityAndPattern?.id, equals('activity_pattern'));

      final withStepsAndTrend = prompts.presetForUserText('steps trend level');
      // Should match activity_pattern or be ambiguous
      expect(
        withStepsAndTrend?.id,
        anyOf(equals('activity_pattern'), isNull),
        reason: 'steps + trend + level should match or be ambiguous',
      );
    });

    test('prep_for_visit has correct keyword coverage logic', () {
      final withPrepAndVisit = prompts.presetForUserText('prep for visit');
      expect(withPrepAndVisit?.id, equals('prep_for_visit'));

      final withPrepareAndAppointment = prompts.presetForUserText(
        'prepare appointment',
      );
      // Should match prep_for_visit or be ambiguous
      expect(
        withPrepareAndAppointment?.id,
        anyOf(equals('prep_for_visit'), isNull),
        reason: 'prepare + appointment should match or be ambiguous',
      );
    });
  });

  group('Freeform preset variants stay on contract', () {
    final cases = <Map<String, String>>[
      {
        'input': 'Pull up my saved labs from local data.',
        'preset': 'share_lab_results',
      },
      {
        'input': 'What medication context should I note from local data?',
        'preset': 'medication_note',
      },
      {
        'input': 'Have I had cramping after meals before in local data?',
        'preset': 'food_trigger',
      },
      {
        'input': 'What do my saved labs mean right now?',
        'preset': 'explain_labs',
      },
      {
        'input': 'Tell me what shifted today in local data.',
        'preset': 'what_changed_today',
      },
      {
        'input': 'What activity pattern do you see in my local data?',
        'preset': 'activity_pattern',
      },
      {
        'input': 'Help me prep for a GI visit from my saved history.',
        'preset': 'prep_for_visit',
      },
      {
        'input': 'What should I bring up at my next doctor visit?',
        'preset': 'prep_for_visit',
      },
      {
        'input': 'Prepare visit notes from my saved local data.',
        'preset': 'prep_for_visit',
      },
    ];

    for (final entry in cases) {
      final input = entry['input']!;
      final preset = entry['preset']!;
      test('recognizes "$input" as $preset', () {
        final match = prompts.presetForUserText(input);
        expect(match, isNotNull);
        expect(match!.id, preset);
      });
    }
  });

  group('System prompt framings exist for new intents', () {
    test('medication_context has framing', () {
      final prompt = prompts.buildSystemPrompt('medication_context');
      expect(prompt, isNotEmpty);
      expect(
        prompt,
        contains('medication'),
        reason: 'Should include medication-specific guidance',
      );
      expect(
        prompt,
        contains('NEVER recommend medication changes'),
        reason: 'Should include safety boundary',
      );
    });

    test('food_trigger_analysis has framing', () {
      final prompt = prompts.buildSystemPrompt('food_trigger_analysis');
      expect(prompt, isNotEmpty);
      expect(
        prompt,
        contains('food'),
        reason: 'Should include food-specific guidance',
      );
      expect(
        prompt,
        contains('meal_relation'),
        reason: 'Should reference meal relation field',
      );
    });

    test('hrv_trend_analysis has framing', () {
      final prompt = prompts.buildSystemPrompt('hrv_trend_analysis');
      expect(prompt, isNotEmpty);
      expect(
        prompt,
        contains('HRV'),
        reason: 'Should include HRV-specific guidance',
      );
      expect(
        prompt,
        anyOf(contains('higher HRV'), contains('heart rate variability')),
        reason: 'Should explain HRV interpretation',
      );
    });

    test('activity_pattern_analysis has framing', () {
      final prompt = prompts.buildSystemPrompt('activity_pattern_analysis');
      expect(prompt, isNotEmpty);
      expect(
        prompt,
        contains('activity'),
        reason: 'Should include activity-specific guidance',
      );
      expect(
        prompt,
        anyOf(contains('steps'), contains('exercise')),
        reason: 'Should reference activity metrics',
      );
    });

    test('visit_preparation has framing', () {
      final prompt = prompts.buildSystemPrompt('visit_preparation');
      expect(prompt, isNotEmpty);
      expect(
        prompt,
        contains('GI appointment'),
        reason: 'Should include visit prep guidance',
      );
      expect(
        prompt,
        contains('questions'),
        reason: 'Should mention questions for doctor',
      );
    });
  });

  group('All new intents use appropriate response format', () {
    test(
      'medication_context uses structured markdown quick-checkin format',
      () {
        final prompt = prompts.buildSystemPrompt('medication_context');
        expect(
          prompt,
          contains('structured chat markdown'),
          reason: 'Should use quick check-in structure format',
        );
        expect(
          prompt,
          contains('Never output a single dense paragraph'),
          reason: 'Should enforce anti-run-on readability rule',
        );
      },
    );

    test('food_trigger_analysis uses kFormatQuickCheckin', () {
      final prompt = prompts.buildSystemPrompt('food_trigger_analysis');
      expect(prompt, contains('structured chat markdown'));
      expect(prompt, contains('Never output a single dense paragraph'));
    });

    test('hrv_trend_analysis uses kFormatQuickCheckin', () {
      final prompt = prompts.buildSystemPrompt('hrv_trend_analysis');
      expect(prompt, contains('structured chat markdown'));
      expect(prompt, contains('Never output a single dense paragraph'));
    });

    test('activity_pattern_analysis uses kFormatQuickCheckin', () {
      final prompt = prompts.buildSystemPrompt('activity_pattern_analysis');
      expect(prompt, contains('structured chat markdown'));
      expect(prompt, contains('Never output a single dense paragraph'));
    });

    test('visit_preparation uses kFormatDeepDive (structured)', () {
      final prompt = prompts.buildSystemPrompt('visit_preparation');
      expect(
        prompt,
        contains('bold inline labels'),
        reason: 'Should use deep dive format for structured visit prep',
      );
      expect(prompt, contains('Never output a single dense paragraph'));
    });
  });

  group('Edge case handling in framings', () {
    test('medication_context framing handles empty data', () {
      final prompt = prompts.buildSystemPrompt('medication_context');
      expect(
        prompt,
        contains('empty medication data'),
        reason: 'Should handle case where no medication data exists',
      );
    });

    test('food_trigger_analysis framing handles sparse data', () {
      final prompt = prompts.buildSystemPrompt('food_trigger_analysis');
      expect(
        prompt,
        contains('food data is sparse or missing'),
        reason: 'Should handle case where food data is limited',
      );
    });

    test('hrv_trend_analysis framing handles missing HRV', () {
      final prompt = prompts.buildSystemPrompt('hrv_trend_analysis');
      expect(
        prompt,
        contains('HRV data is missing'),
        reason: 'Should handle case where HRV is not synced',
      );
    });

    test('activity_pattern_analysis framing handles no activity data', () {
      final prompt = prompts.buildSystemPrompt('activity_pattern_analysis');
      expect(
        prompt,
        contains('activity data is missing'),
        reason: 'Should handle case where activity is not synced',
      );
    });

    test('visit_preparation framing handles sparse data', () {
      final prompt = prompts.buildSystemPrompt('visit_preparation');
      expect(
        prompt,
        contains('data is sparse'),
        reason: 'Should handle case where user has minimal data for visit',
      );
    });
  });

  group('Safety boundaries in new framings', () {
    test('medication_context prohibits medication advice', () {
      final prompt = prompts.buildSystemPrompt('medication_context');
      expect(prompt, contains('NEVER recommend medication changes'));
      expect(prompt, contains('dosing adjustments'));
      expect(prompt, contains('stopping medication'));
      expect(
        prompt,
        contains('Your GI doctor is the right person for medication decisions'),
      );
    });

    test('food_trigger_analysis does not prescribe diets', () {
      final prompt = prompts.buildSystemPrompt('food_trigger_analysis');
      expect(prompt, contains('Do NOT prescribe elimination diets'));
      expect(prompt, contains('correlation is not causation'));
      expect(prompt, contains('registered dietitian'));
    });

    test('hrv_trend_analysis does not diagnose conditions', () {
      final prompt = prompts.buildSystemPrompt('hrv_trend_analysis');
      expect(prompt, contains('Do NOT diagnose medical conditions'));
      expect(prompt, contains('discussing with GI doctor'));
    });

    test('activity_pattern_analysis does not prescribe exercise', () {
      final prompt = prompts.buildSystemPrompt('activity_pattern_analysis');
      expect(prompt, contains('Do NOT prescribe exercise plans'));
      expect(prompt, contains('IBD fatigue is real'));
      expect(prompt, contains('rest is valid'));
    });

    test('all new framings explicitly exclude score/confidence', () {
      final contexts = [
        'medication_context',
        'food_trigger_analysis',
        'hrv_trend_analysis',
        'activity_pattern_analysis',
        'visit_preparation',
      ];

      for (final context in contexts) {
        final prompt = prompts.buildSystemPrompt(context);
        expect(
          prompt,
          contains('Do NOT mention flare risk score or confidence'),
          reason: '$context should explicitly exclude score/confidence',
        );
      }
    });
  });

  group('Urgency triage in edge cases', () {
    test('medication_context handles urgent concerns', () {
      final prompt = prompts.buildSystemPrompt('medication_context');
      expect(
        prompt,
        contains('urgent concerns'),
        reason: 'Should redirect urgent medication issues',
      );
      expect(prompt, contains('redirect to GI team immediately'));
    });

    test('food_trigger_analysis handles urgent symptoms', () {
      final prompt = prompts.buildSystemPrompt('food_trigger_analysis');
      expect(
        prompt,
        contains('urgent symptoms'),
        reason: 'Should triage urgent symptoms to GI team',
      );
      expect(prompt, contains('triage to GI team'));
    });

    test('hrv_trend_analysis handles concerning drops', () {
      final prompt = prompts.buildSystemPrompt('hrv_trend_analysis');
      expect(
        prompt,
        contains('concerning drops'),
        reason: 'Should suggest medical consultation for HRV concerns',
      );
      expect(prompt, contains('discussing with GI doctor'));
    });

    test('visit_preparation flags severe symptoms', () {
      final prompt = prompts.buildSystemPrompt('visit_preparation');
      expect(
        prompt,
        contains('severe symptoms'),
        reason: 'Should flag urgency for visit prep',
      );
      expect(prompt, contains('Consider calling ahead'));
    });
  });
}
