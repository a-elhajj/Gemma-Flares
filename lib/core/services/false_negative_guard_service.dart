class FalseNegativeGuardResult {
  const FalseNegativeGuardResult({
    required this.triggered,
    required this.floor,
    required this.signalFamilies,
    required this.reasons,
  });

  final bool triggered;
  final double floor;
  final int signalFamilies;
  final List<String> reasons;
}

class FalseNegativeGuardService {
  const FalseNegativeGuardService();

  FalseNegativeGuardResult evaluate({
    required double baseScore,
    required Map<String, Object?> featureJson,
    required Map<String, Object?> contributionJson,
    required int signalFamilyCount,
  }) {
    final reasons = <String>[];
    final heartQuiet =
        ((_asDouble(contributionJson['resting_hr_points']) ?? 0) <= 2) &&
            ((_asDouble(featureJson['rhr_3d_delta_vs_baseline']) ?? 0) < 2);

    if ((_asDouble(contributionJson['symptom_points']) ?? 0) > 0 ||
        ((_asDouble(featureJson['apple_health_symptom_count']) ?? 0) > 0)) {
      reasons.add('symptoms_changed');
    }
    if ((_asDouble(featureJson['respiratory_rate_3d_delta_vs_baseline']) ??
            0) >=
        1.5) {
      reasons.add('breathing_changed');
    }
    if ((_asDouble(contributionJson['sleep_points']) ?? 0) > 0) {
      reasons.add('sleep_changed');
    }
    if ((_asDouble(featureJson['temp_3d_delta_vs_baseline']) ?? 0) >= 0.3 ||
        ((_asDouble(featureJson['spo2_7d_delta_vs_baseline']) ?? 0) >= 1)) {
      reasons.add('vitals_changed');
    }
    if ((_asDouble(featureJson['mobility_decline_signal']) ?? 0) >= 1) {
      reasons.add('mobility_changed');
    }
    if ((_asDouble(featureJson['context_medication_missed_possible']) ?? 0) >=
        1) {
      reasons.add('medication_context');
    }
    if ((_asDouble(featureJson['context_clinical_anchor_present']) ?? 0) >= 1) {
      reasons.add('clinical_anchor');
    }

    final nonHrFamilies = reasons.toSet().length;
    var floor = 0.0;
    if (nonHrFamilies >= 2) {
      floor = 35;
    }
    if (reasons.contains('symptoms_changed') &&
        (reasons.contains('sleep_changed') ||
            reasons.contains('breathing_changed') ||
            reasons.contains('vitals_changed'))) {
      floor = floor < 50 ? 50 : floor;
    }
    if (reasons.contains('clinical_anchor')) {
      floor = floor < 65 ? 65 : floor;
    }
    if (reasons.contains('clinical_anchor') &&
        reasons.contains('symptoms_changed') &&
        signalFamilyCount >= 3) {
      floor = floor < 75 ? 75 : floor;
    }

    final triggered = heartQuiet && floor > baseScore;
    return FalseNegativeGuardResult(
      triggered: triggered,
      floor: triggered ? floor : 0,
      signalFamilies: nonHrFamilies,
      reasons: reasons,
    );
  }

  double? _asDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return null;
  }
}
