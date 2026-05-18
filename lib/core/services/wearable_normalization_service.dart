import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../contracts/health_bridge_contracts.dart';

class NormalizedWearableSample {
  const NormalizedWearableSample({
    required this.sampleKey,
    required this.localDate,
    required this.vendorSampleId,
    required this.sourceName,
    required this.sourceDevice,
    required this.metricName,
    required this.metricFamily,
    required this.valueNumeric,
    required this.unit,
    required this.startTimeUtc,
    required this.endTimeUtc,
    required this.timezone,
    required this.aggregationLevel,
    required this.isEstimated,
    required this.isDeleted,
    required this.metadata,
    required this.sourcePayload,
    required this.importedAt,
    required this.updatedAt,
  });

  final String sampleKey;
  final String localDate;
  final String? vendorSampleId;
  final String sourceName;
  final String sourceDevice;
  final String metricName;
  final String metricFamily;
  final double valueNumeric;
  final String unit;
  final DateTime startTimeUtc;
  final DateTime endTimeUtc;
  final String timezone;
  final String aggregationLevel;
  final bool isEstimated;
  final bool isDeleted;
  final Map<String, Object?> metadata;
  final Map<String, Object?> sourcePayload;
  final DateTime importedAt;
  final DateTime updatedAt;

  Map<String, Object?> toRow() {
    return {
      'sample_key': sampleKey,
      'local_date': localDate,
      'vendor_sample_id': vendorSampleId,
      'source_name': sourceName,
      'source_device': sourceDevice,
      'metric_name': metricName,
      'metric_family': metricFamily,
      'value_numeric': valueNumeric,
      'unit': unit,
      'start_time_utc': startTimeUtc.toIso8601String(),
      'end_time_utc': endTimeUtc.toIso8601String(),
      'timezone': timezone,
      'aggregation_level': aggregationLevel,
      'is_estimated': isEstimated ? 1 : 0,
      'is_deleted': isDeleted ? 1 : 0,
      'metadata_json': jsonEncode(metadata),
      'source_payload_json': jsonEncode(sourcePayload),
      'imported_at': importedAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }
}

class NormalizationBatchResult {
  const NormalizationBatchResult({
    required this.samples,
    required this.invalid,
    required this.flags,
  });

  final List<NormalizedWearableSample> samples;
  final int invalid;
  final List<String> flags;
}

class WearableNormalizationService {
  const WearableNormalizationService();

  String normalizedMetricName(HealthMetricType metricType) {
    return _metricName(metricType);
  }

  String normalizedMetricFamily(HealthMetricType metricType) {
    return _metricFamily(metricType);
  }

  String normalizedUnit(HealthMetricType metricType) {
    return _normalizedUnit(metricType);
  }

  NormalizationBatchResult normalizeBatch({
    required HealthMetricType metricType,
    required List<HealthSampleDto> samples,
    DateTime? importedAt,
  }) {
    final validSamples = <NormalizedWearableSample>[];
    var invalid = 0;
    final timestamp = importedAt?.toUtc() ?? DateTime.now().toUtc();

    for (final sample in samples) {
      final normalized = normalizeSample(
        metricType: metricType,
        sample: sample,
        importedAt: timestamp,
      );
      if (normalized == null) {
        invalid += 1;
        continue;
      }
      validSamples.add(normalized);
    }

    return NormalizationBatchResult(
      samples: validSamples,
      invalid: invalid,
      flags: validSamples.isEmpty
          ? const []
          : const ['summary_recompute_required'],
    );
  }

  NormalizedWearableSample? normalizeSample({
    required HealthMetricType metricType,
    required HealthSampleDto sample,
    required DateTime importedAt,
  }) {
    final metricName = _metricName(metricType);
    final metricFamily = _metricFamily(metricType);
    final normalizedValue = _normalizeValue(metricType, sample.value);
    if (!_isValid(metricType, normalizedValue)) {
      return null;
    }

    final sampleKey = _sampleKey(
      sourceName: sample.sourceName,
      metricName: metricName,
      sample: sample,
      normalizedValue: normalizedValue,
    );

    final localDate = _localDate(metricType: metricType, sample: sample);
    return NormalizedWearableSample(
      sampleKey: sampleKey,
      localDate: localDate,
      vendorSampleId: sample.vendorSampleId,
      sourceName: sample.sourceName,
      sourceDevice: sample.sourceDevice,
      metricName: metricName,
      metricFamily: metricFamily,
      valueNumeric: normalizedValue,
      unit: _normalizedUnit(metricType),
      startTimeUtc: sample.startTime.toUtc(),
      endTimeUtc: sample.endTime.toUtc(),
      timezone: sample.timezone,
      aggregationLevel: 'sample',
      isEstimated: sample.metadata['isEstimated'] == true,
      isDeleted: sample.metadata['isDeleted'] == true,
      metadata: sample.metadata,
      sourcePayload: sample.toJson(),
      importedAt: importedAt,
      updatedAt: importedAt,
    );
  }

