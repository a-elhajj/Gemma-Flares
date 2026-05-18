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
  // Activity & fitness
  'steps',
  'active_energy_kcal',
  'exercise_minutes',
  'walking_running_distance_m',
  'flights_climbed',
  'workout',
  // Cardiovascular
  'hrv_sdnn',
  'resting_hr',
  'heart_rate',
  'walking_hr_avg',
  'heart_rate_recovery_1min',
  'high_heart_rate_event',
  'low_heart_rate_event',
  'irregular_heart_rhythm_event',
  'atrial_fibrillation_burden_pct',
  'electrocardiogram',
  // Oxygen & respiration
  'spo2',
  'respiratory_rate',
  // Sleep
  'sleep_segment',
  'wrist_temp_sleep',
  'sleep_breathing_disturbance',
  // Cardiorespiratory fitness
  'vo2_max',
  // Mobility & gait
  'walking_speed_mps',
  'walking_step_length_m',
  'walking_asymmetry_pct',
  'walking_double_support_pct',
  'stair_ascent_speed_mps',
  'stair_descent_speed_mps',
  'six_minute_walk_distance_m',
  // Nutrition & intake
  'dietary_water_ml',
  'dietary_caffeine_mg',
  'dietary_energy_kcal',
  'alcoholic_beverages',
  // Medication
  'medication_dose_event',
];
