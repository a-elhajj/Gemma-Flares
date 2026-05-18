enum HealthMetricType {
  heartRateVariabilitySdnn,
  restingHeartRate,
  heartRate,
  sleepAnalysis,
  oxygenSaturation,
  stepCount,
  appleSleepingWristTemperature,
  workout,
  activeEnergyBurned,
  appleExerciseTime,
  distanceWalkingRunning,
  flightsClimbed,
  walkingHeartRateAverage,
  heartRateRecoveryOneMinute,
  vo2Max,
  respiratoryRate,
  sleepingBreathingDisturbance,
  abdominalCramps,
  bloating,
  constipation,
  diarrhea,
  heartburn,
  nausea,
  vomiting,
  appetiteChanges,
  chills,
  fatigue,
  fever,
  dietaryCaffeine,
  dietaryWater,
  dietaryEnergyConsumed,
  numberOfAlcoholicBeverages,
  medicationDoseEvent,
  walkingSpeed,
  walkingStepLength,
  walkingAsymmetryPercentage,
  walkingDoubleSupportPercentage,
  stairAscentSpeed,
  stairDescentSpeed,
  sixMinuteWalkTestDistance,
  highHeartRateEvent,
  lowHeartRateEvent,
  irregularHeartRhythmEvent,
  atrialFibrillationBurden,
  electrocardiogram,
}

extension HealthMetricTypeWireName on HealthMetricType {
  String get wireName {
    switch (this) {
      case HealthMetricType.heartRateVariabilitySdnn:
        return 'heartRateVariabilitySDNN';
      case HealthMetricType.restingHeartRate:
        return 'restingHeartRate';
      case HealthMetricType.heartRate:
        return 'heartRate';
      case HealthMetricType.sleepAnalysis:
        return 'sleepAnalysis';
      case HealthMetricType.oxygenSaturation:
        return 'oxygenSaturation';
      case HealthMetricType.stepCount:
        return 'stepCount';
      case HealthMetricType.appleSleepingWristTemperature:
        return 'appleSleepingWristTemperature';
      case HealthMetricType.workout:
        return 'workout';
      case HealthMetricType.activeEnergyBurned:
        return 'activeEnergyBurned';
      case HealthMetricType.appleExerciseTime:
        return 'appleExerciseTime';
      case HealthMetricType.distanceWalkingRunning:
        return 'distanceWalkingRunning';
      case HealthMetricType.flightsClimbed:
        return 'flightsClimbed';
      case HealthMetricType.walkingHeartRateAverage:
        return 'walkingHeartRateAverage';
      case HealthMetricType.heartRateRecoveryOneMinute:
        return 'heartRateRecoveryOneMinute';
      case HealthMetricType.vo2Max:
        return 'vo2Max';
      case HealthMetricType.respiratoryRate:
        return 'respiratoryRate';
      case HealthMetricType.sleepingBreathingDisturbance:
        return 'sleepingBreathingDisturbance';
      case HealthMetricType.abdominalCramps:
        return 'abdominalCramps';
      case HealthMetricType.bloating:
        return 'bloating';
      case HealthMetricType.constipation:
        return 'constipation';
      case HealthMetricType.diarrhea:
        return 'diarrhea';
      case HealthMetricType.heartburn:
        return 'heartburn';
      case HealthMetricType.nausea:
        return 'nausea';
      case HealthMetricType.vomiting:
        return 'vomiting';
      case HealthMetricType.appetiteChanges:
        return 'appetiteChanges';
      case HealthMetricType.chills:
        return 'chills';
      case HealthMetricType.fatigue:
        return 'fatigue';
      case HealthMetricType.fever:
        return 'fever';
      case HealthMetricType.dietaryCaffeine:
        return 'dietaryCaffeine';
      case HealthMetricType.dietaryWater:
        return 'dietaryWater';
      case HealthMetricType.dietaryEnergyConsumed:
        return 'dietaryEnergyConsumed';
      case HealthMetricType.numberOfAlcoholicBeverages:
        return 'numberOfAlcoholicBeverages';
      case HealthMetricType.medicationDoseEvent:
        return 'medicationDoseEvent';
      case HealthMetricType.walkingSpeed:
        return 'walkingSpeed';
      case HealthMetricType.walkingStepLength:
        return 'walkingStepLength';
      case HealthMetricType.walkingAsymmetryPercentage:
        return 'walkingAsymmetryPercentage';
      case HealthMetricType.walkingDoubleSupportPercentage:
        return 'walkingDoubleSupportPercentage';
      case HealthMetricType.stairAscentSpeed:
        return 'stairAscentSpeed';
      case HealthMetricType.stairDescentSpeed:
        return 'stairDescentSpeed';
      case HealthMetricType.sixMinuteWalkTestDistance:
        return 'sixMinuteWalkTestDistance';
      case HealthMetricType.highHeartRateEvent:
        return 'highHeartRateEvent';
      case HealthMetricType.lowHeartRateEvent:
        return 'lowHeartRateEvent';
      case HealthMetricType.irregularHeartRhythmEvent:
        return 'irregularHeartRhythmEvent';
      case HealthMetricType.atrialFibrillationBurden:
        return 'atrialFibrillationBurden';
      case HealthMetricType.electrocardiogram:
        return 'electrocardiogram';
    }
  }