  double _normalizeValue(HealthMetricType metricType, double value) {
    switch (metricType) {
      case HealthMetricType.oxygenSaturation:
      case HealthMetricType.walkingAsymmetryPercentage:
      case HealthMetricType.walkingDoubleSupportPercentage:
      case HealthMetricType.atrialFibrillationBurden:
        return value <= 1.0 ? value * 100.0 : value;
      default:
        return value;
    }
  }

  bool _isValid(HealthMetricType metricType, double value) {
    switch (metricType) {
      case HealthMetricType.heartRateVariabilitySdnn:
        return value >= 5 && value <= 300;
      case HealthMetricType.restingHeartRate:
        return value >= 30 && value <= 150;
      case HealthMetricType.heartRate:
        return value >= 30 && value <= 220;
      case HealthMetricType.oxygenSaturation:
        return value >= 85 && value <= 100;
      case HealthMetricType.stepCount:
        return value >= 0;
      case HealthMetricType.workout:
      case HealthMetricType.activeEnergyBurned:
      case HealthMetricType.appleExerciseTime:
      case HealthMetricType.distanceWalkingRunning:
      case HealthMetricType.flightsClimbed:
      case HealthMetricType.heartRateRecoveryOneMinute:
      case HealthMetricType.dietaryCaffeine:
      case HealthMetricType.dietaryWater:
      case HealthMetricType.dietaryEnergyConsumed:
      case HealthMetricType.numberOfAlcoholicBeverages:
      case HealthMetricType.walkingStepLength:
      case HealthMetricType.sixMinuteWalkTestDistance:
        return value >= 0;
      case HealthMetricType.walkingHeartRateAverage:
        return value >= 30 && value <= 220;
      case HealthMetricType.vo2Max:
        return value >= 5 && value <= 100;
      case HealthMetricType.respiratoryRate:
        return value >= 4 && value <= 60;
      case HealthMetricType.walkingSpeed:
      case HealthMetricType.stairAscentSpeed:
      case HealthMetricType.stairDescentSpeed:
        return value >= 0 && value <= 10;
      case HealthMetricType.walkingAsymmetryPercentage:
      case HealthMetricType.walkingDoubleSupportPercentage:
      case HealthMetricType.atrialFibrillationBurden:
        return value >= 0 && value <= 100;
      case HealthMetricType.sleepAnalysis:
      case HealthMetricType.appleSleepingWristTemperature:
      case HealthMetricType.sleepingBreathingDisturbance:
      case HealthMetricType.abdominalCramps:
      case HealthMetricType.bloating:
      case HealthMetricType.constipation:
      case HealthMetricType.diarrhea:
      case HealthMetricType.heartburn:
      case HealthMetricType.nausea:
      case HealthMetricType.vomiting:
      case HealthMetricType.appetiteChanges:
      case HealthMetricType.chills:
      case HealthMetricType.fatigue:
      case HealthMetricType.fever:
      case HealthMetricType.medicationDoseEvent:
      case HealthMetricType.highHeartRateEvent:
      case HealthMetricType.lowHeartRateEvent:
      case HealthMetricType.irregularHeartRhythmEvent:
      case HealthMetricType.electrocardiogram:
        return true;
    }
  }

