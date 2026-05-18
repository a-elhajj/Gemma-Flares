// ignore_for_file: lines_longer_than_80_chars
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/lab_risk_contribution_service.dart';

LabValueRecord _lab({
  required String labType,
  required double value,
  required String unit,
  String? drawnDate,
}) {
  final now = DateTime.utc(2026, 5, 13);
  return LabValueRecord(
    drawnDate: drawnDate ?? '2026-05-13',
    labType: labType,
    valueNumeric: value,
    unit: unit,
    createdAt: now,
    updatedAt: now,
  );
}

const sut = LabRiskContributionService();
const _today = '2026-05-13';

// Helper: lab drawn N days before dateLocal
String _daysAgo(int n, {String from = _today}) {
  final d = DateTime.parse(from).subtract(Duration(days: n));
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

void main() {
  // ── Empty inputs ────────────────────────────────────────────────────────────

  test('no labs → LabRiskContribution.empty', () {
    final result = sut.computeContribution(
      dateLocal: _today,
      candidateLabs: [],
      userBaselineByLabType: {},
    );
    expect(result.points, 0);
    expect(result.labsPresent, isFalse);
    expect(result.narrativeKey, 'no_labs_available');
    expect(result.confidenceBoost, 0);
  });

  test('invalid dateLocal → empty', () {
    final result = sut.computeContribution(
      dateLocal: 'not-a-date',
      candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
      userBaselineByLabType: {},
    );
    expect(result.points, 0);
  });

  test('lab with unrecognized unit → empty (skipped at normalization)', () {
    final result = sut.computeContribution(
      dateLocal: _today,
      candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'oz')],
      userBaselineByLabType: {},
    );
    expect(result.points, 0);
    expect(result.labsPresent, isFalse);
  });

  // ── FC scoring ─────────────────────────────────────────────────────────────

  group('FC scoring (CD baseline)', () {
    test('FC 0 → 0 points', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'fc', value: 0, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(r.points, 0);
    });

    test('FC 50 → 0 points (below 75 threshold)', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'fc', value: 50, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(r.points, 0);
    });

    test('FC 100 → 8 points (borderline)', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'fc', value: 100, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(r.points, 8);
    });

    test('FC 320 today > FC 8.3 today (same wearable baseline)', () {
      final rHi = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      final rLo = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'fc', value: 8.3, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(rHi.points, greaterThan(rLo.points));
    });

    test('FC 320 → 24 points (300-500 tier)', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(r.points, 24);
    });

    test('FC 400 → 24 points (300-500 tier)', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'fc', value: 400, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(r.points, 24);
    });

    test('FC 600 → 30 points (≥500 tier)', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'fc', value: 600, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(r.points, 30);
    });

    test('FC 320 today → narrative fc_elevated_recent', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(r.narrativeKey, 'fc_elevated_recent');
    });

    test('FC 500+ today → narrative fc_markedly_elevated_recent', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'fc', value: 600, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(r.narrativeKey, 'fc_markedly_elevated_recent');
    });

    test('FC 100 today → narrative fc_borderline_recent', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'fc', value: 100, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(r.narrativeKey, 'fc_borderline_recent');
    });

    test('FC 320, 14 days ago → narrative fc_elevated_older', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [
          _lab(
            labType: 'fc',
            value: 320,
            unit: 'μg/g',
            drawnDate: _daysAgo(14),
          ),
        ],
        userBaselineByLabType: {},
      );
      expect(r.narrativeKey, 'fc_elevated_older');
    });
  });

  // ── Decay ──────────────────────────────────────────────────────────────────

  group('FC decay', () {
    test('FC 320 today (decay 1.0) > FC 320 28 days ago (decay 0.30)', () {
      final rToday = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [
          _lab(labType: 'fc', value: 320, unit: 'μg/g', drawnDate: _today),
        ],
        userBaselineByLabType: {},
      );
      final rOld = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [
          _lab(
            labType: 'fc',
            value: 320,
            unit: 'μg/g',
            drawnDate: _daysAgo(28),
          ),
        ],
        userBaselineByLabType: {},
      );
      expect(rToday.points, greaterThan(rOld.points));
    });

    test('FC 320 today = 24 (decay 1.0)', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [
          _lab(labType: 'fc', value: 320, unit: 'μg/g', drawnDate: _today),
        ],
        userBaselineByLabType: {},
      );
      expect(r.points, equals(24));
    });

    test('FC 320, 31 days ago → ≤2 points (decay 0.05 → 24×0.05=1.2→1)', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [
          _lab(
            labType: 'fc',
            value: 320,
            unit: 'μg/g',
            drawnDate: _daysAgo(31),
          ),
        ],
        userBaselineByLabType: {},
      );
      expect(r.points, lessThanOrEqualTo(2));
    });

    test('FC 320, 14 days ago → 19 points (24 × 0.80 = 19.2 → 19)', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [
          _lab(
            labType: 'fc',
            value: 320,
            unit: 'μg/g',
            drawnDate: _daysAgo(14),
          ),
        ],
        userBaselineByLabType: {},
      );
      expect(r.points, equals(19));
    });

    test('FC 320, 21 days ago → 13 points (24 × 0.55 = 13.2 → 13)', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [
          _lab(
            labType: 'fc',
            value: 320,
            unit: 'μg/g',
            drawnDate: _daysAgo(21),
          ),
        ],
        userBaselineByLabType: {},
      );
      expect(r.points, equals(13));
    });

    test('future-dated lab → 0 points (skip)', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [
          _lab(
            labType: 'fc',
            value: 320,
            unit: 'μg/g',
            drawnDate: '2026-05-20',
          ),
        ],
        userBaselineByLabType: {},
      );
      expect(r.points, 0);
    });
  });

  // ── CRP scoring ────────────────────────────────────────────────────────────

  group('CRP scoring', () {
    test('CRP 2 mg/dL → 0 points', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'crp', value: 2, unit: 'mg/dL')],
        userBaselineByLabType: {},
      );
      expect(r.points, 0);
    });

    test('CRP 4 mg/dL → 5 points (3-5 tier)', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'crp', value: 4, unit: 'mg/dL')],
        userBaselineByLabType: {},
      );
      expect(r.points, 5);
    });

    test('CRP 7 mg/dL → 12 points (5-10 tier)', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'crp', value: 7, unit: 'mg/dL')],
        userBaselineByLabType: {},
      );
      expect(r.points, 12);
    });

    test('CRP 15 mg/dL today → narrative crp_elevated_recent', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'crp', value: 15, unit: 'mg/dL')],
        userBaselineByLabType: {},
      );
      expect(r.narrativeKey, 'crp_elevated_recent');
    });

    test('CRP in mg/L: 50 mg/L = 5 mg/dL → elevated tier', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'crp', value: 50, unit: 'mg/L')],
        userBaselineByLabType: {},
      );
      expect(r.points, 12); // 5 mg/dL → 12 points (5-10 tier)
    });
  });

  // ── ESR scoring ────────────────────────────────────────────────────────────

  group('ESR scoring', () {
    test('ESR 15 mm/h → 0 points', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'esr', value: 15, unit: 'mm/h')],
        userBaselineByLabType: {},
      );
      expect(r.points, 0);
    });

    test('ESR 35 mm/h → 8 points (30-50 tier)', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'esr', value: 35, unit: 'mm/h')],
        userBaselineByLabType: {},
      );
      expect(r.points, 8);
    });

    test('ESR 90 mm/h → 16 points (≥80 tier)', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'esr', value: 90, unit: 'mm/h')],
        userBaselineByLabType: {},
      );
      expect(r.points, 16);
    });

    test('ESR ≥30 → narrative esr_elevated_recent', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'esr', value: 45, unit: 'mm/h')],
        userBaselineByLabType: {},
      );
      expect(r.narrativeKey, 'esr_elevated_recent');
    });
  });

  // ── Multi-lab aggregation (MAX not SUM) ─────────────────────────────────────

  group('Paper MAX aggregation', () {
    test('FC 320 + CRP 15 = max(FC,CRP) not sum', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [
          _lab(labType: 'fc', value: 320, unit: 'μg/g'),
          _lab(labType: 'crp', value: 15, unit: 'mg/dL'),
        ],
        userBaselineByLabType: {},
      );
      // FC 320 = 24 raw (300-500 tier), CRP 15 = 18 raw (10-20 tier); max = 24 (not 42)
      expect(r.points, equals(24));
    });

    test('FC 600 dominates CRP 5: result = 30 not 30+12', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [
          _lab(labType: 'fc', value: 600, unit: 'μg/g'),
          _lab(labType: 'crp', value: 5, unit: 'mg/dL'),
        ],
        userBaselineByLabType: {},
      );
      expect(r.points, equals(30));
    });

    test('dominant lab type is the one with max points', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [
          _lab(labType: 'fc', value: 600, unit: 'μg/g'),
          _lab(labType: 'crp', value: 3, unit: 'mg/dL'),
        ],
        userBaselineByLabType: {},
      );
      expect(r.dominantLabType, 'fc');
    });
  });

  // ── IBS thresholds ─────────────────────────────────────────────────────────

  group('IBS adjustment', () {
    test('IBS user FC 160 < CD user FC 160 (IBS threshold doubled)', () {
      final rCd = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'fc', value: 160, unit: 'μg/g')],
        userBaselineByLabType: {},
        diagnosisCategory: 'cd',
      );
      final rIbs = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'fc', value: 160, unit: 'μg/g')],
        userBaselineByLabType: {},
        diagnosisCategory: 'ibs',
      );
      expect(rIbs.points, lessThan(rCd.points));
    });

    test('IBS confidence boost reduced by 3 when FC dominant', () {
      final rCd = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
        diagnosisCategory: 'cd',
      );
      final rIbs = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
        diagnosisCategory: 'ibs',
      );
      expect(rIbs.confidenceBoost, lessThan(rCd.confidenceBoost));
    });

    test('IBS user FC 310 = at IBS threshold triggers some points', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'fc', value: 310, unit: 'μg/g')],
        userBaselineByLabType: {},
        diagnosisCategory: 'ibs',
      );
      // 310/2 = 155 → 18 points tier
      expect(r.points, greaterThan(0));
    });
  });

  // ── Unknown diagnosis ───────────────────────────────────────────────────────
  // 'unknown' applies when a user has not set a diagnosis. Must use standard IBD
  // thresholds (same as CD/UC — no IBS 2× multiplier) with a −2 confidence
  // reduction. Prevents the false 'cd'-default bug on cold-start.

  group('Unknown diagnosis', () {
    test(
      'unknown FC 160 scores identically to CD FC 160 (no IBS multiplier)',
      () {
        final rCd = sut.computeContribution(
          dateLocal: _today,
          candidateLabs: [_lab(labType: 'fc', value: 160, unit: 'μg/g')],
          userBaselineByLabType: {},
          diagnosisCategory: 'cd',
        );
        final rUnknown = sut.computeContribution(
          dateLocal: _today,
          candidateLabs: [_lab(labType: 'fc', value: 160, unit: 'μg/g')],
          userBaselineByLabType: {},
          diagnosisCategory: 'unknown',
        );
        final rIbs = sut.computeContribution(
          dateLocal: _today,
          candidateLabs: [_lab(labType: 'fc', value: 160, unit: 'μg/g')],
          userBaselineByLabType: {},
          diagnosisCategory: 'ibs',
        );
        expect(
          rUnknown.points,
          equals(rCd.points),
          reason: 'unknown must not apply IBS threshold doubling',
        );
        expect(
          rUnknown.points,
          greaterThan(rIbs.points),
          reason:
              'unknown is more sensitive than IBS (which doubles thresholds)',
        );
      },
    );

    test('unknown confidenceBoost is 2 less than CD for elevated FC', () {
      final rCd = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
        diagnosisCategory: 'cd',
      );
      final rUnknown = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
        diagnosisCategory: 'unknown',
      );
      expect(rUnknown.confidenceBoost, equals(rCd.confidenceBoost - 2));
    });

    test('unknown confidenceBoost is clamped to 0 minimum', () {
      // Very old lab → decay 0.05 → base confidenceBoost stays >0 per logic,
      // but the -2 penalty must never push it below 0.
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [
          _lab(
            labType: 'fc',
            value: 320,
            unit: 'μg/g',
            drawnDate: _daysAgo(35),
          ),
        ],
        userBaselineByLabType: {},
        diagnosisCategory: 'unknown',
      );
      expect(
        r.confidenceBoost,
        greaterThanOrEqualTo(0),
        reason: 'confidence must never go negative',
      );
    });

    test(
      'ic (indeterminate colitis) scores identically to CD — no penalty',
      () {
        final rCd = sut.computeContribution(
          dateLocal: _today,
          candidateLabs: [_lab(labType: 'fc', value: 160, unit: 'μg/g')],
          userBaselineByLabType: {},
          diagnosisCategory: 'cd',
        );
        final rIc = sut.computeContribution(
          dateLocal: _today,
          candidateLabs: [_lab(labType: 'fc', value: 160, unit: 'μg/g')],
          userBaselineByLabType: {},
          diagnosisCategory: 'ic',
        );
        expect(rIc.points, equals(rCd.points));
        expect(
          rIc.confidenceBoost,
          equals(rCd.confidenceBoost),
          reason: 'ic has confirmed IBD — no confidence reduction',
        );
      },
    );

    test('unknown CRP elevated: same points as CD, reduced confidence', () {
      final rCd = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'crp', value: 12.0, unit: 'mg/dL')],
        userBaselineByLabType: {},
        diagnosisCategory: 'cd',
      );
      final rUnknown = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'crp', value: 12.0, unit: 'mg/dL')],
        userBaselineByLabType: {},
        diagnosisCategory: 'unknown',
      );
      expect(rUnknown.points, equals(rCd.points));
      expect(rUnknown.confidenceBoost, equals(rCd.confidenceBoost - 2));
    });
  });

  // ── Baseline attenuation ────────────────────────────────────────────────────

  group('Baseline attenuation', () {
    test('CRP within 20% of user baseline → attenuated (×0.4)', () {
      // User baseline 5 mg/dL; current 5.5 = +10% → within 20%
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'crp', value: 5.5, unit: 'mg/dL')],
        userBaselineByLabType: {'crp': 5.0},
      );
      // Raw 12 × 0.4 = 4 (rounded)
      final rNoBase = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'crp', value: 5.5, unit: 'mg/dL')],
        userBaselineByLabType: {},
      );
      expect(r.points, lessThan(rNoBase.points));
    });

    test('CRP below user baseline → 0 points', () {
      // User baseline 10; current 7 (below) → 0
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'crp', value: 7, unit: 'mg/dL')],
        userBaselineByLabType: {'crp': 10.0},
      );
      expect(r.points, 0);
    });

    test('CRP well above baseline → no attenuation applied', () {
      // Baseline 2, current 15 (>6× — well above 20% delta)
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'crp', value: 15, unit: 'mg/dL')],
        userBaselineByLabType: {'crp': 2.0},
      );
      expect(r.points, greaterThan(0));
    });
  });

  // ── Secondary bucket ──────────────────────────────────────────────────────

  group('Secondary bucket', () {
    test('Albumin 2.8 → contribution > 0', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'albumin', value: 2.8, unit: 'g/dL')],
        userBaselineByLabType: {},
      );
      expect(r.points, greaterThan(0));
    });

    test('Albumin 4.0 → 0 points (normal)', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'albumin', value: 4.0, unit: 'g/dL')],
        userBaselineByLabType: {},
      );
      expect(r.points, 0);
    });

    test('Albumin 2.3 → 8 points (<2.5 tier)', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'albumin', value: 2.3, unit: 'g/dL')],
        userBaselineByLabType: {},
      );
      expect(r.points, equals(8));
    });

    test('Hemoglobin male 11.0 → 6 points (12.0-10.0 tier)', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'hemoglobin', value: 11.0, unit: 'g/dL')],
        userBaselineByLabType: {},
        userSex: 'm',
      );
      expect(r.points, equals(6));
    });

    test('Hemoglobin female 10.5 → 6 points (11.0-9.0 tier)', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'hemoglobin', value: 10.5, unit: 'g/dL')],
        userBaselineByLabType: {},
        userSex: 'f',
      );
      expect(r.points, equals(6));
    });

    test('Vitamin D 15 → 2 points (10-20 tier)', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [_lab(labType: 'vitamin_d', value: 15, unit: 'ng/mL')],
        userBaselineByLabType: {},
      );
      expect(r.points, equals(2));
    });

    test('Albumin low + Hemoglobin low → secondary bucket capped at 8', () {
      final r = sut.computeContribution(
        dateLocal: _today,
        candidateLabs: [
          _lab(labType: 'albumin', value: 2.3, unit: 'g/dL'),
          _lab(labType: 'hemoglobin', value: 8.0, unit: 'g/dL'),
          _lab(labType: 'vitamin_d', value: 5.0, unit: 'ng/mL'),
        ],
        userBaselineByLabType: {},
        userSex: 'm',
      );
      expect(r.points, lessThanOrEqualTo(8));
    });
  });

  // ── Total capped at 30 ────────────────────────────────────────────────────

  test('Total always ≤ 30 even with extreme values', () {
    final r = sut.computeContribution(
      dateLocal: _today,
      candidateLabs: [
        _lab(labType: 'fc', value: 9999, unit: 'μg/g'),
        _lab(labType: 'crp', value: 999, unit: 'mg/dL'),
        _lab(labType: 'albumin', value: 1.0, unit: 'g/dL'),
        _lab(labType: 'hemoglobin', value: 5.0, unit: 'g/dL'),
        _lab(labType: 'vitamin_d', value: 1.0, unit: 'ng/mL'),
      ],
      userBaselineByLabType: {},
    );
    expect(r.points, lessThanOrEqualTo(30));
  });

  test('Lab flood: 100 labs logged → still ≤ 30 points total', () {
    final labs = List.generate(
      100,
      (i) => _lab(
        labType: 'fc',
        value: 9999,
        unit: 'μg/g',
        drawnDate: _daysAgo(i % 30),
      ),
    );
    final r = sut.computeContribution(
      dateLocal: _today,
      candidateLabs: labs,
      userBaselineByLabType: {},
    );
    expect(r.points, lessThanOrEqualTo(30));
  });

  // ── Confidence boost ─────────────────────────────────────────────────────

  test('confidenceBoost > 0 when labs present and elevated', () {
    final r = sut.computeContribution(
      dateLocal: _today,
      candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
      userBaselineByLabType: {},
    );
    expect(r.confidenceBoost, greaterThan(0));
  });

  test('confidenceBoost = 0 when no labs', () {
    final r = sut.computeContribution(
      dateLocal: _today,
      candidateLabs: [],
      userBaselineByLabType: {},
    );
    expect(r.confidenceBoost, 0);
  });

  test('recent lab (≤7d) has confidenceBoost 8', () {
    final r = sut.computeContribution(
      dateLocal: _today,
      candidateLabs: [
        _lab(labType: 'fc', value: 320, unit: 'μg/g', drawnDate: _today),
      ],
      userBaselineByLabType: {},
    );
    expect(r.confidenceBoost, 8);
  });

  test('older lab (>7d) has confidenceBoost 5', () {
    final r = sut.computeContribution(
      dateLocal: _today,
      candidateLabs: [
        _lab(labType: 'fc', value: 320, unit: 'μg/g', drawnDate: _daysAgo(14)),
      ],
      userBaselineByLabType: {},
    );
    expect(r.confidenceBoost, 5);
  });

  // ── contributionJson keys ────────────────────────────────────────────────

  test('contributionJson has expected keys when labs present', () {
    final r = sut.computeContribution(
      dateLocal: _today,
      candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
      userBaselineByLabType: {},
    );
    expect(r.contributionJson.containsKey('total_points'), isTrue);
    expect(r.contributionJson.containsKey('paper_points'), isTrue);
    expect(r.contributionJson.containsKey('secondary_bucket_points'), isTrue);
    expect(r.contributionJson.containsKey('narrative_key'), isTrue);
  });

  // ── Determinism ──────────────────────────────────────────────────────────

  test('same inputs × 5 calls → identical result', () {
    final labs = [_lab(labType: 'fc', value: 320, unit: 'μg/g')];
    final results = List.generate(
      5,
      (_) => sut.computeContribution(
        dateLocal: _today,
        candidateLabs: labs,
        userBaselineByLabType: {},
      ).points,
    );
    expect(results.toSet().length, 1);
  });

  test('20 FC values same day → deterministic winner (highest)', () {
    final labs = List.generate(
      20,
      (i) => _lab(labType: 'fc', value: (i + 1) * 20.0, unit: 'μg/g'),
    );
    final r1 = sut.computeContribution(
      dateLocal: _today,
      candidateLabs: labs,
      userBaselineByLabType: {},
    );
    final r2 = sut.computeContribution(
      dateLocal: _today,
      candidateLabs: labs.reversed.toList(),
      userBaselineByLabType: {},
    );
    expect(r1.points, equals(r2.points));
    expect(r1.dominantLabValue, equals(r2.dominantLabValue));
  });
}
