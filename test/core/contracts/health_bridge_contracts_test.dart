import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/contracts/health_bridge_contracts.dart';

void main() {
  test('authorization status request serializes metric wire names', () {
    const request = AuthorizationStatusRequest(
      requestedTypes: [
        HealthMetricType.heartRateVariabilitySdnn,
        HealthMetricType.stepCount,
      ],
    );

    expect(request.toJson(), {
      'requestedTypes': ['heartRateVariabilitySDNN', 'stepCount'],
    });
  });

  // ── Regression tests for fb36008 ──────────────────────────────────────────
  // fb36008 changed HealthKitBridge.swift to return "denied" for .unnecessary
  // (Bug 1) and [] for grantedTypes on success (Bug 2). These contract tests
  // verify the Dart parsing layer handles all wire values correctly.

  test(
    'AuthorizationStatusResponse.fromJson parses "authorized" wire name '
    '(regression: fb36008 Bug 1 caused Swift to never return "authorized")',
    () {
      final response = AuthorizationStatusResponse.fromJson({
        'healthDataAvailable': true,
        'requestedAt': '2026-04-12T00:00:00Z',
        'typeStatuses': {'heartRateVariabilitySDNN': 'authorized'},
      });

      expect(response.healthDataAvailable, isTrue);
      expect(
        response.typeStatuses[HealthMetricType.heartRateVariabilitySdnn],
        HealthAuthorizationState.authorized,
      );
    },
  );

  test(
    'AuthorizationStatusResponse.fromJson parses all four authorization states',
    () {
      final response = AuthorizationStatusResponse.fromJson({
        'healthDataAvailable': true,
        'requestedAt': '2026-04-12T00:00:00Z',
        'typeStatuses': {
          'heartRateVariabilitySDNN': 'authorized',
          'restingHeartRate': 'notDetermined',
          'heartRate': 'denied',
          'sleepAnalysis': 'unavailable',
        },
      });

      expect(
        response.typeStatuses[HealthMetricType.heartRateVariabilitySdnn],
        HealthAuthorizationState.authorized,
      );
      expect(
        response.typeStatuses[HealthMetricType.restingHeartRate],
        HealthAuthorizationState.notDetermined,
      );
      expect(
        response.typeStatuses[HealthMetricType.heartRate],
        HealthAuthorizationState.denied,
      );
      expect(
        response.typeStatuses[HealthMetricType.sleepAnalysis],
        HealthAuthorizationState.unavailable,
      );
    },
  );

  test(
    'AuthorizationStatusResponse.fromJson handles missing typeStatuses gracefully',
    () {
      final response = AuthorizationStatusResponse.fromJson({
        'healthDataAvailable': false,
        'requestedAt': '2026-04-12T00:00:00Z',
      });

      expect(response.healthDataAvailable, isFalse);
      expect(response.typeStatuses, isEmpty);
    },
  );

  test(
    'RequestAuthorizationResponse.fromJson parses non-empty grantedTypes list '
    '(regression for fb36008 Bug 2: Swift bridge was returning [] always)',
    () {
      final response = RequestAuthorizationResponse.fromJson({
        'status': 'success',
        'grantedTypes': [
          'heartRateVariabilitySDNN',
          'restingHeartRate',
          'heartRate',
          'sleepAnalysis',
          'oxygenSaturation',
          'stepCount',
          'appleSleepingWristTemperature',
        ],
        'notGrantedTypes': ['sleepingBreathingDisturbance'],
        'requestedAt': '2026-04-12T00:00:00Z',
      });

      expect(response.status, 'success');
      expect(response.grantedTypes, hasLength(7));
      expect(
        response.grantedTypes,
        contains(HealthMetricType.heartRateVariabilitySdnn),
      );
      expect(
        response.grantedTypes,
        contains(HealthMetricType.restingHeartRate),
      );
      expect(
        response.grantedTypes,
        contains(HealthMetricType.appleSleepingWristTemperature),
      );
      expect(response.notGrantedTypes, hasLength(1));
      expect(
        response.notGrantedTypes,
        contains(HealthMetricType.sleepingBreathingDisturbance),
      );
    },
  );

  test(
    'RequestAuthorizationResponse.fromJson handles empty grantedTypes gracefully '
    '(regression guard: must not crash on [] — the broken fb36008 payload)',
    () {
      final response = RequestAuthorizationResponse.fromJson({
        'status': 'success',
        'grantedTypes': <String>[],
        'notGrantedTypes': <String>[],
        'requestedAt': '2026-04-12T00:00:00Z',
      });

      expect(response.status, 'success');
      expect(response.grantedTypes, isEmpty);
      expect(response.notGrantedTypes, isEmpty);
    },
  );

  test(
      'RequestAuthorizationResponse.fromJson handles missing grantedTypes key '
      '(defensive: bridge must not crash if field is omitted)', () {
    final response = RequestAuthorizationResponse.fromJson({
      'status': 'failed',
      'requestedAt': '2026-04-12T00:00:00Z',
    });

    expect(response.status, 'failed');
    expect(response.grantedTypes, isEmpty);
    expect(response.notGrantedTypes, isEmpty);
  });

  test(
    'HealthAuthorizationStateWireName.fromWireName throws on unknown wire name '
    '(safety: malformed Swift payloads must not silently map to authorized)',
    () {
      expect(
        () => HealthAuthorizationStateWireName.fromWireName('unknown_state'),
        throwsArgumentError,
        reason:
            'Unknown authorization states must throw, not silently default to authorized',
      );
    },
  );

  // ── End regression tests for fb36008 ──────────────────────────────────────

  test('fetch samples response deserializes sample payload', () {
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
    expect(response.samples, hasLength(1));
    expect(response.samples.single.metadata['algorithmVersion'], 'native');
    expect(
      response.samples.single.toJson()['metricType'],
      'heartRateVariabilitySDNN',
    );
  });
}