  String _metricName(HealthMetricType metricType) {
    switch (metricType) {
      case HealthMetricType.heartRateVariabilitySdnn:
        return 'hrv_sdnn';
      case HealthMetricType.restingHeartRate:
        return 'resting_hr';
      case HealthMetricType.heartRate:
        return 'heart_rate';
      case HealthMetricType.sleepAnalysis:
        return 'sleep_segment';
      case HealthMetricType.oxygenSaturation:
        return 'spo2';
      case HealthMetricType.stepCount:
        return 'steps';
      case HealthMetricType.appleSleepingWristTemperature:
        return 'wrist_temp_sleep';
      case HealthMetricType.workout:
        return 'workout';
      case HealthMetricType.activeEnergyBurned:
        return 'active_energy_kcal';
      case HealthMetricType.appleExerciseTime:
        return 'exercise_minutes';
      case HealthMetricType.distanceWalkingRunning:
        return 'walking_running_distance_m';
      case HealthMetricType.flightsClimbed:
        return 'flights_climbed';
      case HealthMetricType.walkingHeartRateAverage:
        return 'walking_hr_avg';
      case HealthMetricType.heartRateRecoveryOneMinute:
        return 'heart_rate_recovery_1min';
      case HealthMetricType.vo2Max:
        return 'vo2_max';
      case HealthMetricType.respiratoryRate:
        return 'respiratory_rate';
      case HealthMetricType.sleepingBreathingDisturbance:
        return 'sleep_breathing_disturbance';
      case HealthMetricType.abdominalCramps:
        return 'apple_health_symptom_abdominal_cramps';
      case HealthMetricType.bloating:
        return 'apple_health_symptom_bloating';
      case HealthMetricType.constipation:
        return 'apple_health_symptom_constipation';
      case HealthMetricType.diarrhea:
        return 'apple_health_symptom_diarrhea';
      case HealthMetricType.heartburn:
        return 'apple_health_symptom_heartburn';
      case HealthMetricType.nausea:
        return 'apple_health_symptom_nausea';
      case HealthMetricType.vomiting:
        return 'apple_health_symptom_vomiting';
      case HealthMetricType.appetiteChanges:
        return 'apple_health_symptom_appetite_changes';
      case HealthMetricType.chills:
        return 'apple_health_symptom_chills';
      case HealthMetricType.fatigue:
        return 'apple_health_symptom_fatigue';
      case HealthMetricType.fever:
        return 'apple_health_symptom_fever';
      case HealthMetricType.dietaryCaffeine:
        return 'dietary_caffeine_mg';
      case HealthMetricType.dietaryWater:
        return 'dietary_water_ml';
      case HealthMetricType.dietaryEnergyConsumed:
        return 'dietary_energy_kcal';
      case HealthMetricType.numberOfAlcoholicBeverages:
        return 'alcoholic_beverages';
      case HealthMetricType.medicationDoseEvent:
        return 'medication_dose_event';
      case HealthMetricType.walkingSpeed:
        return 'walking_speed_mps';
      case HealthMetricType.walkingStepLength:
        return 'walking_step_length_m';
      case HealthMetricType.walkingAsymmetryPercentage:
        return 'walking_asymmetry_pct';
      case HealthMetricType.walkingDoubleSupportPercentage:
        return 'walking_double_support_pct';
      case HealthMetricType.stairAscentSpeed:
        return 'stair_ascent_speed_mps';
      case HealthMetricType.stairDescentSpeed:
        return 'stair_descent_speed_mps';
      case HealthMetricType.sixMinuteWalkTestDistance:
        return 'six_minute_walk_distance_m';
      case HealthMetricType.highHeartRateEvent:
        return 'high_heart_rate_event';
      case HealthMetricType.lowHeartRateEvent:
        return 'low_heart_rate_event';
      case HealthMetricType.irregularHeartRhythmEvent:
        return 'irregular_heart_rhythm_event';
      case HealthMetricType.atrialFibrillationBurden:
        return 'atrial_fibrillation_burden_pct';
      case HealthMetricType.electrocardiogram:
        return 'electrocardiogram';
    }
  }

  String _metricFamily(HealthMetricType metricType) {
    switch (metricType) {
      case HealthMetricType.heartRateVariabilitySdnn:
        return 'recovery';
      case HealthMetricType.restingHeartRate:
      case HealthMetricType.heartRate:
        return 'cardiovascular';
      case HealthMetricType.sleepAnalysis:
        return 'sleep';
      case HealthMetricType.oxygenSaturation:
        return 'oxygen';
      case HealthMetricType.stepCount:
        return 'activity';
      case HealthMetricType.appleSleepingWristTemperature:
        return 'temperature';
      case HealthMetricType.workout:
      case HealthMetricType.activeEnergyBurned:
      case HealthMetricType.appleExerciseTime:
      case HealthMetricType.distanceWalkingRunning:
      case HealthMetricType.flightsClimbed:
      case HealthMetricType.walkingSpeed:
      case HealthMetricType.walkingStepLength:
      case HealthMetricType.walkingAsymmetryPercentage:
      case HealthMetricType.walkingDoubleSupportPercentage:
      case HealthMetricType.stairAscentSpeed:
      case HealthMetricType.stairDescentSpeed:
      case HealthMetricType.sixMinuteWalkTestDistance:
        return 'activity';
      case HealthMetricType.walkingHeartRateAverage:
      case HealthMetricType.heartRateRecoveryOneMinute:
      case HealthMetricType.vo2Max:
      case HealthMetricType.highHeartRateEvent:
      case HealthMetricType.lowHeartRateEvent:
      case HealthMetricType.irregularHeartRhythmEvent:
      case HealthMetricType.atrialFibrillationBurden:
      case HealthMetricType.electrocardiogram:
        return 'cardiovascular';
      case HealthMetricType.respiratoryRate:
      case HealthMetricType.sleepingBreathingDisturbance:
        return 'respiratory';
      case HealthMetricType.abdominalCramps:
      case HealthMetricType.bloating:
      case HealthMetricType.constipation:
      case HealthMetricType.diarrhea:
      case HealthMetricType.heartburn:
      case HealthMetricType.nausea:
      case HealthMetricType.vomiting:
      case HealthMetricType.appetiteChanges:
      case HealthMetricType.chills:
      case HealthMetricType.fatigue:
      case HealthMetricType.fever:
        return 'symptom';
      case HealthMetricType.dietaryCaffeine:
      case HealthMetricType.dietaryWater:
      case HealthMetricType.dietaryEnergyConsumed:
      case HealthMetricType.numberOfAlcoholicBeverages:
        return 'nutrition';
      case HealthMetricType.medicationDoseEvent:
        return 'medication';
    }
  }

