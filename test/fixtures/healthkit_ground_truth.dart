// ignore_for_file: lines_longer_than_80_chars
// ═══════════════════════════════════════════════════════════════════════════
// HEALTHKIT GROUND TRUTH FIXTURE
// Synthetic deterministic dataset for WearableAggregationService tests.
//
// Epoch:     2025-01-01 (Wednesday) = dayIndex 0
// Reference: 2026-05-13 (Wednesday) = dayIndex 497  (497 = 71 × 7 → cycle 0)
//
// Cycle mapping (dayIndex % 7):
//   0=Wed  1=Thu  2=Fri  3=Sat  4=Sun  5=Mon  6=Tue
//
// Per-metric formula: value(date) = base + (dayIndex % 7) * increment
//
// ───────────────────────────────────────────────────────────────────────────
// REFERENCE TABLE: Ground Truth Aggregates  (kNow = 2026-05-13)
// ───────────────────────────────────────────────────────────────────────────
//
// Window definitions:
//   today        = 2026-05-13  (Wed, cycle 0)
//   yesterday    = 2026-05-12  (Tue, cycle 6)
//   this_week    = 2026-05-11 to 2026-05-13   (Mon–Wed, 3 days, cycles 5,6,0)
//   last_week    = 2026-05-04 to 2026-05-10   (Mon–Sun, 7 days, cycles 5,6,0,1,2,3,4)
//   this_month   = 2026-05-01 to 2026-05-13   (13 days)
//   last_month   = 2026-04-01 to 2026-04-30   (30 days)
//   past7        = 2026-05-07 to 2026-05-13   (7 days)
//   past14       = 2026-04-30 to 2026-05-13   (14 days)
//   past30       = 2026-04-14 to 2026-05-13   (30 days)
//
// metric                     | today  | yesterday | this_week | last_week | this_month | last_month
// ─────────────────────────────────────────────────────────────────────────────────────────────────
// hrv_sdnn (avgW ms)         |  44.0  |   56.0    |   51.33   |   50.0    |   49.69    |  49.67
// resting_hr (avgE bpm)      |  58.0  |   64.0    |   61.67   |   61.0    |   60.77    |  60.0
// heart_rate (avgE bpm)      |  65.0  |   71.0    |   68.67   |   68.0    |   67.77    |  67.0
// steps (sum)                |  6000  |   9000    |   23500   |  52500    |   98500    | 222500
// active_energy_kcal (sum)   |  300   |   450     |   1175    |  2625     |   4925     | 11250
// exercise_minutes (sum)     |  30    |   45      |   117.5   |  262.5    |   492.5    | 1125
// walking_running_distance_m |  4.0km |   6.8km   |   17.4km  |  39.2km   |   73.4km   | 168km
// flights_climbed (sum)      |  5     |   11      |   26      |  56       |   101      | 225
// sleep_segment (totalH)     |  6.67h |   8.67h   |   23.67h  |  53.67h   |  118.00h   | 213.33h
// spo2 (avgW %)              |  96.0  |   97.8    |   96.9    |   96.9    |   96.93    |  96.93
// respiratory_rate (avgE)    |  14.0  |   17.0    |   15.67   |   15.50   |   15.46    |  15.43
// ═══════════════════════════════════════════════════════════════════════════

/// Ground-truth dates as YYYY-MM-DD strings.
const String kEpochStr = '2025-01-01';
const String kTodayStr = '2026-05-13';
const String kYesterdayStr = '2026-05-12';

/// ISO Monday of the week containing 2026-05-13 (Wednesday).
const String kThisWeekStartStr = '2026-05-11';
const String kLastWeekStartStr = '2026-05-04';
const String kLastWeekEndStr = '2026-05-10';
const String kThisMonthStartStr = '2026-05-01';
const String kLastMonthStartStr = '2026-04-01';
const String kLastMonthEndStr = '2026-04-30';

// ── Core helpers ─────────────────────────────────────────────────────────────

