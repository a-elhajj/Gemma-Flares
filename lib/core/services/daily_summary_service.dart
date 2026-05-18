import '../database/wearable_sample_repository.dart';

class DailySummaryComputationResult {
  const DailySummaryComputationResult({
    required this.recomputedDates,
    required this.failedDates,
  });

  final List<String> recomputedDates;
  final List<String> failedDates;
}

class BaselineComputationResult {
  const BaselineComputationResult({
    required this.asOfDate,
    required this.readinessState,
    required this.validDays,
    required this.baselineJson,
  });

  final String asOfDate;
  final String readinessState;
  final int validDays;
  final Map<String, Object?> baselineJson;
}

class DailySummaryService {
  DailySummaryService({required WearableSampleRepository repository})
      : _repository = repository;

  final WearableSampleRepository _repository;

  Future<DailySummaryComputationResult> recomputeDates(
    List<String> dates,
  ) async {
    final recomputed = <String>[];
    final failed = <String>[];

    for (final date in dates.toSet().toList()..sort()) {
      try {
        final rows = await _repository.getSamplesForLocalDate(date);
        final summary = _buildSummary(date: date, rows: rows);
        await _repository.upsertDailySummary(summary);
        recomputed.add(date);
      } catch (_) {
        failed.add(date);
      }
    }

    return DailySummaryComputationResult(
      recomputedDates: recomputed,
      failedDates: failed,
    );
  }

  Future<BaselineComputationResult?> recomputeBaseline({
    String? asOfDate,
  }) async {
    final summaries = await _repository.getDailySummaries();
    if (summaries.isEmpty) {
      return null;
    }

    final effectiveDate = asOfDate ?? summaries.last.dateLocal;
    final eligible = summaries
        .where((item) => item.dateLocal.compareTo(effectiveDate) <= 0)
        .toList();
    final recent = eligible.length > 28
        ? eligible.sublist(eligible.length - 28)
        : eligible;
    final validDays =
        recent.where((item) => _countCoreMetrics(item.summaryJson) >= 3).length;
    final readinessState = _readinessState(validDays);

    final baselineJson = <String, Object?>{
      'baseline_hrv_sdnn': _winsorizedMean(
        _metricSeries(recent, 'hrv_sdnn_mean'),
      ),
      'baseline_resting_hr': _winsorizedMean(
        _metricSeries(recent, 'resting_hr_mean'),
      ),
      'baseline_sleep_total_minutes': _winsorizedMean(
        _metricSeries(recent, 'sleep_total_minutes'),
      ),
      'baseline_steps': _winsorizedMean(
        _metricSeries(recent, 'step_count_total'),
      ),
      'baseline_spo2': _winsorizedMean(
        _metricSeries(
          recent,
          'spo2_mean',
          countKey: 'spo2_count',
          minimumCount: 3,
        ),
      ),
      'baseline_temp': _winsorizedMean(
        _metricSeries(recent, 'wrist_temp_mean'),
      ),
      'baseline_window_days': recent.length,
    };

    final record = BaselineSnapshotRecord(
      snapshotDateLocal: effectiveDate,
      readinessState: readinessState,
      baselineJson: baselineJson,
      validDays: validDays,
      createdAt: DateTime.now().toUtc(),
    );
    await _repository.upsertBaselineSnapshot(record);

    return BaselineComputationResult(
      asOfDate: effectiveDate,
      readinessState: readinessState,
      validDays: validDays,
      baselineJson: baselineJson,
    );
  }

