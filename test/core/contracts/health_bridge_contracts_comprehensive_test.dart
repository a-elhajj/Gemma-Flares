@Tags(['extended'])
@Skip('Extended regression suite; run on demand with --run-skipped.')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/contracts/health_bridge_contracts.dart';

void main() {
  group('HealthMetricType wire names', () {
    test('heartRateVariabilitySdnn maps to heartRateVariabilitySDNN', () {
      expect(
        HealthMetricType.heartRateVariabilitySdnn.wireName,
        'heartRateVariabilitySDNN',
      );
    });

    test('restingHeartRate maps to restingHeartRate', () {
      expect(HealthMetricType.restingHeartRate.wireName, 'restingHeartRate');
    });

    test('heartRate maps to heartRate', () {
      expect(HealthMetricType.heartRate.wireName, 'heartRate');
    });

    test('sleepAnalysis maps to sleepAnalysis', () {
      expect(HealthMetricType.sleepAnalysis.wireName, 'sleepAnalysis');
    });

    test('oxygenSaturation maps to oxygenSaturation', () {
      expect(HealthMetricType.oxygenSaturation.wireName, 'oxygenSaturation');
    });

    test('stepCount maps to stepCount', () {
      expect(HealthMetricType.stepCount.wireName, 'stepCount');
    });

    test('appleSleepingWristTemperature maps correctly', () {
      expect(
        HealthMetricType.appleSleepingWristTemperature.wireName,
        'appleSleepingWristTemperature',
      );
    });

    test('production context metrics map to HealthKit wire names', () {
      expect(HealthMetricType.workout.wireName, 'workout');
      expect(
        HealthMetricType.activeEnergyBurned.wireName,
        'activeEnergyBurned',
      );
      expect(HealthMetricType.appleExerciseTime.wireName, 'appleExerciseTime');
      expect(
        HealthMetricType.distanceWalkingRunning.wireName,
        'distanceWalkingRunning',
      );
      expect(
        HealthMetricType.walkingHeartRateAverage.wireName,
        'walkingHeartRateAverage',
      );
      expect(
        HealthMetricType.heartRateRecoveryOneMinute.wireName,
        'heartRateRecoveryOneMinute',
      );
      expect(HealthMetricType.respiratoryRate.wireName, 'respiratoryRate');
      expect(HealthMetricType.diarrhea.wireName, 'diarrhea');
      expect(HealthMetricType.dietaryCaffeine.wireName, 'dietaryCaffeine');
      expect(HealthMetricType.walkingSpeed.wireName, 'walkingSpeed');
      expect(
        HealthMetricType.irregularHeartRhythmEvent.wireName,
        'irregularHeartRhythmEvent',
      );
    });

    test('fromWireName round-trips all metric types', () {
      for (final type in HealthMetricType.values) {
        final wireName = type.wireName;
        final roundTripped = HealthMetricTypeWireName.fromWireName(wireName);
        expect(roundTripped, type, reason: 'Failed round-trip for $type');
      }
    });

    test('fromWireName throws for unknown wire name', () {
      expect(
        () => HealthMetricTypeWireName.fromWireName('unknownMetric'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('HealthAuthorizationState wire names', () {
    test('all states round-trip correctly', () {
      for (final state in HealthAuthorizationState.values) {
        final wireName = state.wireName;
        final roundTripped = HealthAuthorizationStateWireName.fromWireName(
          wireName,
        );
        expect(roundTripped, state);
      }
    });

    test('fromWireName throws for unknown state', () {
      expect(
        () => HealthAuthorizationStateWireName.fromWireName('unknownState'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('AuthorizationStatusRequest serialization', () {
    test('serializes single type', () {
      const request = AuthorizationStatusRequest(
        requestedTypes: [HealthMetricType.heartRateVariabilitySdnn],
      );
      expect(request.toJson(), {
        'requestedTypes': ['heartRateVariabilitySDNN'],
      });
    });

    test('serializes multiple types', () {
      const request = AuthorizationStatusRequest(
        requestedTypes: [
          HealthMetricType.heartRateVariabilitySdnn,
          HealthMetricType.stepCount,
          HealthMetricType.sleepAnalysis,
        ],
      );
      final json = request.toJson();
      expect(json['requestedTypes'], hasLength(3));
      expect(json['requestedTypes'], contains('heartRateVariabilitySDNN'));
      expect(json['requestedTypes'], contains('stepCount'));
      expect(json['requestedTypes'], contains('sleepAnalysis'));
    });

    test('serializes empty type list', () {
      const request = AuthorizationStatusRequest(requestedTypes: []);
      expect(request.toJson(), {'requestedTypes': <String>[]});
    });
  });

  group('AuthorizationStatusResponse deserialization', () {
    test('deserializes with multiple authorized types', () {
      final response = AuthorizationStatusResponse.fromJson({
        'healthDataAvailable': true,
        'typeStatuses': {
          'heartRateVariabilitySDNN': 'authorized',
          'stepCount': 'notDetermined',
        },
        'requestedAt': '2026-04-11T12:00:00Z',
      });
      expect(response.healthDataAvailable, isTrue);
      expect(response.typeStatuses, hasLength(2));
      expect(
        response.typeStatuses[HealthMetricType.heartRateVariabilitySdnn],
        HealthAuthorizationState.authorized,
      );
      expect(
        response.typeStatuses[HealthMetricType.stepCount],
        HealthAuthorizationState.notDetermined,
      );
    });

    test('deserializes with health data unavailable', () {
      final response = AuthorizationStatusResponse.fromJson({
        'healthDataAvailable': false,
        'typeStatuses': <String, String>{},
        'requestedAt': '2026-04-11T12:00:00Z',
      });
      expect(response.healthDataAvailable, isFalse);
      expect(response.typeStatuses, isEmpty);
    });
  });

  group('RequestAuthorizationResponse deserialization', () {
    test('deserializes with granted types', () {
      final response = RequestAuthorizationResponse.fromJson({
        'status': 'success',
        'grantedTypes': ['heartRateVariabilitySDNN', 'stepCount'],
        'notGrantedTypes': <String>[],
        'requestedAt': '2026-04-11T12:00:00Z',
      });
      expect(response.status, 'success');
      expect(response.grantedTypes, hasLength(2));
      expect(
        response.grantedTypes,
        contains(HealthMetricType.heartRateVariabilitySdnn),
      );
      expect(response.grantedTypes, contains(HealthMetricType.stepCount));
    });

    test('deserializes with empty granted types', () {
      final response = RequestAuthorizationResponse.fromJson({
        'status': 'denied',
        'grantedTypes': <String>[],
        'notGrantedTypes': ['stepCount'],
        'requestedAt': '2026-04-11T12:00:00Z',
      });
      expect(response.status, 'denied');
      expect(response.grantedTypes, isEmpty);
    });
  });

  group('FetchSamplesResponse deserialization', () {
    test('deserializes single sample', () {
      final response = FetchSamplesResponse.fromJson({
        'status': 'success',
        'metricType': 'heartRateVariabilitySDNN',
        'sampleCount': 1,
        'samples': [
          {
            'vendorSampleId': 'abc123',
            'sourceName': 'apple_health',
            'sourceDevice': 'AppleWatchSeries9',
            'metricType': 'heartRateVariabilitySDNN',
            'value': 42.7,
            'unit': 'ms',
            'startTime': '2026-04-11T05:03:12Z',
            'endTime': '2026-04-11T05:04:12Z',
            'timezone': 'America/New_York',
            'metadata': {'algorithmVersion': 'native'},
          },
        ],
      });
      expect(response.metricType, HealthMetricType.heartRateVariabilitySdnn);
      expect(response.sampleCount, 1);
      expect(response.samples, hasLength(1));
      expect(response.samples.single.value, 42.7);
      expect(response.samples.single.sourceName, 'apple_health');
      expect(response.samples.single.metadata['algorithmVersion'], 'native');
    });

    test('deserializes empty samples', () {
      final response = FetchSamplesResponse.fromJson({
        'status': 'success',
        'metricType': 'stepCount',
        'sampleCount': 0,
        'samples': <Map<String, Object?>>[],
      });
      expect(response.samples, isEmpty);
      expect(response.sampleCount, 0);
    });
  });

  group('HealthSampleDto serialization', () {
    test('toJson produces correct wire format', () {
      final dto = HealthSampleDto(
        vendorSampleId: 'test-id',
        sourceName: 'apple_health',
        sourceDevice: 'AppleWatch',
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        value: 42.0,
        unit: 'ms',
        startTime: DateTime.parse('2026-04-11T08:00:00Z'),
        endTime: DateTime.parse('2026-04-11T08:01:00Z'),
        timezone: 'America/Toronto',
        metadata: const {'key': 'value'},
      );
      final json = dto.toJson();
      expect(json['vendorSampleId'], 'test-id');
      expect(json['sourceName'], 'apple_health');
      expect(json['metricType'], 'heartRateVariabilitySDNN');
      expect(json['value'], 42.0);
      expect(json['timezone'], 'America/Toronto');
    });

    test('toJson roundtrip preserves data', () {
      final dto = HealthSampleDto(
        vendorSampleId: 'rt-id',
        sourceName: 'apple_health',
        sourceDevice: 'AppleWatch',
        metricType: HealthMetricType.stepCount,
        value: 8200,
        unit: 'count',
        startTime: DateTime.parse('2026-04-11T08:00:00Z'),
        endTime: DateTime.parse('2026-04-11T08:05:00Z'),
        timezone: 'America/Toronto',
        metadata: const {},
      );
      final json = dto.toJson();
      final restored = HealthSampleDto.fromJson(json);
      expect(restored.vendorSampleId, dto.vendorSampleId);
      expect(restored.metricType, dto.metricType);
      expect(restored.value, dto.value);
    });
  });

  group('FetchSamplesRequest serialization', () {
    test('serializes request with backfill mode', () {
      final request = FetchSamplesRequest(
        metricType: HealthMetricType.heartRateVariabilitySdnn,
        startTime: DateTime.parse('2026-03-15T00:00:00Z'),
        endTime: DateTime.parse('2026-04-15T00:00:00Z'),
        mode: FetchMode.backfill,
      );
      final json = request.toJson();
      expect(json['metricType'], 'heartRateVariabilitySDNN');
      expect(json['mode'], isNotNull);
    });

    test('serializes request with incremental mode', () {
      final request = FetchSamplesRequest(
        metricType: HealthMetricType.stepCount,
        startTime: DateTime.parse('2026-04-14T00:00:00Z'),
        endTime: DateTime.parse('2026-04-15T00:00:00Z'),
        mode: FetchMode.incremental,
      );
      final json = request.toJson();
      expect(json['metricType'], 'stepCount');
    });
  });
}