  static HealthMetricType fromWireName(String value) {
    return HealthMetricType.values.firstWhere(
      (metric) => metric.wireName == value,
      orElse: () =>
          throw ArgumentError.value(value, 'value', 'Unsupported metric type'),
    );
  }
}

enum HealthAuthorizationState { authorized, notDetermined, denied, unavailable }

extension HealthAuthorizationStateWireName on HealthAuthorizationState {
  String get wireName {
    switch (this) {
      case HealthAuthorizationState.authorized:
        return 'authorized';
      case HealthAuthorizationState.notDetermined:
        return 'notDetermined';
      case HealthAuthorizationState.denied:
        return 'denied';
      case HealthAuthorizationState.unavailable:
        return 'unavailable';
    }
  }

  static HealthAuthorizationState fromWireName(String value) {
    return HealthAuthorizationState.values.firstWhere(
      (state) => state.wireName == value,
      orElse: () => throw ArgumentError.value(
        value,
        'value',
        'Unsupported authorization state',
      ),
    );
  }
}

enum FetchMode { backfill, incremental }

extension FetchModeWireName on FetchMode {
  String get wireName {
    switch (this) {
      case FetchMode.backfill:
        return 'backfill';
      case FetchMode.incremental:
        return 'incremental';
    }
  }
}

class AuthorizationStatusRequest {
  const AuthorizationStatusRequest({required this.requestedTypes});

  final List<HealthMetricType> requestedTypes;

  Map<String, Object?> toJson() {
    return {
      'requestedTypes':
          requestedTypes.map((metric) => metric.wireName).toList(),
    };
  }
}

class AuthorizationStatusResponse {
  const AuthorizationStatusResponse({
    required this.healthDataAvailable,
    required this.typeStatuses,
    required this.requestedAt,
  });

  final bool healthDataAvailable;
  final Map<HealthMetricType, HealthAuthorizationState> typeStatuses;
  final DateTime requestedAt;

  factory AuthorizationStatusResponse.fromJson(Map<Object?, Object?> json) {
    final rawStatuses =
        (json['typeStatuses'] as Map<Object?, Object?>?) ?? const {};
    return AuthorizationStatusResponse(
      healthDataAvailable: json['healthDataAvailable'] as bool? ?? false,
      typeStatuses: rawStatuses.map(
        (key, value) => MapEntry(
          HealthMetricTypeWireName.fromWireName(key as String),
          HealthAuthorizationStateWireName.fromWireName(value as String),
        ),
      ),
      requestedAt: DateTime.parse(json['requestedAt'] as String),
    );
  }
}

class RequestAuthorizationResponse {
  const RequestAuthorizationResponse({
    required this.status,
    required this.grantedTypes,
    required this.notGrantedTypes,
    required this.requestedAt,
  });

  final String status;
  final List<HealthMetricType> grantedTypes;
  final List<HealthMetricType> notGrantedTypes;
  final DateTime requestedAt;