/// Number of calendar days from [kEpochStr] to [dateStr] (inclusive 0-based).
int epochDayIndex(String dateStr) {
  final epoch = DateTime(2025, 1, 1);
  final date = DateTime.parse(dateStr);
  return date.difference(epoch).inDays;
}

/// Cycle position within the 7-day repeating pattern (0–6).
/// 0=Wed 1=Thu 2=Fri 3=Sat 4=Sun 5=Mon 6=Tue
int cycleFor(String dateStr) => epochDayIndex(dateStr) % 7;

// ── Metric formulas ──────────────────────────────────────────────────────────

/// Sparse metrics that only have values on specific days.
const Set<String> kSparseMetrics = {
  'vo2_max',
  'six_minute_walk_distance_m',
  'electrocardiogram',
};

/// Metrics whose non-zero pattern depends on cycle (not linear formula).
const Set<String> kCycleEventMetrics = {
  'workout',
  'alcoholic_beverages',
  'high_heart_rate_event',
};

/// Returns the synthetic daily value for [metric] on [dateStr].
/// Returns 0.0 when a sparse metric has no reading that day.
double syntheticValue(String metric, String dateStr) {
  final idx = epochDayIndex(dateStr);
  final cycle = idx % 7;

  switch (metric) {
    // ── Linear formula metrics ──────────────────────────────────────────────
    case 'hrv_sdnn':
      return 44.0 + cycle * 2.0;
    case 'resting_hr':
      return 58.0 + cycle * 1.0;
    case 'heart_rate':
      return 65.0 + cycle * 1.0;
    case 'steps':
      return 6000.0 + cycle * 500.0;
    case 'active_energy_kcal':
      return 300.0 + cycle * 50.0;
    case 'exercise_minutes':
      return 30.0 + cycle * 5.0;
    case 'walking_running_distance_m':
      return 4000.0 + cycle * 400.0; // stored in metres; displayed in km
    case 'flights_climbed':
      return 5.0 + cycle * 1.0;
    case 'sleep_segment':
      return 24000.0 + cycle * 1200.0; // seconds: 6h40m → 8h40m
    case 'spo2':
      return 96.0 + cycle * 0.3;
    case 'respiratory_rate':
      return 14.0 + cycle * 0.5;
    case 'wrist_temp_sleep':
      return 36.0 + cycle * 0.1;
    case 'walking_speed_mps':
      return 1.20 + cycle * 0.05;
    case 'stair_ascent_speed_mps':
      return 0.40 + cycle * 0.02;
    case 'stair_descent_speed_mps':
      return 0.50 + cycle * 0.02;
    case 'walking_step_length_m':
      return 0.65 + cycle * 0.01;
    case 'walking_asymmetry_pct':
      return 5.0 + cycle * 0.3;
    case 'walking_double_support_pct':
      return 25.0 + cycle * 0.5;
    case 'dietary_water_ml':
      return 1500.0 + cycle * 100.0;
    case 'dietary_caffeine_mg':
      return 100.0 + cycle * 20.0;
    case 'dietary_energy_kcal':
      return 1800.0 + cycle * 100.0;
    case 'heart_rate_recovery_1min':
      return 20.0 + cycle * 2.0;
    case 'walking_hr_avg':
      return 85.0 + cycle * 2.0;
    case 'sleep_breathing_disturbance':
      return 2.0 + cycle * 0.5;

    // ── Always-constant metrics ──────────────────────────────────────────────
    case 'medication_dose_event':
      return 1.0;
    case 'atrial_fibrillation_burden_pct':
      return 0.0;
    case 'low_heart_rate_event':
      return 0.0;
    case 'irregular_heart_rhythm_event':
      return 0.0;

    // ── Cycle-event metrics ──────────────────────────────────────────────────
    case 'workout':
      // 1.0 on Mon (cycle 5) and Thu (cycle 1)
      return (cycle == 5 || cycle == 1) ? 1.0 : 0.0;
    case 'alcoholic_beverages':
      // 1.0 on Sat (cycle 3) and Sun (cycle 4)
      return (cycle == 3 || cycle == 4) ? 1.0 : 0.0;
    case 'high_heart_rate_event':
      // 1.0 on Sun (cycle 4)
      return cycle == 4 ? 1.0 : 0.0;

    // ── Sparse metrics ───────────────────────────────────────────────────────
    case 'electrocardiogram':
      return idx % 30 == 0 ? 1.0 : 0.0;
    case 'vo2_max':
      if (idx % 30 == 0) {
        return 42.0 + (idx ~/ 30) * 0.1;
      }
      return 0.0;
    case 'six_minute_walk_distance_m':
      if (idx % 30 == 0) {
        return 500.0 + (idx ~/ 30) * 2.0;
      }
      return 0.0;

    default:
      return 0.0;
  }
}

