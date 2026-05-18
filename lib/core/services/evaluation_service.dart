import 'dart:math' as math;

import '../database/wearable_sample_repository.dart';
import 'logistic_risk_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// EvaluationMetrics — metrics for a single model at a single horizon
// ─────────────────────────────────────────────────────────────────────────────

class EvaluationMetrics {
  const EvaluationMetrics({
    required this.modelKey,
    required this.horizonDays,
    required this.flareType,
    required this.sampleCount,
    required this.auc,
    required this.auprc,
    required this.f1,
    required this.sensitivity,
    required this.specificity,
    required this.optimalThreshold,
  });

  final String modelKey;
  final int horizonDays;
  final String flareType;
  final int sampleCount;
  final double auc;
  final double auprc;
  final double f1;
  final double sensitivity;
  final double specificity;
  final double optimalThreshold;

  Map<String, Object?> toJson() => {
        'model_key': modelKey,
        'horizon_days': horizonDays,
        'flare_type': flareType,
        'sample_count': sampleCount,
        'auc': auc,
        'auprc': auprc,
        'f1': f1,
        'sensitivity': sensitivity,
        'specificity': specificity,
        'optimal_threshold': optimalThreshold,
        'vs_target_label': vsTargetLabel,
      };

  /// Paper reported targets (Hirten et al. 2025, Supplementary Tables 3–6):
  /// Inflammatory flare: AUC 0.97–0.99, F1 0.88–0.90
  /// Symptomatic flare: AUC 0.96, F1 0.81–0.83
  String get vsTargetLabel {
    final aucDiff = (auc - _targetAuc).toStringAsFixed(3);
    final f1Diff = (f1 - _targetF1).toStringAsFixed(3);
    final aucSign = auc >= _targetAuc ? '+' : '';
    final f1Sign = f1 >= _targetF1 ? '+' : '';
    return 'vs paper: AUC $aucSign$aucDiff, F1 $f1Sign$f1Diff';
  }

  double get _targetAuc => flareType == 'inflammatory' ? 0.98 : 0.96;
  double get _targetF1 => flareType == 'inflammatory' ? 0.88 : 0.81;
}

// ─────────────────────────────────────────────────────────────────────────────
// EvaluationReport
// ─────────────────────────────────────────────────────────────────────────────

class EvaluationReport {
  const EvaluationReport({
    required this.metrics,
    required this.generatedAt,
    required this.totalLabeledDays,
    required this.inflammatoryFlareDays,
    required this.symptomaticFlareDays,
  });

  final List<EvaluationMetrics> metrics;
  final DateTime generatedAt;
  final int totalLabeledDays;
  final int inflammatoryFlareDays;
  final int symptomaticFlareDays;

  bool get hasEnoughData =>
      totalLabeledDays >= EvaluationService.minimumLabeledSamples;

  Map<String, Object?> toJson() => {
        'generated_at': generatedAt.toUtc().toIso8601String(),
        'total_labeled_days': totalLabeledDays,
        'inflammatory_flare_days': inflammatoryFlareDays,
        'symptomatic_flare_days': symptomaticFlareDays,
        'has_enough_data': hasEnoughData,
        'status_label': statusLabel,
        'metrics':
            metrics.map((metric) => metric.toJson()).toList(growable: false),
        'clinical_validation_note':
            'Local diagnostic evaluation only. This is not a clinical validation result.',
      };

