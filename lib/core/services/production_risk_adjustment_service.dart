import 'false_negative_guard_service.dart';

class ProductionRiskAdjustmentResult {
  const ProductionRiskAdjustmentResult({
    required this.riskScore,
    required this.confidenceScore,
    required this.riskBand,
    required this.contributionJson,
    required this.featureUpdates,
  });

  final double riskScore;
  final double confidenceScore;
  final String riskBand;
  final Map<String, Object?> contributionJson;
  final Map<String, Object?> featureUpdates;
}

class ProductionRiskAdjustmentService {
  const ProductionRiskAdjustmentService({
    FalseNegativeGuardService falseNegativeGuardService =
        const FalseNegativeGuardService(),
  }) : _falseNegativeGuardService = falseNegativeGuardService;

  final FalseNegativeGuardService _falseNegativeGuardService;

  ProductionRiskAdjustmentResult adjust({
    required double baseScore,
    required double baseConfidence,
    required String baseRiskBand,
    required Map<String, Object?> featureJson,
    required Map<String, Object?> contributionJson,
  }) {
    var score = baseScore;
    var confidence = baseConfidence;
    var contextAdjustment = 0.0;
    final reasons = <String>[];

    final hrvPoints = _asDouble(contributionJson['hrv_points']) ?? 0;
    final rhrPoints = _asDouble(contributionJson['resting_hr_points']) ?? 0;
    final sleepPoints = _asDouble(contributionJson['sleep_points']) ?? 0;
    final symptomPoints = _asDouble(contributionJson['symptom_points']) ?? 0;
    final stepsPoints = _asDouble(contributionJson['steps_points']) ?? 0;
    final sparsePoints =
        _asDouble(contributionJson['sparse_vitals_points']) ?? 0;
    final labPoints = _asDouble(contributionJson['lab_points']) ?? 0;
    final labNarrativeKey =
        featureJson['lab_narrative_key'] as String? ?? 'no_labs_available';
    final respiratoryPoints = _respiratoryContribution(featureJson);
    final mobilityPoints = _mobilityContribution(featureJson);
    final clinicalPoints =
        (_asDouble(featureJson['context_clinical_anchor_present']) ?? 0) >= 1
            ? 15.0
            : 0.0;
    final medicationPoints =
        (_asDouble(featureJson['context_medication_missed_possible']) ?? 0) >= 1
            ? 8.0
            : 0.0;

    score +=
        respiratoryPoints + mobilityPoints + clinicalPoints + medicationPoints;

    final supportingNonHrSignals = [
      hrvPoints > 0,
      sleepPoints > 0,
      symptomPoints > 0 ||
          ((_asDouble(featureJson['apple_health_symptom_count']) ?? 0) > 0),
      stepsPoints > 0,
      sparsePoints > 0,
      respiratoryPoints > 0,
      mobilityPoints > 0,
      clinicalPoints > 0,
      medicationPoints > 0,
      labPoints > 0,
    ].where((item) => item).length;
    final hrDominant = rhrPoints >= 6 && supportingNonHrSignals <= 1;

    final exercisePct =
        _asDouble(featureJson['context_hr_exercise_explained_pct']) ?? 0;
    final mealPct =
        _asDouble(featureJson['context_hr_meal_explained_pct']) ?? 0;
    final workoutPresent =
        (_asDouble(featureJson['context_exercise_present']) ?? 0) >= 1 ||
            (_asDouble(featureJson['context_recovery_present']) ?? 0) >= 1;
    final mealPresent =
        (_asDouble(featureJson['context_meal_present']) ?? 0) >= 1 ||
            (_asDouble(featureJson['context_caffeine_present']) ?? 0) >= 1;

    if (hrDominant && (workoutPresent || exercisePct >= 0.35)) {
      final reduction = rhrPoints >= 12 ? 18.0 : 10.0;
      score -= reduction;
      contextAdjustment -= reduction;
      reasons.add('looks_workout_related');
    }
    if (hrDominant && (mealPresent || mealPct >= 0.2)) {
      final reduction = rhrPoints >= 12 ? 12.0 : 6.0;
      score -= reduction;
      contextAdjustment -= reduction;
      reasons.add('looks_meal_timed');
    }
    if ((_asDouble(featureJson['context_alcohol_present']) ?? 0) >= 1) {
      confidence -= 10;
      reasons.add('alcohol_can_distort_sleep_and_hrv');
    }
    if ((_asDouble(featureJson['context_rhythm_reliability_warning']) ?? 0) >=
        1) {
      confidence -= 15;
      reasons.add('heart_rhythm_data_harder_to_interpret');
    }

    final signalFamilyCount = _signalFamilyCount(
      hrvPoints: hrvPoints,
      rhrPoints: rhrPoints,
      sleepPoints: sleepPoints,
      symptomPoints: symptomPoints,
      stepsPoints: stepsPoints,
      sparsePoints: sparsePoints,
      respiratoryPoints: respiratoryPoints,
      mobilityPoints: mobilityPoints,
      clinicalPoints: clinicalPoints,
      medicationPoints: medicationPoints,
      labPoints: labPoints,
      featureJson: featureJson,
    );
    if (signalFamilyCount >= 3) {
      confidence += 5;
      reasons.add('multiple_signals_agree');
    }

    final falseNegativeGuard = _falseNegativeGuardService.evaluate(
      baseScore: score,
      featureJson: featureJson,
      contributionJson: contributionJson,
      signalFamilyCount: signalFamilyCount,
    );
    var falseNegativePoints = 0.0;
    if (falseNegativeGuard.triggered) {
      falseNegativePoints = falseNegativeGuard.floor - score;
      score = falseNegativeGuard.floor;
      reasons.add('false_negative_guard');
    }

    score = score.clamp(0, 100).toDouble();
    confidence = confidence.clamp(0, 100).toDouble();
    final reason = _primaryReason(reasons, signalFamilyCount);
    final updatedContributions = <String, Object?>{
      ...contributionJson,
      'respiratory_points': respiratoryPoints.round(),
      'mobility_points': mobilityPoints.round(),
      'medication_context_points': medicationPoints.round(),
      'clinical_anchor_points': clinicalPoints.round(),
      'context_adjustment_points': contextAdjustment.round(),
      'false_negative_guard_points': falseNegativePoints.round(),
      'context_attribution_reason': reason,
      'context_reason_codes': reasons,
      'context_signal_family_count': signalFamilyCount,
      'false_negative_guard_triggered': falseNegativeGuard.triggered,
      'false_negative_guard_reasons': falseNegativeGuard.reasons,
      'paper_base_score': baseScore.round(),
      'paper_base_band': baseRiskBand,
      'model_family': 'production_safety_layer',
      'local_diagnostic_only': true,
      // v20 lab fields propagated through adjustment layer
      'lab_points': labPoints.round(),
      'lab_narrative_key': labNarrativeKey,
    };

    return ProductionRiskAdjustmentResult(
      riskScore: score,
      confidenceScore: confidence,
      riskBand: _riskBand(score),
      contributionJson: updatedContributions,
      featureUpdates: {
        'context_signal_family_count': signalFamilyCount,
        'context_false_negative_guard_triggered':
            falseNegativeGuard.triggered ? 1 : 0,
        'context_attribution_reason': reason,
        'risk_v2_context_adjusted_score': score,
      },
    );
  }

