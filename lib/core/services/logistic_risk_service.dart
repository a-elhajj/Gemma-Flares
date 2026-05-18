import 'dart:math' as math;

import '../database/wearable_sample_repository.dart';
import 'auc_computation_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// LogisticPrediction — one prediction for one horizon × flare type
// ─────────────────────────────────────────────────────────────────────────────

class LogisticPrediction {
  const LogisticPrediction({
    required this.modelKey,
    required this.horizonDays,
    required this.flareType,
    required this.probability,
    required this.trainingSamples,
  });

  final String modelKey;
  final int horizonDays;
  final String flareType;
  final double probability; // 0.0–1.0
  final int trainingSamples;

  static const minimumTrainingSamples = 14;

  bool get hasEnoughData => trainingSamples >= minimumTrainingSamples;
}

// ─────────────────────────────────────────────────────────────────────────────
// LogisticRiskService
//
// Implements mixed-effect logistic regression adapted for single-user on-device
// use (Hirten et al. 2025, Supplementary Eq. 2):
//
//   logit(P(Flare_{t+i}=1 | X_t)) = β₀ + β₁·X_{it} + u_i·Z_i + ε_{it}
//
// For a single user (no random effects across participants), this reduces to:
//   logit(P) = intercept + Σ(weight_j × feature_j)
//
// Prediction horizons: i ∈ {7, 14, 21, 28, 35, 42, 49} days (paper Figure 3A)
// Flare types: 'inflammatory', 'symptomatic'
// → 14 models total (2 types × 7 horizons)
//
// Learning strategy: online SGD with decaying learning rate.
// Initial weights are seeded from paper-reported effect directions so the model
// is directionally correct from day 1, before any labeled data accumulates.
// ─────────────────────────────────────────────────────────────────────────────

