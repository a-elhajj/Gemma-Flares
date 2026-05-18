import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/contracts/health_bridge_contracts.dart';
import 'package:gemma_flares/core/services/wearable_normalization_service.dart';

void main() {
  const service = WearableNormalizationService();

  test('normalizes oxygen saturation from fraction to percent', () {
    final result = service.normalizeBatch(
      metricType: HealthMetricType.oxygenSaturation,
      samples: [
        HealthSampleDto(
          vendorSampleId: 'spo2-1',
          sourceName: 'apple_health',
          sourceDevice: 'AppleWatch',
          metricType: HealthMetricType.oxygenSaturation,
          value: 0.97,
          unit: '%',
          startTime: DateTime.parse('2026-04-11T05:03:12Z'),
          endTime: DateTime.parse('2026-04-11T05:04:12Z'),
          timezone: 'America/Toronto',
          metadata: const {},
        ),
      ],
      importedAt: DateTime.parse('2026-04-12T00:00:00Z'),
    );

    expect(result.invalid, 0);
    expect(result.samples.single.metricName, 'spo2');
    expect(result.samples.single.valueNumeric, 97.0);
    expect(result.samples.single.unit, 'percent');
  });

  test('rejects invalid hrv values outside supported range', () {
    final result = service.normalizeBatch(
      metricType: HealthMetricType.heartRateVariabilitySdnn,
      samples: [
        HealthSampleDto(
          vendorSampleId: 'hrv-1',
          sourceName: 'apple_health',
          sourceDevice: 'AppleWatch',
          metricType: HealthMetricType.heartRateVariabilitySdnn,
          value: 500,
          unit: 'ms',
          startTime: DateTime.parse('2026-04-11T05:03:12Z'),
          endTime: DateTime.parse('2026-04-11T05:04:12Z'),
          timezone: 'America/Toronto',
          metadata: const {},
        ),
      ],
      importedAt: DateTime.parse('2026-04-12T00:00:00Z'),
    );

    expect(result.invalid, 1);
    expect(result.samples, isEmpty);
  });
}