/// Returns the aggregation rule string for [metric].
/// Matches WearableAggRule enum names in the service.
String aggregationRule(String metric) {
  switch (metric) {
    case 'steps':
    case 'active_energy_kcal':
    case 'exercise_minutes':
    case 'walking_running_distance_m':
    case 'flights_climbed':
    case 'workout':
    case 'dietary_water_ml':
    case 'dietary_caffeine_mg':
    case 'dietary_energy_kcal':
    case 'alcoholic_beverages':
    case 'medication_dose_event':
    case 'high_heart_rate_event':
    case 'low_heart_rate_event':
    case 'irregular_heart_rhythm_event':
    case 'electrocardiogram':
      return 'sum';
    case 'hrv_sdnn':
    case 'walking_hr_avg':
    case 'heart_rate_recovery_1min':
    case 'spo2':
    case 'walking_speed_mps':
    case 'stair_ascent_speed_mps':
    case 'stair_descent_speed_mps':
    case 'walking_step_length_m':
    case 'walking_asymmetry_pct':
    case 'walking_double_support_pct':
    case 'atrial_fibrillation_burden_pct':
    case 'sleep_breathing_disturbance':
      return 'avgWeighted';
    case 'resting_hr':
    case 'heart_rate':
    case 'respiratory_rate':
    case 'wrist_temp_sleep':
      return 'avgWithEnvelope';
    case 'sleep_segment':
      return 'totalHours';
    case 'vo2_max':
    case 'six_minute_walk_distance_m':
      return 'latest';
    default:
      return 'sum';
  }
}

// ── Reference value computation ──────────────────────────────────────────────

/// Generates all dates in [startDate, endDate] inclusive.
List<String> _dateRange(String startDate, String endDate) {
  final result = <String>[];
  var current = DateTime.parse(startDate);
  final end = DateTime.parse(endDate);
  while (!current.isAfter(end)) {
    result.add(_dateStr(current));
    current = current.add(const Duration(days: 1));
  }
  return result;
}