class LogisticRiskService {
  LogisticRiskService({
    required WearableSampleRepository repository,
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final WearableSampleRepository _repository;
  final DateTime Function() _nowProvider;

  static const modelVersion = 'logistic_v1';
  static const horizons = [7, 14, 21, 28, 35, 42, 49];
  static const flareTypes = ['inflammatory', 'symptomatic'];
  static const stableDisplaySamples =
      LogisticPrediction.minimumTrainingSamples * 3;

  // SGD hyperparameters
  static const _baseLearningRate = 0.01;
  static const _lrDecayFactor = 0.001;
  static const _l2Lambda = 0.001; // L2 regularization weight
  static const _calibrationWarmupSamples =
      LogisticPrediction.minimumTrainingSamples;

  // AUC computation: recompute every 7 new training samples once past warmup.
  // Milestone check: trainingSamples % 7 == 0 AND trainingSamples >= minimumTrainingSamples.
  static const _aucComputeInterval = 7;
  static const _maxTrainingHistory = 200; // circular buffer size per model

  static bool shouldUseLearningState(int trainingSamples) {
    return trainingSamples < stableDisplaySamples;
  }

  // Baseline flare prevalence derived from the paper intercept sigmoid(-2.0).
  // Hirten et al. 2025 cohort: ~11.9% IBD-patient baseline flare rate.
  // This is the correct Bayesian shrinkage target when training data is sparse —
  // reverting to the prior, not to maximum-uncertainty 0.5.
  static const _baselineFlareRisk = 0.119;

  static double calibrateDisplayProbability({
    required double rawProbability,
    required int trainingSamples,
  }) {
    // Cold-start: fewer than minimumTrainingSamples observations.
    // Return the paper-derived baseline prior directly. The cold_start flag in
    // featureJson suppresses display, but stored records should carry the prior
    // (0.119) rather than an inflated 0.5-pulled value (which would be ~0.367).
    if (trainingSamples < LogisticPrediction.minimumTrainingSamples) {
      return _baselineFlareRisk.clamp(0.08, 0.92);
    }
    final boundedRaw = rawProbability.clamp(0.0, 1.0);
    final progress = ((trainingSamples -
                LogisticPrediction.minimumTrainingSamples) /
            (stableDisplaySamples - LogisticPrediction.minimumTrainingSamples))
        .clamp(0.0, 1.0);
    final weight = 0.35 + (progress * 0.65);
    // Shrink toward the paper-derived baseline (12%), not toward 0.5.
    // At weight=0.35 (14 samples): calibrated ≈ baseline + (raw−baseline)×0.35
    // At weight=1.00 (42 samples): calibrated = raw  (full model confidence)
    final calibrated =
        _baselineFlareRisk + ((boundedRaw - _baselineFlareRisk) * weight);
    return calibrated.clamp(0.08, 0.92);
  }

  static double displayProbabilityFromLogit(double logit) {
    final temperedLogit = (logit / 4.0).clamp(-8.0, 8.0);
    return _sigmoid(temperedLogit);
  }

  // ── Feature names (ordered, stable — do not reorder) ──────────────────────
  // Derived from paper predictors: HRV, HR, RHR, Steps, SpO₂ (Figure 3B)
  // Plus cosinor features (MESOR, Amplitude — paper Figures 1, 2)
  // Plus symptom features (product enhancement)
  static const featureNames = [
    'hrv_3d_pct_drop', // % drop vs baseline (inverted sign: positive = drop)
    'hrv_7d_pct_drop',
    'rhr_3d_rise', // absolute rise vs baseline in bpm
    'steps_7d_pct_drop',
    'spo2_7d_drop', // absolute drop in %
    'sleep_3d_pct_drop',
    'sleep_deep_pct',
    'sleep_rem_pct',
    'cosinor_mesor_drop', // personal MESOR deviation (lower during inflammatory flare)
    'cosinor_amplitude_rise', // amplitude deviation (higher during symptomatic flare)
    'hrv_14d_slope',
    'rhr_14d_slope',
    'steps_14d_slope',
    'symptom_weighted_sum', // weighted symptom severity sum (48h)
    'symptom_max_severity', // max severity score (48h)
    'llm_pain_intensity',
    'llm_urgency_present',
    'llm_fatigue_signal',
    'llm_dietary_trigger',
    'user_age',
    'user_sex_male',
    'user_bmi',
    'user_disease_cd',
    'hrv_mesor_14d_trend', // 14-day OLS slope of daily MESOR (normalized); falling MESOR raises inflammatory risk
  ];

  // Paper-informed prior weights (sign and rough magnitude from paper results).
  // Inflammatory flare priors:
  //   - HRV MESOR decreases (paper Figure 1A, p<.0001)
  //   - HR, RHR increase (paper Figure 1B)
  //   - Steps decrease (paper Figure 1B, p=.01)
  // Symptomatic flare priors:
  //   - HRV Amplitude increases (paper Figure 1C, p=.006)
  //   - HR, RHR increase
  static Map<String, double> _priorWeights(String flareType) {
    if (flareType == 'inflammatory') {
      return {
        'hrv_3d_pct_drop': 0.08,
        'hrv_7d_pct_drop': 0.10,
        'rhr_3d_rise': 0.12,
        'steps_7d_pct_drop': 0.06,
        'spo2_7d_drop': 0.08,
        'sleep_3d_pct_drop': 0.04,
        'sleep_deep_pct': -0.04,
        'sleep_rem_pct': -0.03,
        'cosinor_mesor_drop': 0.12, // primary signal for inflammatory
        'cosinor_amplitude_rise': 0.02,
        'hrv_14d_slope': -0.06,
        'rhr_14d_slope': 0.08,
        'steps_14d_slope': -0.05,
        'symptom_weighted_sum': 0.05,
        'symptom_max_severity': 0.06,
        'llm_pain_intensity': 0.08,
        'llm_urgency_present': 0.06,
        'llm_fatigue_signal': 0.05,
        'llm_dietary_trigger': 0.03,
        'user_age': 0.01,
        'user_sex_male': 0.02,
        'user_bmi': 0.02,
        'user_disease_cd': 0.03,
        // Falling 14d MESOR trend is the strongest paper predictor (Figure 2).
        // Negative coefficient because falling MESOR (negative trend value) should
        // increase risk — the feature is encoded as slope so negative slope → risk.
        'hrv_mesor_14d_trend': -0.10,
      };
    }
    // symptomatic
    return {
      'hrv_3d_pct_drop': 0.05,
      'hrv_7d_pct_drop': 0.06,
      'rhr_3d_rise': 0.10,
      'steps_7d_pct_drop': 0.04,
      'spo2_7d_drop': 0.05,
      'sleep_3d_pct_drop': 0.06,
      'sleep_deep_pct': -0.05,
      'sleep_rem_pct': -0.04,
      'cosinor_mesor_drop': 0.04,
      'cosinor_amplitude_rise': 0.12, // primary signal for symptomatic
      'hrv_14d_slope': -0.04,
      'rhr_14d_slope': 0.08,
      'steps_14d_slope': -0.04,
      'symptom_weighted_sum': 0.12,
      'symptom_max_severity': 0.10,
      'llm_pain_intensity': 0.10,
      'llm_urgency_present': 0.08,
      'llm_fatigue_signal': 0.06,
      'llm_dietary_trigger': 0.04,
      'user_age': 0.01,
      'user_sex_male': 0.02,
      'user_bmi': 0.02,
      'user_disease_cd': 0.03,
      'hrv_mesor_14d_trend': -0.05, // weaker for symptomatic than inflammatory
    };
  }

  // ── Public: predict + SGD update for all horizons × flare types ──────────

  /// Builds the feature vector for [date], predicts flare probability at all
  /// 14 model keys, and runs an SGD weight update for any horizon where we
  /// already have a ground-truth label.
  ///
  /// Returns a list of all 14 predictions (probability may be low confidence
  /// when trainingSamples is below [LogisticPrediction.minimumTrainingSamples]
  /// — callers should check [hasEnoughData]).
  Future<List<LogisticPrediction>> recomputeForDate(String date) async {
    final features = await _buildFeatureVector(date);
    final predictions = <LogisticPrediction>[];

    for (final flareType in flareTypes) {
      for (final horizon in horizons) {
        final modelKey = _modelKey(flareType, horizon);
        var state = await _repository.getLogisticModelState(modelKey);
        state ??= _initialState(modelKey, horizon, flareType);

        // Predict
        final prob = _sigmoid(
          _dotProduct(state.coefficientsJson, features) + state.intercept,
        );

        // SGD update if we have a label for date + horizon days from now
        final labelDate = _offsetDate(date, horizon);
        final label = await _repository.getFlareLabel(labelDate);
        if (label != null) {
          final actual = flareType == 'inflammatory'
              ? label.inflammatoryFlare
              : label.symptomaticFlare;
          state = await _handleLabeledObservation(
            state: state,
            modelKey: modelKey,
            date: date,
            preUpdateProb: prob,
            features: features,
            actual: actual,
          );
        }

        predictions.add(
          LogisticPrediction(
            modelKey: modelKey,
            horizonDays: horizon,
            flareType: flareType,
            probability: prob,
            trainingSamples: state.trainingSamples,
          ),
        );
      }
    }

    return predictions;
  }

  // ── Shared training-observation pipeline ─────────────────────────────────
  // Inserts the pre-update prediction + actual label into training history,
  // prunes the circular buffer, runs the SGD (or cold-start counter) update,
  // recomputes AUC at every 7-sample milestone (post-warmup), and persists
  // the new state. Called from BOTH recomputeForDate and
  // recomputeForDateWithFeatures so the live app path (uses the *WithFeatures
  // variant via RiskEngineService) actually accumulates training history and
  // computes AUC. Without this shared call site, AUC tracking is dead code.
  Future<LogisticModelStateRecord> _handleLabeledObservation({
    required LogisticModelStateRecord state,
    required String modelKey,
    required String date,
    required double preUpdateProb,
    required Map<String, double> features,
    required bool actual,
  }) async {
    // The history row is the idempotency marker for online training. If this
    // same model/date has already been observed, recomputation is prediction
    // only and must not advance trainingSamples or weights again.
    try {
      final inserted = await _repository.insertTrainingHistoryRecordIfAbsent(
        LogisticTrainingHistoryRecord(
          modelKey: modelKey,
          sampleDate: date,
          predictedProb: preUpdateProb,
          actualLabel: actual ? 1 : 0,
          trainingN: state.trainingSamples,
          recordedAt: _nowProvider(),
        ),
      );
      if (!inserted) return state;
      await _repository.pruneTrainingHistory(
        modelKey,
        keepLast: _maxTrainingHistory,
      );
    } catch (_) {
      // If we cannot write the idempotency marker, skip training. Prediction can
      // continue using the existing state, and a future successful recompute can
      // safely record the observation exactly once.
      return state;
    }

    var nextState = _observeOrUpdate(state, features, actual);

    // AUC at every 7-sample milestone past the 14-sample warmup.
    // Wrapped in _updateAuc which already swallows failures.
    if (nextState.trainingSamples >=
            LogisticPrediction.minimumTrainingSamples &&
        nextState.trainingSamples % _aucComputeInterval == 0) {
      nextState = await _updateAuc(nextState, modelKey);
    }

    await _repository.upsertLogisticModelState(nextState);
    return nextState;
  }

  // ── AUC update helper ────────────────────────────────────────────────────

  Future<LogisticModelStateRecord> _updateAuc(
    LogisticModelStateRecord state,
    String modelKey,
  ) async {
    try {
      final history = await _repository.getTrainingHistory(modelKey);
      final preds = history.map((h) => h.predictedProb).toList();
      final actuals = history.map((h) => h.actualLabel).toList();
      final auc = AucComputationService.computeAuc(preds, actuals);
      final f1 = AucComputationService.computeF1(preds, actuals);
      if (auc.isNaN && f1.isNaN) {
        return state; // degenerate: not enough class diversity
      }
      return LogisticModelStateRecord(
        modelKey: state.modelKey,
        horizonDays: state.horizonDays,
        flareType: state.flareType,
        coefficientsJson: state.coefficientsJson,
        intercept: state.intercept,
        trainingSamples: state.trainingSamples,
        lastAuc: auc.isNaN ? state.lastAuc : auc,
        lastF1: f1.isNaN ? state.lastF1 : f1,
        updatedAt: state.updatedAt,
      );
    } catch (_) {
      // AUC computation failure must never block prediction or training.
      return state;
    }
  }

  // ── Feature vector construction ─────────────────────────────────────────

  Future<Map<String, double>> _buildFeatureVector(String date) async {
    // Try to use the stored daily feature JSON (computed by RiskEngineService).
    // Fall back to zero vector if not yet available (pre-sync cold start).
    final storedFeature = await _repository.getDailyFeatureForDate(date);

    // Get cosinor features
    final cosinor = await _repository.getCosinorFeature(date);

    // Seed feature vector from RiskEngine's pre-computed daily_features row.
    // This avoids double-querying summaries. Zero-fill missing keys.
    final features = <String, double>{};
    for (final name in featureNames) {
      features[name] = 0.0;
    }
    if (storedFeature != null) {
      features.addAll(extractFromRiskFeatures(storedFeature.featureJson));
    }

    // Cosinor features — compute deviation from personal 28-day Cosinor mean
    if (cosinor != null && cosinor.fitValid) {
      final recent = await _repository.getCosinorFeaturesInRange(
        _offsetDate(date, -28),
        _offsetDate(date, -1),
      );
      final validRecent = recent.where((r) => r.fitValid).toList();
      if (validRecent.isNotEmpty) {
        features['cosinor_mesor_drop'] = _zDelta(
          baseline: validRecent.map((r) => r.mesor).whereType<double>(),
          current: cosinor.mesor,
          invertDirection: true,
        );
        features['cosinor_amplitude_rise'] = _zDelta(
          baseline: validRecent.map((r) => r.amplitude).whereType<double>(),
          current: cosinor.amplitude,
        );
      }
    }

    // 14-day MESOR trend — paper's strongest pre-flare predictor (Figure 2)
    final trend = await _computeMesor14dTrend(date);
    features['hrv_mesor_14d_trend'] =
        (trend.isNaN || trend.isInfinite) ? 0.0 : trend;

    await _scaleSleepStagesFromPersonalBaseline(date, features);
    return features;
  }

  // ── Model initialization ─────────────────────────────────────────────────

  LogisticModelStateRecord _initialState(
    String modelKey,
    int horizon,
    String flareType,
  ) =>
      LogisticModelStateRecord(
        modelKey: modelKey,
        horizonDays: horizon,
        flareType: flareType,
        coefficientsJson: Map.from(_priorWeights(flareType)),
        intercept:
            -2.0, // prior: ~11% baseline flare prevalence (sigmoid(-2)≈0.12)
        trainingSamples: 0,
        updatedAt: _nowProvider(),
      );

  // ── SGD update ───────────────────────────────────────────────────────────

  LogisticModelStateRecord _sgdUpdate(
    LogisticModelStateRecord state,
    Map<String, double> features,
    bool actualFlare,
  ) {
    final lr = _learningRate(state.trainingSamples);
    final prediction = _sigmoid(
      _dotProduct(state.coefficientsJson, features) + state.intercept,
    );
    final error = prediction - (actualFlare ? 1.0 : 0.0);

    // MAP-anchored L2: regularize toward the paper-derived prior, not toward zero.
    // Standard SGD L2 (toward zero) erases prior knowledge as N grows.
    // MAP-anchored version keeps: θ_new = θ - lr*(error*x + λ*(θ - θ_prior))
    // At θ=θ_prior: regularization gradient = 0 → prior is a stable fixed point.
    // At large N: lr→0 and posterior converges to MLE (same as standard SGD).
    final prior = _priorWeights(state.flareType);
    final newCoefficients = Map<String, double>.from(state.coefficientsJson);
    for (final name in featureNames) {
      final featureValue = features[name] ?? 0.0;
      final currentWeight = newCoefficients[name] ?? 0.0;
      final priorWeight = prior[name] ?? 0.0;
      newCoefficients[name] = currentWeight -
          lr *
              (error * featureValue +
                  _l2Lambda * (currentWeight - priorWeight));
    }
    final newIntercept = state.intercept - lr * error;

    return LogisticModelStateRecord(
      modelKey: state.modelKey,
      horizonDays: state.horizonDays,
      flareType: state.flareType,
      coefficientsJson: newCoefficients,
      intercept: newIntercept,
      trainingSamples: state.trainingSamples + 1,
      lastAuc: state.lastAuc,
      lastF1: state.lastF1,
      updatedAt: _nowProvider(),
    );
  }

  LogisticModelStateRecord _observeOrUpdate(
    LogisticModelStateRecord state,
    Map<String, double> features,
    bool actualFlare,
  ) {
    if (state.trainingSamples + 1 < _calibrationWarmupSamples) {
      return LogisticModelStateRecord(
        modelKey: state.modelKey,
        horizonDays: state.horizonDays,
        flareType: state.flareType,
        coefficientsJson: state.coefficientsJson,
        intercept: state.intercept,
        trainingSamples: state.trainingSamples + 1,
        lastAuc: state.lastAuc,
        lastF1: state.lastF1,
        updatedAt: _nowProvider(),
      );
    }
    return _sgdUpdate(state, features, actualFlare);
  }

  // ── Public: inject wearable features from existing risk engine ────────────

  /// Called by RiskEngineService to inject its already-computed features into
  /// the logistic model feature vector. Avoids re-querying summaries.
  Future<List<LogisticPrediction>> recomputeForDateWithFeatures(
    String date,
    Map<String, Object?> riskFeatureJson,
  ) async {
    final features = extractFromRiskFeatures(riskFeatureJson);

    // Augment with cosinor deviation
    final cosinor = await _repository.getCosinorFeature(date);
    if (cosinor != null && cosinor.fitValid) {
      final recent = await _repository.getCosinorFeaturesInRange(
        _offsetDate(date, -28),
        _offsetDate(date, -1),
      );
      final validRecent = recent.where((r) => r.fitValid).toList();
      if (validRecent.isNotEmpty) {
        features['cosinor_mesor_drop'] = _zDelta(
          baseline: validRecent.map((r) => r.mesor).whereType<double>(),
          current: cosinor.mesor,
          invertDirection: true,
        );
        features['cosinor_amplitude_rise'] = _zDelta(
          baseline: validRecent.map((r) => r.amplitude).whereType<double>(),
          current: cosinor.amplitude,
        );
      }
    }

    // 14-day MESOR trend
    final trend = await _computeMesor14dTrend(date);
    features['hrv_mesor_14d_trend'] =
        (trend.isNaN || trend.isInfinite) ? 0.0 : trend;

    await _scaleSleepStagesFromPersonalBaseline(date, features);
    final predictions = <LogisticPrediction>[];

    for (final flareType in flareTypes) {
      for (final horizon in horizons) {
        final modelKey = _modelKey(flareType, horizon);
        var state = await _repository.getLogisticModelState(modelKey);
        state ??= _initialState(modelKey, horizon, flareType);

        final prob = _sigmoid(
          _dotProduct(state.coefficientsJson, features) + state.intercept,
        );

        // SGD update if label exists. Use the shared training-observation
        // pipeline so training history + AUC tracking fire in the production
        // path (RiskEngineService calls THIS method, not recomputeForDate).
        final labelDate = _offsetDate(date, horizon);
        final label = await _repository.getFlareLabel(labelDate);
        if (label != null) {
          final actual = flareType == 'inflammatory'
              ? label.inflammatoryFlare
              : label.symptomaticFlare;
          state = await _handleLabeledObservation(
            state: state,
            modelKey: modelKey,
            date: date,
            preUpdateProb: prob,
            features: features,
            actual: actual,
          );
        }

        predictions.add(
          LogisticPrediction(
            modelKey: modelKey,
            horizonDays: horizon,
            flareType: flareType,
            probability: prob,
            trainingSamples: state.trainingSamples,
          ),
        );
      }
    }

    return predictions;
  }

  // ── 14-day MESOR trend ───────────────────────────────────────────────────

  /// Returns the OLS slope of valid MESOR values over the 14 days prior to [date],
  /// normalized by the inter-day MESOR standard deviation (units: stdDev/day).
  /// Returns 0.0 when fewer than 4 valid cosinor fits exist in the window.
  /// Result is clamped to [−3, 3] to bound the feature magnitude.
  Future<double> _computeMesor14dTrend(String date) async {
    final endDate = _offsetDate(date, -1);
    final startDate = _offsetDate(date, -14);
    final records = await _repository.getCosinorFeaturesInRange(
      startDate,
      endDate,
    );
    final valid = records
        .where((r) => r.fitValid && r.mesor != null)
        .toList(growable: false);
    if (valid.length < 4) return 0.0; // insufficient data for reliable slope

    final sorted = [...valid]
      ..sort((a, b) => a.featureDate.compareTo(b.featureDate));
    final nv = sorted.length;
    final ts = List.generate(nv, (i) => i.toDouble());
    final ys = sorted.map((r) => r.mesor!).toList(growable: false);

    // OLS slope: β = Σ(t−t̄)(y−ȳ) / Σ(t−t̄)²
    final tMean = ts.reduce((a, b) => a + b) / nv;
    final yMean = ys.reduce((a, b) => a + b) / nv;
    double num = 0, den = 0;
    for (var i = 0; i < nv; i++) {
      num += (ts[i] - tMean) * (ys[i] - yMean);
      den += (ts[i] - tMean) * (ts[i] - tMean);
    }
    if (den < 1e-9) return 0.0; // all same-day indices (degenerate)

    final slope = num / den; // ms per day

    // Normalize by MESOR standard deviation → unitless slope per stdDev
    final variance =
        ys.map((y) => math.pow(y - yMean, 2)).reduce((a, b) => a + b) / nv;
    final stdDev = math.sqrt(variance);
    if (stdDev < 0.1) return 0.0; // near-zero variance — no reliable trend

    return (slope / stdDev).clamp(-3.0, 3.0);
  }

  // ── Feature extraction from RiskEngine JSON ──────────────────────────────

  static Map<String, double> extractFromRiskFeatures(
    Map<String, Object?> json,
  ) {
    double? g(String key) => (json[key] as num?)?.toDouble();

    return {
      // Positive sign = risk direction (drop for HRV = drop from baseline)
      'hrv_3d_pct_drop': (g('hrv_3d_pct_delta_vs_baseline') ?? 0).clamp(
        -100.0,
        100.0,
      ),
      'hrv_7d_pct_drop': (g('hrv_7d_pct_delta_vs_baseline') ?? 0).clamp(
        -100.0,
        100.0,
      ),
      'rhr_3d_rise': (g('rhr_3d_delta_vs_baseline') ?? 0).clamp(-20.0, 20.0),
      'steps_7d_pct_drop': (g('steps_7d_pct_delta_vs_baseline') ?? 0).clamp(
        -100.0,
        100.0,
      ),
      'spo2_7d_drop': (g('spo2_7d_delta_vs_baseline') ?? 0).clamp(-10.0, 10.0),
      'sleep_3d_pct_drop': (g('sleep_3d_pct_delta_vs_baseline') ?? 0).clamp(
        -100.0,
        100.0,
      ),
      'sleep_deep_pct': (g('sleep_deep_pct') ?? 0).clamp(0.0, 1.0),
      'sleep_rem_pct': (g('sleep_rem_pct') ?? 0).clamp(0.0, 1.0),
      'cosinor_mesor_drop': 0.0, // filled in by caller after cosinor lookup
      'cosinor_amplitude_rise': 0.0,
      'hrv_14d_slope': (g('hrv_14d_slope') ?? 0).clamp(-20.0, 20.0),
      'rhr_14d_slope': (g('rhr_14d_slope') ?? 0).clamp(-20.0, 20.0),
      'steps_14d_slope': (g('steps_14d_slope') ?? 0).clamp(-5000.0, 5000.0),
      'symptom_weighted_sum': (g('symptom_weighted_sum_48h') ?? 0).clamp(
        0.0,
        30.0,
      ),
      'symptom_max_severity': (g('symptom_max_severity_48h') ?? 0).clamp(
        0.0,
        10.0,
      ),
      'llm_pain_intensity': (g('llm_pain_intensity') ?? 0).clamp(0.0, 1.0),
      'llm_urgency_present': (g('llm_urgency_present') ?? 0).clamp(0.0, 1.0),
      'llm_fatigue_signal': (g('llm_fatigue_signal') ?? 0).clamp(0.0, 1.0),
      'llm_dietary_trigger': (g('llm_dietary_trigger') ?? 0).clamp(0.0, 1.0),
      'user_age': (g('user_age') ?? 0).clamp(0.0, 120.0),
      'user_sex_male': (g('user_sex_male') ?? 0).clamp(0.0, 1.0),
      'user_bmi': (g('user_bmi') ?? 0).clamp(0.0, 80.0),
      'user_disease_cd': (g('user_disease_cd') ?? 0).clamp(0.0, 1.0),
      // hrv_mesor_14d_trend is computed from cosinor history, not from riskFeatureJson.
      // Zero-filled here; the async _computeMesor14dTrend fills it after this call.
      'hrv_mesor_14d_trend': 0.0,
    };
  }

  // ── Utilities ────────────────────────────────────────────────────────────

  static String _modelKey(String flareType, int horizon) =>
      '${modelVersion}_${flareType}_${horizon}d';

  static double _sigmoid(double x) =>
      1.0 / (1.0 + math.exp(-x.clamp(-20.0, 20.0)));

  static double _learningRate(int n) =>
      _baseLearningRate / (1.0 + _lrDecayFactor * n);

  static double _dotProduct(
    Map<String, double> weights,
    Map<String, double> features,
  ) {
    var sum = 0.0;
    for (final entry in weights.entries) {
      sum += entry.value * (features[entry.key] ?? 0.0);
    }
    return sum;
  }

  Future<void> _scaleSleepStagesFromPersonalBaseline(
    String date,
    Map<String, double> features,
  ) async {
    final summaries = await _repository.getDailySummaries();
    final currentIndex = summaries.indexWhere(
      (summary) => summary.dateLocal == date,
    );
    if (currentIndex <= 0) {
      return;
    }
    final prior = summaries.sublist(0, currentIndex);
    final baseline =
        prior.length > 28 ? prior.sublist(prior.length - 28) : prior;
    features['sleep_deep_pct'] = _zDelta(
      baseline: baseline
          .map(
            (summary) => _sleepStagePct(summary, 'sleep_asleep_deep_minutes'),
          )
          .whereType<double>(),
      current: features['sleep_deep_pct'],
    );
    features['sleep_rem_pct'] = _zDelta(
      baseline: baseline
          .map((summary) => _sleepStagePct(summary, 'sleep_asleep_rem_minutes'))
          .whereType<double>(),
      current: features['sleep_rem_pct'],
    );
  }

  double? _sleepStagePct(DailySummaryRecord summary, String stageKey) {
    final total =
        (summary.summaryJson['sleep_total_minutes'] as num?)?.toDouble();
    final stage = (summary.summaryJson[stageKey] as num?)?.toDouble();
    if (total == null || total <= 0 || stage == null) {
      return null;
    }
    return stage / total;
  }

  double _zDelta({
    required Iterable<double> baseline,
    required double? current,
    bool invertDirection = false,
  }) {
    final values = baseline.toList(growable: false);
    if (current == null || values.length < 7) {
      return 0.0;
    }
    final mean = values.reduce((a, b) => a + b) / values.length;
    final variance = values
            .map((value) => (value - mean) * (value - mean))
            .reduce((a, b) => a + b) /
        values.length;
    final sd = math.sqrt(variance);
    if (sd <= 0.000001) {
      return 0.0;
    }
    final z = (current - mean) / sd;
    return (invertDirection ? -z : z).clamp(-5.0, 5.0);
  }

  String _offsetDate(String dateStr, int days) {
    final dt = DateTime.parse('${dateStr}T00:00:00Z');
    final offset = dt.add(Duration(days: days));
    final y = offset.year.toString().padLeft(4, '0');
    final m = offset.month.toString().padLeft(2, '0');
    final d = offset.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
