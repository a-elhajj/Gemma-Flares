import '../contracts/health_bridge_contracts.dart';

class AppleWatchModelCapability {
  const AppleWatchModelCapability({
    required this.id,
    required this.label,
    required this.supportedMetrics,
    required this.riskFeatureKeys,
  });

  final String id;
  final String label;
  final Set<HealthMetricType> supportedMetrics;
  final Set<String> riskFeatureKeys;

  bool supportsMetric(HealthMetricType metric) =>
      supportedMetrics.contains(metric);

  bool supportsRiskFeature(String key) => riskFeatureKeys.contains(key);
}

class AppleWatchCapabilityService {
  const AppleWatchCapabilityService();

  static const unknownModelId = 'apple_watch_unknown';

  static const _core = <HealthMetricType>{
    HealthMetricType.heartRate,
    HealthMetricType.restingHeartRate,
    HealthMetricType.heartRateVariabilitySdnn,
    HealthMetricType.stepCount,
    HealthMetricType.activeEnergyBurned,
    HealthMetricType.appleExerciseTime,
    HealthMetricType.sleepAnalysis,
  };

  static const _gpsCore = <HealthMetricType>{
    ..._core,
    HealthMetricType.distanceWalkingRunning,
  };

  static const _respiratory = HealthMetricType.respiratoryRate;
  static const _spo2 = HealthMetricType.oxygenSaturation;
  static const _temp = HealthMetricType.appleSleepingWristTemperature;
  static const _vo2 = HealthMetricType.vo2Max;

  static const _basicRisk = <String>{
    'hrv',
    'resting_hr',
    'sleep',
    'steps',
    'activity',
  };

  static const _respiratoryRisk = 'respiratory_rate';
  static const _spo2Risk = 'spo2';
  static const _tempRisk = 'wrist_temperature';
  static const _vo2Risk = 'vo2_max';

  static const models = <AppleWatchModelCapability>[
    AppleWatchModelCapability(
      id: unknownModelId,
      label: 'Apple Watch / not sure',
      supportedMetrics: {..._gpsCore, _respiratory, _spo2, _temp, _vo2},
      riskFeatureKeys: {
        ..._basicRisk,
        _respiratoryRisk,
        _spo2Risk,
        _tempRisk,
        _vo2Risk,
      },
    ),
    AppleWatchModelCapability(
      id: 'apple_watch_1st_gen',
      label: 'Apple Watch 1st gen',
      supportedMetrics: _core,
      riskFeatureKeys: _basicRisk,
    ),
    AppleWatchModelCapability(
      id: 'apple_watch_series_1',
      label: 'Apple Watch Series 1',
      supportedMetrics: _core,
      riskFeatureKeys: _basicRisk,
    ),
    AppleWatchModelCapability(
      id: 'apple_watch_series_2',
      label: 'Apple Watch Series 2',
      supportedMetrics: _gpsCore,
      riskFeatureKeys: _basicRisk,
    ),
    AppleWatchModelCapability(
      id: 'apple_watch_series_3',
      label: 'Apple Watch Series 3',
      supportedMetrics: _gpsCore,
      riskFeatureKeys: _basicRisk,
    ),
    AppleWatchModelCapability(
      id: 'apple_watch_series_4',
      label: 'Apple Watch Series 4',
      supportedMetrics: {..._gpsCore, _vo2},
      riskFeatureKeys: {..._basicRisk, _vo2Risk},
    ),
    AppleWatchModelCapability(
      id: 'apple_watch_series_5',
      label: 'Apple Watch Series 5',
      supportedMetrics: {..._gpsCore, _vo2},
      riskFeatureKeys: {..._basicRisk, _vo2Risk},
    ),
    AppleWatchModelCapability(
      id: 'apple_watch_series_6',
      label: 'Apple Watch Series 6',
      supportedMetrics: {..._gpsCore, _spo2, _vo2},
      riskFeatureKeys: {..._basicRisk, _spo2Risk, _vo2Risk},
    ),
    AppleWatchModelCapability(
      id: 'apple_watch_se_1',
      label: 'Apple Watch SE 1st gen',
      supportedMetrics: {..._gpsCore, _vo2},
      riskFeatureKeys: {..._basicRisk, _vo2Risk},
    ),
    AppleWatchModelCapability(
      id: 'apple_watch_series_7',
      label: 'Apple Watch Series 7',
      supportedMetrics: {..._gpsCore, _spo2, _vo2},
      riskFeatureKeys: {..._basicRisk, _spo2Risk, _vo2Risk},
    ),
    AppleWatchModelCapability(
      id: 'apple_watch_series_8',
      label: 'Apple Watch Series 8',
      supportedMetrics: {..._gpsCore, _respiratory, _spo2, _temp, _vo2},
      riskFeatureKeys: {
        ..._basicRisk,
        _respiratoryRisk,
        _spo2Risk,
        _tempRisk,
        _vo2Risk,
      },
    ),
    AppleWatchModelCapability(
      id: 'apple_watch_se_2',
      label: 'Apple Watch SE 2nd gen',
      supportedMetrics: {..._gpsCore, _respiratory, _vo2},
      riskFeatureKeys: {..._basicRisk, _respiratoryRisk, _vo2Risk},
    ),
    AppleWatchModelCapability(
      id: 'apple_watch_ultra',
      label: 'Apple Watch Ultra',
      supportedMetrics: {..._gpsCore, _respiratory, _spo2, _temp, _vo2},
      riskFeatureKeys: {
        ..._basicRisk,
        _respiratoryRisk,
        _spo2Risk,
        _tempRisk,
        _vo2Risk,
      },
    ),
    AppleWatchModelCapability(
      id: 'apple_watch_series_9',
      label: 'Apple Watch Series 9',
      supportedMetrics: {..._gpsCore, _respiratory, _spo2, _temp, _vo2},
      riskFeatureKeys: {
        ..._basicRisk,
        _respiratoryRisk,
        _spo2Risk,
        _tempRisk,
        _vo2Risk,
      },
    ),
    AppleWatchModelCapability(
      id: 'apple_watch_ultra_2',
      label: 'Apple Watch Ultra 2',
      supportedMetrics: {..._gpsCore, _respiratory, _spo2, _temp, _vo2},
      riskFeatureKeys: {
        ..._basicRisk,
        _respiratoryRisk,
        _spo2Risk,
        _tempRisk,
        _vo2Risk,
      },
    ),
    AppleWatchModelCapability(
      id: 'apple_watch_series_10',
      label: 'Apple Watch Series 10',
      supportedMetrics: {..._gpsCore, _respiratory, _spo2, _temp, _vo2},
      riskFeatureKeys: {
        ..._basicRisk,
        _respiratoryRisk,
        _spo2Risk,
        _tempRisk,
        _vo2Risk,
      },
    ),
  ];

  static Map<String, String> get dropdownItems => {
        for (final model in models) model.id: model.label,
      };

  AppleWatchModelCapability capabilityFor(String? modelIdOrLabel) {
    final normalized = (modelIdOrLabel ?? '').trim().toLowerCase();
    if (normalized.isEmpty) return models.first;
    for (final model in models) {
      if (model.id.toLowerCase() == normalized ||
          model.label.toLowerCase() == normalized) {
        return model;
      }
    }
    return models.first;
  }
}
