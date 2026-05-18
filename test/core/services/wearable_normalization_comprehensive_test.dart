@Tags(['extended'])
@Skip('Extended regression suite; run on demand with --run-skipped.')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/contracts/health_bridge_contracts.dart';
import 'package:gemma_flares/core/services/wearable_normalization_service.dart';

HealthSampleDto _sample({
  required HealthMetricType type,
  required double value,
  String? vendorId,
  String unit = 'ms',
  DateTime? start,
  DateTime? end,
  String timezone = 'America/Toronto',
  Map<String, Object?> metadata = const {},
}) {
  final s = start ?? DateTime.parse('2026-04-11T08:00:00Z');
  return HealthSampleDto(
    vendorSampleId: vendorId,
    sourceName: 'apple_health',
    sourceDevice: 'AppleWatch',
    metricType: type,
    value: value,
    unit: unit,
    startTime: s,
    endTime: end ?? s.add(const Duration(minutes: 1)),
    timezone: timezone,
    metadata: metadata,
  );
}

void main() {
  const service = WearableNormalizationService();
  final importedAt = DateTime.parse('2026-04-12T00:00:00Z');

  group('oxygen saturation normalization', () {
    test('converts fraction 0.97 to percent 97.0', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.oxygenSaturation,
        samples: [
          _sample(
            type: HealthMetricType.oxygenSaturation,
            value: 0.97,
            vendorId: 'spo2-1',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples.single.valueNumeric, 97.0);
      expect(result.samples.single.unit, 'percent');
    });

    test('passes through already-percent value 96.5', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.oxygenSaturation,
        samples: [
          _sample(
            type: HealthMetricType.oxygenSaturation,
            value: 96.5,
            vendorId: 'spo2-2',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples.single.valueNumeric, 96.5);
    });

    test('rejects SpO2 below 85%', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.oxygenSaturation,
        samples: [
          _sample(
            type: HealthMetricType.oxygenSaturation,
            value: 0.80,
            vendorId: 'spo2-low',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.invalid, 1);
      expect(result.samples, isEmpty);
    });

    test('rejects SpO2 above 100%', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.oxygenSaturation,
        samples: [
          _sample(
            type: HealthMetricType.oxygenSaturation,
            value: 101.0,
            vendorId: 'spo2-high',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.invalid, 1);
    });

    test('accepts SpO2 at boundary 85%', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.oxygenSaturation,
        samples: [
          _sample(
            type: HealthMetricType.oxygenSaturation,
            value: 0.85,
            vendorId: 'spo2-boundary',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples.single.valueNumeric, 85.0);
    });

    test('accepts SpO2 at boundary 100%', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.oxygenSaturation,
        samples: [
          _sample(
            type: HealthMetricType.oxygenSaturation,
            value: 1.0,
            vendorId: 'spo2-100',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples.single.valueNumeric, 100.0);
    });
  });

  group('HRV validation ranges', () {
    test('accepts valid HRV of 42 ms', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        samples: [
          _sample(
            type: HealthMetricType.heartRateVariabilitySdnn,
            value: 42.0,
            vendorId: 'hrv-ok',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples, hasLength(1));
      expect(result.samples.single.metricName, 'hrv_sdnn');
      expect(result.samples.single.metricFamily, 'recovery');
      expect(result.samples.single.unit, 'ms');
    });

    test('rejects HRV below 5 ms', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        samples: [
          _sample(
            type: HealthMetricType.heartRateVariabilitySdnn,
            value: 3.0,
            vendorId: 'hrv-low',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.invalid, 1);
    });

    test('rejects HRV above 300 ms', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        samples: [
          _sample(
            type: HealthMetricType.heartRateVariabilitySdnn,
            value: 500.0,
            vendorId: 'hrv-500',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.invalid, 1);
    });

    test('accepts HRV at lower boundary 5 ms', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        samples: [
          _sample(
            type: HealthMetricType.heartRateVariabilitySdnn,
            value: 5.0,
            vendorId: 'hrv-5',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples, hasLength(1));
    });

    test('accepts HRV at upper boundary 300 ms', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        samples: [
          _sample(
            type: HealthMetricType.heartRateVariabilitySdnn,
            value: 300.0,
            vendorId: 'hrv-300',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples, hasLength(1));
    });
  });

  group('resting heart rate validation', () {
    test('accepts RHR in normal range', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.restingHeartRate,
        samples: [
          _sample(
            type: HealthMetricType.restingHeartRate,
            value: 60.0,
            vendorId: 'rhr-ok',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples.single.metricName, 'resting_hr');
      expect(result.samples.single.metricFamily, 'cardiovascular');
      expect(result.samples.single.unit, 'bpm');
    });

    test('rejects RHR below 30 bpm', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.restingHeartRate,
        samples: [
          _sample(
            type: HealthMetricType.restingHeartRate,
            value: 25.0,
            vendorId: 'rhr-low',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.invalid, 1);
    });

    test('rejects RHR above 150 bpm', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.restingHeartRate,
        samples: [
          _sample(
            type: HealthMetricType.restingHeartRate,
            value: 160.0,
            vendorId: 'rhr-high',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.invalid, 1);
    });

    test('accepts RHR at boundary 30', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.restingHeartRate,
        samples: [
          _sample(
            type: HealthMetricType.restingHeartRate,
            value: 30.0,
            vendorId: 'rhr-30',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples, hasLength(1));
    });

    test('accepts RHR at boundary 150', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.restingHeartRate,
        samples: [
          _sample(
            type: HealthMetricType.restingHeartRate,
            value: 150.0,
            vendorId: 'rhr-150',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples, hasLength(1));
    });
  });

  group('heart rate validation', () {
    test('accepts heart rate in range', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.heartRate,
        samples: [
          _sample(
            type: HealthMetricType.heartRate,
            value: 80.0,
            vendorId: 'hr-ok',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples.single.metricName, 'heart_rate');
      expect(result.samples.single.metricFamily, 'cardiovascular');
    });

    test('rejects HR below 30', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.heartRate,
        samples: [
          _sample(
            type: HealthMetricType.heartRate,
            value: 20.0,
            vendorId: 'hr-low',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.invalid, 1);
    });

    test('rejects HR above 220', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.heartRate,
        samples: [
          _sample(
            type: HealthMetricType.heartRate,
            value: 250.0,
            vendorId: 'hr-high',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.invalid, 1);
    });
  });

  group('step count and always-valid types', () {
    test('accepts step count of zero', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.stepCount,
        samples: [
          _sample(
            type: HealthMetricType.stepCount,
            value: 0,
            vendorId: 'steps-0',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples, hasLength(1));
      expect(result.samples.single.metricName, 'steps');
      expect(result.samples.single.metricFamily, 'activity');
      expect(result.samples.single.unit, 'count');
    });

    test('accepts large step count', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.stepCount,
        samples: [
          _sample(
            type: HealthMetricType.stepCount,
            value: 50000,
            vendorId: 'steps-50k',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples, hasLength(1));
    });

    test('sleep analysis is always valid', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.sleepAnalysis,
        samples: [
          _sample(
            type: HealthMetricType.sleepAnalysis,
            value: 3,
            vendorId: 'sleep-valid',
            start: DateTime.parse('2026-04-10T23:00:00Z'),
            end: DateTime.parse('2026-04-11T07:00:00Z'),
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples, hasLength(1));
      expect(result.samples.single.metricName, 'sleep_segment');
      expect(result.samples.single.metricFamily, 'sleep');
    });

    test('wrist temperature is always valid', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.appleSleepingWristTemperature,
        samples: [
          _sample(
            type: HealthMetricType.appleSleepingWristTemperature,
            value: 0.5,
            vendorId: 'temp-ok',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples, hasLength(1));
      expect(result.samples.single.metricName, 'wrist_temp_sleep');
      expect(result.samples.single.metricFamily, 'temperature');
      expect(result.samples.single.unit, 'degC');
    });
  });

  group('production context metrics', () {
    test('normalizes workouts and preserves metadata', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.workout,
        samples: [
          _sample(
            type: HealthMetricType.workout,
            value: 45,
            vendorId: 'workout-1',
            unit: 'min',
            metadata: const {'workoutActivityType': 52},
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples.single.metricName, 'workout');
      expect(result.samples.single.metricFamily, 'activity');
      expect(result.samples.single.unit, 'min');
      expect(result.samples.single.metadata['workoutActivityType'], 52);
    });

    test('normalizes respiratory and mobility metrics', () {
      final respiratory = service.normalizeBatch(
        metricType: HealthMetricType.respiratoryRate,
        samples: [
          _sample(
            type: HealthMetricType.respiratoryRate,
            value: 16,
            vendorId: 'resp-1',
          ),
        ],
        importedAt: importedAt,
      );
      final walking = service.normalizeBatch(
        metricType: HealthMetricType.walkingSpeed,
        samples: [
          _sample(
            type: HealthMetricType.walkingSpeed,
            value: 1.2,
            vendorId: 'walk-1',
          ),
        ],
        importedAt: importedAt,
      );
      expect(respiratory.samples.single.metricName, 'respiratory_rate');
      expect(respiratory.samples.single.unit, 'breaths/min');
      expect(walking.samples.single.metricName, 'walking_speed_mps');
      expect(walking.samples.single.unit, 'm/s');
    });

    test('normalizes Apple Health symptoms and intake context', () {
      final symptom = service.normalizeBatch(
        metricType: HealthMetricType.diarrhea,
        samples: [
          _sample(type: HealthMetricType.diarrhea, value: 1, vendorId: 'sym-1'),
        ],
        importedAt: importedAt,
      );
      final caffeine = service.normalizeBatch(
        metricType: HealthMetricType.dietaryCaffeine,
        samples: [
          _sample(
            type: HealthMetricType.dietaryCaffeine,
            value: 95,
            vendorId: 'caf-1',
          ),
        ],
        importedAt: importedAt,
      );
      expect(
        symptom.samples.single.metricName,
        'apple_health_symptom_diarrhea',
      );
      expect(symptom.samples.single.metricFamily, 'symptom');
      expect(caffeine.samples.single.metricName, 'dietary_caffeine_mg');
      expect(caffeine.samples.single.unit, 'mg');
    });
  });

  group('sample key generation', () {
    test('uses vendor ID when present', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        samples: [
          _sample(
            type: HealthMetricType.heartRateVariabilitySdnn,
            value: 42.0,
            vendorId: 'my-vendor-id',
          ),
        ],
        importedAt: importedAt,
      );
      expect(
        result.samples.single.sampleKey,
        'apple_health|hrv_sdnn|my-vendor-id',
      );
    });

    test('generates SHA1 digest when vendor ID is null', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        samples: [
          _sample(
            type: HealthMetricType.heartRateVariabilitySdnn,
            value: 42.0,
            vendorId: null,
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples.single.sampleKey, hasLength(40)); // SHA1 hex
    });

    test('generates SHA1 digest when vendor ID is empty', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        samples: [
          _sample(
            type: HealthMetricType.heartRateVariabilitySdnn,
            value: 42.0,
            vendorId: '',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples.single.sampleKey, hasLength(40));
    });

    test('same data produces same SHA1 key (dedup)', () {
      final dt = DateTime.parse('2026-04-11T08:00:00Z');
      final s = _sample(
        type: HealthMetricType.heartRateVariabilitySdnn,
        value: 42.0,
        vendorId: null,
        start: dt,
      );
      final r1 = service.normalizeBatch(
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        samples: [s],
        importedAt: importedAt,
      );
      final r2 = service.normalizeBatch(
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        samples: [s],
        importedAt: importedAt,
      );
      expect(r1.samples.single.sampleKey, r2.samples.single.sampleKey);
    });
  });

  group('sleep date anchoring', () {
    test('overnight sleep anchors to wake date', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.sleepAnalysis,
        samples: [
          _sample(
            type: HealthMetricType.sleepAnalysis,
            value: 1,
            vendorId: 'sleep-overnight',
            start: DateTime.parse('2026-04-10T23:00:00Z'),
            end: DateTime.parse('2026-04-11T07:00:00Z'),
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples.single.localDate, '2026-04-11');
    });

    test('same-day nap stays on start date', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.sleepAnalysis,
        samples: [
          _sample(
            type: HealthMetricType.sleepAnalysis,
            value: 1,
            vendorId: 'sleep-nap',
            start: DateTime.parse('2026-04-11T14:00:00Z'),
            end: DateTime.parse('2026-04-11T15:00:00Z'),
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples.single.localDate, '2026-04-11');
    });

    test('non-sleep metric uses start date even with multi-day span', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.stepCount,
        samples: [
          _sample(
            type: HealthMetricType.stepCount,
            value: 500,
            vendorId: 'steps-multiday',
            start: DateTime.parse('2026-04-10T23:55:00Z'),
            end: DateTime.parse('2026-04-11T00:05:00Z'),
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples.single.localDate, '2026-04-10');
    });
  });

  group('batch processing', () {
    test('normalizeBatch processes mixed valid and invalid samples', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        samples: [
          _sample(
            type: HealthMetricType.heartRateVariabilitySdnn,
            value: 42.0,
            vendorId: 'hrv-v',
          ),
          _sample(
            type: HealthMetricType.heartRateVariabilitySdnn,
            value: 500.0,
            vendorId: 'hrv-inv',
          ),
          _sample(
            type: HealthMetricType.heartRateVariabilitySdnn,
            value: 55.0,
            vendorId: 'hrv-v2',
          ),
          _sample(
            type: HealthMetricType.heartRateVariabilitySdnn,
            value: 2.0,
            vendorId: 'hrv-inv2',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.samples, hasLength(2));
      expect(result.invalid, 2);
    });

    test('empty batch returns no samples and no flags', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        samples: const [],
        importedAt: importedAt,
      );
      expect(result.samples, isEmpty);
      expect(result.invalid, 0);
      expect(result.flags, isEmpty);
    });

    test('valid batch includes summary_recompute_required flag', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        samples: [
          _sample(
            type: HealthMetricType.heartRateVariabilitySdnn,
            value: 42.0,
            vendorId: 'hrv-flag',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.flags, contains('summary_recompute_required'));
    });

    test('all-invalid batch has empty flags', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        samples: [
          _sample(
            type: HealthMetricType.heartRateVariabilitySdnn,
            value: 999.0,
            vendorId: 'hrv-allinv',
          ),
        ],
        importedAt: importedAt,
      );
      expect(result.flags, isEmpty);
    });
  });

  group('metadata and toRow serialization', () {
    test('toRow contains all required columns', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        samples: [
          _sample(
            type: HealthMetricType.heartRateVariabilitySdnn,
            value: 42.0,
            vendorId: 'hrv-row',
          ),
        ],
        importedAt: importedAt,
      );
      final row = result.samples.single.toRow();
      expect(row, containsPair('sample_key', 'apple_health|hrv_sdnn|hrv-row'));
      expect(row, containsPair('metric_name', 'hrv_sdnn'));
      expect(row, containsPair('metric_family', 'recovery'));
      expect(row, containsPair('value_numeric', 42.0));
      expect(row, containsPair('unit', 'ms'));
      expect(row, containsPair('aggregation_level', 'sample'));
      expect(row, containsPair('is_estimated', 0));
      expect(row, containsPair('is_deleted', 0));
      expect(row, contains('metadata_json'));
      expect(row, contains('source_payload_json'));
      expect(row, contains('imported_at'));
      expect(row, contains('updated_at'));
    });

    test('isEstimated and isDeleted propagate from metadata', () {
      final result = service.normalizeBatch(
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        samples: [
          _sample(
            type: HealthMetricType.heartRateVariabilitySdnn,
            value: 42.0,
            vendorId: 'hrv-meta',
            metadata: const {'isEstimated': true, 'isDeleted': true},
          ),
        ],
        importedAt: importedAt,
      );
      final row = result.samples.single.toRow();
      expect(row['is_estimated'], 1);
      expect(row['is_deleted'], 1);
    });
  });
}
