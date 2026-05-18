// =============================================================================
// GEMMA 4 HACKATHON — Deterministic Risk Engine (Gemma-Free)
// =============================================================================
// This service computes the flare-risk score. Gemma 4 is NOT involved here.
//
// Why deterministic scoring matters:
//   - Same inputs always produce the same score — auditable, reproducible.
//   - Every score persists its full contribution breakdown (context_attribution)
//     so Gemma can explain exactly which wearable signals drove the result.
//   - Gemma receives the pre-computed score and attribution as a grounded JSON
//     payload; it translates numbers into plain English, not the other way around.
//
// Pipeline:
//   HealthKit samples → WearableNormalizationService (UTC, dedup, units)
//     → DailySummaryService (rolling features, circadian baseline)
//     → LogisticRiskService (logistic regression on assets/models/risk_v1.json)
//     → ProductionRiskAdjustmentService (confidence penalty, symptom burden)
//     → RiskEngineService.recomputeForDates() (orchestration + persistence)
//
// This strict boundary — deterministic scoring, Gemma explains — is what makes
// Gemma Flares safe to use as a health-pattern tracking tool.
// =============================================================================

import '../database/wearable_sample_repository.dart';
import 'apple_watch_capability_service.dart';
import 'context_attribution_service.dart';
import 'diagnostic_log_service.dart';
import 'ibd_checkin_service.dart';
import 'lab_normalization_service.dart';
import 'lab_risk_contribution_service.dart';
import 'logistic_risk_service.dart';
import 'production_risk_adjustment_service.dart';
import 'profile_service.dart';
import 'score_stability_gate.dart';

class RiskEngineComputationResult {
  const RiskEngineComputationResult({
    required this.recomputedDates,
    required this.failedDates,
  });

  final List<String> recomputedDates;
  final List<String> failedDates;
}

