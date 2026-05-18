import 'dart:math' as math;

import '../contracts/health_bridge_contracts.dart';
import '../database/wearable_sample_repository.dart';

// ── Aggregation rules ──────────────────────────────────────────────────────
// Each metric declares how its raw samples should be reduced.
// Rule is applied FIRST at daily grain (samples → day), THEN at window grain
// (days → week / month / range).
enum WearableAggRule {
  // SUM samples per day; SUM days for weekly/monthly total (e.g. steps, energy)
  sum,
  // AVG samples per day weighted by sample_count; AVG days (e.g. RHR, HRV)
  avgWeighted,
  // Sum total asleep-stage seconds, convert to hours (sleepAnalysis)
  totalHours,
  // Latest non-null value in window (sparse metrics: VO2 max, ECG)
  latest,
  // AVG with min/max envelope (walking metrics, respiratory rate)
  avgWithEnvelope,
}

// ── Window resolution ──────────────────────────────────────────────────────
enum WearableGrain { day, week, month, range }

class WearableWindow {
  const WearableWindow({
    required this.grain,
    required this.startDate,
    required this.endDate,
    required this.label,
  });

  final WearableGrain grain;
  final String startDate; // 'YYYY-MM-DD' inclusive
  final String endDate; // 'YYYY-MM-DD' inclusive
  final String label; // human-readable ("yesterday", "last week", ...)
}

// ── Metric specification ───────────────────────────────────────────────────
class WearableMetricSpec {
  const WearableMetricSpec({
    required this.type,
    required this.dbName, // matches wearable_samples.metric_name
    required this.displayName,
    required this.unit,
    required this.rule,
    required this.phrases,
  });

  final HealthMetricType type;
  final String dbName;
  final String displayName;
  final String unit;
  final WearableAggRule rule;
  final List<String> phrases; // lowercased user-phrase aliases
}

// ── Aggregation result ─────────────────────────────────────────────────────
class WearableAggResult {
  const WearableAggResult({
    required this.metric,
    required this.window,
    required this.value,
    required this.min,
    required this.max,
    required this.sampleDays,
    this.unit = '',
    this.sourceCount = 1,
    this.sourceNames = const [],
  });

  final WearableMetricSpec metric;
  final WearableWindow window;
  // null means no data in window
  final double? value;
  final double? min;
  final double? max;
  final int sampleDays;
  final String unit;
  // How many distinct wearable sources contributed to this aggregate.
  final int sourceCount;
  // Names of contributing sources (e.g. ['Apple Watch', 'Oura Ring']).
  final List<String> sourceNames;

  /// Qualitative confidence tier based on source agreement and sample density.
  String get confidenceTier {
    if (value == null) return 'no_data';
    if (sourceCount == 0 || sampleDays == 0) return 'no_data';
    if (sourceCount >= 2 && sampleDays >= 5) return 'high';
    if (sourceCount >= 2 || sampleDays >= 3) return 'medium';
    return 'low';
  }
}

/// Query plan returned by [WearableAggregationService.resolve].
/// Null-resolve means the user message is not a specific metric+window ask —
/// fall through to the existing summary / Gemma path.
class WearableQueryPlan {
  const WearableQueryPlan({required this.metric, required this.window});
  final WearableMetricSpec metric;
  final WearableWindow window;
}

/// Comparison plan: same metric over two distinct time windows.
/// Returned by [WearableAggregationService.resolveComparison].
class WearableComparisonPlan {
  const WearableComparisonPlan({
    required this.metric,
    required this.windowA,
    required this.windowB,
  });
  final WearableMetricSpec metric;
  final WearableWindow windowA; // "primary" window (e.g. this month)
  final WearableWindow windowB; // "reference" window (e.g. last month)
}

/// Result of a comparison execution.
class WearableComparisonResult {
  const WearableComparisonResult({
    required this.metric,
    required this.resultA,
    required this.resultB,
  });
  final WearableMetricSpec metric;
  final WearableAggResult resultA;
  final WearableAggResult resultB;

  /// Signed delta (A – B). Null when either value is missing.
  double? get delta {
    final a = resultA.value;
    final b = resultB.value;
    if (a == null || b == null) return null;
    return a - b;
  }

  /// Percentage change relative to B. Null when B is 0 or either value missing.
  double? get pctChange {
    final b = resultB.value;
    if (b == null || b == 0) return null;
    final d = delta;
    if (d == null) return null;
    return (d / b) * 100;
  }
}

