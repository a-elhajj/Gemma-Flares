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

    // "today"
    if (lower.contains('today')) {
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