  factory RequestAuthorizationResponse.fromJson(Map<Object?, Object?> json) {
    List<HealthMetricType> parseMetrics(Object? value) {
      final items = (value as List<Object?>?) ?? const [];
      return items
          .map((item) => HealthMetricTypeWireName.fromWireName(item as String))
          .toList(growable: false);
    }

    return RequestAuthorizationResponse(
      status: json['status'] as String? ?? 'unknown',
      grantedTypes: parseMetrics(json['grantedTypes']),
      notGrantedTypes: parseMetrics(json['notGrantedTypes']),
      requestedAt: DateTime.parse(json['requestedAt'] as String),
    );
  }
}

class FetchSamplesRequest {
  const FetchSamplesRequest({
    required this.metricType,
    required this.startTime,
    required this.endTime,
    required this.mode,
  });

  final HealthMetricType metricType;
  final DateTime startTime;
  final DateTime endTime;
  final FetchMode mode;

  Map<String, Object?> toJson() {
    return {
      'metricType': metricType.wireName,
      'startTime': startTime.toUtc().toIso8601String(),
      'endTime': endTime.toUtc().toIso8601String(),
      'mode': mode.wireName,
    };
  }
}

class HealthSampleDto {
  const HealthSampleDto({
    required this.vendorSampleId,
    required this.sourceName,
    required this.sourceDevice,
    required this.metricType,
    required this.value,
    required this.unit,
    required this.startTime,
    required this.endTime,
    required this.timezone,
    required this.metadata,
  });

  final String? vendorSampleId;
  final String sourceName;
  final String sourceDevice;
  final HealthMetricType metricType;
  final double value;
  final String unit;
  final DateTime startTime;
  final DateTime endTime;
  final String timezone;
  final Map<String, Object?> metadata;

  factory HealthSampleDto.fromJson(Map<Object?, Object?> json) {
    final rawMetadata =
        (json['metadata'] as Map<Object?, Object?>?) ?? const {};
    return HealthSampleDto(
      vendorSampleId: json['vendorSampleId'] as String?,
      sourceName: json['sourceName'] as String? ?? 'unknown',
      sourceDevice: json['sourceDevice'] as String? ?? 'unknown',
      metricType: HealthMetricTypeWireName.fromWireName(
        json['metricType'] as String,
      ),
      value: (json['value'] as num).toDouble(),
      unit: json['unit'] as String? ?? '',
      startTime: DateTime.parse(json['startTime'] as String),
      endTime: DateTime.parse(json['endTime'] as String),
      timezone: json['timezone'] as String? ?? 'UTC',
      metadata: rawMetadata.map((key, value) => MapEntry(key as String, value)),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'vendorSampleId': vendorSampleId,
      'sourceName': sourceName,
      'sourceDevice': sourceDevice,
      'metricType': metricType.wireName,
      'value': value,
      'unit': unit,
      'startTime': startTime.toUtc().toIso8601String(),
      'endTime': endTime.toUtc().toIso8601String(),
      'timezone': timezone,
      'metadata': metadata,
    };
  }
}

class FetchSamplesResponse {
  const FetchSamplesResponse({
    required this.status,
    required this.metricType,
    required this.samples,
    required this.nextPageToken,
    required this.sampleCount,
  });

  final String status;
  final HealthMetricType metricType;
  final List<HealthSampleDto> samples;
  final String? nextPageToken;
  final int sampleCount;

  factory FetchSamplesResponse.fromJson(Map<Object?, Object?> json) {
    final rawSamples = (json['samples'] as List<Object?>?) ?? const [];
    return FetchSamplesResponse(
      status: json['status'] as String? ?? 'unknown',
      metricType: HealthMetricTypeWireName.fromWireName(
        json['metricType'] as String,
      ),
      samples: rawSamples
          .map(
            (sample) =>
                HealthSampleDto.fromJson(sample as Map<Object?, Object?>),
          )
          .toList(growable: false),
      nextPageToken: json['nextPageToken'] as String?,
      sampleCount: json['sampleCount'] as int? ?? rawSamples.length,
    );
  }
}
