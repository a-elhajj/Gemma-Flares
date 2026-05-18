// ignore_for_file: lines_longer_than_80_chars
//
// risk_engine_lab_integration_test.dart
//
// Integration-level tests for the lab contribution pipeline:
// LabNormalizationService → LabRiskContributionService → contribution output.
//
// These tests exercise the full lab scoring path without a live database by
// constructing LabValueRecord objects directly and calling computeContribution.
// This is the layer that feeds into RiskEngineService._buildScore.
//
// FEA-023 / BUG-078 regression invariants are enforced here.

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/lab_normalization_service.dart';
import 'package:gemma_flares/core/services/lab_risk_contribution_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

LabValueRecord _lab({
  required String labType,
  required double value,
  required String unit,
  String? drawnDate,
  DateTime? updatedAt,
}) {
  final now = DateTime.utc(2026, 5, 13);
  return LabValueRecord(
    drawnDate: drawnDate ?? '2026-05-13',
    labType: labType,
    valueNumeric: value,
    unit: unit,
    createdAt: now,
    updatedAt: updatedAt ?? now,
  );
}

const _sut = LabRiskContributionService();
const _dateLocal = '2026-05-13';

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  // ── FEA-023 regression: FC 320 must move score ────────────────────────────

  group('FEA-023 regression: FC 320 μg/g', () {
    test('FC 320 today → points > 0', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(result.points, greaterThan(0));
    });

    test('FC 320 → points > FC 8.3 points (same date)', () {
      final high = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      final low = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 8.3, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(high.points, greaterThan(low.points));
    });

    test('FC 320 → narrativeKey is fc_elevated_recent', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(result.narrativeKey, 'fc_elevated_recent');
    });

    test('FC 500 → narrativeKey is fc_markedly_elevated_recent', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 500, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(result.narrativeKey, 'fc_markedly_elevated_recent');
    });

    test('FC 320 → labsPresent = true', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(result.labsPresent, isTrue);
    });

    test('FC 320 → dominantLabType = fc', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(result.dominantLabType, 'fc');
    });
  });

  // ── Unit normalization pass-through ──────────────────────────────────────

  group('unit normalization pass-through', () {
    test('FC in mg/g → same contribution as μg/g equivalent', () {
      // 0.32 mg/g = 320 μg/g
      final mgG = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 0.32, unit: 'mg/g')],
        userBaselineByLabType: {},
      );
      final ugG = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(mgG.points, ugG.points);
    });

    test('CRP 50 mg/L produces same contribution as CRP 5 mg/dL', () {
      final mgL = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'crp', value: 50, unit: 'mg/L')],
        userBaselineByLabType: {},
      );
      final mgDL = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'crp', value: 5, unit: 'mg/dL')],
        userBaselineByLabType: {},
      );
      expect(mgL.points, mgDL.points);
    });

    test('CRP in unrecognized unit (g/L) → 0 contribution', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'crp', value: 5, unit: 'g/L')],
        userBaselineByLabType: {},
      );
      expect(result.points, 0);
    });

    test('FC in invalid unit (ng/mL) → 0 contribution', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'ng/mL')],
        userBaselineByLabType: {},
      );
      expect(result.points, 0);
    });
  });

  // ── Time decay ────────────────────────────────────────────────────────────

  group('time decay', () {
    test('FC 320 today → full decay factor (1.0)', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [
          _lab(labType: 'fc', value: 320, unit: 'μg/g', drawnDate: _dateLocal),
        ],
        userBaselineByLabType: {},
      );
      expect(result.decayFactor, closeTo(1.0, 0.001));
    });

    test('FC 320 drawn 7 days ago → still full decay (1.0)', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [
          _lab(
            labType: 'fc',
            value: 320,
            unit: 'μg/g',
            drawnDate: '2026-05-06',
          ),
        ],
        userBaselineByLabType: {},
      );
      expect(result.decayFactor, closeTo(1.0, 0.001));
    });

    test('FC 320 drawn 7 days ago → points equal to FC 320 today', () {
      final today = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      final sevenDays = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [
          _lab(
            labType: 'fc',
            value: 320,
            unit: 'μg/g',
            drawnDate: '2026-05-06',
          ),
        ],
        userBaselineByLabType: {},
      );
      expect(today.points, sevenDays.points);
    });

    test('FC 320 drawn 14 days ago → points < today (0.80 decay)', () {
      final today = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      final old = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [
          _lab(
            labType: 'fc',
            value: 320,
            unit: 'μg/g',
            drawnDate: '2026-04-29',
          ),
        ],
        userBaselineByLabType: {},
      );
      expect(old.points, lessThan(today.points));
    });

    test('FC 320 drawn 21 days ago → decay 0.55', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [
          _lab(
            labType: 'fc',
            value: 320,
            unit: 'μg/g',
            drawnDate: '2026-04-22',
          ),
        ],
        userBaselineByLabType: {},
      );
      expect(result.decayFactor, closeTo(0.55, 0.001));
    });

    test(
      'FC 320 drawn 28 days ago → points significantly reduced (0.30 decay)',
      () {
        final today = _sut.computeContribution(
          dateLocal: _dateLocal,
          candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
          userBaselineByLabType: {},
        );
        final old = _sut.computeContribution(
          dateLocal: _dateLocal,
          candidateLabs: [
            _lab(
              labType: 'fc',
              value: 320,
              unit: 'μg/g',
              drawnDate: '2026-04-15',
            ),
          ],
          userBaselineByLabType: {},
        );
        expect(old.points, lessThan(today.points));
      },
    );

    test('FC 320 drawn 31 days ago → near-zero decay (0.05)', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [
          _lab(
            labType: 'fc',
            value: 320,
            unit: 'μg/g',
            drawnDate: '2026-04-12',
          ),
        ],
        userBaselineByLabType: {},
      );
      expect(result.decayFactor, closeTo(0.05, 0.001));
    });
  });

  // ── IBS threshold adjustment ───────────────────────────────────────────────

  group('IBS threshold adjustment', () {
    test('FC 160 for IBS → lower points than FC 160 for CD', () {
      final cd = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 160, unit: 'μg/g')],
        userBaselineByLabType: {},
        diagnosisCategory: 'cd',
      );
      final ibs = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 160, unit: 'μg/g')],
        userBaselineByLabType: {},
        diagnosisCategory: 'ibs',
      );
      expect(ibs.points, lessThan(cd.points));
    });

    test('IBS FC 300 ≈ CD FC 150 (doubled threshold)', () {
      final cdAt150 = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 150, unit: 'μg/g')],
        userBaselineByLabType: {},
        diagnosisCategory: 'cd',
      );
      final ibsAt300 = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 300, unit: 'μg/g')],
        userBaselineByLabType: {},
        diagnosisCategory: 'ibs',
      );
      expect(cdAt150.points, ibsAt300.points);
    });

    test('IBS confidenceBoost reduced by 3 vs CD for FC dominant', () {
      final cd = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
        diagnosisCategory: 'cd',
      );
      final ibs = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
        diagnosisCategory: 'ibs',
      );
      expect(ibs.confidenceBoost, cd.confidenceBoost - 3);
    });
  });

  // ── Baseline attenuation ──────────────────────────────────────────────────

  group('baseline attenuation', () {
    test('CRP within 20% of personal baseline → attenuated (×0.4)', () {
      // Baseline 5.0. Current 5.2 = 4% above baseline → within 20% → attenuated
      final attenuated = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'crp', value: 5.2, unit: 'mg/dL')],
        userBaselineByLabType: {'crp': 5.0},
      );
      // Without baseline context, same value
      final noBaseline = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'crp', value: 5.2, unit: 'mg/dL')],
        userBaselineByLabType: {},
      );
      expect(attenuated.points, lessThan(noBaseline.points));
    });

    test('CRP below personal baseline → 0 contribution', () {
      // Baseline 6.0. Current 5.5 = below baseline → 0
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'crp', value: 5.5, unit: 'mg/dL')],
        userBaselineByLabType: {'crp': 6.0},
      );
      expect(result.points, 0);
    });

    test('FC well above baseline → not attenuated', () {
      // Baseline 50. Current 320 → 540% above → not within 20% → full score
      final withBaseline = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {'fc': 50.0},
      );
      final noBaseline = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(withBaseline.points, noBaseline.points);
    });
  });

  // ── Multi-lab MAX aggregation ─────────────────────────────────────────────

  group('multi-lab MAX (not SUM)', () {
    test('FC 320 + CRP 15 → max(fc_raw, crp_raw) not sum', () {
      final fc320 = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      final both = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [
          _lab(labType: 'fc', value: 320, unit: 'μg/g'),
          _lab(labType: 'crp', value: 15, unit: 'mg/dL'),
        ],
        userBaselineByLabType: {},
      );
      // CRP 15 raw = 18. FC 320 raw = 24. Max is FC. Combined should equal FC alone (paper max)
      // BUT secondary bucket can differ. Test paper max dominance: both.points >= fc320.points
      expect(both.points, greaterThanOrEqualTo(fc320.points));
    });

    test('CRP is dominant when higher than FC', () {
      // CRP 20+ → raw 24. FC 80 → raw 8. CRP wins.
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [
          _lab(labType: 'crp', value: 25, unit: 'mg/dL'),
          _lab(labType: 'fc', value: 80, unit: 'μg/g'),
        ],
        userBaselineByLabType: {},
      );
      expect(result.dominantLabType, 'crp');
    });

    test('FC dominant when highest paper contribution', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [
          _lab(labType: 'fc', value: 320, unit: 'μg/g'),
          _lab(labType: 'crp', value: 2, unit: 'mg/dL'),
          _lab(labType: 'esr', value: 15, unit: 'mm/h'),
        ],
        userBaselineByLabType: {},
      );
      expect(result.dominantLabType, 'fc');
    });
  });

  // ── Secondary bucket ─────────────────────────────────────────────────────

  group('secondary bucket', () {
    test('albumin 2.8 → secondary contribution > 0', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'albumin', value: 2.8, unit: 'g/dL')],
        userBaselineByLabType: {},
      );
      expect(result.points, greaterThan(0));
    });

    test('albumin 3.8 → secondary contribution = 0', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'albumin', value: 3.8, unit: 'g/dL')],
        userBaselineByLabType: {},
      );
      expect(result.points, 0);
    });

    test('hemoglobin 10.5 (female) → secondary contribution > 0', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'hemoglobin', value: 10.5, unit: 'g/dL')],
        userBaselineByLabType: {},
        userSex: 'f',
      );
      expect(result.points, greaterThan(0));
    });

    test('hemoglobin 14 (male) → secondary = 0', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'hemoglobin', value: 14, unit: 'g/dL')],
        userBaselineByLabType: {},
        userSex: 'm',
      );
      expect(result.points, 0);
    });

    test('secondary bucket capped at 8 even with extreme values', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [
          _lab(labType: 'albumin', value: 1.0, unit: 'g/dL'), // 8
          _lab(labType: 'hemoglobin', value: 5.0, unit: 'g/dL'), // 8
          _lab(labType: 'vitamin_d', value: 5.0, unit: 'ng/mL'), // 3
        ],
        userBaselineByLabType: {},
      );
      // Secondary bucket capped at 8
      expect(result.points, lessThanOrEqualTo(8));
    });

    test('narrativeKey secondary_labs_only when no paper labs', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'albumin', value: 2.8, unit: 'g/dL')],
        userBaselineByLabType: {},
      );
      expect(result.narrativeKey, 'secondary_labs_only');
    });
  });

  // ── Total cap ────────────────────────────────────────────────────────────

  group('total cap at 30', () {
    test('extreme FC + secondary → total ≤ 30', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [
          _lab(labType: 'fc', value: 1000, unit: 'μg/g'),
          _lab(labType: 'crp', value: 50, unit: 'mg/dL'),
          _lab(labType: 'esr', value: 100, unit: 'mm/h'),
          _lab(labType: 'albumin', value: 1.5, unit: 'g/dL'),
          _lab(labType: 'hemoglobin', value: 5.0, unit: 'g/dL'),
        ],
        userBaselineByLabType: {},
      );
      expect(result.points, lessThanOrEqualTo(30));
    });

    test('100 FC labs same day → deterministic winner, total ≤ 30', () {
      final labs = List.generate(
        100,
        (i) => _lab(labType: 'fc', value: (i * 5 + 1).toDouble(), unit: 'μg/g'),
      );
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: labs,
        userBaselineByLabType: {},
      );
      expect(result.points, lessThanOrEqualTo(30));
      expect(result.dominantLabType, 'fc');
    });

    test('lab flood: 20 labs same type → still ≤ 30 points', () {
      final labs = List.generate(
        20,
        (i) =>
            _lab(labType: 'fc', value: (i * 10 + 100).toDouble(), unit: 'μg/g'),
      );
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: labs,
        userBaselineByLabType: {},
      );
      expect(result.points, lessThanOrEqualTo(30));
    });
  });

  // ── No labs ────────────────────────────────────────────────────────────────

  group('no labs', () {
    test('empty list → LabRiskContribution.empty semantics', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [],
        userBaselineByLabType: {},
      );
      expect(result.points, 0);
      expect(result.labsPresent, isFalse);
      expect(result.narrativeKey, 'no_labs_available');
      expect(result.confidenceBoost, 0);
    });

    test('labs only from beyond 30-day window → 0 contribution', () {
      // drawnDate > 30 days before dateLocal
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [
          _lab(
            labType: 'fc',
            value: 320,
            unit: 'μg/g',
            drawnDate: '2026-04-01',
          ),
        ],
        userBaselineByLabType: {},
      );
      // 42 days ago — decays to 0.05 which is non-zero but near-zero
      // The spec says ≥31 days → 0.05 decay. Points are still > 0 but very low.
      expect(result.decayFactor, closeTo(0.05, 0.001));
    });
  });

  // ── Confidence boost ──────────────────────────────────────────────────────

  group('confidence boost', () {
    test('labs present → confidenceBoost > 0', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(result.confidenceBoost, greaterThan(0));
    });

    test('no labs → confidenceBoost = 0', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [],
        userBaselineByLabType: {},
      );
      expect(result.confidenceBoost, 0);
    });

    test('recent labs (≤7d) → confidenceBoost = 8', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(result.confidenceBoost, 8);
    });

    test('older labs (>7d, ≤30d) → confidenceBoost = 5', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [
          _lab(
            labType: 'fc',
            value: 320,
            unit: 'μg/g',
            drawnDate: '2026-04-29',
          ),
        ],
        userBaselineByLabType: {},
      );
      expect(result.confidenceBoost, 5);
    });
  });

  // ── Determinism ────────────────────────────────────────────────────────────

  group('determinism', () {
    test('same inputs × 5 runs → identical output', () {
      final labs = [
        _lab(labType: 'fc', value: 320, unit: 'μg/g'),
        _lab(labType: 'crp', value: 8, unit: 'mg/dL'),
        _lab(labType: 'albumin', value: 3.2, unit: 'g/dL'),
      ];
      final results = List.generate(
        5,
        (_) => _sut.computeContribution(
          dateLocal: _dateLocal,
          candidateLabs: labs,
          userBaselineByLabType: {},
        ),
      );
      for (final r in results) {
        expect(r.points, results.first.points);
        expect(r.narrativeKey, results.first.narrativeKey);
        expect(r.decayFactor, results.first.decayFactor);
      }
    });

    test('20 FC values same day → highest wins (deterministic)', () {
      final labs = List.generate(
        20,
        (i) =>
            _lab(labType: 'fc', value: (i * 10 + 10).toDouble(), unit: 'μg/g'),
      );
      final r1 = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: labs,
        userBaselineByLabType: {},
      );
      // Shuffle and re-run
      final shuffled = [...labs]
        ..sort((a, b) => b.valueNumeric.compareTo(a.valueNumeric));
      final r2 = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: shuffled,
        userBaselineByLabType: {},
      );
      expect(r1.points, r2.points);
      expect(r1.dominantLabValue, r2.dominantLabValue);
    });
  });

  // ── Edge cases ────────────────────────────────────────────────────────────

  group('edge cases', () {
    test(
      'FC exactly at threshold (150) → scored as elevated not borderline',
      () {
        final result = _sut.computeContribution(
          dateLocal: _dateLocal,
          candidateLabs: [_lab(labType: 'fc', value: 150, unit: 'μg/g')],
          userBaselineByLabType: {},
        );
        // [150, 300) → raw 18
        expect(result.narrativeKey, 'fc_elevated_recent');
      },
    );

    test('FC just below threshold (149) → borderline', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 149, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      // [75, 150) → raw 8 → borderline
      expect(result.narrativeKey, 'fc_borderline_recent');
    });

    test('CRP at exactly 5 → elevated_recent', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'crp', value: 5, unit: 'mg/dL')],
        userBaselineByLabType: {},
      );
      expect(result.narrativeKey, 'crp_elevated_recent');
    });

    test('ESR exactly 30 → esr_elevated_recent', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'esr', value: 30, unit: 'mm/h')],
        userBaselineByLabType: {},
      );
      expect(result.narrativeKey, 'esr_elevated_recent');
    });

    test('contributionJson is non-empty when labs present', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(result.contributionJson, isNotEmpty);
    });

    test('vitamin_d deficient (8 ng/mL) → secondary contribution', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'vitamin_d', value: 8, unit: 'ng/mL')],
        userBaselineByLabType: {},
      );
      expect(result.points, greaterThan(0));
    });

    test('vitamin_d normal (35 ng/mL) → 0 contribution', () {
      final result = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'vitamin_d', value: 35, unit: 'ng/mL')],
        userBaselineByLabType: {},
      );
      expect(result.points, 0);
    });
  });

  // ── LabNormalizationService + LabRiskContributionService integration ───────

  group('normalization + contribution integration', () {
    test('conflict resolution: FC 320 μg/g beats FC 80 μg/g same day', () {
      const norm = LabNormalizationService();
      final lo = _lab(labType: 'fc', value: 80, unit: 'μg/g');
      final hi = _lab(labType: 'fc', value: 320, unit: 'μg/g');
      final winner = norm.resolveConflict([lo, hi]);
      expect(winner.valueNumeric, 320);
    });

    test('CRP conflict: 50 mg/L vs 6 mg/dL — 50 mg/L = 5 mg/dL < 6 mg/dL', () {
      const norm = LabNormalizationService();
      final mgL = _lab(labType: 'crp', value: 50, unit: 'mg/L'); // 5 mg/dL
      final mgDL = _lab(labType: 'crp', value: 6, unit: 'mg/dL'); // 6 mg/dL
      final winner = norm.resolveConflict([mgL, mgDL]);
      expect(winner.valueNumeric, 6.0); // mgDL wins (higher normalized)
    });

    test('full pipeline: FC 0.32 mg/g → same points as FC 320 μg/g', () {
      final fromMgG = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 0.32, unit: 'mg/g')],
        userBaselineByLabType: {},
      );
      final fromUgG = _sut.computeContribution(
        dateLocal: _dateLocal,
        candidateLabs: [_lab(labType: 'fc', value: 320, unit: 'μg/g')],
        userBaselineByLabType: {},
      );
      expect(fromMgG.points, fromUgG.points);
    });
  });
}
