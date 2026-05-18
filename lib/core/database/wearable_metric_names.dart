// Canonical list of normalized metric_name values stored in wearable_samples.
// Generated from WearableNormalizationService._metricName() — the snake_case
// names that WearableNormalizationService.toRow() writes to the DB.
//
// BUG-065 root cause: the previous SQL IN-list in getWearableMetricAggregates
// used wireNames ('stepCount', 'heartRateVariabilitySDNN', …) which never
// matched any row. This constant uses the correct stored names.
//
// WearableAggregationService imports this to build its registry dbName fields.
// WearableSampleRepository imports this to build the dynamic SQL IN-list.
// Neither imports the other, so there is no circular dependency.
const List<String> kWearableMetricDbNames = [
  'steps',
  'active_energy_kcal',
  'exercise_minutes',
  'walking_running_distance_m',
  'flights_climbed',
  'hrv_sdnn',
  'resting_hr',
  'heart_rate',
  'walking_hr_avg',
  'heart_rate_recovery_1min',
  'spo2',
  'respiratory_rate',
  'sleep_segment',
  'wrist_temp_sleep',
  'sleep_breathing_disturbance',
  'vo2_max',
  'walking_speed_mps',
  'stair_ascent_speed_mps',
  'atrial_fibrillation_burden_pct',
  'dietary_water_ml',
  'dietary_caffeine_mg',
];