  DailySummaryRecord _buildSummary({
    required String date,
    required List<Map<String, Object?>> rows,
  }) {
    final hrvValues = _metricValues(rows, 'hrv_sdnn');
    final restingHrValues = _metricValues(rows, 'resting_hr');
    final heartRateValues = _metricValues(rows, 'heart_rate');
    final spo2Values = _metricValues(rows, 'spo2');
    final stepValues = _metricValues(rows, 'steps');
    final wristTempValues = _metricValues(rows, 'wrist_temp_sleep');
    final workoutValues = _metricValues(rows, 'workout');
    final activeEnergyValues = _metricValues(rows, 'active_energy_kcal');
    final exerciseMinuteValues = _metricValues(rows, 'exercise_minutes');
    final distanceValues = _metricValues(rows, 'walking_running_distance_m');
    final flightsValues = _metricValues(rows, 'flights_climbed');
    final walkingHrValues = _metricValues(rows, 'walking_hr_avg');
    final heartRateRecoveryValues = _metricValues(
      rows,
      'heart_rate_recovery_1min',
    );
    final vo2MaxValues = _metricValues(rows, 'vo2_max');
    final respiratoryRateValues = _metricValues(rows, 'respiratory_rate');
    final breathingDisturbanceValues = _metricValues(
      rows,
      'sleep_breathing_disturbance',
    );
    final caffeineValues = _metricValues(rows, 'dietary_caffeine_mg');
    final waterValues = _metricValues(rows, 'dietary_water_ml');
    final dietaryEnergyValues = _metricValues(rows, 'dietary_energy_kcal');
    final alcoholValues = _metricValues(rows, 'alcoholic_beverages');
    final walkingSpeedValues = _metricValues(rows, 'walking_speed_mps');
    final walkingStepLengthValues = _metricValues(
      rows,
      'walking_step_length_m',
    );
    final walkingAsymmetryValues = _metricValues(rows, 'walking_asymmetry_pct');
    final walkingDoubleSupportValues = _metricValues(
      rows,
      'walking_double_support_pct',
    );
    final stairAscentValues = _metricValues(rows, 'stair_ascent_speed_mps');
    final stairDescentValues = _metricValues(rows, 'stair_descent_speed_mps');
    final sixMinuteWalkValues = _metricValues(
      rows,
      'six_minute_walk_distance_m',
    );
    final rhythmWarningCount = rows
        .where(
          (row) => const {
            'high_heart_rate_event',
            'low_heart_rate_event',
            'irregular_heart_rhythm_event',
            'atrial_fibrillation_burden_pct',
            'electrocardiogram',
          }.contains(row['metric_name']),
        )
        .length;
    final appleHealthSymptomCount = rows
        .where(
          (row) => (row['metric_name'] as String? ?? '').startsWith(
            'apple_health_symptom_',
          ),
        )
        .length;
    final sleepRows = rows
        .where((row) => row['metric_name'] == 'sleep_segment')
        .toList(growable: false);
    final sleepTotalMinutes = sleepRows.isEmpty
        ? null
        : _sleepMinutesForCategoryValues(sleepRows, const {1, 3, 4, 5});
    final sleepInBedMinutes = _sleepMinutesForCategoryValues(sleepRows, const {
      0,
    });
    final sleepCoreMinutes = _sleepMinutesForCategoryValues(sleepRows, const {
      3,
    });
    final sleepDeepMinutes = _sleepMinutesForCategoryValues(sleepRows, const {
      4,
    });
    final sleepRemMinutes = _sleepMinutesForCategoryValues(sleepRows, const {
      5,
    });

    final summaryJson = <String, Object?>{
      'date_local': date,
      'hrv_sdnn_mean': _mean(hrvValues),
      'hrv_sdnn_median': _median(hrvValues),
      'hrv_sdnn_count': hrvValues.length,
      'resting_hr_mean': _mean(restingHrValues),
      'resting_hr_latest':
          restingHrValues.isEmpty ? null : restingHrValues.last,
      'resting_hr_count': restingHrValues.length,
      'hr_mean': _mean(heartRateValues),
      'hr_count': heartRateValues.length,
      'sleep_total_minutes': sleepTotalMinutes,
      'sleep_in_bed_minutes': sleepInBedMinutes == 0 ? null : sleepInBedMinutes,
      'sleep_asleep_core_minutes':
          sleepCoreMinutes == 0 ? null : sleepCoreMinutes,
      'sleep_asleep_deep_minutes':
          sleepDeepMinutes == 0 ? null : sleepDeepMinutes,
      'sleep_asleep_rem_minutes': sleepRemMinutes == 0 ? null : sleepRemMinutes,
      'spo2_mean': _mean(spo2Values),
      'spo2_count': spo2Values.length,
      'step_count_total': stepValues.isEmpty
          ? null
          : stepValues.fold<double>(0, (sum, value) => sum + value).round(),
      'wrist_temp_mean': _mean(wristTempValues),
      'workout_count': workoutValues.length,
      'workout_minutes_total':
          workoutValues.isEmpty ? null : _sum(workoutValues),
      'active_energy_kcal_total':
          activeEnergyValues.isEmpty ? null : _sum(activeEnergyValues),
      'exercise_minutes_total':
          exerciseMinuteValues.isEmpty ? null : _sum(exerciseMinuteValues),
      'walking_running_distance_m_total':
          distanceValues.isEmpty ? null : _sum(distanceValues),
      'flights_climbed_total':
          flightsValues.isEmpty ? null : _sum(flightsValues),
      'walking_hr_avg_mean': _mean(walkingHrValues),
      'heart_rate_recovery_1min_mean': _mean(heartRateRecoveryValues),
      'vo2_max_latest': vo2MaxValues.isEmpty ? null : vo2MaxValues.last,
      'respiratory_rate_mean': _mean(respiratoryRateValues),
      'respiratory_rate_count': respiratoryRateValues.length,
      'sleep_breathing_disturbance_count': breathingDisturbanceValues.length,
      'dietary_caffeine_mg_total':
          caffeineValues.isEmpty ? null : _sum(caffeineValues),
      'dietary_water_ml_total': waterValues.isEmpty ? null : _sum(waterValues),
      'dietary_energy_kcal_total':
          dietaryEnergyValues.isEmpty ? null : _sum(dietaryEnergyValues),
      'alcoholic_beverages_total':
          alcoholValues.isEmpty ? null : _sum(alcoholValues),
      'walking_speed_mean': _mean(walkingSpeedValues),
      'walking_step_length_mean': _mean(walkingStepLengthValues),
      'walking_asymmetry_pct_mean': _mean(walkingAsymmetryValues),
      'walking_double_support_pct_mean': _mean(walkingDoubleSupportValues),
      'stair_ascent_speed_mean': _mean(stairAscentValues),
      'stair_descent_speed_mean': _mean(stairDescentValues),
      'six_minute_walk_distance_latest':
          sixMinuteWalkValues.isEmpty ? null : sixMinuteWalkValues.last,
      'apple_health_symptom_count': appleHealthSymptomCount,
      'rhythm_reliability_warning_count': rhythmWarningCount,
      'missing_metrics_json': _missingMetrics(
        hrvValues: hrvValues,
        restingHrValues: restingHrValues,
        sleepRows: sleepRows,
        stepValues: stepValues,
      ),
    };

    final syncQualityScore = _syncQualityScore(summaryJson);
    return DailySummaryRecord(
      dateLocal: date,
      summaryJson: summaryJson,
      syncQualityScore: syncQualityScore,
      recomputedAt: DateTime.now().toUtc(),
    );
  }

