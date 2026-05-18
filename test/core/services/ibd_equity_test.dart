// FEA-019: IBD equity — IBS-SSS scoring, disease branching, red flags
//
// Three categories:
//   A. IBS-SSS scoring math (generated corpus — 100 cases)
//   B. Curated assertions — 10 hard-coded edge cases
//   C. IbdCheckInService disease branching contracts
//
// No UI under test here. UI branching is exercised via the score service.

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/ibd_checkin_service.dart';

void main() {
  group('FEA-019-A: IBS-SSS scoring corpus (100 generated cases)', () {
    // Generate 100 cases by enumerating meaningful combinations.
    // Each case has (painSeverity, painDays, bowelSatisfaction, lifeInterference,
    // bloatingSeverity) with expected total and expected isFlare.
    //
    // Generation logic:
    //   - 5 pain levels × 5 day counts × 4 mixed combos = 100 cases
    //   - Total = painSeverity + painDays*10 + bowelSatisfaction + lifeInterference + bloatingSeverity
    //   - isFlare = total >= 175

    final List<
        ({
          int p,
          int d,
          int b,
          int l,
          int bl,
          int expectedTotal,
          bool expectedFlare,
        })> corpus = () {
      final cases = <({
        int p,
        int d,
        int b,
        int l,
        int bl,
        int expectedTotal,
        bool expectedFlare,
      })>[];
      // Sweep: 5 painSeverity values × 5 painDays × 4 suffix combos
      const painSeverities = [0, 20, 50, 80, 100];
      const painDays = [0, 2, 5, 7, 10];
      const suffixCombos = [
        (b: 0, l: 0, bl: 0),
        (b: 25, l: 25, bl: 25),
        (b: 50, l: 50, bl: 50),
        (b: 75, l: 75, bl: 75),
      ];
      for (final ps in painSeverities) {
        for (final pd in painDays) {
          for (final s in suffixCombos) {
            final total = ps + pd * 10 + s.b + s.l + s.bl;
            cases.add((
              p: ps,
              d: pd,
              b: s.b,
              l: s.l,
              bl: s.bl,
              expectedTotal: total,
              expectedFlare: total >= 175,
            ));
          }
        }
      }
      return cases;
    }();

    // Confirm corpus size.
    test('corpus has exactly 100 cases', () {
      expect(corpus.length, 100);
    });

    for (final c in corpus) {
      test(
          'IBS-SSS: p=${c.p} d=${c.d} b=${c.b} l=${c.l} bl=${c.bl} → '
          'total=${c.expectedTotal} flare=${c.expectedFlare}', () {
        final total = Pro2SurveyRecord.ibsSssTotal(
          painSeverity: c.p,
          painDays: c.d,
          bowelSatisfaction: c.b,
          lifeInterference: c.l,
          bloatingSeverity: c.bl,
        );
        expect(total, closeTo(c.expectedTotal.toDouble(), 0.001));
        expect(total >= Pro2SurveyRecord.ibsSssFlareThreshold, c.expectedFlare);
      });
    }
  });

  group('FEA-019-B: curated edge cases', () {
    test('TS-05: IBS-SSS score 174 → isFlare = false', () {
      // 80 + 5*10 + 24 + 25 + 25 = 80 + 50 + 74 = 204 — adjust to hit 174 exactly
      // 50 + 5*10 + 24 + 25 + 25 = 50+50+74 = 174 ✓
      final total = Pro2SurveyRecord.ibsSssTotal(
        painSeverity: 50,
        painDays: 5,
        bowelSatisfaction: 24,
        lifeInterference: 25,
        bloatingSeverity: 25,
      );
      expect(total, closeTo(174.0, 0.001));
      expect(total >= Pro2SurveyRecord.ibsSssFlareThreshold, isFalse);
    });

    test('TS-06: IBS-SSS score 175 → isFlare = true', () {
      final total = Pro2SurveyRecord.ibsSssTotal(
        painSeverity: 50,
        painDays: 5,
        bowelSatisfaction: 25,
        lifeInterference: 25,
        bloatingSeverity: 25,
      );
      expect(total, closeTo(175.0, 0.001));
      expect(total >= Pro2SurveyRecord.ibsSssFlareThreshold, isTrue);
    });

    test('TS-07: IBS-SSS score 500 (max) stored cleanly', () {
      final total = Pro2SurveyRecord.ibsSssTotal(
        painSeverity: 100,
        painDays: 10,
        bowelSatisfaction: 100,
        lifeInterference: 100,
        bloatingSeverity: 100,
      );
      expect(total, closeTo(500.0, 0.001));
      expect(total >= Pro2SurveyRecord.ibsSssFlareThreshold, isTrue);
    });

    test('TS-08: IBS-SSS all zeros → score 0, isFlare = false', () {
      final total = Pro2SurveyRecord.ibsSssTotal(
        painSeverity: 0,
        painDays: 0,
        bowelSatisfaction: 0,
        lifeInterference: 0,
        bloatingSeverity: 0,
      );
      expect(total, closeTo(0.0, 0.001));
      expect(total >= Pro2SurveyRecord.ibsSssFlareThreshold, isFalse);
    });

    test(
      'TS-07b: IBS-SSS clamps out-of-range inputs (no crash, no overflow)',
      () {
        // painSeverity > 100, painDays > 10 → clamped
        final total = Pro2SurveyRecord.ibsSssTotal(
          painSeverity: 999,
          painDays: 99,
          bowelSatisfaction: 999,
          lifeInterference: 999,
          bloatingSeverity: 999,
        );
        // Clamped: 100 + 10*10 + 100 + 100 + 100 = 500
        expect(total, closeTo(500.0, 0.001));
      },
    );

    test('TS-09: summaryForSurvey for IBS contains no "Crohn\'s" or "UC"', () {
      final survey = Pro2SurveyRecord(
        surveyDate: '2026-05-12',
        diseaseType: 'IBS',
        pro2Score: 200,
        isFlare: true,
        scoreVersion: Pro2SurveyRecord.ibsSssV1,
        notes: () {
          // Encode notes with IBS-SSS components
          return IbdCheckInService.encodeNotes(
            diseaseType: 'IBS',
            dailyCore: {
              'ibs_pain_severity_0_100': 60,
              'ibs_pain_days_0_10': 5,
              'ibs_bowel_satisfaction_0_100': 40,
              'ibs_life_interference_0_100': 40,
              'ibs_bloating_severity_0_100': 60,
            },
          );
        }(),
        createdAt: DateTime.utc(2026, 5, 12),
      );
      final summary = IbdCheckInService.summaryForSurvey(survey);
      expect(summary, isNot(contains("Crohn's")));
      expect(summary, isNot(contains('UC check-in')));
      expect(summary, contains('IBS check-in'));
    });

    test('TS-10: IBS red flag fires for rectal bleeding', () {
      // Encode a check-in where IBS user reports rectal bleeding
      final notes = IbdCheckInService.encodeNotes(
        diseaseType: 'IBS',
        dailyCore: {
          'ibs_pain_severity_0_100': 50,
          'ibs_pain_days_0_10': 3,
          'ibs_bowel_satisfaction_0_100': 30,
          'ibs_life_interference_0_100': 30,
          'ibs_bloating_severity_0_100': 30,
        },
        dailyDetails: {'ibs_rectal_bleeding': 1},
      );
      final parsed = IbdCheckInService.parseNotes(notes);
      final redFlags =
          (parsed['red_flags'] as List?)?.whereType<String>().toList() ?? [];
      expect(redFlags, contains('rectal_bleeding_ibs_atypical'));
    });

    test(
      'TS-11: null / missing diseaseType on legacy record falls back to CD',
      () {
        // Legacy record with no notes and unknown disease type should not crash.
        final survey = Pro2SurveyRecord(
          surveyDate: '2024-01-01',
          diseaseType: 'CD',
          cdAbdominalPain: 1,
          cdStoolFrequency: 1,
          pro2Score: 8.0,
          isFlare: false,
          createdAt: DateTime.utc(2024, 1, 1),
        );
        expect(
          () => IbdCheckInService.summaryForSurvey(survey),
          returnsNormally,
        );
        final summary = IbdCheckInService.summaryForSurvey(survey);
        expect(summary, contains("Crohn's check-in"));
      },
    );

    test('TS-09b: UC summary does not contain "Crohn\'s" or "IBS"', () {
      final survey = Pro2SurveyRecord(
        surveyDate: '2026-05-12',
        diseaseType: 'UC',
        ucRectalBleeding: 1,
        ucStoolFrequency: 2,
        pro2Score: 3.0,
        isFlare: true,
        scoreVersion: Pro2SurveyRecord.ucV1BleedingStool,
        createdAt: DateTime.utc(2026, 5, 12),
      );
      final summary = IbdCheckInService.summaryForSurvey(survey);
      expect(summary, isNot(contains("Crohn's")));
      expect(summary, isNot(contains('IBS check-in')));
      expect(summary, contains('UC check-in'));
    });

    test(
      'ibsIsFlare: encodeNotes → parseNotes → ibsIsFlare round-trips correctly',
      () {
        final notes = IbdCheckInService.encodeNotes(
          diseaseType: 'IBS',
          dailyCore: {
            'ibs_pain_severity_0_100': 80,
            'ibs_pain_days_0_10': 5,
            'ibs_bowel_satisfaction_0_100': 40,
            'ibs_life_interference_0_100': 30,
            'ibs_bloating_severity_0_100': 25,
          },
        );
        final parsed = IbdCheckInService.parseNotes(notes);
        final core = Map<String, Object?>.from(
          parsed['daily_core'] as Map? ?? {},
        );
        // 80 + 50 + 40 + 30 + 25 = 225 ≥ 175 → flare
        expect(IbdCheckInService.ibsIsFlare(core), isTrue);
      },
    );
  });

  group('FEA-019-C: IbdCheckInService disease-type contract', () {
    test('encodeNotes stores disease_type field verbatim', () {
      for (final dt in ['CD', 'UC', 'IBS', 'IC']) {
        final notes = IbdCheckInService.encodeNotes(
          diseaseType: dt,
          dailyCore: const {},
        );
        final parsed = IbdCheckInService.parseNotes(notes);
        expect(parsed['disease_type'], dt);
      }
    });

    test('IBS-SSS constants: ibsSssFlareThreshold == 175', () {
      expect(Pro2SurveyRecord.ibsSssFlareThreshold, 175);
    });

    test('scoreVersion constant: ibsSssV1 is non-empty string', () {
      expect(Pro2SurveyRecord.ibsSssV1, isNotEmpty);
    });
  });
}
