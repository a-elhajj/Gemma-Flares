import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/evaluation_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// EvaluationService — pure metric computation tests
//
// Tests AUC (Mann-Whitney U), AUPRC (trapezoidal), and confusion metrics.
// No database required — all methods are static with List<({score, label})> input.
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  // Shorthand builder
  List<({double score, bool label})> pairs(List<(double, bool)> raw) =>
      raw.map((t) => (score: t.$1, label: t.$2)).toList();

  group('EvaluationService.computeAuc', () {
    test('AUC = 1.0 for perfectly separated data', () {
      final data = pairs([
        (0.9, true),
        (0.8, true),
        (0.7, true),
        (0.2, false),
        (0.1, false),
        (0.05, false),
      ]);
      expect(EvaluationService.computeAuc(data), closeTo(1.0, 0.001));
    });

    test('AUC = 0.0 for perfectly anti-separated (flipped) data', () {
      // Positives all score lower than negatives
      final data = pairs([
        (0.1, true),
        (0.2, true),
        (0.8, false),
        (0.9, false),
      ]);
      expect(EvaluationService.computeAuc(data), closeTo(0.0, 0.001));
    });

    test('AUC ≈ 0.5 for random / no-discrimination data', () {
      // Interleaved scores
      final data = pairs([
        (0.9, true),
        (0.8, false),
        (0.7, true),
        (0.6, false),
        (0.5, true),
        (0.4, false),
      ]);
      // Not exactly 0.5 due to specific ordering, but should be close
      final auc = EvaluationService.computeAuc(data);
      expect(auc, greaterThan(0.3));
      expect(auc, lessThan(0.7));
    });

    test('returns 0.5 for empty data', () {
      expect(EvaluationService.computeAuc([]), closeTo(0.5, 0.001));
    });

    test('returns 0.5 when all labels are positive', () {
      final data = pairs([(0.9, true), (0.7, true), (0.5, true)]);
      expect(EvaluationService.computeAuc(data), closeTo(0.5, 0.001));
    });

    test('handles tied scores (0.5 credit each)', () {
      // All same score — result should be 0.5
      final data = pairs([
        (0.5, true),
        (0.5, false),
        (0.5, true),
        (0.5, false),
      ]);
      expect(EvaluationService.computeAuc(data), closeTo(0.5, 0.001));
    });

    test('AUC with 1 positive vs 4 negatives is computed correctly', () {
      // Single positive ranked highest → U = 4, n_pos*n_neg = 4 → AUC = 1.0
      final data = pairs([
        (0.9, true),
        (0.6, false),
        (0.4, false),
        (0.2, false),
        (0.1, false),
      ]);
      expect(EvaluationService.computeAuc(data), closeTo(1.0, 0.001));
    });
  });

  group('EvaluationService.computeAuprc', () {
    test('AUPRC = 1.0 for perfectly separated data', () {
      final data = pairs([
        (0.9, true),
        (0.8, true),
        (0.2, false),
        (0.1, false),
      ]);
      expect(EvaluationService.computeAuprc(data), closeTo(1.0, 0.01));
    });

    test('returns 0.0 for empty data', () {
      expect(EvaluationService.computeAuprc([]), closeTo(0.0, 0.001));
    });

    test('returns 0.0 when no positives', () {
      final data = pairs([(0.9, false), (0.5, false)]);
      expect(EvaluationService.computeAuprc(data), closeTo(0.0, 0.001));
    });

    test('AUPRC is bounded [0, 1]', () {
      final data = pairs([
        (0.7, true),
        (0.6, false),
        (0.5, true),
        (0.4, false),
        (0.3, true),
      ]);
      final auprc = EvaluationService.computeAuprc(data);
      expect(auprc, greaterThanOrEqualTo(0.0));
      expect(auprc, lessThanOrEqualTo(1.0));
    });
  });

  group('EvaluationService.computeConfusionMetrics', () {
    test('all correct predictions at threshold 0.5', () {
      final data = pairs([
        (0.9, true),
        (0.8, true),
        (0.2, false),
        (0.1, false),
      ]);
      final m = EvaluationService.computeConfusionMetrics(data, 0.5);

      expect(m['tp'], closeTo(2.0, 0.001));
      expect(m['fp'], closeTo(0.0, 0.001));
      expect(m['tn'], closeTo(2.0, 0.001));
      expect(m['fn'], closeTo(0.0, 0.001));
      expect(m['f1'], closeTo(1.0, 0.001));
      expect(m['sensitivity'], closeTo(1.0, 0.001));
      expect(m['specificity'], closeTo(1.0, 0.001));
      expect(m['precision'], closeTo(1.0, 0.001));
    });

    test('all negative predictions at threshold 1.0', () {
      final data = pairs([(0.9, true), (0.8, false)]);
      final m = EvaluationService.computeConfusionMetrics(data, 1.0);

      // Nothing predicted positive (score < threshold)
      expect(m['tp'], closeTo(0.0, 0.001));
      expect(m['fp'], closeTo(0.0, 0.001));
      expect(m['fn'], closeTo(1.0, 0.001)); // missed the positive
      expect(m['f1'], closeTo(0.0, 0.001));
    });

    test('F1 is harmonic mean of precision and recall', () {
      // 2 TP, 1 FP, 1 FN → precision=2/3, recall=2/3, F1=2/3
      final data = pairs([
        (0.9, true), // TP
        (0.8, true), // TP
        (0.7, false), // FP
        (0.2, true), // FN (below threshold 0.5)
      ]);
      final m = EvaluationService.computeConfusionMetrics(data, 0.5);

      expect(m['tp'], closeTo(2.0, 0.001));
      expect(m['fp'], closeTo(1.0, 0.001));
      expect(m['fn'], closeTo(1.0, 0.001));
      final precision = m['precision']!;
      final recall = m['recall']!;
      final expectedF1 = 2 * precision * recall / (precision + recall);
      expect(m['f1'], closeTo(expectedF1, 0.001));
    });

    test('sensitivity equals recall', () {
      final data = pairs([
        (0.9, true),
        (0.8, false),
        (0.3, true),
        (0.2, false),
      ]);
      final m = EvaluationService.computeConfusionMetrics(data, 0.5);
      expect(m['sensitivity'], closeTo(m['recall']!, 0.001));
    });

    test('specificity = TN / (TN + FP)', () {
      // Score ≥ 0.5 → predicted positive
      final data = pairs([
        (0.9, false), // FP
        (0.7, false), // FP
        (0.3, false), // TN
        (0.1, true), // FN
      ]);
      final m = EvaluationService.computeConfusionMetrics(data, 0.5);
      // TN=1, FP=2 → specificity = 1/3
      expect(m['specificity'], closeTo(1.0 / 3.0, 0.001));
    });

    test('handles edge case: all true positives', () {
      final data = pairs([(0.9, true), (0.8, true), (0.7, true)]);
      final m = EvaluationService.computeConfusionMetrics(data, 0.5);
      expect(m['tp'], closeTo(3.0, 0.001));
      expect(m['fp'], closeTo(0.0, 0.001));
      expect(m['f1'], closeTo(1.0, 0.001));
    });
  });

  group('EvaluationMetrics.vsTargetLabel', () {
    test('shows positive delta when AUC beats paper target (inflammatory)', () {
      const m = EvaluationMetrics(
        modelKey: 'logistic_v1_inflammatory_7d',
        horizonDays: 7,
        flareType: 'inflammatory',
        sampleCount: 50,
        auc: 0.99, // above 0.98 target
        auprc: 0.95,
        f1: 0.90, // above 0.88 target
        sensitivity: 0.92,
        specificity: 0.88,
        optimalThreshold: 0.5,
      );
      expect(m.vsTargetLabel, contains('+'));
      expect(m.vsTargetLabel, contains('AUC'));
      expect(m.vsTargetLabel, contains('F1'));
    });

    test('shows negative delta when below target', () {
      const m = EvaluationMetrics(
        modelKey: 'logistic_v1_symptomatic_7d',
        horizonDays: 7,
        flareType: 'symptomatic',
        sampleCount: 30,
        auc: 0.80, // below 0.96 target
        auprc: 0.70,
        f1: 0.60, // below 0.81 target
        sensitivity: 0.70,
        specificity: 0.75,
        optimalThreshold: 0.4,
      );
      // Both diffs should be negative
      expect(m.vsTargetLabel, contains('-'));
    });
  });

  group('EvaluationReport', () {
    test('hasEnoughData is true when totalLabeledDays >= 30', () {
      final report = EvaluationReport(
        metrics: [],
        generatedAt: _fixedDate,
        totalLabeledDays: 30,
        inflammatoryFlareDays: 5,
        symptomaticFlareDays: 3,
      );
      expect(report.hasEnoughData, isTrue);
    });

    test('hasEnoughData is false when totalLabeledDays < 30', () {
      final report = EvaluationReport(
        metrics: [],
        generatedAt: _fixedDate,
        totalLabeledDays: 29,
        inflammatoryFlareDays: 2,
        symptomaticFlareDays: 1,
      );
      expect(report.hasEnoughData, isFalse);
    });

    test('statusLabel includes best AUC and F1 when data available', () {
      final m = EvaluationMetrics(
        modelKey: 'logistic_v1_inflammatory_7d',
        horizonDays: 7,
        flareType: 'inflammatory',
        sampleCount: 30,
        auc: 0.95,
        auprc: 0.90,
        f1: 0.85,
        sensitivity: 0.88,
        specificity: 0.90,
        optimalThreshold: 0.5,
      );
      final report = EvaluationReport(
        metrics: [m],
        generatedAt: _fixedDate,
        totalLabeledDays: 30,
        inflammatoryFlareDays: 10,
        symptomaticFlareDays: 5,
      );
      expect(report.statusLabel, contains('AUC'));
      expect(report.statusLabel, contains('F1'));
    });

    test('toJson labels metrics as diagnostic only', () {
      final report = EvaluationReport(
        metrics: const [],
        generatedAt: _fixedDate,
        totalLabeledDays: 30,
        inflammatoryFlareDays: 10,
        symptomaticFlareDays: 5,
      );
      expect(
        report.toJson()['clinical_validation_note'],
        contains('not a clinical validation'),
      );
    });
  });

  group('EvaluationService.findYoudenThreshold', () {
    test('chooses threshold with strongest sensitivity plus specificity', () {
      final data = pairs([
        (0.95, true),
        (0.80, true),
        (0.70, false),
        (0.40, false),
      ]);
      final threshold = EvaluationService.findYoudenThreshold(data);
      expect(threshold, closeTo(0.80, 0.001));
    });
  });
}

final _fixedDate = DateTime.utc(2026, 1, 1);