  /// Best single-line status for dashboard display.
  String get statusLabel {
    if (!hasEnoughData) {
      return 'Need $totalLabeledDays / ${EvaluationService.minimumLabeledSamples}+ labeled days before evaluation.';
    }
    final best = metrics
        .where(
          (m) => m.sampleCount >= EvaluationService.minimumLabeledSamples,
        )
        .toList()
      ..sort((a, b) => b.auc.compareTo(a.auc));
    if (best.isEmpty) return 'Evaluation pending labeled data.';
    final m = best.first;
    return '${m.flareType} ${m.horizonDays}d: AUC ${m.auc.toStringAsFixed(2)}, F1 ${m.f1.toStringAsFixed(2)}';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EvaluationService
//
// Computes AUC (Mann-Whitney U), AUPRC (trapezoidal interpolation), and F1
// across all 7 horizons × 2 flare types — matching the paper's Figure 3B
// and Supplementary Tables 3–6.
//
// Minimum 30 labeled samples required per model before reporting metrics.
// ─────────────────────────────────────────────────────────────────────────────

class EvaluationService {
  EvaluationService({required WearableSampleRepository repository})
      : _repository = repository;

  final WearableSampleRepository _repository;

  static const minimumLabeledSamples = 30;

  // ── Public: generate full report ─────────────────────────────────────────

  Future<EvaluationReport> generateReport() async {
    final allLabels = await _repository.getAllFlareLabels();
    final totalLabeled = allLabels.length;
    final inflammatoryDays = allLabels.where((l) => l.inflammatoryFlare).length;
    final symptomaticDays = allLabels.where((l) => l.symptomaticFlare).length;

    final metricsList = <EvaluationMetrics>[];

    for (final flareType in LogisticRiskService.flareTypes) {
      for (final horizon in LogisticRiskService.horizons) {
        final modelKey =
            '${LogisticRiskService.modelVersion}_${flareType}_${horizon}d';
        final state = await _repository.getLogisticModelState(modelKey);
        if (state == null || state.trainingSamples < minimumLabeledSamples) {
          continue;
        }

        // In-sample evaluation: for each labeled date, find the feature record
        // from horizon days earlier (the prediction date), re-score it with
        // the current model weights, and compare against the actual label.
        // This is a diagnostic baseline — not out-of-sample performance.
        final pairs = <({double score, bool label})>[];
        for (final flareLabel in allLabels) {
          // The feature vector that would have been used to PREDICT this label
          final predictionDate = _offsetDate(flareLabel.labelDate, -horizon);
          final featureRecord = await _repository.getDailyFeatureForDate(
            predictionDate,
          );
          if (featureRecord == null) continue;

          final features = LogisticRiskService.extractFromRiskFeatures(
            featureRecord.featureJson,
          );

          final score = _sigmoidStatic(
            _dotProductStatic(state.coefficientsJson, features) +
                state.intercept,
          );
          final actual = flareType == 'inflammatory'
              ? flareLabel.inflammatoryFlare
              : flareLabel.symptomaticFlare;
          pairs.add((score: score, label: actual));
        }

        if (pairs.length < minimumLabeledSamples) continue;

        final auc = computeAuc(pairs);
        final auprc = computeAuprc(pairs);
        final optimal = findYoudenThreshold(pairs);
        final confusion = computeConfusionMetrics(pairs, optimal);

        // Persist updated AUC/F1 back to model state
        await _repository.upsertLogisticModelState(
          LogisticModelStateRecord(
            modelKey: state.modelKey,
            horizonDays: state.horizonDays,
            flareType: state.flareType,
            coefficientsJson: state.coefficientsJson,
            intercept: state.intercept,
            trainingSamples: state.trainingSamples,
            lastAuc: auc,
            lastF1: confusion['f1'] ?? 0,
            updatedAt: DateTime.now().toUtc(),
          ),
        );

        metricsList.add(
          EvaluationMetrics(
            modelKey: modelKey,
            horizonDays: horizon,
            flareType: flareType,
            sampleCount: pairs.length,
            auc: auc,
            auprc: auprc,
            f1: confusion['f1'] ?? 0,
            sensitivity: confusion['sensitivity'] ?? 0,
            specificity: confusion['specificity'] ?? 0,
            optimalThreshold: optimal,
          ),
        );
      }
    }

    final report = EvaluationReport(
      metrics: metricsList,
      generatedAt: DateTime.now().toUtc(),
      totalLabeledDays: totalLabeled,
      inflammatoryFlareDays: inflammatoryDays,
      symptomaticFlareDays: symptomaticDays,
    );
    await _repository.upsertAppSettingJson(
      key: 'eval_results_json',
      value: report.toJson(),
    );
    return report;
  }

  // ── Static metric functions (pure math, fully testable) ──────────────────

  /// AUC via Mann-Whitney U statistic.
  /// Equivalent to Wilcoxon rank-sum test AUC = U / (n_pos × n_neg).
  static double computeAuc(List<({double score, bool label})> data) {
    if (data.isEmpty) return 0.5;
    final pos = data.where((d) => d.label).toList();
    final neg = data.where((d) => !d.label).toList();
    if (pos.isEmpty || neg.isEmpty) return 0.5;

    final sorted = [...data]..sort((a, b) => a.score.compareTo(b.score));
    var rank = 1.0;
    var posRankSum = 0.0;
    var index = 0;
    while (index < sorted.length) {
      var tieEnd = index + 1;
      while (tieEnd < sorted.length &&
          sorted[tieEnd].score == sorted[index].score) {
        tieEnd++;
      }
      final averageRank = (rank + rank + (tieEnd - index) - 1) / 2;
      for (var tieIndex = index; tieIndex < tieEnd; tieIndex++) {
        if (sorted[tieIndex].label) {
          posRankSum += averageRank;
        }
      }
      rank += tieEnd - index;
      index = tieEnd;
    }
    final u = posRankSum - (pos.length * (pos.length + 1) / 2);
    return u / (pos.length * neg.length);
  }

  /// AUPRC via trapezoidal interpolation over all unique score thresholds.
  static double computeAuprc(List<({double score, bool label})> data) {
    if (data.isEmpty) return 0.0;
    final sorted = [...data]..sort((a, b) => b.score.compareTo(a.score));
    final totalPos = data.where((d) => d.label).length;
    if (totalPos == 0) return 0.0;

    var tp = 0.0;
    var fp = 0.0;
    var prevPrecision = 1.0;
    var prevRecall = 0.0;
    var auprc = 0.0;

    for (final point in sorted) {
      if (point.label) {
        tp += 1;
      } else {
        fp += 1;
      }
      final precision = tp / (tp + fp);
      final recall = tp / totalPos;
      // Trapezoidal rule
      auprc += (recall - prevRecall) * (precision + prevPrecision) / 2;
      prevPrecision = precision;
      prevRecall = recall;
    }
    return auprc.clamp(0.0, 1.0);
  }

  /// Computes TP/FP/TN/FN + F1/sensitivity/specificity at [threshold].
  static Map<String, double> computeConfusionMetrics(
    List<({double score, bool label})> data,
    double threshold,
  ) {
    var tp = 0.0, fp = 0.0, tn = 0.0, fn = 0.0;
    for (final point in data) {
      final predicted = point.score >= threshold;
      if (predicted && point.label) tp++;
      if (predicted && !point.label) fp++;
      if (!predicted && !point.label) tn++;
      if (!predicted && point.label) fn++;
    }
    final precision = tp + fp > 0 ? tp / (tp + fp) : 0.0;
    final recall = tp + fn > 0 ? tp / (tp + fn) : 0.0;
    final f1 = precision + recall > 0
        ? 2 * precision * recall / (precision + recall)
        : 0.0;
    final specificity = tn + fp > 0 ? tn / (tn + fp) : 0.0;
    return {
      'tp': tp,
      'fp': fp,
      'tn': tn,
      'fn': fn,
      'precision': precision,
      'recall': recall,
      'sensitivity': recall,
      'specificity': specificity,
      'f1': f1,
    };
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  /// Finds the threshold that maximises Youden's J statistic:
  /// sensitivity + specificity - 1.
  static double findYoudenThreshold(List<({double score, bool label})> data) {
    if (data.isEmpty) return 0.5;
    final thresholds = data.map((d) => d.score).toSet().toList()..sort();
    var bestYouden = double.negativeInfinity;
    var bestThreshold = 0.5;
    for (final t in thresholds) {
      final metrics = computeConfusionMetrics(data, t);
      final youden = (metrics['sensitivity'] ?? 0.0) +
          (metrics['specificity'] ?? 0.0) -
          1.0;
      if (youden > bestYouden) {
        bestYouden = youden;
        bestThreshold = t;
      }
    }
    return bestThreshold;
  }

  String _offsetDate(String dateStr, int days) {
    final dt = DateTime.parse('${dateStr}T00:00:00Z');
    final offset = dt.add(Duration(days: days));
    final y = offset.year.toString().padLeft(4, '0');
    final m = offset.month.toString().padLeft(2, '0');
    final d = offset.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  // Logistic math helpers — pure, no external deps
  static double _sigmoidStatic(double x) =>
      1.0 / (1.0 + math.exp(-x.clamp(-20.0, 20.0)));

  static double _dotProductStatic(
    Map<String, double> weights,
    Map<String, double> features,
  ) {
    var sum = 0.0;
    for (final entry in weights.entries) {
      sum += entry.value * (features[entry.key] ?? 0.0);
    }
    return sum;
  }
}
