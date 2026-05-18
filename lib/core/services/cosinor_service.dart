import 'dart:math' as math;

import '../database/wearable_sample_repository.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CosinorFitResult
// ─────────────────────────────────────────────────────────────────────────────

class CosinorFitResult {
  const CosinorFitResult({
    required this.mesor,
    required this.amplitude,
    required this.acrophaseRad,
    required this.peakTimeHours,
    required this.rSquared,
    required this.sampleCount,
    required this.timeSpanHours,
    required this.fitValid,
  });

  final double mesor;
  final double amplitude;
  final double acrophaseRad; // radians, chronobiological convention
  final double peakTimeHours; // 0.0–24.0
  final double rSquared;
  final int sampleCount;
  final double timeSpanHours;
  final bool fitValid;

  /// Plain-English summary for chat context / dashboard.
  String get summary {
    if (!fitValid) return 'HRV rhythm fit insufficient data.';
    final peakH = peakTimeHours.toStringAsFixed(1);
    final m = mesor.toStringAsFixed(1);
    final a = amplitude.toStringAsFixed(1);
    return 'HRV rhythm: center $m ms, swing $a ms, peak ~$peakH h.';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CosinorComputationResult
// ─────────────────────────────────────────────────────────────────────────────

class CosinorComputationResult {
  const CosinorComputationResult({
    required this.recomputedDates,
    required this.failedDates,
  });

  final List<String> recomputedDates;
  final List<String> failedDates;
}

// ─────────────────────────────────────────────────────────────────────────────
// CosinorService
//
// Implements the paper's circadian HRV analysis (Hirten et al. 2025):
//   y(t) = M + A·cos(2πt/24) + B·sin(2πt/24) + ε        [Supplementary Eq. 1,
//                                                           simplified for N=1]
//
// Parameter extraction (equivalent to paper's convention):
//   MESOR        = M           (midline-estimating statistic of rhythm)
//   Amplitude    = √(A² + B²)
//   Acrophase    = atan2(−B, A)    [φ in paper]
//   PeakTime     = −φ × 24 / (2π)  mod 24
//
// Fitting method: Weighted Least Squares (WLS) with circadian-phase weights.
// Apple Watch HRV is least affected by motion artifact during sleep (22–6h),
// giving the most reliable MESOR estimate for the paper's primary predictor.
// Weights: sleep window 22–6h → 1.5; shoulders 6–9h, 18–22h → 1.0; active → 0.6.
// Backward compatible: uniform weights = OLS (legacy behavior preserved).
//
// The mixed-effects terms (random effects, covariate interactions) from the
// full paper model are correctly omitted here — they pool 309 participants.
// For a single-user personal model, WLS-OLS is the correct simplification.
//
// Validation thresholds:
//   sample_count  >= 6 samples on the day
//   time_span     >= 8 h between first and last sample
//   r_squared     >= 0.20 (raised from 0.10 — 10% explained variance is too
//                           permissive for 6 sparse samples)
// ─────────────────────────────────────────────────────────────────────────────

class CosinorService {
  CosinorService({
    required WearableSampleRepository repository,
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final WearableSampleRepository _repository;
  final DateTime Function() _nowProvider;

  static const _minSamples = 6;
  static const _minTimeSpanHours = 8.0;
  static const _minRSquared =
      0.20; // raised: 0.10 too permissive for sparse data
  static const _tau = 24.0; // circadian period in hours

  // ── Public: batch recompute ─────────────────────────────────────────────────

  Future<CosinorComputationResult> recomputeDates(List<String> dates) async {
    final recomputed = <String>[];
    final failed = <String>[];

    for (final date in dates.toSet().toList()..sort()) {
      try {
        final rows = await _repository.getHrvSamplesForDate(date);
        final samples = _extractSamples(rows);
        final weights = _circadianWeights(samples);
        final fit = fitCosinor(samples, weights: weights);
        await _repository.upsertCosinorFeature(
          CosinorFeatureRecord(
            featureDate: date,
            mesor: fit.fitValid ? fit.mesor : null,
            amplitude: fit.fitValid ? fit.amplitude : null,
            acrophaseRad: fit.fitValid ? fit.acrophaseRad : null,
            peakTimeHours: fit.fitValid ? fit.peakTimeHours : null,
            rSquared: fit.rSquared,
            sampleCount: fit.sampleCount,
            timeSpanHours: fit.timeSpanHours,
            fitValid: fit.fitValid,
            recomputedAt: _nowProvider(),
          ),
        );
        recomputed.add(date);
      } catch (_) {
        failed.add(date);
      }
    }

    return CosinorComputationResult(
      recomputedDates: recomputed,
      failedDates: failed,
    );
  }

  // ── Public: WLS cosinor fit — no DB, testable in isolation ─────────────────

  /// Fits a single-period Cosinor model to [samples] using Weighted Least Squares.
  ///
  /// Each sample is ({hour: 0.0–24.0, value: HRV in ms}).
  /// [weights] — optional per-sample weights (null = uniform = OLS).
  ///   Weights must be positive; values are clamped to [0.01, 10.0].
  ///   Length mismatch → falls back to uniform weights silently.
  ///
  /// Returns [CosinorFitResult] with fitValid=false when sample quality
  /// does not meet the validation thresholds.
  static CosinorFitResult fitCosinor(
    List<({double hour, double value})> samples, {
    List<double>? weights,
  }) {
    final n = samples.length;
    if (n < _minSamples) {
      return _invalidResult(sampleCount: n, timeSpanHours: 0);
    }

    // Guard: filter out samples with NaN or Infinity values
    final clean = samples
        .where(
          (s) =>
              s.value.isFinite &&
              !s.value.isNaN &&
              s.hour.isFinite &&
              !s.hour.isNaN,
        )
        .toList(growable: false);
    if (clean.length < _minSamples) {
      return _invalidResult(sampleCount: clean.length, timeSpanHours: 0);
    }

    final nc = clean.length;
    final hours = clean.map((s) => s.hour).toList(growable: false);
    final values = clean.map((s) => s.value).toList(growable: false);

    final timeSpanHours = hours.reduce(math.max) - hours.reduce(math.min);
    if (timeSpanHours < _minTimeSpanHours) {
      return _invalidResult(sampleCount: nc, timeSpanHours: timeSpanHours);
    }

    // Build per-sample weights: clamp to [0.01, 10.0], fall back to uniform on mismatch
    final w = (weights != null && weights.length == n)
        ? weights.map((v) => v.clamp(0.01, 10.0)).toList(growable: false)
        : List.filled(nc, 1.0);
    // If weights was provided for original n but some samples were filtered,
    // rebuild uniform weights for the clean subset to keep indices aligned.
    // (Only occurs when NaN/Inf samples exist — rare in practice.)
    final wClean = (weights != null && weights.length == n && nc < n)
        ? List.filled(nc, 1.0)
        : w;

    // Build design matrix columns: [1, cos(2πt/τ), sin(2πt/τ)]
    final cosX = hours
        .map((t) => math.cos(2 * math.pi * t / _tau))
        .toList(growable: false);
    final sinZ = hours
        .map((t) => math.sin(2 * math.pi * t / _tau))
        .toList(growable: false);

    // WLS normal equations: X'WX * beta = X'Wy
    // X'WX is a 3×3 symmetric matrix with diagonal weight matrix W.
    final sumW = _wdot1(wClean);
    final sumWCos = _wdot(wClean, cosX);
    final sumWSin = _wdot(wClean, sinZ);
    final sumWCos2 = _wdot2(wClean, cosX);
    final sumWSin2 = _wdot2(wClean, sinZ);
    final sumWCosSin = _wdotcross(wClean, cosX, sinZ);
    final sumWY = _wdot(wClean, values);
    final sumWYCos = _wdotcross(wClean, values, cosX);
    final sumWYSin = _wdotcross(wClean, values, sinZ);

    final xtx = [
      [sumW, sumWCos, sumWSin],
      [sumWCos, sumWCos2, sumWCosSin],
      [sumWSin, sumWCosSin, sumWSin2],
    ];
    final xty = [sumWY, sumWYCos, sumWYSin];

    final beta = _solve3x3(xtx, xty);
    if (beta == null || beta.any((v) => v.isNaN || v.isInfinite)) {
      return _invalidResult(sampleCount: nc, timeSpanHours: timeSpanHours);
    }

    final m = beta[0]; // MESOR
    final a = beta[1]; // cosine coefficient
    final b = beta[2]; // sine coefficient

    final amplitude = math.sqrt(a * a + b * b);

    // Acrophase (paper convention: φ = atan2(−B, A))
    final acrophase = math.atan2(-b, a);

    // PeakTime = −φ × τ / (2π), mod τ (paper Supplementary Eq. 1 definition)
    var peakTime = -acrophase * _tau / (2 * math.pi);
    peakTime = peakTime % _tau;
    if (peakTime < 0) peakTime += _tau;

    // Weighted R² (weighted SS to match WLS objective)
    final meanYW = sumWY / sumW;
    double ssTotW = 0;
    double ssResW = 0;
    for (var i = 0; i < nc; i++) {
      final predicted = m + a * cosX[i] + b * sinZ[i];
      ssTotW += wClean[i] * math.pow(values[i] - meanYW, 2);
      ssResW += wClean[i] * math.pow(values[i] - predicted, 2);
    }
    final rSquared = ssTotW > 0 ? (1.0 - ssResW / ssTotW).clamp(0.0, 1.0) : 0.0;

    final fitValid = rSquared >= _minRSquared;

    return CosinorFitResult(
      mesor: m,
      amplitude: amplitude,
      acrophaseRad: acrophase,
      peakTimeHours: peakTime,
      rSquared: rSquared,
      sampleCount: nc,
      timeSpanHours: timeSpanHours,
      fitValid: fitValid,
    );
  }

  // ── Private helpers ─────────────────────────────────────────────────────────

  List<({double hour, double value})> _extractSamples(
    List<Map<String, Object?>> rows,
  ) {
    final result = <({double hour, double value})>[];
    for (final row in rows) {
      final startUtc = row['start_time_utc'] as String?;
      final value = (row['value_numeric'] as num?)?.toDouble();
      if (startUtc == null || value == null) continue;
      final dt = DateTime.parse(startUtc).toLocal();
      final hourFraction = dt.hour + dt.minute / 60.0 + dt.second / 3600.0;
      result.add((hour: hourFraction, value: value));
    }
    return result;
  }

  /// Circadian-phase-based weights for Apple Watch HRV reliability.
  /// Sleep window (22–6h): highest reliability → weight 1.5.
  /// Morning/evening shoulders (6–9h, 18–22h): moderate → 1.0.
  /// Active daytime (9–18h): most motion artifact risk → 0.6.
  static List<double> _circadianWeights(
    List<({double hour, double value})> samples,
  ) {
    return samples.map((s) {
      final h = s.hour;
      if (h >= 22.0 || h < 6.0) return 1.5; // sleep window
      if (h < 9.0 || h >= 18.0) return 1.0; // morning/evening shoulders
      return 0.6; // active day
    }).toList(growable: false);
  }

  static CosinorFitResult _invalidResult({
    required int sampleCount,
    required double timeSpanHours,
  }) =>
      CosinorFitResult(
        mesor: 0,
        amplitude: 0,
        acrophaseRad: 0,
        peakTimeHours: 0,
        rSquared: 0,
        sampleCount: sampleCount,
        timeSpanHours: timeSpanHours,
        fitValid: false,
      );

  // ── WLS dot-product helpers ─────────────────────────────────────────────────

  /// Σ w_i  (sum of weights)
  static double _wdot1(List<double> w) {
    var s = 0.0;
    for (final wi in w) {
      s += wi;
    }
    return s;
  }

  /// Σ w_i * x_i
  static double _wdot(List<double> w, List<double> x) {
    var s = 0.0;
    for (var i = 0; i < w.length; i++) {
      s += w[i] * x[i];
    }
    return s;
  }

  /// Σ w_i * x_i²
  static double _wdot2(List<double> w, List<double> x) {
    var s = 0.0;
    for (var i = 0; i < w.length; i++) {
      s += w[i] * x[i] * x[i];
    }
    return s;
  }

  /// Σ w_i * x_i * z_i  (cross-product weighted)
  static double _wdotcross(List<double> w, List<double> x, List<double> z) {
    var s = 0.0;
    for (var i = 0; i < w.length; i++) {
      s += w[i] * x[i] * z[i];
    }
    return s;
  }

  /// Solves Ax = b for a 3×3 system using Cramer's rule.
  /// Returns null if A is singular (det ≈ 0).
  static List<double>? _solve3x3(List<List<double>> a, List<double> b) {
    final det = _det3(a);
    if (det.abs() < 1e-10) return null;

    // Replace each column with b and compute determinant (Cramer's rule).
    final x = <double>[];
    for (var col = 0; col < 3; col++) {
      final modified = [
        [a[0][0], a[0][1], a[0][2]],
        [a[1][0], a[1][1], a[1][2]],
        [a[2][0], a[2][1], a[2][2]],
      ];
      modified[0][col] = b[0];
      modified[1][col] = b[1];
      modified[2][col] = b[2];
      x.add(_det3(modified) / det);
    }
    return x;
  }

  /// 3×3 determinant via Sarrus' rule.
  static double _det3(List<List<double>> m) {
    return m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
        m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
        m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
  }
}