  int _signalFamilyCount({
    required double hrvPoints,
    required double rhrPoints,
    required double sleepPoints,
    required double symptomPoints,
    required double stepsPoints,
    required double sparsePoints,
    required double respiratoryPoints,
    required double mobilityPoints,
    required double clinicalPoints,
    required double medicationPoints,
    double labPoints = 0,
    required Map<String, Object?> featureJson,
  }) {
    return [
      hrvPoints > 0,
      rhrPoints > 0,
      sleepPoints > 0 || stepsPoints > 0 || mobilityPoints > 0,
      sparsePoints > 0 || respiratoryPoints > 0,
      symptomPoints > 0 ||
          ((_asDouble(featureJson['apple_health_symptom_count']) ?? 0) > 0) ||
          clinicalPoints > 0 ||
          medicationPoints > 0,
      labPoints > 0,
    ].where((item) => item).length;
  }

  double _respiratoryContribution(Map<String, Object?> featureJson) {
    final delta = _asDouble(
      featureJson['respiratory_rate_3d_delta_vs_baseline'],
    );
    if (delta == null) return 0;
    if (delta >= 4) return 10;
    if (delta >= 2.5) return 7;
    if (delta >= 1.5) return 4;
    return 0;
  }

  double _mobilityContribution(Map<String, Object?> featureJson) {
    final signal = _asDouble(featureJson['mobility_decline_signal']) ?? 0;
    if (signal >= 3) return 10;
    if (signal >= 2) return 7;
    if (signal >= 1) return 4;
    return 0;
  }

  String _primaryReason(List<String> reasons, int signalFamilyCount) {
    if (reasons.contains('false_negative_guard')) {
      return 'symptoms_changed_even_with_quiet_heart_rate';
    }
    if (reasons.contains('looks_workout_related')) {
      return 'looks_workout_related';
    }
    if (reasons.contains('looks_meal_timed')) {
      return 'looks_meal_timed';
    }
    if (signalFamilyCount >= 3) {
      return 'multiple_signals_agree';
    }
    return 'less_explained_by_activity';
  }

  String _riskBand(double score) {
    if (score >= 60) return 'high';
    if (score >= 35) return 'elevated';
    if (score >= 20) return 'moderate';
    return 'low';
  }

  double? _asDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return null;
  }
}