// ── Metric registry ────────────────────────────────────────────────────────
// Single source of truth for wearable metrics visible to the aggregation layer.
// Normalized dbName is what WearableNormalizationService._metricName() returns
// and what actually lives in wearable_samples.metric_name (BUG-065 fix).
const _kRegistry = <WearableMetricSpec>[
  WearableMetricSpec(
    type: HealthMetricType.stepCount,
    dbName: 'steps',
    displayName: 'steps',
    unit: 'steps',
    rule: WearableAggRule.sum,
    phrases: [
      'step',
      'steps',
      'step count',
      'how many steps',
      'total steps',
      'walk',
      'walked',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.activeEnergyBurned,
    dbName: 'active_energy_kcal',
    displayName: 'active energy',
    unit: 'kcal',
    rule: WearableAggRule.sum,
    phrases: [
      'active energy',
      'calories burned',
      'active calories',
      'kcal burned',
      'energy burned',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.appleExerciseTime,
    dbName: 'exercise_minutes',
    displayName: 'exercise minutes',
    unit: 'min',
    rule: WearableAggRule.sum,
    phrases: [
      'exercise minutes',
      'exercise time',
      'workout minutes',
      'minutes of exercise',
      'active minutes',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.distanceWalkingRunning,
    dbName: 'walking_running_distance_m',
    displayName: 'walking/running distance',
    unit: 'km',
    rule: WearableAggRule.sum,
    phrases: [
      'distance walked',
      'walking distance',
      'running distance',
      'distance run',
      'km walked',
      'miles walked',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.flightsClimbed,
    dbName: 'flights_climbed',
    displayName: 'flights climbed',
    unit: 'flights',
    rule: WearableAggRule.sum,
    phrases: ['flights climbed', 'floors climbed', 'stairs climbed'],
  ),
  WearableMetricSpec(
    type: HealthMetricType.heartRateVariabilitySdnn,
    dbName: 'hrv_sdnn',
    displayName: 'HRV',
    unit: 'ms',
    rule: WearableAggRule.avgWeighted,
    phrases: [
      'hrv',
      'heart rate variability',
      'heart rate variation',
      'rmssd',
      'sdnn',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.restingHeartRate,
    dbName: 'resting_hr',
    displayName: 'resting heart rate',
    unit: 'bpm',
    rule: WearableAggRule.avgWithEnvelope,
    phrases: [
      'resting heart rate',
      'resting hr',
      'resting bpm',
      'rhr',
      'heart rate at rest',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.heartRate,
    dbName: 'heart_rate',
    displayName: 'heart rate',
    unit: 'bpm',
    rule: WearableAggRule.avgWithEnvelope,
    phrases: ['heart rate', 'hr', 'pulse', 'bpm'],
  ),
  WearableMetricSpec(
    type: HealthMetricType.walkingHeartRateAverage,
    dbName: 'walking_hr_avg',
    displayName: 'walking heart rate',
    unit: 'bpm',
    rule: WearableAggRule.avgWeighted,
    phrases: ['walking heart rate', 'walking hr', 'walking bpm'],
  ),
  WearableMetricSpec(
    type: HealthMetricType.heartRateRecoveryOneMinute,
    dbName: 'heart_rate_recovery_1min',
    displayName: 'heart rate recovery',
    unit: 'bpm drop',
    rule: WearableAggRule.avgWeighted,
    phrases: [
      'heart rate recovery',
      'hr recovery',
      'recovery rate',
      'one minute recovery',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.oxygenSaturation,
    dbName: 'spo2',
    displayName: 'blood oxygen',
    unit: '%',
    rule: WearableAggRule.avgWeighted,
    phrases: [
      'spo2',
      'blood oxygen',
      'oxygen saturation',
      'o2 saturation',
      'oxygen level',
      'pulse ox',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.respiratoryRate,
    dbName: 'respiratory_rate',
    displayName: 'respiratory rate',
    unit: 'breaths/min',
    rule: WearableAggRule.avgWithEnvelope,
    phrases: [
      'respiratory rate',
      'breathing rate',
      'breaths per minute',
      'respiration',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.sleepAnalysis,
    dbName: 'sleep_segment',
    displayName: 'sleep',
    unit: 'hours',
    rule: WearableAggRule.totalHours,
    phrases: [
      'sleep',
      'slept',
      'sleeping',
      'hours of sleep',
      'sleep duration',
      'time asleep',
      'sleep last night',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.appleSleepingWristTemperature,
    dbName: 'wrist_temp_sleep',
    displayName: 'wrist temperature',
    unit: '°C',
    rule: WearableAggRule.avgWithEnvelope,
    phrases: [
      'wrist temperature',
      'wrist temp',
      'skin temperature',
      'sleeping temperature',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.sleepingBreathingDisturbance,
    dbName: 'sleep_breathing_disturbance',
    displayName: 'breathing disturbances',
    unit: 'events',
    rule: WearableAggRule.avgWeighted,
    phrases: [
      'breathing disturbance',
      'sleep disturbance',
      'sleep apnea events',
      'breathing events',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.vo2Max,
    dbName: 'vo2_max',
    displayName: 'VO₂ max',
    unit: 'mL/kg/min',
    rule: WearableAggRule.latest,
    phrases: ['vo2 max', 'vo2max', 'cardio fitness', 'cardio fitness score'],
  ),
  WearableMetricSpec(
    type: HealthMetricType.walkingSpeed,
    dbName: 'walking_speed_mps',
    displayName: 'walking speed',
    unit: 'm/s',
    rule: WearableAggRule.avgWeighted,
    phrases: ['walking speed', 'walk speed', 'gait speed'],
  ),
  WearableMetricSpec(
    type: HealthMetricType.stairAscentSpeed,
    dbName: 'stair_ascent_speed_mps',
    displayName: 'stair ascent speed',
    unit: 'm/s',
    rule: WearableAggRule.avgWeighted,
    phrases: ['stair ascent speed', 'stair speed', 'stair climbing speed'],
  ),
  WearableMetricSpec(
    type: HealthMetricType.atrialFibrillationBurden,
    dbName: 'atrial_fibrillation_burden_pct',
    displayName: 'AFib burden',
    unit: '%',
    rule: WearableAggRule.avgWeighted,
    phrases: ['afib burden', 'atrial fibrillation burden', 'afib percentage'],
  ),
  WearableMetricSpec(
    type: HealthMetricType.dietaryWater,
    dbName: 'dietary_water_ml',
    displayName: 'water intake',
    unit: 'mL',
    rule: WearableAggRule.sum,
    phrases: ['water intake', 'water drunk', 'hydration', 'water consumed'],
  ),
  WearableMetricSpec(
    type: HealthMetricType.dietaryCaffeine,
    dbName: 'dietary_caffeine_mg',
    displayName: 'caffeine intake',
    unit: 'mg',
    rule: WearableAggRule.sum,
    phrases: ['caffeine', 'caffeine intake', 'caffeine consumed'],
  ),
  WearableMetricSpec(
    type: HealthMetricType.workout,
    dbName: 'workout',
    displayName: 'workouts',
    unit: 'sessions',
    rule: WearableAggRule.sum,
    phrases: [
      'workout',
      'workouts',
      'exercise session',
      'exercise sessions',
      'training session',
      'gym session',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.dietaryEnergyConsumed,
    dbName: 'dietary_energy_kcal',
    displayName: 'calorie intake',
    unit: 'kcal',
    rule: WearableAggRule.sum,
    phrases: [
      'calorie intake',
      'calories consumed',
      'dietary energy',
      'food calories',
      'energy consumed',
      'caloric intake',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.numberOfAlcoholicBeverages,
    dbName: 'alcoholic_beverages',
    displayName: 'alcoholic beverages',
    unit: 'drinks',
    rule: WearableAggRule.sum,
    phrases: [
      'alcohol',
      'alcoholic beverages',
      'drinks',
      'alcoholic drinks',
      'beer',
      'wine',
      'alcohol intake',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.medicationDoseEvent,
    dbName: 'medication_dose_event',
    displayName: 'medication doses',
    unit: 'doses',
    rule: WearableAggRule.sum,
    phrases: [
      'medication dose',
      'medication doses',
      'dose events',
      'medication events',
      'doses logged',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.walkingStepLength,
    dbName: 'walking_step_length_m',
    displayName: 'step length',
    unit: 'm',
    rule: WearableAggRule.avgWeighted,
    phrases: ['step length', 'stride length', 'walking step length'],
  ),
  WearableMetricSpec(
    type: HealthMetricType.walkingAsymmetryPercentage,
    dbName: 'walking_asymmetry_pct',
    displayName: 'walking asymmetry',
    unit: '%',
    rule: WearableAggRule.avgWeighted,
    phrases: ['walking asymmetry', 'gait asymmetry', 'step asymmetry'],
  ),
  WearableMetricSpec(
    type: HealthMetricType.walkingDoubleSupportPercentage,
    dbName: 'walking_double_support_pct',
    displayName: 'double support time',
    unit: '%',
    rule: WearableAggRule.avgWeighted,
    phrases: [
      'double support',
      'walking double support',
      'ground contact time',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.stairDescentSpeed,
    dbName: 'stair_descent_speed_mps',
    displayName: 'stair descent speed',
    unit: 'm/s',
    rule: WearableAggRule.avgWeighted,
    phrases: ['stair descent speed', 'stair descent', 'descending stairs'],
  ),
  WearableMetricSpec(
    type: HealthMetricType.sixMinuteWalkTestDistance,
    dbName: 'six_minute_walk_distance_m',
    displayName: '6-minute walk distance',
    unit: 'm',
    rule: WearableAggRule.latest,
    phrases: [
      'six minute walk',
      '6 minute walk',
      '6-minute walk',
      'six-minute walk test',
      '6mwt',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.highHeartRateEvent,
    dbName: 'high_heart_rate_event',
    displayName: 'high heart rate events',
    unit: 'events',
    rule: WearableAggRule.sum,
    phrases: [
      'high heart rate event',
      'high heart rate events',
      'elevated heart rate events',
      'high hr event',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.lowHeartRateEvent,
    dbName: 'low_heart_rate_event',
    displayName: 'low heart rate events',
    unit: 'events',
    rule: WearableAggRule.sum,
    phrases: [
      'low heart rate event',
      'low heart rate events',
      'low hr event',
      'bradycardia event',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.irregularHeartRhythmEvent,
    dbName: 'irregular_heart_rhythm_event',
    displayName: 'irregular rhythm events',
    unit: 'events',
    rule: WearableAggRule.sum,
    phrases: [
      'irregular heart rhythm',
      'irregular rhythm events',
      'arrhythmia events',
      'rhythm events',
      'irregular rhythm',
    ],
  ),
  WearableMetricSpec(
    type: HealthMetricType.electrocardiogram,
    dbName: 'electrocardiogram',
    displayName: 'ECG readings',
    unit: 'readings',
    rule: WearableAggRule.sum,
    phrases: ['ecg', 'electrocardiogram', 'ecg reading', 'ekg'],
  ),
];

// Build a fast-lookup index: normalized phrase → metric spec.
final Map<String, WearableMetricSpec> _kPhraseIndex =
    Map<String, WearableMetricSpec>.unmodifiable(_buildPhraseIndex());

Map<String, WearableMetricSpec> _buildPhraseIndex() {
  final map = <String, WearableMetricSpec>{};
  for (final spec in _kRegistry) {
    for (final phrase in spec.phrases) {
      map[phrase] = spec;
    }
  }
  return map;
}

// ── Window phrase patterns ─────────────────────────────────────────────────
// Named weekday map for "last Monday", "last Tuesday", etc.
const _kWeekdays = {
  'monday': 1,
  'tuesday': 2,
  'wednesday': 3,
  'thursday': 4,
  'friday': 5,
  'saturday': 6,
  'sunday': 7,
};

const _kMonthNames = {
  'january': 1,
  'february': 2,
  'march': 3,
  'april': 4,
  'may': 5,
  'june': 6,
  'july': 7,
  'august': 8,
  'september': 9,
  'october': 10,
  'november': 11,
  'december': 12,
};

/// Maximum allowed window in days. Prevents runaway range queries.
const _kMaxWindowDays = 365;

// ── Service ────────────────────────────────────────────────────────────────
class WearableAggregationService {
  const WearableAggregationService(this._repository);

  final WearableSampleRepository _repository;

  // ── Public API ─────────────────────────────────────────────────────────

  /// Resolves [userMessage] to a [WearableQueryPlan], or null if the message
  /// is not a specific metric+window ask (fall through to summary path).
  WearableQueryPlan? resolve(String userMessage, {DateTime? now}) {
    final lower = userMessage.toLowerCase();
    final metric = _matchMetric(lower);
    if (metric == null) return null;
    final window = _matchWindow(lower, now: now ?? DateTime.now());
    if (window == null) return null;
    return WearableQueryPlan(metric: metric, window: window);
  }

  /// Executes [plan] against the local DB and returns an [WearableAggResult].
  Future<WearableAggResult> execute(WearableQueryPlan plan) async {
    final rows = await _repository.getMetricRowsForWindow(
      dbName: plan.metric.dbName,
      startDate: plan.window.startDate,
      endDate: plan.window.endDate,
    );

    if (rows.isEmpty) {
      return WearableAggResult(
        metric: plan.metric,
        window: plan.window,
        value: null,
        min: null,
        max: null,
        sampleDays: 0,
        unit: plan.metric.unit,
      );
    }

    final sources = await _repository.getDistinctSourcesForWindow(
      dbName: plan.metric.dbName,
      startDate: plan.window.startDate,
      endDate: plan.window.endDate,
    );

    final base = switch (plan.metric.rule) {
      WearableAggRule.sum => _computeSum(plan, rows),
      WearableAggRule.avgWeighted => _computeAvgWeighted(plan, rows),
      WearableAggRule.totalHours => _computeTotalHours(plan, rows),
      WearableAggRule.latest => _computeLatest(plan, rows),
      WearableAggRule.avgWithEnvelope => _computeAvgWithEnvelope(plan, rows),
    };

    return WearableAggResult(
      metric: base.metric,
      window: base.window,
      value: base.value,
      min: base.min,
      max: base.max,
      sampleDays: base.sampleDays,
      unit: base.unit,
      sourceCount: sources.length,
      sourceNames: sources,
    );
  }

  /// Renders a deterministic English sentence from [result].
  String render(WearableAggResult result) {
    final w = result.window.label;
    final name = result.metric.displayName;
    final unit = result.unit;
    final meaning = _metricMeaning(result.metric);

    if (result.value == null) {
      return "I don't have $name data for $w. "
          'Make sure Apple Health is synced and try again. '
          'What this metric means: $meaning '
          'Interpretation: once at least a few days of samples are synced, I can interpret the trend direction for this metric.';
    }

    final v = result.value!;
    final interpretation = _metricInterpretation(result);
    final confidenceSuffix = _confidenceInterpretation(result);

    final String base;
    switch (result.metric.rule) {
      case WearableAggRule.sum:
        final formatted = _fmt(v, unit: unit);
        base =
            '${_renderConfidencePrefix(result)}$w, your total $name was $formatted.';
        break;
      case WearableAggRule.avgWeighted:
        final formatted = _fmt(v, unit: unit);
        base =
            '${_renderConfidencePrefix(result)}$w, your average $name was $formatted.';
        break;
      case WearableAggRule.totalHours:
        final h = v.truncate();
        final m = ((v - h) * 60).round();
        final timeStr = m > 0 ? '${h}h ${m}m' : '${h}h';
        base = '${_renderConfidencePrefix(result)}$w, you slept $timeStr.';
        break;
      case WearableAggRule.latest:
        final formatted = _fmt(v, unit: unit);
        base =
            '${_renderConfidencePrefix(result)}$w, your most recent $name reading was $formatted.';
        break;
      case WearableAggRule.avgWithEnvelope:
        final formatted = _fmt(v, unit: unit);
        if (result.min != null && result.max != null) {
          final lo = _fmt(result.min!, unit: unit);
          final hi = _fmt(result.max!, unit: unit);
          base =
              '${_renderConfidencePrefix(result)}$w, your $name averaged $formatted (range: $lo – $hi).';
        } else {
          base =
              '${_renderConfidencePrefix(result)}$w, your average $name was $formatted.';
        }
        break;
    }

    return '$base What this metric means: $meaning Interpretation: $interpretation$confidenceSuffix';
  }

  String _metricMeaning(WearableMetricSpec metric) {
    return switch (metric.dbName) {
      'steps' => 'Step count reflects your total daily movement volume.',
      'active_energy_kcal' =>
        'Active energy estimates calories burned from movement above resting baseline.',
      'exercise_minutes' =>
        'Exercise minutes capture intentional moderate or vigorous activity time.',
      'walking_running_distance_m' =>
        'Walking and running distance tracks total distance covered from ambulatory activity.',
      'flights_climbed' =>
        'Flights climbed reflects vertical activity load from stairs and hills.',
      'hrv_sdnn' =>
        'HRV SDNN measures beat-to-beat variability and is often used as a recovery and stress-load proxy.',
      'resting_hr' =>
        'Resting heart rate reflects pulse at rest and is a useful strain and recovery signal over time.',
      'heart_rate' =>
        'Heart rate reflects pulse intensity and should be interpreted with activity context.',
      'walking_hr_avg' =>
        'Walking heart rate reflects cardiovascular effort during routine movement.',
      'heart_rate_recovery_1min' =>
        'Heart rate recovery tracks how much your pulse drops after exertion.',
      'spo2' => 'Blood oxygen estimates peripheral oxygen saturation.',
      'respiratory_rate' => 'Respiratory rate captures breathing frequency.',
      'sleep_segment' =>
        'Sleep duration captures total recorded sleep time in the window.',
      'wrist_temp_sleep' =>
        'Sleeping wrist temperature reflects overnight temperature drift versus your own baseline.',
      'sleep_breathing_disturbance' =>
        'Breathing disturbance events reflect nighttime breathing instability markers.',
      'vo2_max' =>
        'VO₂ max estimates aerobic capacity and cardiorespiratory fitness.',
      'walking_speed_mps' =>
        'Walking speed reflects functional mobility and activity tolerance.',
      'stair_ascent_speed_mps' =>
        'Stair ascent speed reflects lower-body functional effort during climbing.',
      'atrial_fibrillation_burden_pct' =>
        'AFib burden reflects the share of monitored time with irregular rhythm episodes.',
      'dietary_water_ml' => 'Water intake tracks logged hydration volume.',
      'dietary_caffeine_mg' =>
        'Caffeine intake tracks logged stimulant exposure.',
      'workout' =>
        'Workout sessions tracks intentional exercise events logged to Apple Health.',
      'dietary_energy_kcal' =>
        'Calorie intake tracks dietary energy logged to Apple Health or connected apps.',
      'alcoholic_beverages' =>
        'Alcoholic beverages tracks logged alcohol consumption events.',
      'medication_dose_event' =>
        'Medication dose events reflect doses logged via Apple Health.',
      'walking_step_length_m' =>
        'Walking step length reflects average stride distance, a functional mobility metric.',
      'walking_asymmetry_pct' =>
        'Walking asymmetry reflects the imbalance between left and right steps — lower is more symmetric.',
      'walking_double_support_pct' =>
        'Double support time reflects the portion of each gait cycle where both feet are on the ground — higher values can indicate slower, more cautious gait.',
      'stair_descent_speed_mps' =>
        'Stair descent speed reflects lower-body control and confidence during stair descent.',
      'six_minute_walk_distance_m' =>
        '6-minute walk test distance is a validated measure of functional exercise capacity.',
      'high_heart_rate_event' =>
        'High heart rate events are notifications from Apple Watch when resting HR exceeds your threshold.',
      'low_heart_rate_event' =>
        'Low heart rate events are notifications when resting HR falls below your threshold.',
      'irregular_heart_rhythm_event' =>
        'Irregular heart rhythm events reflect Apple Watch detections of possible irregular rhythm, which can indicate AFib.',
      'electrocardiogram' =>
        'ECG readings reflect manually taken electrocardiogram scans from Apple Watch.',
      _ => 'This metric reflects an Apple Health-derived physiological signal.',
    };
  }

  String _metricInterpretation(WearableAggResult result) {
    final value = result.value;
    if (value == null) {
      return 'No local samples are available in this window yet.';
    }
    final v = value;

    return switch (result.metric.dbName) {
      'steps' =>
        'Higher totals usually mean more movement tolerance; sustained drops over several days can align with fatigue, recovery days, or rising symptom burden.',
      'active_energy_kcal' =>
        'Higher totals generally reflect more exertion; abrupt declines can align with lower energy or reduced activity capacity.',
      'exercise_minutes' =>
        'More minutes generally reflect stronger activity consistency; lower minutes over multiple days can indicate reduced exercise tolerance.',
      'walking_running_distance_m' =>
        'Higher distance suggests greater activity range; falling distance over repeated days can indicate lower stamina or intentional rest.',
      'flights_climbed' =>
        'More flights usually means higher vertical activity load; lower values can indicate reduced intensity days.',
      'hrv_sdnn' =>
        'Higher HRV versus your own baseline usually supports better recovery, while repeated multi-day drops can indicate higher stress or inflammatory load.',
      'resting_hr' =>
        'Sustained increases versus your own baseline can indicate higher strain, while stable or lower values can indicate better recovery state.',
      'heart_rate' =>
        'Interpret this with context: activity, stress, hydration, and illness can all move average heart rate.',
      'walking_hr_avg' =>
        'If walking HR rises for the same routine activity, that can indicate higher physiological strain; stability suggests consistent effort load.',
      'heart_rate_recovery_1min' =>
        'A larger 1-minute drop is generally favorable for recovery; smaller drops can suggest higher strain or incomplete recovery.',
      'spo2' =>
        'Focus on persistent downward shifts rather than one isolated low point, since single values can be noisy.',
      'respiratory_rate' =>
        'Sustained increases can reflect higher physiologic load; stable trends are usually more informative than single-day noise.',
      'sleep_segment' => v < 6
          ? 'This is a short-sleep window; repeated short sleep can worsen recovery and next-day stress load.'
          : v <= 9
              ? 'This is within a typical recovery-supportive sleep range for many adults; trend consistency matters most.'
              : 'Long sleep windows can reflect recovery demand; interpret with daytime energy and symptom trends.',
      'wrist_temp_sleep' =>
        'Interpret against your own baseline; persistent upward drift can appear with illness, stress, or inflammatory load.',
      'sleep_breathing_disturbance' =>
        'Higher event counts can align with fragmented sleep and lower recovery quality the next day.',
      'vo2_max' =>
        'Higher values generally indicate stronger aerobic capacity; month-to-month trend is more useful than day-to-day changes.',
      'walking_speed_mps' =>
        'Declining walking speed over time can indicate lower functional tolerance; stable speed suggests steadier capacity.',
      'stair_ascent_speed_mps' =>
        'Declining stair ascent speed can indicate lower exertional tolerance; stable or improving speed suggests better functional reserve.',
      'atrial_fibrillation_burden_pct' =>
        'Any non-zero burden means irregular-rhythm time was detected; persistent or rising burden should be reviewed with your clinical team.',
      'dietary_water_ml' =>
        'Lower intake can raise dehydration risk, especially on higher stool-loss days; consistency matters more than one single day.',
      'dietary_caffeine_mg' =>
        'Higher intake, especially later in the day, can reduce sleep quality and sometimes suppress recovery markers such as HRV.',
      'workout' =>
        'More sessions generally reflect stronger exercise consistency; fewer sessions can indicate intentional rest, fatigue, or lower tolerance.',
      'dietary_energy_kcal' =>
        'Compare to your typical intake; sustained deficits can affect energy and recovery, while surpluses may reflect increased appetite during recovery.',
      'alcoholic_beverages' =>
        'Even moderate intake can suppress HRV and disrupt sleep; trends around symptom flare days are worth watching.',
      'medication_dose_event' =>
        'Consistent dose logging supports adherence tracking; gaps may indicate missed doses or incomplete logging.',
      'walking_step_length_m' =>
        'Declining step length can indicate reduced mobility or fatigue; stable or improving length suggests steadier gait.',
      'walking_asymmetry_pct' =>
        'Lower asymmetry is generally better; rising asymmetry over time can indicate gait compensation or injury risk.',
      'walking_double_support_pct' =>
        'Higher double support can indicate more cautious gait; trending upward over weeks may reflect lower confidence or balance.',
      'stair_descent_speed_mps' =>
        'Declining stair descent speed can indicate lower functional confidence or lower-limb weakness; stable speed suggests maintained reserve.',
      'six_minute_walk_distance_m' =>
        'Higher distance reflects better functional capacity; month-to-month trend is more meaningful than a single reading.',
      'high_heart_rate_event' =>
        'Recurrent events at rest may indicate higher physiological stress or dehydration; discuss persistent patterns with your care team.',
      'low_heart_rate_event' =>
        'Isolated events in fit individuals are often normal; recurring events with symptoms should be reviewed by your care team.',
      'irregular_heart_rhythm_event' =>
        'Any recurrent irregular rhythm detection warrants clinical review, especially if associated with palpitations or shortness of breath.',
      'electrocardiogram' =>
        'Individual ECG readings are most meaningful when reviewed alongside symptoms; your care team can interpret results in clinical context.',
      _ =>
        'Use trend direction across several days, not one point, and interpret alongside symptoms and check-ins.',
    };
  }

  String _confidenceInterpretation(WearableAggResult result) {
    return switch (result.confidenceTier) {
      'high' =>
        ' Confidence note: multi-source and multi-day coverage is strong in this window.',
      'medium' =>
        ' Confidence note: coverage is moderate; prioritize trend direction over single-day changes.',
      'low' =>
        ' Confidence note: data coverage is limited; treat this as an early directional signal only.',
      _ => '',
    };
  }

  /// Returns a confidence-awareness prefix when data is multi-source or sparse.
  String _renderConfidencePrefix(WearableAggResult result) {
    if (result.sourceCount >= 2) {
      final names = result.sourceNames.join(' and ');
      return 'Data from $names — ';
    }
    if (result.confidenceTier == 'low') {
      return 'Limited data (${result.sampleDays} day${result.sampleDays == 1 ? '' : 's'}) — ';
    }
    return '';
  }

  // ── Comparison resolution ──────────────────────────────────────────────

  /// Resolves a comparison query ("X this month vs last month") to a
  /// [WearableComparisonPlan], or null if the message isn't a comparison.
  WearableComparisonPlan? resolveComparison(
    String userMessage, {
    DateTime? now,
  }) {
    final lower = userMessage.toLowerCase();
    final metric = _matchMetric(lower);
    if (metric == null) return null;
    final now_ = now ?? DateTime.now();

    // Detect canonical comparison patterns.
    // Strategy: extract two windows using stripped variants of the message.
    WearableWindow? windowA;
    WearableWindow? windowB;

    // "this week vs last week" / "this month vs last month"
    if (_containsAll(lower, ['this week', 'last week'])) {
      windowA = _matchWindow('this week', now: now_);
      windowB = _matchWindow('last week', now: now_);
    } else if (_containsAll(lower, ['this month', 'last month'])) {
      windowA = _matchWindow('this month', now: now_);
      windowB = _matchWindow('last month', now: now_);
    } else if (_containsAll(lower, ['this month', 'last'])) {
      windowA = _matchWindow('this month', now: now_);
      windowB = _matchWindow('last month', now: now_);
    } else if (_containsAll(lower, ['this week', 'last'])) {
      windowA = _matchWindow('this week', now: now_);
      windowB = _matchWindow('last week', now: now_);
    } else if (_containsAny(lower, ['compare', 'vs ', 'versus', 'compared to',
      'compared with', 'vs.', 'against'])) {
      // Generic comparison: try to find two distinct windows.
      // Try this week / last week first, then this month / last month.
      if (lower.contains('week')) {
        if (lower.contains('this week')) {
          windowA = _matchWindow('this week', now: now_);
          windowB = _matchWindow('last week', now: now_);
        } else {
          windowA = _matchWindow('last week', now: now_);
          windowB = _matchWindow('past 2 weeks', now: now_);
        }
      } else if (lower.contains('month')) {
        if (lower.contains('this month')) {
          windowA = _matchWindow('this month', now: now_);
          windowB = _matchWindow('last month', now: now_);
        } else {
          windowA = _matchWindow('last month', now: now_);
          // Compare last month to the month before
          final prevMonthEnd = DateTime(now_.year, now_.month, 0);
          final prevMonthStart = DateTime(prevMonthEnd.year, prevMonthEnd.month, 1);
          final twoMonthsAgoStart = DateTime(prevMonthStart.year, prevMonthStart.month - 1, 1);
          windowB = WearableWindow(
            grain: WearableGrain.month,
            startDate: _dateStr(twoMonthsAgoStart),
            endDate: _dateStr(prevMonthStart.subtract(const Duration(days: 1))),
            label: 'Two months ago',
          );
        }
      } else if (lower.contains('yesterday') || lower.contains('today')) {
        windowA = _matchWindow(lower.contains('today') ? 'today' : 'yesterday', now: now_);
        windowB = _matchWindow(
          lower.contains('today') ? 'yesterday' : 'last week',
          now: now_,
        );
      }
    }

    if (windowA == null || windowB == null) return null;
    return WearableComparisonPlan(metric: metric, windowA: windowA, windowB: windowB);
  }

  /// Executes a comparison plan and returns a [WearableComparisonResult].
  Future<WearableComparisonResult> executeComparison(
    WearableComparisonPlan plan,
  ) async {
    final planA = WearableQueryPlan(metric: plan.metric, window: plan.windowA);
    final planB = WearableQueryPlan(metric: plan.metric, window: plan.windowB);
    final resultA = await execute(planA);
    final resultB = await execute(planB);
    return WearableComparisonResult(metric: plan.metric, resultA: resultA, resultB: resultB);
  }

  /// Renders a comparison result into a human-readable English sentence.
  String renderComparison(WearableComparisonResult result) {
    final name = result.metric.displayName;
    final labelA = result.resultA.window.label;
    final labelB = result.resultB.window.label;

    if (result.resultA.value == null && result.resultB.value == null) {
      return "I don't have $name data for either period ($labelA or $labelB). "
          'Make sure Apple Health is synced and try again.';
    }
    if (result.resultA.value == null) {
      final bVal = _fmt(result.resultB.value!, unit: result.resultB.unit);
      return "I don't have $name data for $labelA. "
          'For $labelB your $name was $bVal.';
    }
    if (result.resultB.value == null) {
      final aVal = _fmt(result.resultA.value!, unit: result.resultA.unit);
      return '$labelA your $name was $aVal. '
          "I don't have $name data for $labelB to compare against.";
    }

    final aVal = _fmt(result.resultA.value!, unit: result.resultA.unit);
    final bVal = _fmt(result.resultB.value!, unit: result.resultB.unit);
    final delta = result.delta;
    final pct = result.pctChange;

    String changePhrase;
    if (delta == null) {
      changePhrase = '';
    } else {
      final absDelta = delta.abs();
      final sign = delta >= 0 ? 'up' : 'down';
      final deltaStr = _fmt(absDelta, unit: result.metric.unit);
      if (pct != null && pct.abs() >= 1) {
        changePhrase = ' — ${sign} ${deltaStr} (${pct.abs().toStringAsFixed(0)}%) '
            'compared to $labelB.';
      } else {
        changePhrase = ' — ${sign} ${deltaStr} compared to $labelB.';
      }
    }

    final interp = _comparisonInterpretation(result);
    return '$labelA your $name was $aVal$changePhrase '
        '$labelB it was $bVal. $interp';
  }

  String _comparisonInterpretation(WearableComparisonResult r) {
    final delta = r.delta;
    if (delta == null) return '';
    final isPositiveGood = _isHigherBetter(r.metric);
    final isImproving = isPositiveGood ? delta > 0 : delta < 0;
    final isWorsening = isPositiveGood ? delta < 0 : delta > 0;
    if (isImproving) {
      return 'This is a positive trend — keep monitoring for consistency.';
    }
    if (isWorsening) {
      return 'The trend is moving in the less favorable direction — '
          'worth watching over the next several days.';
    }
    return 'The trend is relatively stable between the two periods.';
  }

  bool _isHigherBetter(WearableMetricSpec metric) {
    return const {
      'steps',
      'active_energy_kcal',
      'exercise_minutes',
      'walking_running_distance_m',
      'flights_climbed',
      'workout',
      'hrv_sdnn',
      'heart_rate_recovery_1min',
      'spo2',
      'vo2_max',
      'walking_speed_mps',
      'walking_step_length_m',
      'stair_ascent_speed_mps',
      'stair_descent_speed_mps',
      'six_minute_walk_distance_m',
      'dietary_water_ml',
    }.contains(metric.dbName);
  }

  // ── Multi-metric resolution ────────────────────────────────────────────

  /// Resolves multiple metrics in a single user message that share one window.
  /// Returns an empty list if fewer than 2 metrics match or no window is found.
  List<WearableQueryPlan> resolveMultiple(
    String userMessage, {
    DateTime? now,
  }) {
    final lower = userMessage.toLowerCase();
    final now_ = now ?? DateTime.now();
    final window = _matchWindow(lower, now: now_);
    if (window == null) return const [];

    final seen = <String>{};
    final plans = <WearableQueryPlan>[];
    for (final spec in _kRegistry) {
      for (final phrase in spec.phrases) {
        if (lower.contains(phrase) && !seen.contains(spec.dbName)) {
          seen.add(spec.dbName);
          plans.add(WearableQueryPlan(metric: spec, window: window));
          break;
        }
      }
    }
    // Only return multi-results when 2+ metrics were matched; single-metric
    // falls through to the normal resolve() path.
    return plans.length >= 2 ? plans : const [];
  }

  /// Executes multiple plans concurrently and returns all results.
  Future<List<WearableAggResult>> executeMultiple(
    List<WearableQueryPlan> plans,
  ) async {
    return Future.wait(plans.map(execute));
  }

  /// Renders a combined response for multiple metric results.
  String renderMultiple(List<WearableAggResult> results) {
    final buffer = StringBuffer();
    for (var i = 0; i < results.length; i++) {
      if (i > 0) buffer.write('\n\n');
      buffer.write(render(results[i]));
    }
    return buffer.toString();
  }

  // ── Internal helpers ───────────────────────────────────────────────────

  static bool _containsAll(String text, List<String> terms) =>
      terms.every(text.contains);

  static bool _containsAny(String text, List<String> terms) =>
      terms.any(text.contains);

  // ── Metric matching ────────────────────────────────────────────────────

  WearableMetricSpec? _matchMetric(String lower) {
    // Longest-match wins to avoid 'walk' shadowing 'walking heart rate'.
    WearableMetricSpec? best;
    int bestLen = 0;
    for (final entry in _kPhraseIndex.entries) {
      if (lower.contains(entry.key) && entry.key.length > bestLen) {
        best = entry.value;
        bestLen = entry.key.length;
      }
    }
    return best;
  }

  // ── Window matching ────────────────────────────────────────────────────

  WearableWindow? _matchWindow(String lower, {required DateTime now}) {
    final today = _dateStr(now);
    final yesterday = _dateStr(now.subtract(const Duration(days: 1)));

    // "today" / "tonight" / "this evening"
    if (lower.contains('today') ||
        lower.contains('tonight') ||
        lower.contains('this evening') ||
        lower.contains('this morning') ||
        lower.contains('so far today')) {
      return WearableWindow(
        grain: WearableGrain.day,
        startDate: today,
        endDate: today,
        label: 'Today ($today)',
      );
    }

    // "yesterday" / "last night"
    if (lower.contains('yesterday') || lower.contains('last night')) {
      return WearableWindow(
        grain: WearableGrain.day,
        startDate: yesterday,
        endDate: yesterday,
        label: 'Yesterday ($yesterday)',
      );
    }

    // "this week"
    if (lower.contains('this week')) {
      final monday = _isoWeekMonday(now);
      if (_isFuture(monday, now)) {
        return null; // week hasn't started (edge: today is Sunday in some locales)
      }
      return WearableWindow(
        grain: WearableGrain.week,
        startDate: _dateStr(monday),
        endDate: today,
        label: 'This week (${_dateStr(monday)} – $today)',
      );
    }

    // "last week"
    if (lower.contains('last week')) {
      final thisMonday = _isoWeekMonday(now);
      final lastMonday = thisMonday.subtract(const Duration(days: 7));
      final lastSunday = thisMonday.subtract(const Duration(days: 1));
      return WearableWindow(
        grain: WearableGrain.week,
        startDate: _dateStr(lastMonday),
        endDate: _dateStr(lastSunday),
        label: 'Last week (${_dateStr(lastMonday)} – ${_dateStr(lastSunday)})',
      );
    }

    // "this month"
    if (lower.contains('this month')) {
      final monthStart = DateTime(now.year, now.month, 1);
      return WearableWindow(
        grain: WearableGrain.month,
        startDate: _dateStr(monthStart),
        endDate: today,
        label: 'This month (${_dateStr(monthStart)} – $today)',
      );
    }

    // "last month"
    if (lower.contains('last month')) {
      final firstOfThisMonth = DateTime(now.year, now.month, 1);
      final lastOfPrevMonth = firstOfThisMonth.subtract(
        const Duration(days: 1),
      );
      final firstOfPrevMonth = DateTime(
        lastOfPrevMonth.year,
        lastOfPrevMonth.month,
        1,
      );
      return WearableWindow(
        grain: WearableGrain.month,
        startDate: _dateStr(firstOfPrevMonth),
        endDate: _dateStr(lastOfPrevMonth),
        label:
            'Last month (${_dateStr(firstOfPrevMonth)} – ${_dateStr(lastOfPrevMonth)})',
      );
    }

    // "past N days / weeks / months"
    final pastMatch = RegExp(
      r'past\s+(\d+)\s+(day|days|week|weeks|month|months)',
    ).firstMatch(lower);
    if (pastMatch != null) {
      final n = int.parse(pastMatch.group(1)!);
      final unit = pastMatch.group(2)!;
      final days = switch (unit) {
        'week' || 'weeks' => n * 7,
        'month' || 'months' => n * 30,
        _ => n,
      };
      if (days < 1 || days > _kMaxWindowDays) return null;
      final start = now.subtract(Duration(days: days - 1));
      return WearableWindow(
        grain: WearableGrain.range,
        startDate: _dateStr(start),
        endDate: today,
        label: 'Past $n $unit',
      );
    }

    // "last N days / weeks / months"
    final lastNMatch = RegExp(
      r'last\s+(\d+)\s+(day|days|week|weeks|month|months)',
    ).firstMatch(lower);
    if (lastNMatch != null) {
      final n = int.parse(lastNMatch.group(1)!);
      final unit = lastNMatch.group(2)!;
      final days = switch (unit) {
        'week' || 'weeks' => n * 7,
        'month' || 'months' => n * 30,
        _ => n,
      };
      if (days < 1 || days > _kMaxWindowDays) return null;
      final start = now.subtract(Duration(days: days - 1));
      return WearableWindow(
        grain: WearableGrain.range,
        startDate: _dateStr(start),
        endDate: today,
        label: 'Last $n $unit',
      );
    }

    // "last Monday" / "last Tuesday" etc.
    for (final entry in _kWeekdays.entries) {
      if (lower.contains('last ${entry.key}') ||
          lower.contains(entry.key) && lower.contains('last')) {
        final target = _lastWeekday(now, entry.value);
        // Refuse future dates (shouldn't happen, but guard it)
        if (!target.isBefore(now) && _dateStr(target) != today) return null;
        final ds = _dateStr(target);
        return WearableWindow(
          grain: WearableGrain.day,
          startDate: ds,
          endDate: ds,
          label: '${_capitalize(entry.key)} ($ds)',
        );
      }
    }

    // Explicit date patterns: "May 3", "May 3rd", "5/3", "2026-05-03"
    final explicitDate = _parseExplicitDate(lower, now: now);
    if (explicitDate != null) {
      // Refuse future dates
      if (explicitDate.isAfter(now)) return null;
      // Refuse dates beyond _kMaxWindowDays in the past
      if (now.difference(explicitDate).inDays > _kMaxWindowDays) return null;
      final ds = _dateStr(explicitDate);
      return WearableWindow(
        grain: WearableGrain.day,
        startDate: ds,
        endDate: ds,
        label: ds,
      );
    }

    // "tomorrow" or "next" → future window refusal (return null → caller refuses)
    if (lower.contains('tomorrow') ||
        lower.contains('next week') ||
        lower.contains('next month')) {
      return null;
    }

    if (lower.contains('trend') ||
        lower.contains('recent') ||
        lower.contains('review') ||
        lower.contains('average') ||
        lower.contains('avg')) {
      final start = now.subtract(const Duration(days: 13));
      return WearableWindow(
        grain: WearableGrain.range,
        startDate: _dateStr(start),
        endDate: today,
        label: 'Last 14 days',
      );
    }

    return null;
  }

  // ── Aggregation compute ────────────────────────────────────────────────

  WearableAggResult _computeSum(
    WearableQueryPlan plan,
    List<Map<String, Object?>> rows,
  ) {
    double total = 0;
    for (final r in rows) {
      total += (r['total_value'] as num? ?? 0).toDouble();
    }
    // Convert metres → km for distance
    final displayValue = plan.metric.unit == 'km' ? total / 1000.0 : total;
    return WearableAggResult(
      metric: plan.metric,
      window: plan.window,
      value: displayValue,
      min: null,
      max: null,
      sampleDays: rows.length,
      unit: plan.metric.unit,
    );
  }

  WearableAggResult _computeAvgWeighted(
    WearableQueryPlan plan,
    List<Map<String, Object?>> rows,
  ) {
    double weightedSum = 0;
    int totalCount = 0;
    double? minVal;
    double? maxVal;
    for (final r in rows) {
      final avg = (r['avg_value'] as num?)?.toDouble();
      final cnt = (r['sample_count'] as num? ?? 1).toInt();
      final mn = (r['min_value'] as num?)?.toDouble();
      final mx = (r['max_value'] as num?)?.toDouble();
      if (avg != null) {
        weightedSum += avg * cnt;
        totalCount += cnt;
        if (mn != null) minVal = minVal == null ? mn : math.min(minVal, mn);
        if (mx != null) maxVal = maxVal == null ? mx : math.max(maxVal, mx);
      }
    }
    return WearableAggResult(
      metric: plan.metric,
      window: plan.window,
      value: totalCount > 0 ? weightedSum / totalCount : null,
      min: minVal,
      max: maxVal,
      sampleDays: rows.length,
      unit: plan.metric.unit,
    );
  }

  WearableAggResult _computeTotalHours(
    WearableQueryPlan plan,
    List<Map<String, Object?>> rows,
  ) {
    // sleepAnalysis samples store duration in seconds in value_numeric.
    // total_value = SUM(value_numeric) = total seconds across all stages.
    // Divide by 3600 for hours.
    double totalSeconds = 0;
    for (final r in rows) {
      totalSeconds += (r['total_value'] as num? ?? 0).toDouble();
    }
    return WearableAggResult(
      metric: plan.metric,
      window: plan.window,
      value: totalSeconds > 0 ? totalSeconds / 3600.0 : null,
      min: null,
      max: null,
      sampleDays: rows.length,
      unit: 'hours',
    );
  }

  WearableAggResult _computeLatest(
    WearableQueryPlan plan,
    List<Map<String, Object?>> rows,
  ) {
    // Rows are ORDER BY local_date DESC — take first non-null max_value.
    double? latest;
    for (final r in rows) {
      final v = (r['max_value'] as num?)?.toDouble() ??
          (r['avg_value'] as num?)?.toDouble();
      if (v != null) {
        latest = v;
        break;
      }
    }
    return WearableAggResult(
      metric: plan.metric,
      window: plan.window,
      value: latest,
      min: null,
      max: null,
      sampleDays: rows.length,
      unit: plan.metric.unit,
    );
  }

  WearableAggResult _computeAvgWithEnvelope(
    WearableQueryPlan plan,
    List<Map<String, Object?>> rows,
  ) {
    // Same as avgWeighted but exposes min/max envelope in the result.
    return _computeAvgWeighted(plan, rows);
  }

  // ── Formatting helpers ─────────────────────────────────────────────────

  String _fmt(double v, {String unit = ''}) {
    final rounded =
        v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
    if (unit.isEmpty ||
        unit == 'steps' ||
        unit == 'count' ||
        unit == 'flights') {
      return rounded;
    }
    return '$rounded $unit';
  }

  // ── Date helpers ───────────────────────────────────────────────────────

  static String _dateStr(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  // Returns Monday of the ISO week containing [d].
  static DateTime _isoWeekMonday(DateTime d) {
    final weekday = d.weekday; // 1=Mon ... 7=Sun
    return d.subtract(Duration(days: weekday - 1));
  }

  static bool _isFuture(DateTime d, DateTime now) {
    return _dateStr(d).compareTo(_dateStr(now)) > 0;
  }

  // Returns the most recent past occurrence of [weekday] (1=Mon...7=Sun).
  static DateTime _lastWeekday(DateTime now, int weekday) {
    var d = now.subtract(Duration(days: now.weekday - weekday));
    if (d.isAfter(now) || _dateStr(d) == _dateStr(now)) {
      d = d.subtract(const Duration(days: 7));
    }
    return d;
  }

  // Parses "May 3", "May 3rd", "5/3", "5-3", "2026-05-03", "May 3 2026" etc.
  static DateTime? _parseExplicitDate(String lower, {required DateTime now}) {
    // ISO format: 2026-05-03
    // If the ISO pattern matches we honor it exclusively — do NOT fall through
    // to the numeric pattern below (which would misparse "9999-01-01" as "01-01").
    final isoMatch = RegExp(r'\b(\d{4})-(\d{2})-(\d{2})\b').firstMatch(lower);
    if (isoMatch != null) {
      final y = int.parse(isoMatch.group(1)!);
      final m = int.parse(isoMatch.group(2)!);
      final d = int.parse(isoMatch.group(3)!);
      return _validDate(y, m, d) ? DateTime(y, m, d) : null;
    }

    // "Month day" or "Month day year": "May 3", "May 3rd", "may 3 2026"
    final monthDay = RegExp(
      r'\b(january|february|march|april|may|june|july|august|september|october|november|december)'
      r'\s+(\d{1,2})(?:st|nd|rd|th)?(?:\s+(\d{4}))?\b',
    ).firstMatch(lower);
    if (monthDay != null) {
      final month = _kMonthNames[monthDay.group(1)!]!;
      final day = int.parse(monthDay.group(2)!);
      final year =
          monthDay.group(3) != null ? int.parse(monthDay.group(3)!) : now.year;
      if (_validDate(year, month, day)) return DateTime(year, month, day);
    }

    // Numeric: "5/3" or "5-3" (month/day, US locale)
    final numMatch = RegExp(r'\b(\d{1,2})[/\-](\d{1,2})\b').firstMatch(lower);
    if (numMatch != null) {
      final m = int.parse(numMatch.group(1)!);
      final d = int.parse(numMatch.group(2)!);
      if (m >= 1 && m <= 12 && d >= 1 && d <= 31) {
        // Use current year; if result is in the future, use last year
        var year = now.year;
        var candidate = DateTime(year, m, d);
        if (candidate.isAfter(now)) candidate = DateTime(year - 1, m, d);
        return candidate;
      }
    }

    return null;
  }

  static bool _validDate(int y, int m, int d) {
    if (m < 1 || m > 12 || d < 1 || d > 31) return false;
    if (y < 2020 || y > 2099) return false; // sanity clamp
    return true;
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