  String _normalizedUnit(HealthMetricType metricType) {
    switch (metricType) {
      case HealthMetricType.heartRateVariabilitySdnn:
        return 'ms';
      case HealthMetricType.restingHeartRate:
      case HealthMetricType.heartRate:
        return 'bpm';
      case HealthMetricType.sleepAnalysis:
        return 'category';
      case HealthMetricType.oxygenSaturation:
        return 'percent';
      case HealthMetricType.stepCount:
        return 'count';
      case HealthMetricType.appleSleepingWristTemperature:
        return 'degC';
      case HealthMetricType.workout:
      case HealthMetricType.appleExerciseTime:
        return 'min';
      case HealthMetricType.activeEnergyBurned:
      case HealthMetricType.dietaryEnergyConsumed:
        return 'kcal';
      case HealthMetricType.distanceWalkingRunning:
      case HealthMetricType.walkingStepLength:
      case HealthMetricType.sixMinuteWalkTestDistance:
        return 'm';
      case HealthMetricType.flightsClimbed:
      case HealthMetricType.numberOfAlcoholicBeverages:
        return 'count';
      case HealthMetricType.walkingHeartRateAverage:
        return 'bpm';
      case HealthMetricType.heartRateRecoveryOneMinute:
        return 'bpm_drop';
      case HealthMetricType.vo2Max:
        return 'mL/kg/min';
      case HealthMetricType.respiratoryRate:
        return 'breaths/min';
      case HealthMetricType.walkingSpeed:
      case HealthMetricType.stairAscentSpeed:
      case HealthMetricType.stairDescentSpeed:
        return 'm/s';
      case HealthMetricType.walkingAsymmetryPercentage:
      case HealthMetricType.walkingDoubleSupportPercentage:
      case HealthMetricType.atrialFibrillationBurden:
        return 'percent';
      case HealthMetricType.dietaryCaffeine:
        return 'mg';
      case HealthMetricType.dietaryWater:
        return 'mL';
      case HealthMetricType.sleepingBreathingDisturbance:
      case HealthMetricType.abdominalCramps:
      case HealthMetricType.bloating:
      case HealthMetricType.constipation:
      case HealthMetricType.diarrhea:
      case HealthMetricType.heartburn:
      case HealthMetricType.nausea:
      case HealthMetricType.vomiting:
      case HealthMetricType.appetiteChanges:
      case HealthMetricType.chills:
      case HealthMetricType.fatigue:
      case HealthMetricType.fever:
      case HealthMetricType.medicationDoseEvent:
      case HealthMetricType.highHeartRateEvent:
      case HealthMetricType.lowHeartRateEvent:
      case HealthMetricType.irregularHeartRhythmEvent:
      case HealthMetricType.electrocardiogram:
        return 'category';
    }
  }

  String _sampleKey({
    required String sourceName,
    required String metricName,
    required HealthSampleDto sample,
    required double normalizedValue,
  }) {
    if (sample.vendorSampleId != null && sample.vendorSampleId!.isNotEmpty) {
      return '$sourceName|$metricName|${sample.vendorSampleId}';
    }

    final digest = sha1.convert(
      utf8.encode(
        [
          sourceName,
          metricName,
          sample.sourceDevice,
          sample.startTime.toUtc().toIso8601String(),
          sample.endTime.toUtc().toIso8601String(),
          normalizedValue.toStringAsFixed(6),
        ].join('|'),
      ),
    );
    return digest.toString();
  }

  String _dateOnly(DateTime dateTime) {
    final month = dateTime.month.toString().padLeft(2, '0');
    final day = dateTime.day.toString().padLeft(2, '0');
    return '${dateTime.year}-$month-$day';
  }

  String _localDate({
    required HealthMetricType metricType,
    required HealthSampleDto sample,
  }) {
    final localStart = sample.startTime.toLocal();
    final localEnd = sample.endTime.toLocal();

    if (metricType == HealthMetricType.sleepAnalysis) {
      final overnight = localStart.year != localEnd.year ||
          localStart.month != localEnd.month ||
          localStart.day != localEnd.day;
      return _dateOnly(overnight ? localEnd : localStart);
    }

    return _dateOnly(localStart);
  }
}
