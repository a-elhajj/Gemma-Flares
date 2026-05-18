// =============================================================================
// AucComputationService — pure-math ROC AUC and F1 from (predicted, actual) pairs
// =============================================================================
// No DB dependency. Fully testable in isolation.
// Used by LogisticRiskService to compute per-model AUC every 7 training samples.
//
// AUC algorithm: Wilcoxon-Mann-Whitney rank statistic.
//   AUC = P(score(positive) > score(negative)) + 0.5 * P(tied)
//   Equivalent to trapezoidal ROC AUC. O(P*N) where P=positives, N=negatives.
//   Fast for N < 200 on-device; no sorting required.
//
// Returns double.nan when there are fewer than 2 positives OR fewer than 2
// negatives — degenerate case, AUC is undefined and the caller must not store it.
// =============================================================================

class AucComputationService {
  const AucComputationService();

  static const _minClassCount = 2; // minimum positives AND negatives

  // ── AUC ──────────────────────────────────────────────────────────────────

  /// Computes the ROC AUC from parallel (predictions, actuals) lists.
  ///
  /// [predictions] — floats in [0.0, 1.0]; values outside this range are clamped.
  /// [actuals]     — integers: 0 (no-flare) or 1 (flare).
  ///
  /// Returns [double.nan] when fewer than [_minClassCount] positives or
  /// negatives exist in [actuals] (degenerate: AUC undefined).
  /// Returns [double.nan] when lists are empty or of different lengths.
  static double computeAuc(List<double> predictions, List<int> actuals) {
    if (predictions.length != actuals.length || predictions.isEmpty) {
      return double.nan;
    }

    final positives = <double>[];
    final negatives = <double>[];
    for (var i = 0; i < predictions.length; i++) {
      final p = predictions[i].clamp(0.0, 1.0);
      if (actuals[i] == 1) {
        positives.add(p);
      } else {
        negatives.add(p);
      }
    }

    if (positives.length < _minClassCount ||
        negatives.length < _minClassCount) {
      return double.nan;
    }

    // Wilcoxon-Mann-Whitney: O(|pos| * |neg|), acceptable for ≤200 samples.
    int concordant = 0, tied = 0;
    for (final p in positives) {
      for (final n in negatives) {
        if (p > n) {
          concordant++;
        } else if (p == n) {
          tied++;
        }
      }
    }
    final total = positives.length * negatives.length;
    return (concordant + 0.5 * tied) / total;
  }

  // ── F1 ───────────────────────────────────────────────────────────────────

  /// Computes binary F1 at threshold = 0.5.
  ///
  /// Returns 0.0 when there are no positive predictions (no TP possible).
  /// Returns [double.nan] when lists are empty or of different lengths.
  static double computeF1(List<double> predictions, List<int> actuals) {
    if (predictions.length != actuals.length || predictions.isEmpty) {
      return double.nan;
    }

    int tp = 0, fp = 0, fn = 0;
    for (var i = 0; i < predictions.length; i++) {
      final predicted = predictions[i] >= 0.5 ? 1 : 0;
      final actual = actuals[i];
      if (predicted == 1 && actual == 1) {
        tp++;
      } else if (predicted == 1 && actual == 0) {
        fp++;
      } else if (predicted == 0 && actual == 1) {
        fn++;
      }
    }

    final precision = (tp + fp) == 0 ? 0.0 : tp / (tp + fp);
    final recall = (tp + fn) == 0 ? 0.0 : tp / (tp + fn);
    if (precision + recall == 0.0) return 0.0;
    return 2 * precision * recall / (precision + recall);
  }
}