class RiskEngineService {
  RiskEngineService({
    required WearableSampleRepository repository,
    DateTime Function()? nowProvider,
    LogisticRiskService? logisticRiskService,
    ProfileService? profileService,
    ContextAttributionService? contextAttributionService,
    ProductionRiskAdjustmentService productionRiskAdjustmentService =
        const ProductionRiskAdjustmentService(),
    LabRiskContributionService? labRiskContributionService,
    LabNormalizationService labNormalizationService =
        const LabNormalizationService(),
    ScoreStabilityGate? scoreStabilityGate,
    DiagnosticLogService? diagnosticLogService,
  })  : _repository = repository,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc()),
        _logisticRiskService = logisticRiskService,
        _profileService = profileService,
        _contextAttributionService = contextAttributionService ??
            ContextAttributionService(
              repository: repository,
              nowProvider: nowProvider,
            ),
        _productionRiskAdjustmentService = productionRiskAdjustmentService,
        _labRiskContributionService = labRiskContributionService,
        _labNormalizationService = labNormalizationService,
        _scoreStabilityGate = scoreStabilityGate,
        _diagnosticLogService = diagnosticLogService;

  static const modelVersion = 'risk_v1';
  static const productionModelVersion = 'risk_v2_context_adjusted';

  final WearableSampleRepository _repository;
  final DateTime Function() _nowProvider;
  // Optional: paper-based logistic model runs alongside heuristic after it is wired in.
  final LogisticRiskService? _logisticRiskService;
  final ProfileService? _profileService;
  final ContextAttributionService _contextAttributionService;
  final ProductionRiskAdjustmentService _productionRiskAdjustmentService;
  final LabRiskContributionService? _labRiskContributionService;
  final LabNormalizationService _labNormalizationService;
  final ScoreStabilityGate? _scoreStabilityGate;
  final DiagnosticLogService? _diagnosticLogService;
  static const Set<String> _ibdRiskRelevantSymptomTypes = {
    'abdominal_pain',
    'pain',
    'cramping',
    'diarrhea',
    'stool_frequency',
    'frequency',
    'urgency',
    'blood',
    'bleeding',
    'rectal_bleeding',
    'nausea',
    'bloating',
    'fatigue',
    'constipation',
    'mouth_sores',
    'vomiting',
    'weight_loss',
    'dehydration',
    'fever',
    'fistula',
    'anal_fissure',
    'obstruction',
    'malnutrition',
    'joint_pain',
    'skin',
    'eye',
  };

  Future<RiskEngineComputationResult> recomputeDates(
    List<String> dates, {
    String? sessionId,
    String? triggerReason,
    bool isUserAction = false,
  }) async {
    final summaries = await _repository.getDailySummaries();
    if (summaries.isEmpty || dates.isEmpty) {
      return const RiskEngineComputationResult(
        recomputedDates: [],
        failedDates: [],
      );
    }

    final summaryDates =
        summaries.map((item) => item.dateLocal).toList(growable: false);
    final targetDates = _expandDates(
      inputDates: dates,
      summaryDates: summaryDates,
    );
    final syncState = await _repository.getSyncState('apple_health');
    final userCovariates =
        await _profileService?.getCovariates() ?? const UserProfileCovariates();
    final userProfile = await _profileService?.loadProfile();
    final watchCapability = const AppleWatchCapabilityService().capabilityFor(
      userProfile?.deviceType == 'Apple Watch'
          ? userProfile?.watchSeries
          : null,
    );

    // Fetch labs for the full date window (+30 day lookback for decay window)
    final labWindowStart = _offsetDate(targetDates.first, -30);
    final labWindowEnd = targetDates.last;
    final allLabs = await _repository.getLabValuesInRange(
      labWindowStart,
      labWindowEnd,
    );
    final labsByKey = _groupAndNormalizeLabs(allLabs);
    final userBaselines = _computeUserLabBaselines(allLabs);
    // 'unknown' for users who have not set a diagnosis. This prevents silently
    // applying the tightest CD lab thresholds (FC≥150, CRP≥5, ESR≥30) to
    // undiagnosed users. The lab service handles 'unknown' with standard IBD
    // thresholds + a −2 confidence reduction. Never default to 'cd'.
    final userDiagnosisCategory =
        (userProfile?.diseaseType ?? 'unknown').toLowerCase();
    final userSex = userProfile?.biologicalSex == null
        ? null
        : (userProfile!.biologicalSex == 'male' ? 'm' : 'f');

    final recomputed = <String>[];
    final failed = <String>[];

    for (final date in targetDates) {
      try {
        final summaryIndex = summaries.indexWhere(
          (item) => item.dateLocal == date,
        );
        if (summaryIndex == -1) {
          continue;
        }

        final currentSummary = summaries[summaryIndex];
        final history = summaries.sublist(0, summaryIndex + 1);
        final prior = summaries.sublist(0, summaryIndex);
        final baseline = _buildBaseline(prior);
        final targetDayEnd = DateTime.parse('${date}T23:59:59Z');
        final symptomWindowEnd = summaryIndex == summaries.length - 1 &&
                _nowProvider().isAfter(targetDayEnd)
            ? _nowProvider()
            : targetDayEnd;
        final symptomWindowStart = symptomWindowEnd.subtract(
          const Duration(hours: 48),
        );
        final symptoms = await _repository.getSymptomsBetween(
          start: symptomWindowStart,
          end: symptomWindowEnd,
        );

        // Cosinor features computed by CosinorService during health sync (before this call).
        final cosinor = await _repository.getCosinorFeature(date);
        final recentCosinor = await _repository.getCosinorFeaturesInRange(
          _offsetDate(date, -7),
          _offsetDate(date, -1),
        );
        final flareLabel = await _repository.getFlareLabel(date);
        final contextFeature = await _contextAttributionService.recomputeDate(
          date,
        );
        final recentCheckIns = await _repository.getPro2SurveysInRange(
          _offsetDate(date, -6),
          date,
        );

        // Lab contribution for this date (using 30-day lookback window)
        final candidateLabs = _labsForDate(date, labsByKey);
        final labContribution =
            _labRiskContributionService?.computeContribution(
                  dateLocal: date,
                  candidateLabs: candidateLabs,
                  userBaselineByLabType: userBaselines,
                  diagnosisCategory: userDiagnosisCategory,
                  userSex: userSex,
                ) ??
                LabRiskContribution.empty;

        final featureJson = _buildFeatureJson(
          date: date,
          history: history,
          currentSummary: currentSummary,
          baseline: baseline,
          symptoms: symptoms,
          syncState: syncState,
          cosinor: cosinor,
          recentCosinor: recentCosinor,
          userCovariates: userCovariates.toFeatureJson(),
          contextFeatures: contextFeature.featureJson,
          flareLabel: flareLabel,
          recentCheckIns: recentCheckIns,
          watchCapability: watchCapability,
          labContribution: labContribution,
        );
        final missingness = _buildMissingness(
          currentSummary: currentSummary,
          baselineReadiness: baseline.readinessState,
          syncState: syncState,
          watchCapability: watchCapability,
        );

        final score = _buildScore(
          featureJson: featureJson,
          missingness: missingness,
          baseline: baseline,
        );
        await _repository.upsertFlareRiskScore(
          FlareRiskScoreRecord(
            dateLocal: date,
            riskScore: score.riskScore,
            riskBand: score.riskBand,
            confidenceScore: score.confidenceScore,
            contributionJson: score.contributionJson,
            featureSnapshotJson: featureJson,
            modelVersion: modelVersion,
            createdAt: _nowProvider(),
          ),
        );

        final productionScore = _productionRiskAdjustmentService.adjust(
          baseScore: score.riskScore,
          baseConfidence: score.confidenceScore,
          baseRiskBand: score.riskBand,
          featureJson: featureJson,
          contributionJson: score.contributionJson,
        );
        featureJson.addAll(productionScore.featureUpdates);
        final productionScoreRecord = FlareRiskScoreRecord(
          dateLocal: date,
          riskScore: productionScore.riskScore,
          riskBand: productionScore.riskBand,
          confidenceScore: productionScore.confidenceScore,
          contributionJson: productionScore.contributionJson,
          featureSnapshotJson: featureJson,
          modelVersion: productionModelVersion,
          createdAt: _nowProvider(),
        );
        await _repository.upsertFlareRiskScore(productionScoreRecord);

        // Score stability gate: only update the session-displayed score when
        // the change is clinically meaningful (≥5 pts) or user-triggered.
        final gate = _scoreStabilityGate;
        if (gate != null && sessionId != null) {
          final gateResult = await gate.evaluateRecomputed(
            recomputed: productionScoreRecord,
            sessionId: sessionId,
            triggerReason: triggerReason ?? 'background_sync',
            isUserAction: isUserAction,
          );
          await _diagnosticLogService?.debug(
            gateResult.displayUpdated
                ? 'score_changed'
                : 'score_recomputed_no_change',
            category: DiagnosticLogService.categoryHealthSync,
            metadata: {
              'gate_decision': gateResult.gateDecision,
              'delta': gateResult.delta,
              'trigger_reason': triggerReason,
              'is_user_action': isUserAction,
              'session_id': sessionId,
            },
          );
        }

        // Paper-based logistic model (14 models: 7 horizons × 2 flare types).
        // Runs after heuristic so featureJson is already built — no double-querying.
        // Safe to call even before training data accumulates (prior weights handle cold start).
        final logistic = _logisticRiskService;
        if (logistic != null) {
          final logisticPredictions =
              await logistic.recomputeForDateWithFeatures(date, featureJson);
          for (final horizon in LogisticRiskService.horizons) {
            final horizonPredictions = logisticPredictions
                .where((prediction) => prediction.horizonDays == horizon)
                .toList(growable: false);
            if (horizonPredictions.isEmpty) {
              featureJson['logistic_p_flare_${horizon}d'] = null;
              continue;
            }
            final maxProbability = horizonPredictions
                .map((prediction) => prediction.probability)
                .reduce((left, right) => left > right ? left : right);
            final maxTrainingSamples = horizonPredictions
                .map((prediction) => prediction.trainingSamples)
                .reduce((left, right) => left > right ? left : right);
            final maxDisplayProbability = horizonPredictions
                .map(
                  (prediction) =>
                      LogisticRiskService.calibrateDisplayProbability(
                    rawProbability: prediction.probability,
                    trainingSamples: prediction.trainingSamples,
                  ),
                )
                .reduce((left, right) => left > right ? left : right);
            final stabilizedProbability = _stabilizeLogisticDisplayProbability(
              probability: maxDisplayProbability,
              horizonDays: horizon,
              featureJson: featureJson,
              contributionJson: productionScore.contributionJson,
            );
            featureJson['logistic_p_flare_${horizon}d'] = stabilizedProbability;
            featureJson['logistic_p_flare_${horizon}d_uncapped'] =
                maxDisplayProbability;
            featureJson['logistic_p_flare_${horizon}d_raw'] = maxProbability;
            featureJson['logistic_${horizon}d_signal_guard_applied'] =
                stabilizedProbability + 1e-6 < maxDisplayProbability ? 1 : 0;
            featureJson['logistic_${horizon}d_cold_start'] =
                maxTrainingSamples < LogisticPrediction.minimumTrainingSamples
                    ? 1
                    : 0;
          }

          for (final prediction in logisticPredictions) {
            final displayProbability =
                LogisticRiskService.calibrateDisplayProbability(
              rawProbability: prediction.probability,
              trainingSamples: prediction.trainingSamples,
            );
            await _repository.upsertFlareRiskScore(
              FlareRiskScoreRecord(
                dateLocal: date,
                riskScore: displayProbability * 100,
                riskBand: _logisticRiskBand(displayProbability),
                confidenceScore: prediction.hasEnoughData
                    ? 90
                    : (prediction.trainingSamples /
                            LogisticPrediction.minimumTrainingSamples *
                            60)
                        .clamp(5, 60)
                        .toDouble(),
                contributionJson: {
                  'model_family': LogisticRiskService.modelVersion,
                  'model_key': prediction.modelKey,
                  'flare_type': prediction.flareType,
                  'horizon_days': prediction.horizonDays,
                  'probability': displayProbability,
                  'raw_probability': prediction.probability,
                  'training_samples': prediction.trainingSamples,
                  'minimum_training_samples':
                      LogisticPrediction.minimumTrainingSamples,
                  'cold_start': !prediction.hasEnoughData,
                  'status': prediction.hasEnoughData ? 'trained' : 'cold_start',
                  'local_diagnostic_only': true,
                },
                featureSnapshotJson: featureJson,
                modelVersion: prediction.modelKey,
                createdAt: _nowProvider(),
              ),
            );
          }
        } else {
          for (final horizon in LogisticRiskService.horizons) {
            featureJson['logistic_p_flare_${horizon}d'] = null;
            featureJson['logistic_${horizon}d_cold_start'] = 1;
          }
        }

        await _repository.upsertFlareRiskScore(
          FlareRiskScoreRecord(
            dateLocal: productionScoreRecord.dateLocal,
            riskScore: productionScoreRecord.riskScore,
            riskBand: productionScoreRecord.riskBand,
            confidenceScore: productionScoreRecord.confidenceScore,
            contributionJson: productionScoreRecord.contributionJson,
            featureSnapshotJson: featureJson,
            modelVersion: productionScoreRecord.modelVersion,
            createdAt: _nowProvider(),
          ),
        );

        await _repository.upsertDailyFeature(
          DailyFeatureRecord(
            featureDateLocal: date,
            featureJson: featureJson,
            missingnessJson: missingness,
            recomputedAt: _nowProvider(),
          ),
        );

        recomputed.add(date);
      } catch (_) {
        failed.add(date);
      }
    }

    return RiskEngineComputationResult(
      recomputedDates: recomputed,
      failedDates: failed,
    );
  }

  List<String> _expandDates({
    required List<String> inputDates,
    required List<String> summaryDates,
  }) {
    final requested = inputDates.toSet();
    final expanded = <String>{...requested};
    for (var index = 0; index < summaryDates.length; index++) {
      final current = summaryDates[index];
      if (!requested.contains(current)) {
        continue;
      }
      final end = (index + 6).clamp(index, summaryDates.length - 1);
      for (var nextIndex = index; nextIndex <= end; nextIndex++) {
        expanded.add(summaryDates[nextIndex]);
      }
    }
    return expanded.toList()..sort();
  }

  Map<String, Object?> _buildFeatureJson({
    required String date,
    required List<DailySummaryRecord> history,
    required DailySummaryRecord currentSummary,
    required _BaselineView baseline,
    required List<SymptomRecord> symptoms,
    required SyncStateRecord? syncState,
    CosinorFeatureRecord? cosinor,
    required List<CosinorFeatureRecord> recentCosinor,
    required Map<String, Object?> userCovariates,
    required Map<String, Object?> contextFeatures,
    required FlareLabelRecord? flareLabel,
    required List<Pro2SurveyRecord> recentCheckIns,
    required AppleWatchModelCapability watchCapability,
    LabRiskContribution labContribution = LabRiskContribution.empty,
  }) {
    final priorHistory = history.length > 1
        ? history.sublist(0, history.length - 1)
        : const <DailySummaryRecord>[];
    final hrv3 = _meanFromSummaries(history, 'hrv_sdnn_mean', window: 3);
    final hrv7 = _meanFromSummaries(history, 'hrv_sdnn_mean', window: 7);
    final rhr3 = _meanFromSummaries(history, 'resting_hr_mean', window: 3);
    final sleep3 = _meanFromSummaries(
      history,
      'sleep_total_minutes',
      window: 3,
    );
    final steps7 = _meanFromSummaries(history, 'step_count_total', window: 7);
    final spo27 = _meanFromSummaries(
      history,
      'spo2_mean',
      window: 7,
      countKey: 'spo2_count',
      minimumCount: 3,
    );
    final temp3 = _meanFromSummaries(history, 'wrist_temp_mean', window: 3);
    final respiratory3 = _meanFromSummaries(
      history,
      'respiratory_rate_mean',
      window: 3,
    );
    final respiratoryBaseline = _winsorizedMean(
      _metricSeries(
        priorHistory,
        'respiratory_rate_mean',
        countKey: 'respiratory_rate_count',
      ),
    );
    final sleepDeepPct = _sleepStagePct(
      currentSummary,
      'sleep_asleep_deep_minutes',
    );
    final sleepRemPct = _sleepStagePct(
      currentSummary,
      'sleep_asleep_rem_minutes',
    );
    final baselineDeepPct = _meanSleepStagePct(
      history.take(history.length - 1).toList(growable: false),
      'sleep_asleep_deep_minutes',
    );
    final baselineRemPct = _meanSleepStagePct(
      history.take(history.length - 1).toList(growable: false),
      'sleep_asleep_rem_minutes',
    );
    final hrv14Slope = _linearSlopeFromSummaries(
      history,
      'hrv_sdnn_mean',
      window: 14,
    );
    final rhr14Slope = _linearSlopeFromSummaries(
      history,
      'resting_hr_mean',
      window: 14,
    );
    final steps14Slope = _linearSlopeFromSummaries(
      history,
      'step_count_total',
      window: 14,
    );
    final mobilityDeclineSignal = _mobilityDeclineSignal(
      current: currentSummary,
      prior: priorHistory,
    );

    final ibdRelevantSymptoms = symptoms
        .where((item) => _isIbdRiskRelevantSymptomType(item.symptomType))
        .toList(growable: false);
    final symptomCountAll = symptoms.length;
    final symptomCount = ibdRelevantSymptoms.length;
    final symptomMaxSeverity = ibdRelevantSymptoms.fold<int>(
      0,
      (max, item) =>
          item.severity != null && item.severity! > max ? item.severity! : max,
    );
    final symptomWeightedSum = ibdRelevantSymptoms.fold<int>(
      0,
      (sum, item) => sum + (item.severity ?? 1),
    );
    final painIntensity = _normalizedSymptomSignal(
      symptoms: ibdRelevantSymptoms,
      symptomTypes: const {'abdominal_pain', 'pain', 'cramping'},
    );
    final urgencyPresent = ibdRelevantSymptoms.any(
      (item) => item.symptomType == 'urgency',
    );
    final fatigueSignal = _normalizedSymptomSignal(
      symptoms: ibdRelevantSymptoms,
      symptomTypes: const {'fatigue'},
    );
    final dietaryTrigger = ibdRelevantSymptoms.any(
      (item) => (item.mealRelation ?? '').startsWith('after_'),
    );
    final cosinorMesor3dDelta = _cosinorDelta(
      current: cosinor?.mesor,
      recent: recentCosinor
          .map((item) => item.mesor)
          .whereType<double>()
          .toList(growable: false),
      window: 3,
    );
    final cosinorAmplitude7dDelta = _cosinorDelta(
      current: cosinor?.amplitude,
      recent: recentCosinor
          .map((item) => item.amplitude)
          .whereType<double>()
          .toList(growable: false),
      window: 7,
    );
    final checkInFeatures = _checkInFeatureJson(
      date: date,
      recentCheckIns: recentCheckIns,
    );
    final coreSignalCount = [
      hrv3,
      rhr3,
      sleep3,
      steps7,
      spo27,
      temp3,
      respiratory3,
    ].whereType<num>().length;
    final coreSignalCoverageRatio = coreSignalCount / 7.0;
    final hasSparseSignalContext =
        coreSignalCoverageRatio < 0.5 || symptomCountAll == 0;

    final featureJson = <String, Object?>{
      'feature_version': 1,
      'date_local': date,
      'watch_model_id': watchCapability.id,
      'watch_model_label': watchCapability.label,
      'baseline_readiness': baseline.readinessState,
      'baseline_valid_days': baseline.validDays,
      'current_sync_quality_score': currentSummary.syncQualityScore,
      'hrv_3d_mean': hrv3,
      'hrv_7d_mean': hrv7,
      'hrv_3d_pct_delta_vs_baseline': _percentDelta(
        hrv3,
        baseline.hrv,
        invertDirection: true,
      ),
      'hrv_7d_pct_delta_vs_baseline': _percentDelta(
        hrv7,
        baseline.hrv,
        invertDirection: true,
      ),
      'rhr_3d_mean': rhr3,
      'rhr_3d_delta_vs_baseline': _absoluteDelta(rhr3, baseline.restingHr),
      'sleep_3d_mean_minutes': sleep3,
      'sleep_3d_pct_delta_vs_baseline': _percentDelta(
        sleep3,
        baseline.sleepMinutes,
        invertDirection: true,
      ),
      'steps_7d_mean': steps7,
      'steps_7d_pct_delta_vs_baseline': _percentDelta(
        steps7,
        baseline.steps,
        invertDirection: true,
      ),
      'spo2_7d_mean': spo27,
      'spo2_7d_delta_vs_baseline': _absoluteDelta(
        spo27,
        baseline.spo2,
        invertDirection: true,
      ),
      'temp_3d_mean': temp3,
      'temp_3d_delta_vs_baseline': _absoluteDelta(temp3, baseline.temp),
      'respiratory_rate_3d_mean': respiratory3,
      'respiratory_rate_3d_delta_vs_baseline': _absoluteDelta(
        respiratory3,
        respiratoryBaseline,
      ),
      'sleep_deep_pct': sleepDeepPct,
      'sleep_rem_pct': sleepRemPct,
      'sleep_deep_7d_delta': _absoluteDelta(sleepDeepPct, baselineDeepPct),
      'sleep_rem_7d_delta': _absoluteDelta(sleepRemPct, baselineRemPct),
      'hrv_14d_slope': hrv14Slope,
      'rhr_14d_slope': rhr14Slope,
      'steps_14d_slope': steps14Slope,
      'symptom_count_48h': symptomCount,
      'symptom_count_48h_all': symptomCountAll,
      'symptom_count_48h_non_ibd': symptomCountAll - symptomCount,
      'symptom_max_severity_48h': symptomMaxSeverity,
      'symptom_weighted_sum_48h': symptomWeightedSum,
      'core_signal_count_7d': coreSignalCount,
      'core_signal_coverage_ratio_7d': coreSignalCoverageRatio,
      'sparse_signal_context': hasSparseSignalContext ? 1 : 0,
      'llm_pain_intensity': painIntensity,
      'llm_urgency_present': urgencyPresent ? 1 : 0,
      'llm_fatigue_signal': fatigueSignal,
      'llm_dietary_trigger': dietaryTrigger ? 1 : 0,
      ...checkInFeatures,
      'workout_count': currentSummary.summaryJson['workout_count'],
      'workout_minutes_total':
          currentSummary.summaryJson['workout_minutes_total'],
      'active_energy_kcal_total':
          currentSummary.summaryJson['active_energy_kcal_total'],
      'exercise_minutes_total':
          currentSummary.summaryJson['exercise_minutes_total'],
      'walking_running_distance_m_total':
          currentSummary.summaryJson['walking_running_distance_m_total'],
      'walking_hr_avg_mean': currentSummary.summaryJson['walking_hr_avg_mean'],
      'heart_rate_recovery_1min_mean':
          currentSummary.summaryJson['heart_rate_recovery_1min_mean'],
      'vo2_max_latest': currentSummary.summaryJson['vo2_max_latest'],
      'apple_health_symptom_count':
          currentSummary.summaryJson['apple_health_symptom_count'],
      'dietary_caffeine_mg_total':
          currentSummary.summaryJson['dietary_caffeine_mg_total'],
      'dietary_water_ml_total':
          currentSummary.summaryJson['dietary_water_ml_total'],
      'alcoholic_beverages_total':
          currentSummary.summaryJson['alcoholic_beverages_total'],
      'mobility_decline_signal': mobilityDeclineSignal,
      'walking_speed_mean': currentSummary.summaryJson['walking_speed_mean'],
      'walking_step_length_mean':
          currentSummary.summaryJson['walking_step_length_mean'],
      'walking_asymmetry_pct_mean':
          currentSummary.summaryJson['walking_asymmetry_pct_mean'],
      'walking_double_support_pct_mean':
          currentSummary.summaryJson['walking_double_support_pct_mean'],
      'rhythm_reliability_warning_count':
          currentSummary.summaryJson['rhythm_reliability_warning_count'],
      'clinical_anchor_inflammatory':
          flareLabel?.inflammatoryFlare == true ? 1 : 0,
      'clinical_anchor_symptomatic':
          flareLabel?.symptomaticFlare == true ? 1 : 0,
      'clinical_anchor_endoscopy': flareLabel?.clinicalFlare == true ? 1 : 0,
      'stale_sync_hours': _staleSyncHours(syncState),
      // Cosinor circadian rhythm parameters (paper Supplementary Eq. 1).
      // Only populated when CosinorService has produced a valid fit for this date.
      'hrv_cosinor_mesor': cosinor?.fitValid == true ? cosinor!.mesor : null,
      'hrv_cosinor_amplitude':
          cosinor?.fitValid == true ? cosinor!.amplitude : null,
      'hrv_cosinor_acrophase':
          cosinor?.fitValid == true ? cosinor!.acrophaseRad : null,
      'hrv_cosinor_peak_time_hours':
          cosinor?.fitValid == true ? cosinor!.peakTimeHours : null,
      'hrv_cosinor_fit_valid': cosinor?.fitValid == true ? 1 : 0,
      'hrv_cosinor_mesor_3d_delta': cosinorMesor3dDelta,
      'hrv_cosinor_amplitude_7d_delta': cosinorAmplitude7dDelta,
      'cosinor_mesor': cosinor?.fitValid == true ? cosinor!.mesor : null,
      'cosinor_amplitude':
          cosinor?.fitValid == true ? cosinor!.amplitude : null,
      'cosinor_acrophase_rad':
          cosinor?.fitValid == true ? cosinor!.acrophaseRad : null,
      'cosinor_peak_time_hours':
          cosinor?.fitValid == true ? cosinor!.peakTimeHours : null,
      'cosinor_r_squared': cosinor?.rSquared,
      'cosinor_fit_valid': cosinor?.fitValid == true ? 1 : 0,
      ..._defaultContextFeatures(),
      ...contextFeatures,
      ...userCovariates,
      // v20 lab contribution fields
      'lab_contribution_points': labContribution.points,
      'lab_contribution_decay': labContribution.decayFactor,
      'lab_dominant_type': labContribution.dominantLabType,
      'lab_dominant_value': labContribution.dominantLabValue,
      'lab_dominant_unit': labContribution.dominantLabUnit,
      'lab_confidence_boost': labContribution.confidenceBoost,
      'lab_narrative_key': labContribution.narrativeKey,
      'lab_present': labContribution.labsPresent ? 1 : 0,
    };
    return _applyWatchCapability(featureJson, watchCapability);
  }

  Map<String, Object?> _applyWatchCapability(
    Map<String, Object?> featureJson,
    AppleWatchModelCapability capability,
  ) {
    final unsupported = <String>[];
    void voidFeature(String family, List<String> keys) {
      if (capability.supportsRiskFeature(family)) return;
      unsupported.add(family);
      for (final key in keys) {
        featureJson[key] = null;
      }
      featureJson['unsupported_$family'] = 1;
    }

    voidFeature('spo2', const ['spo2_7d_mean', 'spo2_7d_delta_vs_baseline']);
    voidFeature('wrist_temperature', const [
      'temp_3d_mean',
      'temp_3d_delta_vs_baseline',
    ]);
    voidFeature('respiratory_rate', const [
      'respiratory_rate_3d_mean',
      'respiratory_rate_3d_delta_vs_baseline',
    ]);
    voidFeature('vo2_max', const ['vo2_max_latest']);
    featureJson['unsupported_watch_risk_features'] = unsupported;
    return featureJson;
  }

  bool _isIbdRiskRelevantSymptomType(String symptomType) {
    final normalized = symptomType.toLowerCase().trim();
    if (normalized.isEmpty) return false;
    return _ibdRiskRelevantSymptomTypes.contains(normalized);
  }

  Map<String, Object?> _defaultContextFeatures() {
    return const {
      'context_exercise_present': 0,
      'context_recovery_present': 0,
      'context_meal_present': 0,
      'context_caffeine_present': 0,
      'context_alcohol_present': 0,
      'context_low_hydration_possible': 0,
      'context_medication_missed_possible': 0,
      'context_clinical_anchor_present': 0,
      'context_rhythm_reliability_warning': 0,
      'context_hr_exercise_explained_pct': 0.0,
      'context_hr_meal_explained_pct': 0.0,
      'context_signal_family_count': 0,
      'context_false_negative_guard_triggered': 0,
      'context_attribution_reason': 'less_explained_by_activity',
      'context_confidence': 0.35,
    };
  }

  Map<String, Object?> _checkInFeatureJson({
    required String date,
    required List<Pro2SurveyRecord> recentCheckIns,
  }) {
    final today = recentCheckIns.where((item) => item.surveyDate == date);
    final todayCheckIn = today.isEmpty ? null : today.last;
    final summary = IbdCheckInService.sevenDaySummary(
      recentCheckIns.reversed.toList(growable: false),
    );
    if (todayCheckIn == null) {
      return {
        'checkin_present_today': 0,
        'checkin_completeness_score': 0.0,
        'checkin_disease_type_cd': 0,
        'checkin_disease_type_uc': 0,
        'checkin_core_symptom_score': 0.0,
        'checkin_pain_0_3': 0,
        'checkin_stool_bucket': 0,
        'checkin_bleeding_0_3': 0,
        'checkin_urgency_0_3': 0,
        'checkin_bloating_0_3': 0,
        'checkin_fatigue_0_3': 0,
        'checkin_nocturnal_stool_0_3': 0,
        'checkin_incomplete_evacuation_0_3': 0,
        'checkin_perianal_symptom_0_3': 0,
        'checkin_red_flag_count': 0,
        'checkin_completed_days_7d': summary['completed_days'],
        'checkin_days_with_bleeding_7d': summary['days_with_bleeding'],
        'checkin_days_with_urgency_7d': summary['days_with_urgency'],
        'checkin_days_with_fatigue_7d': summary['days_with_fatigue'],
      };
    }
    final evidence = IbdCheckInService.evidenceForSurvey(todayCheckIn);
    final core = Map<String, Object?>.from(evidence['core'] as Map);
    final details = Map<String, Object?>.from(evidence['details'] as Map);
    final redFlags = (evidence['red_flags'] as List?) ?? const [];
    final isCd = todayCheckIn.diseaseType == 'CD';
    final pain = _asDouble(core['abdominal_pain_0_3']) ??
        _asDouble(details['belly_or_rectal_pain_0_3']) ??
        0;
    final stool = _asDouble(core['loose_stool_bucket']) ??
        _asDouble(core['bathroom_frequency_0_3']) ??
        0;
    final bleeding = _asDouble(core['rectal_bleeding_0_3']) ??
        _asDouble(details['blood_0_3']) ??
        0;
    final urgency = _asDouble(details['urgency_0_3']) ?? 0;
    final bloating = _asDouble(details['bloating_0_3']) ?? 0;
    final fatigue = _asDouble(details['fatigue_0_3']) ?? 0;
    final nocturnal = _asDouble(details['nocturnal_bathroom_0_3']) ?? 0;
    final incomplete = _asDouble(details['incomplete_evacuation_0_3']) ?? 0;
    final perianal = _asDouble(details['perianal_symptom_0_3']) ?? 0;
    final optionalBurden = [
      urgency,
      bloating,
      fatigue,
      nocturnal,
      incomplete,
      perianal,
      bleeding,
    ].reduce((a, b) => a > b ? a : b);
    return {
      'checkin_present_today': todayCheckIn.surveyDate == date ? 1 : 0,
      'checkin_completeness_score': IbdCheckInService.completionScore(
        todayCheckIn,
      ),
      'checkin_disease_type_cd': isCd ? 1 : 0,
      'checkin_disease_type_uc': isCd ? 0 : 1,
      'checkin_core_symptom_score': todayCheckIn.pro2Score,
      'checkin_symptom_burden':
          (todayCheckIn.pro2Score + optionalBurden).clamp(0.0, 12.0).toDouble(),
      'checkin_pain_0_3': pain.round(),
      'checkin_stool_bucket': stool.round(),
      'checkin_bleeding_0_3': bleeding.round(),
      'checkin_urgency_0_3': urgency.round(),
      'checkin_bloating_0_3': bloating.round(),
      'checkin_fatigue_0_3': fatigue.round(),
      'checkin_nocturnal_stool_0_3': nocturnal.round(),
      'checkin_incomplete_evacuation_0_3': incomplete.round(),
      'checkin_perianal_symptom_0_3': perianal.round(),
      'checkin_red_flag_count': redFlags.length,
      'checkin_completed_days_7d': summary['completed_days'],
      'checkin_days_with_bleeding_7d': summary['days_with_bleeding'],
      'checkin_days_with_urgency_7d': summary['days_with_urgency'],
      'checkin_days_with_fatigue_7d': summary['days_with_fatigue'],
    };
  }

  int _mobilityDeclineSignal({
    required DailySummaryRecord current,
    required List<DailySummaryRecord> prior,
  }) {
    if (prior.isEmpty) {
      return 0;
    }
    var signal = 0;
    final currentWalkingSpeed = _asDouble(
      current.summaryJson['walking_speed_mean'],
    );
    final baselineWalkingSpeed = _winsorizedMean(
      _metricSeries(prior, 'walking_speed_mean'),
    );
    if (currentWalkingSpeed != null &&
        baselineWalkingSpeed != null &&
        baselineWalkingSpeed > 0 &&
        currentWalkingSpeed < baselineWalkingSpeed * 0.9) {
      signal += 1;
    }

    final currentStepLength = _asDouble(
      current.summaryJson['walking_step_length_mean'],
    );
    final baselineStepLength = _winsorizedMean(
      _metricSeries(prior, 'walking_step_length_mean'),
    );
    if (currentStepLength != null &&
        baselineStepLength != null &&
        baselineStepLength > 0 &&
        currentStepLength < baselineStepLength * 0.9) {
      signal += 1;
    }

    final currentDoubleSupport = _asDouble(
      current.summaryJson['walking_double_support_pct_mean'],
    );
    final baselineDoubleSupport = _winsorizedMean(
      _metricSeries(prior, 'walking_double_support_pct_mean'),
    );
    if (currentDoubleSupport != null &&
        baselineDoubleSupport != null &&
        currentDoubleSupport > baselineDoubleSupport + 5) {
      signal += 1;
    }

    final currentAsymmetry = _asDouble(
      current.summaryJson['walking_asymmetry_pct_mean'],
    );
    final baselineAsymmetry = _winsorizedMean(
      _metricSeries(prior, 'walking_asymmetry_pct_mean'),
    );
    if (currentAsymmetry != null &&
        baselineAsymmetry != null &&
        currentAsymmetry > baselineAsymmetry + 5) {
      signal += 1;
    }
    return signal.clamp(0, 4).toInt();
  }

  Map<String, Object?> _buildMissingness({
    required DailySummaryRecord currentSummary,
    required String baselineReadiness,
    required SyncStateRecord? syncState,
    required AppleWatchModelCapability watchCapability,
  }) {
    final summary = currentSummary.summaryJson;
    final staleSyncHours = _staleSyncHours(syncState);
    final supportsSpo2 = watchCapability.supportsRiskFeature('spo2');
    final supportsTemp = watchCapability.supportsRiskFeature(
      'wrist_temperature',
    );
    final supportsRespiratory = watchCapability.supportsRiskFeature(
      'respiratory_rate',
    );
    final supportsVo2 = watchCapability.supportsRiskFeature('vo2_max');
    return {
      'missing_hrv': summary['hrv_sdnn_mean'] == null,
      'missing_resting_hr': summary['resting_hr_mean'] == null,
      'missing_sleep': summary['sleep_total_minutes'] == null,
      'missing_steps': summary['step_count_total'] == null,
      'missing_spo2': supportsSpo2 &&
          (summary['spo2_mean'] == null ||
              (((summary['spo2_count'] as num?)?.toInt() ?? 0) < 3)),
      'missing_temp': supportsTemp && summary['wrist_temp_mean'] == null,
      'missing_respiratory_rate':
          supportsRespiratory && summary['respiratory_rate_mean'] == null,
      'missing_vo2_max': supportsVo2 && summary['vo2_max_latest'] == null,
      'unsupported_spo2': !supportsSpo2,
      'unsupported_temp': !supportsTemp,
      'unsupported_respiratory_rate': !supportsRespiratory,
      'unsupported_vo2_max': !supportsVo2,
      'baseline_not_ready': baselineReadiness == 'not_ready',
      'baseline_low_confidence': baselineReadiness == 'low_confidence',
      'stale_sync': staleSyncHours != null && staleSyncHours > 72,
    };
  }

  _ScoreView _buildScore({
    required Map<String, Object?> featureJson,
    required Map<String, Object?> missingness,
    required _BaselineView baseline,
  }) {
    final hrvDrop = _maxDouble([
      _asDouble(featureJson['hrv_3d_pct_delta_vs_baseline']),
      _asDouble(featureJson['hrv_7d_pct_delta_vs_baseline']),
    ]);
    final hrvContribution = _piecewise(
      hrvDrop,
      thresholds: const [5, 10, 15],
      scores: const [0, 8, 16, 25],
    );
    final rhrContribution = _piecewise(
      _asDouble(featureJson['rhr_3d_delta_vs_baseline']),
      thresholds: const [2, 4, 7],
      scores: const [0, 6, 12, 20],
    );
    // Cap sleep contribution at 7 pts when HRV/cosinor data is available.
    // Rationale: sleep disruption is correlated with HRV MESOR decline
    // (Hirten et al. 2025 supplementary). Including both double-counts the
    // same physiological state. When HRV data is absent, allow full 15 pts.
    final cosinorValid = (featureJson['cosinor_fit_valid'] as int? ?? 0) == 1;
    final hrvPresent =
        _asDouble(featureJson['hrv_3d_pct_delta_vs_baseline']) != null;
    final sleepCap = (cosinorValid || hrvPresent) ? 7 : 15;
    final sleepContribution = _piecewise(
      _asDouble(featureJson['sleep_3d_pct_delta_vs_baseline']),
      thresholds: const [5, 10, 20],
      scores: const [0, 5, 10, 15],
    ).clamp(0, sleepCap);
    final loggedSymptomContribution = _symptomContribution(
      weightedSum:
          (_asDouble(featureJson['symptom_weighted_sum_48h']) ?? 0).round(),
      maxSeverity:
          (_asDouble(featureJson['symptom_max_severity_48h']) ?? 0).round(),
    );
    final checkInSymptomContribution = _piecewise(
      _asDouble(featureJson['checkin_symptom_burden']),
      thresholds: const [2, 4, 7],
      scores: const [0, 3, 5, 8],
    );
    final symptomContribution =
        (loggedSymptomContribution + checkInSymptomContribution)
            .clamp(0, 20)
            .toInt();
    final stepsContribution = _piecewise(
      _asDouble(featureJson['steps_7d_pct_delta_vs_baseline']),
      thresholds: const [10, 20, 35],
      scores: const [0, 4, 7, 10],
    );
    final sparseContribution = _maxInt([
      _piecewise(
        _asDouble(featureJson['spo2_7d_delta_vs_baseline']),
        thresholds: const [1, 2, 3],
        scores: const [0, 4, 7, 10],
      ),
      _piecewise(
        _asDouble(featureJson['temp_3d_delta_vs_baseline']),
        thresholds: const [0.3, 0.5, 0.8],
        scores: const [0, 4, 7, 10],
      ),
    ]);

    final labPoints =
        ((_asDouble(featureJson['lab_contribution_points']) ?? 0).round())
            .clamp(0, 30);
    final rawScore = (hrvContribution +
            rhrContribution +
            sleepContribution +
            symptomContribution +
            stepsContribution +
            sparseContribution +
            labPoints)
        .clamp(0, 100)
        .toInt();

    final syncQualityScore =
        (_asDouble(featureJson['current_sync_quality_score']) ?? 0)
            .clamp(0.0, 1.0)
            .toDouble();
    final availableMetricFamilies = [
      missingness['missing_hrv'] != true,
      missingness['missing_resting_hr'] != true,
      missingness['missing_sleep'] != true,
      missingness['missing_steps'] != true,
      missingness['missing_spo2'] != true ||
          missingness['missing_temp'] != true,
    ].where((item) => item).length;
    final activeSignalFamilies = [
      hrvContribution > 0,
      rhrContribution > 0,
      sleepContribution > 0 || stepsContribution > 0,
      sparseContribution > 0,
      symptomContribution > 0,
      labPoints > 0,
    ].where((item) => item).length;

    final baselineComponent = switch (baseline.readinessState) {
      'ready' => baseline.validDays >= 21 ? 0.92 : 0.82,
      'low_confidence' => 0.55,
      _ => 0.05,
    };
    final coverageComponent =
        (availableMetricFamilies / 5).clamp(0.2, 1.0).toDouble();
    final freshnessComponent = missingness['stale_sync'] == true ? 0.3 : 1.0;
    final qualityComponent =
        (0.4 + (syncQualityScore * 0.6)).clamp(0.4, 1.0).toDouble();
    final checkInComponent =
        ((_asDouble(featureJson['checkin_present_today']) ?? 0) > 0
                ? (_asDouble(featureJson['checkin_completeness_score']) ?? 0.4)
                : 0.0)
            .clamp(0.0, 1.0)
            .toDouble();

    double corroborationComponent;
    if (rawScore < 20) {
      if (availableMetricFamilies >= 4) {
        corroborationComponent = 0.75;
      } else if (availableMetricFamilies >= 3) {
        corroborationComponent = 0.6;
      } else {
        corroborationComponent = 0.45;
      }
    } else {
      switch (activeSignalFamilies) {
        case >= 4:
          corroborationComponent = 1.0;
          break;
        case 3:
          corroborationComponent = 0.88;
          break;
        case 2:
          corroborationComponent = 0.72;
          break;
        case 1:
          corroborationComponent = 0.45;
          break;
        default:
          corroborationComponent = 0.35;
      }
      if (rhrContribution > 0 && activeSignalFamilies == 1) {
        corroborationComponent = 0.25;
      }
      if (symptomContribution > 0 && activeSignalFamilies >= 2) {
        corroborationComponent += 0.05;
      }
    }

    var weightedConfidence = 100 *
        ((baselineComponent * 0.4) +
            (coverageComponent * 0.25) +
            (freshnessComponent * 0.15) +
            (qualityComponent * 0.1) +
            (corroborationComponent.clamp(0.2, 1.0) * 0.1));
    if (rawScore >= 35 && activeSignalFamilies <= 1) {
      weightedConfidence -= 12;
    }
    if (rawScore >= 60 && activeSignalFamilies >= 3) {
      weightedConfidence += 4;
    }
    if (checkInComponent > 0) {
      weightedConfidence += 4 * checkInComponent;
    }
    if (missingness['baseline_not_ready'] == true &&
        availableMetricFamilies <= 2 &&
        missingness['stale_sync'] == true) {
      weightedConfidence -= 6;
    }
    final labConfBoost =
        ((_asDouble(featureJson['lab_confidence_boost']) ?? 0)).toInt();
    weightedConfidence += labConfBoost;

    final boundedConfidence = weightedConfidence.clamp(12, 96).toDouble();
    final boundedScore = rawScore.clamp(0, 100).toDouble();

    return _ScoreView(
      riskScore: boundedScore,
      confidenceScore: boundedConfidence,
      riskBand: _riskBand(boundedScore),
      contributionJson: {
        'hrv_points': hrvContribution,
        'resting_hr_points': rhrContribution,
        'sleep_points': sleepContribution,
        'symptom_points': symptomContribution,
        'logged_symptom_points': loggedSymptomContribution,
        'checkin_symptom_points': checkInSymptomContribution,
        'steps_points': stepsContribution,
        'sparse_vitals_points': sparseContribution,
        'lab_points': labPoints,
        'lab_narrative_key': featureJson['lab_narrative_key'],
        'total_points': boundedScore.round(),
        'evidence_family_count': availableMetricFamilies,
        'active_signal_family_count': activeSignalFamilies,
        'confidence_components': {
          'baseline_maturity': (baselineComponent * 40).round(),
          'data_coverage': (coverageComponent * 25).round(),
          'sync_freshness': (freshnessComponent * 15).round(),
          'sync_quality': (qualityComponent * 10).round(),
          'signal_corroboration':
              (corroborationComponent.clamp(0.2, 1.0) * 10).round(),
          'checkin_quality': (checkInComponent * 4).round(),
        },
        'confidence_inputs': {
          'baseline_readiness': baseline.readinessState,
          'baseline_valid_days': baseline.validDays,
          'available_metric_families': availableMetricFamilies,
          'active_signal_families': activeSignalFamilies,
          'sync_quality_score': syncQualityScore,
          'stale_sync': missingness['stale_sync'] == true,
          'checkin_present_today':
              (_asDouble(featureJson['checkin_present_today']) ?? 0) > 0,
          'checkin_completeness_score': checkInComponent,
        },
        'confidence_adjustments': {
          'isolated_signal_penalty':
              rawScore >= 35 && activeSignalFamilies <= 1 ? -12 : 0,
          'multi_signal_boost':
              rawScore >= 60 && activeSignalFamilies >= 3 ? 4 : 0,
          'sparse_data_penalty': missingness['baseline_not_ready'] == true &&
                  availableMetricFamilies <= 2 &&
                  missingness['stale_sync'] == true
              ? -6
              : 0,
          'lab_confidence_boost': labConfBoost,
        },
      },
    );
  }

  _BaselineView _buildBaseline(List<DailySummaryRecord> prior) {
    final recent = prior.length > 28 ? prior.sublist(prior.length - 28) : prior;
    final validDays =
        recent.where((item) => _countCoreMetrics(item.summaryJson) >= 3).length;
    return _BaselineView(
      readinessState: _readinessState(validDays),
      validDays: validDays,
      hrv: _winsorizedMean(_metricSeries(recent, 'hrv_sdnn_mean')),
      restingHr: _winsorizedMean(_metricSeries(recent, 'resting_hr_mean')),
      sleepMinutes: _winsorizedMean(
        _metricSeries(recent, 'sleep_total_minutes'),
      ),
      steps: _winsorizedMean(_metricSeries(recent, 'step_count_total')),
      spo2: _winsorizedMean(
        _metricSeries(
          recent,
          'spo2_mean',
          countKey: 'spo2_count',
          minimumCount: 3,
        ),
      ),
      temp: _winsorizedMean(_metricSeries(recent, 'wrist_temp_mean')),
    );
  }

  double? _meanFromSummaries(
    List<DailySummaryRecord> history,
    String key, {
    required int window,
    String? countKey,
    int minimumCount = 1,
  }) {
    final slice = history.length > window
        ? history.sublist(history.length - window)
        : history;
    final values = _metricSeries(
      slice,
      key,
      countKey: countKey,
      minimumCount: minimumCount,
    );
    if (values.isEmpty) {
      return null;
    }
    return values.reduce((left, right) => left + right) / values.length;
  }

  double? _sleepStagePct(DailySummaryRecord summary, String stageKey) {
    final total =
        (summary.summaryJson['sleep_total_minutes'] as num?)?.toDouble();
    final stage = (summary.summaryJson[stageKey] as num?)?.toDouble();
    if (total == null || stage == null || total <= 0) {
      return null;
    }
    return stage / total;
  }

  double? _meanSleepStagePct(
    List<DailySummaryRecord> summaries,
    String stageKey,
  ) {
    final values = summaries
        .map((summary) => _sleepStagePct(summary, stageKey))
        .whereType<double>()
        .toList(growable: false);
    if (values.isEmpty) {
      return null;
    }
    return values.reduce((left, right) => left + right) / values.length;
  }

  double? _linearSlopeFromSummaries(
    List<DailySummaryRecord> history,
    String key, {
    required int window,
  }) {
    final slice = history.length > window
        ? history.sublist(history.length - window)
        : history;
    final pairs = <(double x, double y)>[];
    for (var index = 0; index < slice.length; index++) {
      final value = (slice[index].summaryJson[key] as num?)?.toDouble();
      if (value != null) {
        pairs.add((index.toDouble(), value));
      }
    }
    if (pairs.length < 2) {
      return null;
    }
    final xMean =
        pairs.map((pair) => pair.$1).reduce((left, right) => left + right) /
            pairs.length;
    final yMean =
        pairs.map((pair) => pair.$2).reduce((left, right) => left + right) /
            pairs.length;
    var numerator = 0.0;
    var denominator = 0.0;
    for (final pair in pairs) {
      numerator += (pair.$1 - xMean) * (pair.$2 - yMean);
      denominator += (pair.$1 - xMean) * (pair.$1 - xMean);
    }
    if (denominator == 0) {
      return null;
    }
    return numerator / denominator;
  }

  double? _normalizedSymptomSignal({
    required List<SymptomRecord> symptoms,
    required Set<String> symptomTypes,
  }) {
    final severities = symptoms
        .where((item) => symptomTypes.contains(item.symptomType))
        .map((item) => (item.severity ?? 0).toDouble())
        .toList(growable: false);
    if (severities.isEmpty) {
      return null;
    }
    return (severities.reduce((left, right) => left > right ? left : right) /
            10.0)
        .clamp(0.0, 1.0);
  }

  double? _cosinorDelta({
    required double? current,
    required List<double> recent,
    required int window,
  }) {
    if (current == null || recent.isEmpty) {
      return null;
    }
    final slice = recent.length > window
        ? recent.sublist(recent.length - window)
        : recent;
    final mean = slice.reduce((left, right) => left + right) / slice.length;
    return current - mean;
  }

  String _offsetDate(String dateStr, int days) {
    final date = DateTime.parse(
      '${dateStr}T00:00:00Z',
    ).add(Duration(days: days));
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  List<double> _metricSeries(
    List<DailySummaryRecord> summaries,
    String key, {
    String? countKey,
    int minimumCount = 1,
  }) {
    return summaries
        .where((summary) {
          if (countKey == null) {
            return true;
          }
          return ((summary.summaryJson[countKey] as num?)?.toInt() ?? 0) >=
              minimumCount;
        })
        .map((summary) => summary.summaryJson[key])
        .whereType<num>()
        .map((value) => value.toDouble())
        .toList(growable: false);
  }

  int _countCoreMetrics(Map<String, Object?> summaryJson) {
    var count = 0;
    if (summaryJson['hrv_sdnn_mean'] != null) count += 1;
    if (summaryJson['resting_hr_mean'] != null) count += 1;
    if (summaryJson['sleep_total_minutes'] != null) count += 1;
    if (summaryJson['step_count_total'] != null) count += 1;
    return count;
  }

  String _readinessState(int validDays) {
    if (validDays >= 28) return 'mature';
    if (validDays >= 14) return 'ready';
    if (validDays >= 7) return 'low_confidence';
    return 'not_ready';
  }

  double? _winsorizedMean(List<double> values) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    if (sorted.length < 5) {
      return sorted.reduce((left, right) => left + right) / sorted.length;
    }

    final lowIndex = (sorted.length * 0.1).floor().clamp(0, sorted.length - 1);
    final highIndex = (sorted.length * 0.9).floor().clamp(0, sorted.length - 1);
    final low = sorted[lowIndex];
    final high = sorted[highIndex];
    final adjusted = sorted.map((value) {
      if (value < low) return low;
      if (value > high) return high;
      return value;
    }).toList(growable: false);
    return adjusted.reduce((left, right) => left + right) / adjusted.length;
  }

  double? _percentDelta(
    double? value,
    double? baseline, {
    bool invertDirection = false,
  }) {
    if (value == null || baseline == null || baseline == 0) {
      return null;
    }
    final delta = ((value - baseline) / baseline) * 100;
    return invertDirection ? (-delta) : delta;
  }

  double? _absoluteDelta(
    double? value,
    double? baseline, {
    bool invertDirection = false,
  }) {
    if (value == null || baseline == null) {
      return null;
    }
    final delta = value - baseline;
    return invertDirection ? (-delta) : delta;
  }

  double? _staleSyncHours(SyncStateRecord? syncState) {
    final lastSyncAt = syncState?.lastSyncAt;
    if (lastSyncAt == null) {
      return null;
    }
    return _nowProvider().difference(lastSyncAt.toUtc()).inMinutes / 60;
  }

  double? _asDouble(Object? value) {
    return (value as num?)?.toDouble();
  }

  double? _maxDouble(List<double?> values) {
    final filtered = values.whereType<double>().toList(growable: false);
    if (filtered.isEmpty) {
      return null;
    }
    return filtered.reduce((left, right) => left > right ? left : right);
  }

  int _maxInt(List<int> values) {
    if (values.isEmpty) {
      return 0;
    }
    return values.reduce((left, right) => left > right ? left : right);
  }

  int _piecewise(
    double? value, {
    required List<double> thresholds,
    required List<int> scores,
  }) {
    if (value == null || value <= thresholds.first) {
      return scores.first;
    }
    for (var index = 1; index < thresholds.length; index++) {
      if (value <= thresholds[index]) {
        return scores[index];
      }
    }
    return scores.last;
  }

  int _symptomContribution({
    required int weightedSum,
    required int maxSeverity,
  }) {
    if (weightedSum >= 6 || maxSeverity >= 4) return 20;
    if (weightedSum >= 3 || maxSeverity >= 3) return 14;
    if (weightedSum >= 1 || maxSeverity >= 1) return 8;
    return 0;
  }

  String _riskBand(double score) {
    if (score >= 76) return 'critical';
    if (score >= 51) return 'high';
    if (score >= 26) return 'moderate';
    return 'low';
  }

  String _logisticRiskBand(double probability) {
    if (probability >= 0.50) return 'high';
    if (probability >= 0.30) return 'moderate';
    if (probability >= 0.15) return 'moderate';
    return 'low';
  }

  double _stabilizeLogisticDisplayProbability({
    required double probability,
    required int horizonDays,
    required Map<String, Object?> featureJson,
    required Map<String, Object?> contributionJson,
  }) {
    var stabilized = probability.clamp(0.05, 0.92).toDouble();

    final activeSignalFamilies =
        (contributionJson['active_signal_family_count'] as num?)?.toInt() ?? 0;
    final coreCoverage =
        (_asDouble(featureJson['core_signal_coverage_ratio_7d']) ?? 0)
            .clamp(0.0, 1.0)
            .toDouble();
    final checkinBurden =
        (_asDouble(featureJson['checkin_symptom_burden']) ?? 0).toDouble();
    final bleedingDays =
        (_asDouble(featureJson['checkin_days_with_bleeding_7d']) ?? 0).round();
    final inflammatoryAnchor =
        ((_asDouble(featureJson['clinical_anchor_inflammatory']) ?? 0) > 0) ||
            ((_asDouble(featureJson['clinical_anchor_symptomatic']) ?? 0) > 0);

    // Mount Sinai signal pattern support: large flare probabilities should be
    // corroborated by multiple physiologic changes (HRV, HR/RHR, steps, SpO2)
    // or explicit inflammatory anchors, not a single sparse signal.
    if (inflammatoryAnchor) {
      return stabilized;
    }

    double sparseCap;
    double mildCap;
    double mediumCap;
    switch (horizonDays) {
      case 7:
        sparseCap = 0.52;
        mildCap = 0.50;
        mediumCap = 0.72;
        break;
      case 14:
        sparseCap = 0.58;
        mildCap = 0.58;
        mediumCap = 0.78;
        break;
      case 21:
        sparseCap = 0.64;
        mildCap = 0.64;
        mediumCap = 0.84;
        break;
      default:
        sparseCap = 0.70;
        mildCap = 0.70;
        mediumCap = 0.88;
        break;
    }

    final mildSymptomContext = checkinBurden <= 2.5 && bleedingDays <= 0;

    if (activeSignalFamilies <= 1 && coreCoverage < 0.6) {
      stabilized = stabilized.clamp(0.05, sparseCap).toDouble();
    }
    if (activeSignalFamilies <= 1 && mildSymptomContext) {
      stabilized = stabilized.clamp(0.05, mildCap).toDouble();
    }
    if (activeSignalFamilies == 2 && coreCoverage < 0.6 && mildSymptomContext) {
      stabilized = stabilized.clamp(0.05, mediumCap).toDouble();
    }

    return stabilized.clamp(0.05, 0.92).toDouble();
  }

  // ── Lab helper methods ────────────────────────────────────────────────────

  /// Groups labs by '${labType}__${drawnDate}' after normalizing units.
  /// Returns a map keyed by that composite key.
  Map<String, List<LabValueRecord>> _groupAndNormalizeLabs(
    List<LabValueRecord> labs,
  ) {
    final map = <String, List<LabValueRecord>>{};
    for (final lab in labs) {
      final normalized = _labNormalizationService.normalize(
        value: lab.valueNumeric,
        rawUnit: lab.unit,
        labType: lab.labType,
      );
      if (normalized == null) continue; // unrecognized unit — skip
      final key = '${lab.labType}__${lab.drawnDate}';
      map.putIfAbsent(key, () => []).add(lab);
    }
    return map;
  }

  /// Returns labs whose drawnDate is within 30 days before [dateLocal].
  List<LabValueRecord> _labsForDate(
    String dateLocal,
    Map<String, List<LabValueRecord>> labsByKey,
  ) {
    final target = DateTime.tryParse(dateLocal);
    if (target == null) return const [];
    final cutoff = target.subtract(const Duration(days: 30));
    final result = <LabValueRecord>[];
    for (final entry in labsByKey.entries) {
      for (final lab in entry.value) {
        final drawn = DateTime.tryParse(lab.drawnDate);
        if (drawn == null) continue;
        if (!drawn.isAfter(target) && !drawn.isBefore(cutoff)) {
          result.add(lab);
        }
      }
    }
    return result;
  }

  /// Computes winsorized mean per labType from [recentLabs].
  /// Only returns an entry if ≥3 values are available for that type.
  Map<String, double> _computeUserLabBaselines(
    List<LabValueRecord> recentLabs,
  ) {
    final valuesByType = <String, List<double>>{};
    for (final lab in recentLabs) {
      final normalized = _labNormalizationService.normalize(
        value: lab.valueNumeric,
        rawUnit: lab.unit,
        labType: lab.labType,
      );
      if (normalized != null) {
        valuesByType.putIfAbsent(lab.labType, () => []).add(normalized);
      }
    }
    final baselines = <String, double>{};
    for (final entry in valuesByType.entries) {
      if (entry.value.length >= 3) {
        baselines[entry.key] = _winsorizedMeanValues(entry.value);
      }
    }
    return baselines;
  }

  /// Winsorizes bottom/top 10% of [values] and returns the mean of remainder.
  static double _winsorizedMeanValues(List<double> values) {
    if (values.isEmpty) return 0;
    if (values.length < 3) {
      return values.reduce((a, b) => a + b) / values.length;
    }
    final sorted = List<double>.from(values)..sort();
    final clip = (sorted.length * 0.1).ceil().clamp(1, sorted.length ~/ 3);
    final trimmed = sorted.sublist(clip, sorted.length - clip);
    if (trimmed.isEmpty) return sorted[sorted.length ~/ 2];
    return trimmed.reduce((a, b) => a + b) / trimmed.length;
  }
}

class _BaselineView {
  const _BaselineView({
    required this.readinessState,
    required this.validDays,
    required this.hrv,
    required this.restingHr,
    required this.sleepMinutes,
    required this.steps,
    required this.spo2,
    required this.temp,
  });

  final String readinessState;
  final int validDays;
  final double? hrv;
  final double? restingHr;
  final double? sleepMinutes;
  final double? steps;
  final double? spo2;
  final double? temp;
}

class _ScoreView {
  const _ScoreView({
    required this.riskScore,
    required this.riskBand,
    required this.confidenceScore,
    required this.contributionJson,
  });

  final double riskScore;
  final String riskBand;
  final double confidenceScore;
  final Map<String, Object?> contributionJson;
}