  List<double> _metricValues(
    List<Map<String, Object?>> rows,
    String metricName,
  ) {
    return rows
        .where((row) => row['metric_name'] == metricName)
        .map((row) => ((row['value_numeric'] as num?) ?? 0).toDouble())
        .toList(growable: false);
  }

  int _sleepMinutesForCategoryValues(
    List<Map<String, Object?>> rows,
    Set<int> values,
  ) {
    var total = 0;
    for (final row in rows) {
      final categoryValue = ((row['value_numeric'] as num?) ?? -1).toInt();
      if (!values.contains(categoryValue)) {
        continue;
      }
      final start = DateTime.parse(row['start_time_utc'] as String);
      final end = DateTime.parse(row['end_time_utc'] as String);
      total += end.difference(start).inMinutes;
    }
    return total;
  }

  String _missingMetrics({
    required List<double> hrvValues,
    required List<double> restingHrValues,
    required List<Map<String, Object?>> sleepRows,
    required List<double> stepValues,
  }) {
    final missing = <String>[];
    if (hrvValues.isEmpty) missing.add('missing_hrv');
    if (restingHrValues.isEmpty) missing.add('missing_resting_hr');
    if (sleepRows.isEmpty) missing.add('missing_sleep');
    if (stepValues.isEmpty) missing.add('missing_steps');
    return '[${missing.map((item) => '"$item"').join(',')}]';
  }

  double _syncQualityScore(Map<String, Object?> summaryJson) {
    final checks = <bool>[
      summaryJson['hrv_sdnn_mean'] != null,
      summaryJson['resting_hr_mean'] != null,
      summaryJson['sleep_total_minutes'] != null,
      summaryJson['step_count_total'] != null,
      summaryJson['spo2_mean'] != null,
      summaryJson['wrist_temp_mean'] != null,
    ];
    final present = checks.where((item) => item).length;
    return present / checks.length;
  }

  double _sum(List<double> values) {
    return values.fold<double>(0, (sum, value) => sum + value);
  }

  int _countCoreMetrics(Map<String, Object?> summaryJson) {
    var count = 0;
    if (summaryJson['hrv_sdnn_mean'] != null) count += 1;
    if (summaryJson['resting_hr_mean'] != null) count += 1;
    if (summaryJson['sleep_total_minutes'] != null) count += 1;
    if (summaryJson['step_count_total'] != null) count += 1;
    return count;
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

  String _readinessState(int validDays) {
    if (validDays >= 28) return 'mature';
    if (validDays >= 14) return 'ready';
    if (validDays >= 7) return 'low_confidence';
    return 'not_ready';
  }

  double? _mean(List<double> values) {
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }

  double? _median(List<double> values) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    final middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[middle];
    return (sorted[middle - 1] + sorted[middle]) / 2;
  }

  double? _winsorizedMean(List<double> values) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    if (sorted.length < 5) {
      return _mean(sorted);
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
    return _mean(adjusted);
  }
}
