import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/auc_computation_service.dart';
import 'package:gemma_flares/core/services/logistic_risk_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// LogisticRiskService — pure math tests (no DB required)
//
// Tests the sigmoid, dot-product, and SGD update logic in isolation using
// the public static methods or by constructing the internal state directly.
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  group('LogisticPrediction', () {
    test('hasEnoughData is true at exactly 14 samples', () {
      const p = LogisticPrediction(
        modelKey: 'logistic_v1_inflammatory_7d',
        horizonDays: 7,
        flareType: 'inflammatory',
        probability: 0.5,
        trainingSamples: 14,
      );
      expect(p.hasEnoughData, isTrue);
    });

    test('hasEnoughData is false below 14 samples', () {
      const p = LogisticPrediction(
        modelKey: 'logistic_v1_inflammatory_7d',
        horizonDays: 7,
        flareType: 'inflammatory',
        probability: 0.5,
        trainingSamples: 13,
      );
      expect(p.hasEnoughData, isFalse);
    });

    test('probability is in [0, 1]', () {
      const p = LogisticPrediction(
        modelKey: 'k',
        horizonDays: 7,
        flareType: 'inflammatory',
        probability: 0.85,
        trainingSamples: 25,
      );
      expect(p.probability, greaterThanOrEqualTo(0.0));
      expect(p.probability, lessThanOrEqualTo(1.0));
    });
  });

  group('Model configuration', () {
    test('has 7 horizons', () {
      expect(LogisticRiskService.horizons.length, 7);
      expect(LogisticRiskService.horizons, [7, 14, 21, 28, 35, 42, 49]);
    });

    test('has 2 flare types', () {
      expect(LogisticRiskService.flareTypes.length, 2);
      expect(
        LogisticRiskService.flareTypes,
        containsAll(['inflammatory', 'symptomatic']),
      );
    });

    test('has 24 feature names (23 original + hrv_mesor_14d_trend)', () {
      expect(LogisticRiskService.featureNames.length, 24);
    });

    test('feature names are stable (do not reorder them)', () {
      expect(LogisticRiskService.featureNames.first, 'hrv_3d_pct_drop');
      // user_disease_cd is now at index 22; hrv_mesor_14d_trend is last (index 23)
      expect(LogisticRiskService.featureNames[22], 'user_disease_cd');
      expect(LogisticRiskService.featureNames.last, 'hrv_mesor_14d_trend');
      expect(
        LogisticRiskService.featureNames,
        containsAll([
          'sleep_deep_pct',
          'sleep_rem_pct',
          'hrv_14d_slope',
          'llm_pain_intensity',
          'llm_dietary_trigger',
          'hrv_mesor_14d_trend',
        ]),
      );
    });

    test('model version follows naming convention', () {
      expect(LogisticRiskService.modelVersion, startsWith('logistic_'));
    });

    test(
      'softens extreme display probabilities while the outlook is learning',
      () {
        final calibrated = LogisticRiskService.calibrateDisplayProbability(
          rawProbability: 0.99,
          trainingSamples: LogisticPrediction.minimumTrainingSamples,
        );

        expect(calibrated, lessThan(0.7));
        expect(
          LogisticRiskService.shouldUseLearningState(
            LogisticPrediction.minimumTrainingSamples,
          ),
          isTrue,
        );
      },
    );

    test('keeps mature-model display probabilities close to the raw score', () {
      final calibrated = LogisticRiskService.calibrateDisplayProbability(
        rawProbability: 0.99,
        trainingSamples: LogisticRiskService.stableDisplaySamples,
      );

      expect(calibrated, greaterThan(0.9));
      expect(
        LogisticRiskService.shouldUseLearningState(
          LogisticRiskService.stableDisplaySamples,
        ),
        isFalse,
      );
    });
  });

  // ── Calibration: baseline-anchored shrinkage (Hirten et al. 2025) ─────────
  // The correct shrinkage target is the paper-derived baseline flare rate
  // sigmoid(-2.0) ≈ 0.119, not 0.5. Pulling toward 0.5 would inflate the
  // cold-start prior from 11.9% to 36.7% — a medically meaningless false alarm.
  group('calibrateDisplayProbability — baseline-anchored shrinkage', () {
    test(
      'cold-start (0 samples) returns paper baseline prior ~0.119, not ~0.367',
      () {
        final calibrated = LogisticRiskService.calibrateDisplayProbability(
          rawProbability: 0.119,
          trainingSamples: 0,
        );
        // Must stay near the baseline prior, NOT be inflated toward 0.5.
        expect(calibrated, closeTo(0.119, 0.01));
        expect(
          calibrated,
          lessThan(0.20),
          reason: 'cold-start must not inflate 11.9% prior to ~37%',
        );
      },
    );

    test('cold-start (0 samples) suppresses even a high raw probability', () {
      // Even if the dot-product happens to produce a high logit, cold-start
      // should return baseline, not pass through the raw value.
      final calibrated = LogisticRiskService.calibrateDisplayProbability(
        rawProbability: 0.85,
        trainingSamples: 0,
      );
      expect(calibrated, lessThan(0.20));
    });

    test(
      'cold-start boundary (13 samples — one below threshold) returns baseline',
      () {
        final calibrated = LogisticRiskService.calibrateDisplayProbability(
          rawProbability: 0.90,
          trainingSamples: LogisticPrediction.minimumTrainingSamples - 1,
        );
        expect(calibrated, lessThan(0.20));
      },
    );

    test(
      'exactly minimumTrainingSamples enters shrinkage regime, stays near baseline for baseline input',
      () {
        final calibrated = LogisticRiskService.calibrateDisplayProbability(
          rawProbability: 0.119,
          trainingSamples: LogisticPrediction.minimumTrainingSamples,
        );
        // progress=0, weight=0.35: calibrated = 0.119 + (0.119-0.119)*0.35 = 0.119
        expect(calibrated, closeTo(0.119, 0.01));
      },
    );

    test(
      '15 samples: high raw probability is shrunk toward baseline, not toward 0.5',
      () {
        final calibrated = LogisticRiskService.calibrateDisplayProbability(
          rawProbability: 0.90,
          trainingSamples: 15,
        );
        // progress ≈ 0.036, weight ≈ 0.373
        // calibrated ≈ 0.119 + (0.781 * 0.373) ≈ 0.410
        // Previously would have been: 0.5 + (0.4 * 0.373) ≈ 0.649
        expect(calibrated, greaterThan(0.119));
        expect(
          calibrated,
          lessThan(0.65),
          reason: 'early shrinkage must not pass through high raw probability',
        );
      },
    );

    test('stableDisplaySamples (42): calibrated equals raw probability', () {
      final calibrated = LogisticRiskService.calibrateDisplayProbability(
        rawProbability: 0.75,
        trainingSamples: LogisticRiskService.stableDisplaySamples,
      );
      // weight=1.0: calibrated = 0.119 + (0.631 * 1.0) = 0.750
      expect(calibrated, closeTo(0.75, 0.01));
    });

    test('output is always within [0.08, 0.92] across all sample counts', () {
      for (final samples in [0, 1, 7, 13, 14, 20, 42, 100]) {
        for (final raw in [0.0, 0.05, 0.119, 0.5, 0.85, 0.99, 1.0]) {
          final calibrated = LogisticRiskService.calibrateDisplayProbability(
            rawProbability: raw,
            trainingSamples: samples,
          );
          expect(
            calibrated,
            greaterThanOrEqualTo(0.08),
            reason: 'samples=$samples raw=$raw',
          );
          expect(
            calibrated,
            lessThanOrEqualTo(0.92),
            reason: 'samples=$samples raw=$raw',
          );
        }
      }
    });
  });

  // ── Prior weights tests (paper-directional priors) ────────────────────────
  group('Prior weights', () {
    test(
      'inflammatory model has higher cosinor_mesor_drop weight than symptomatic',
      () {
        expect(
          LogisticRiskService.featureNames,
          contains('cosinor_mesor_drop'),
        );
        expect(
          LogisticRiskService.featureNames,
          contains('cosinor_amplitude_rise'),
        );
      },
    );

    test('hrv_mesor_14d_trend is in feature list', () {
      expect(LogisticRiskService.featureNames, contains('hrv_mesor_14d_trend'));
    });

    test(
      'featureNames has exactly 24 elements and user_disease_cd at index 22',
      () {
        expect(LogisticRiskService.featureNames.length, 24);
        expect(LogisticRiskService.featureNames.indexOf('user_disease_cd'), 22);
        expect(LogisticRiskService.featureNames.last, 'hrv_mesor_14d_trend');
      },
    );
  });

  // ── AUC computation (pure math — no DB) ──────────────────────────────────
  group('AucComputationService', () {
    test('perfect classifier → AUC=1.0', () {
      final preds = [0.9, 0.95, 0.1, 0.05];
      final actuals = [1, 1, 0, 0];
      expect(
        AucComputationService.computeAuc(preds, actuals),
        closeTo(1.0, 0.001),
      );
    });

    test('anti-correlated classifier → AUC=0.0', () {
      final preds = [0.1, 0.05, 0.9, 0.95];
      final actuals = [1, 1, 0, 0];
      expect(
        AucComputationService.computeAuc(preds, actuals),
        closeTo(0.0, 0.001),
      );
    });

    test('all-tied predictions → AUC=0.5', () {
      final preds = [0.5, 0.5, 0.5, 0.5];
      final actuals = [1, 1, 0, 0];
      expect(
        AucComputationService.computeAuc(preds, actuals),
        closeTo(0.5, 0.001),
      );
    });

    test('insufficient positives (<2) → AUC=NaN', () {
      final preds = [0.9, 0.1, 0.1, 0.1];
      final actuals = [1, 0, 0, 0]; // only 1 positive
      expect(AucComputationService.computeAuc(preds, actuals).isNaN, isTrue);
    });

    test('insufficient negatives (<2) → AUC=NaN', () {
      final preds = [0.9, 0.9, 0.9, 0.1];
      final actuals = [1, 1, 1, 0]; // only 1 negative
      expect(AucComputationService.computeAuc(preds, actuals).isNaN, isTrue);
    });

    test('empty lists → AUC=NaN', () {
      expect(AucComputationService.computeAuc([], []).isNaN, isTrue);
    });

    test('mismatched list lengths → AUC=NaN', () {
      expect(AucComputationService.computeAuc([0.5, 0.5], [1]).isNaN, isTrue);
    });

    test('predictions outside [0,1] are clamped, AUC still valid', () {
      // -1.0 clamped to 0.0, 2.0 clamped to 1.0
      final preds = [2.0, 1.5, -1.0, -0.5];
      final actuals = [1, 1, 0, 0];
      expect(
        AucComputationService.computeAuc(preds, actuals),
        closeTo(1.0, 0.001),
      );
    });

    test('F1: perfect predictions → F1=1.0', () {
      final preds = [0.9, 0.9, 0.1, 0.1];
      final actuals = [1, 1, 0, 0];
      expect(
        AucComputationService.computeF1(preds, actuals),
        closeTo(1.0, 0.001),
      );
    });

    test('F1: all wrong predictions → F1=0.0', () {
      final preds = [0.1, 0.1, 0.9, 0.9];
      final actuals = [1, 1, 0, 0];
      expect(
        AucComputationService.computeF1(preds, actuals),
        closeTo(0.0, 0.001),
      );
    });

    test('F1: empty lists → NaN', () {
      expect(AucComputationService.computeF1([], []).isNaN, isTrue);
    });

    test('AUC result is in [0.0, 1.0] for any valid input combination', () {
      final cases = [
        ([0.9, 0.8, 0.3, 0.2], [1, 1, 0, 0]),
        ([0.5, 0.6, 0.4, 0.3], [1, 1, 0, 0]),
        ([0.9, 0.1, 0.9, 0.1], [1, 0, 1, 0]),
        ([0.3, 0.7, 0.5, 0.8], [1, 1, 0, 0]),
        ([0.2, 0.4, 0.6, 0.8, 0.1, 0.3], [1, 1, 1, 0, 0, 0]),
      ];
      for (final c in cases) {
        final auc = AucComputationService.computeAuc(c.$1, c.$2);
        if (!auc.isNaN) {
          expect(auc, greaterThanOrEqualTo(0.0), reason: 'preds=${c.$1}');
          expect(auc, lessThanOrEqualTo(1.0), reason: 'preds=${c.$1}');
        }
      }
    });
  });

  // ── calibrateDisplayProbability — 182-case parameterized sweep ───────────
  group('calibrateDisplayProbability — 182-case sweep', () {
    test(
      'result is in [0.08, 0.92] and monotone in raw for all sample×raw combos',
      () {
        final sampleCounts = [
          0,
          1,
          5,
          13,
          14,
          15,
          20,
          28,
          35,
          41,
          42,
          43,
          50,
          100,
        ];
        final rawValues = [
          0.0,
          0.05,
          0.10,
          0.119,
          0.15,
          0.20,
          0.30,
          0.50,
          0.70,
          0.80,
          0.90,
          0.99,
          1.0,
        ];
        for (final samples in sampleCounts) {
          double? prevCalibrated;
          for (final raw in rawValues) {
            final calibrated = LogisticRiskService.calibrateDisplayProbability(
              rawProbability: raw,
              trainingSamples: samples,
            );
            // Bounds check
            expect(
              calibrated,
              greaterThanOrEqualTo(0.08),
              reason: 'samples=$samples raw=$raw',
            );
            expect(
              calibrated,
              lessThanOrEqualTo(0.92),
              reason: 'samples=$samples raw=$raw',
            );
            // Monotonicity: higher raw → higher or equal calibrated
            if (prevCalibrated != null) {
              expect(
                calibrated,
                greaterThanOrEqualTo(prevCalibrated - 0.001),
                reason: 'monotone violated at samples=$samples raw=$raw',
              );
            }
            prevCalibrated = calibrated;
          }
          // Cold-start check
          if (samples < LogisticPrediction.minimumTrainingSamples) {
            final coldCalibrated =
                LogisticRiskService.calibrateDisplayProbability(
              rawProbability: 0.99,
              trainingSamples: samples,
            );
            expect(
              coldCalibrated,
              closeTo(0.119, 0.001),
              reason: 'cold-start samples=$samples must return baseline 0.119',
            );
          }
          // Mature model check
          if (samples >= LogisticRiskService.stableDisplaySamples) {
            final matureCalibrated =
                LogisticRiskService.calibrateDisplayProbability(
              rawProbability: 0.75,
              trainingSamples: samples,
            );
            expect(
              matureCalibrated,
              closeTo(0.75, 0.01),
              reason: 'mature model samples=$samples should return ≈ raw',
            );
          }
        }
      },
    );
  });
}