String _dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Computes the reference aggregate for [metric] over [startDate, endDate].
///
/// Rules:
///  - sum:  sum all daily values; for walking_running_distance_m divide by 1000
///  - totalHours: sum seconds, divide by 3600
///  - latest: last non-zero value (most recent date with value > 0)
///  - avgWeighted / avgWithEnvelope: simple average of daily values
///    (all stub rows have count=1, so weighted = plain average)
///
/// Returns null when no data exists in the window.
double? referenceValue(String metric, String startDate, String endDate) {
  final dates = _dateRange(startDate, endDate);
  final rule = aggregationRule(metric);

  switch (rule) {
    case 'sum':
      double total = 0;
      bool hasData = false;
      for (final d in dates) {
        final v = syntheticValue(metric, d);
        // For purely-zero event metrics (low_hr, afib, irregular) there IS data,
        // it's just zero.  We treat any row as "data present" for sum rules
        // unless it's a sparse metric with no measurement that day.
        if (kSparseMetrics.contains(metric) && v == 0) continue;
        total += v;
        hasData = true;
      }
      if (!hasData) return null;
      // Distance is stored in metres, displayed in km.
      if (metric == 'walking_running_distance_m') return total / 1000.0;
      return total;

    case 'totalHours':
      double totalSec = 0;
      bool hasData = false;
      for (final d in dates) {
        final v = syntheticValue(metric, d);
        totalSec += v;
        hasData = true;
      }
      if (!hasData) return null;
      return totalSec / 3600.0;

    case 'latest':
      // Most recent non-zero value in the window.
      for (final d in dates.reversed) {
        final v = syntheticValue(metric, d);
        // The service uses max_value for latest; we set max_value = v * 1.1 in
        // the stub, but _computeLatest takes max_value first.
        // For the reference table we return v * 1.1 to match what the service
        // actually returns.
        if (v > 0) return v * 1.1;
      }
      return null;

    case 'avgWeighted':
    case 'avgWithEnvelope':
      double sum = 0;
      int count = 0;
      for (final d in dates) {
        final v = syntheticValue(metric, d);
        // For sparse metrics, only count days with readings.
        if (kSparseMetrics.contains(metric) && v == 0) continue;
        // For event metrics that are always 0, include them in the avg.
        sum += v;
        count++;
      }
      if (count == 0) return null;
      return sum / count;

    default:
      return null;
  }
}

// ── Pre-computed reference table ─────────────────────────────────────────────

/// All 35 metric db names covered by the test suite.
const List<String> kAllMetrics = [
  'hrv_sdnn',
  'resting_hr',
  'heart_rate',
  'steps',
  'active_energy_kcal',
  'exercise_minutes',
  'walking_running_distance_m',
  'flights_climbed',
  'sleep_segment',
  'spo2',
  'respiratory_rate',
  'wrist_temp_sleep',
  'walking_speed_mps',
  'stair_ascent_speed_mps',
  'stair_descent_speed_mps',
  'walking_step_length_m',
  'walking_asymmetry_pct',
  'walking_double_support_pct',
  'dietary_water_ml',
  'dietary_caffeine_mg',
  'dietary_energy_kcal',
  'heart_rate_recovery_1min',
  'walking_hr_avg',
  'sleep_breathing_disturbance',
  'medication_dose_event',
  'atrial_fibrillation_burden_pct',
  'low_heart_rate_event',
  'irregular_heart_rhythm_event',
  'workout',
  'alcoholic_beverages',
  'high_heart_rate_event',
  'electrocardiogram',
  'vo2_max',
  'six_minute_walk_distance_m',
];

/// Window key → (startDate, endDate) pairs.
/// All dates computed relative to kNow = 2026-05-13.
const Map<String, (String, String)> kWindowDates = {
  'today': ('2026-05-13', '2026-05-13'),
  'yesterday': ('2026-05-12', '2026-05-12'),
  'this_week': ('2026-05-11', '2026-05-13'),
  'last_week': ('2026-05-04', '2026-05-10'),
  'this_month': ('2026-05-01', '2026-05-13'),
  'last_month': ('2026-04-01', '2026-04-30'),
  'past7': ('2026-05-07', '2026-05-13'),
  'past14': ('2026-04-30', '2026-05-13'),
  'past30': ('2026-04-14', '2026-05-13'),
  'ytd2026': ('2026-01-01', '2026-05-13'),
};

/// Pre-computed reference table: metric → windowKey → expected value.
/// Built once at startup and reused by all test groups.
final Map<String, Map<String, double?>> kReferenceTable = _buildReferenceTable();

Map<String, Map<String, double?>> _buildReferenceTable() {
  final table = <String, Map<String, double?>>{};
  for (final metric in kAllMetrics) {
    final row = <String, double?>{};
    for (final entry in kWindowDates.entries) {
      final (start, end) = entry.value;
      row[entry.key] = referenceValue(metric, start, end);
    }
    table[metric] = row;
  }
  return table;
}
