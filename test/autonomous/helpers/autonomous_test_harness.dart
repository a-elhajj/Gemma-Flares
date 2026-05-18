import 'dart:collection';
import 'dart:io';

import 'package:gemma_flares/core/app_services.dart';
import 'package:gemma_flares/core/contracts/health_bridge_contracts.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/method_channel_health_bridge.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class AutonomousTestHarness {
  AutonomousTestHarness._({
    required this.tempRoot,
    required this.database,
    required this.runtime,
    required this.healthBridge,
  });

  final Directory tempRoot;
  final AppDatabase database;
  final TestLocalModelRuntime runtime;
  final TestHealthBridge healthBridge;

  static Future<AutonomousTestHarness> create({
    TestLocalModelRuntime? runtime,
    TestHealthBridge? healthBridge,
  }) async {
    sqfliteFfiInit();
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_autonomous_test',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final resolvedRuntime = runtime ?? TestLocalModelRuntime.loaded();
    final resolvedHealthBridge = healthBridge ?? TestHealthBridge.authorized();
    AppServices.configureForTesting(
      databaseOverride: database,
      localModelRuntimeOverride: resolvedRuntime,
      healthBridgeOverride: resolvedHealthBridge,
    );
    return AutonomousTestHarness._(
      tempRoot: tempRoot,
      database: database,
      runtime: resolvedRuntime,
      healthBridge: resolvedHealthBridge,
    );
  }

  Future<void> dispose() async {
    await database.close();
    await tempRoot.delete(recursive: true);
    AppServices.resetToDefaults();
  }
}

class TestLocalModelRuntime implements LocalModelRuntime {
  TestLocalModelRuntime({
    required this.status,
    required this.loadStatus,
    Iterable<LocalModelResponse> responses = const [],
  }) : _responses = Queue<LocalModelResponse>.of(responses);

  factory TestLocalModelRuntime.loaded({
    Iterable<LocalModelResponse> responses = const [],
  }) {
    const status = LocalModelRuntimeStatus(
      status: 'loaded',
      runtimeName: 'litert-lm-ios-gemma4',
      backendStyle: 'litert-lm',
      modelId: 'gemma-4-e2b-litert-lm',
      quantization: 'int4_litert_lm_bundle',
      expectedModelFilename: 'Models/litert-lm/gemma-4-E2B-it',
      isBackendLinked: true,
      isBundledModelPresent: true,
      isModelLoaded: true,
      reason: 'loaded',
      activeRuntimeProfile: 'phone_balanced',
      backendRequested: 'cpu',
      backendUsed: 'litert-lm',
      supportsTools: true,
      supportsVision: true,
      supportsAudio: true,
      supportsStreaming: false,
      localOnlyEnforced: true,
    );
    return TestLocalModelRuntime(
      status: status,
      loadStatus: status,
      responses: responses,
    );
  }

  factory TestLocalModelRuntime.notLoaded({
    Iterable<LocalModelResponse> responses = const [],
  }) {
    const status = LocalModelRuntimeStatus(
      status: 'not_loaded',
      runtimeName: 'litert-lm-ios-gemma4',
      backendStyle: 'litert-lm',
      modelId: 'gemma-4-e2b-litert-lm',
      quantization: 'int4_litert_lm_bundle',
      expectedModelFilename: 'Models/litert-lm/gemma-4-E2B-it',
      isBackendLinked: true,
      isBundledModelPresent: true,
      isModelLoaded: false,
      reason: 'not_loaded',
      activeRuntimeProfile: 'phone_balanced',
      backendRequested: 'cpu',
      backendUsed: 'litert-lm',
      localOnlyEnforced: true,
    );
    const loadStatus = LocalModelRuntimeStatus(
      status: 'loaded',
      runtimeName: 'litert-lm-ios-gemma4',
      backendStyle: 'litert-lm',
      modelId: 'gemma-4-e2b-litert-lm',
      quantization: 'int4_litert_lm_bundle',
      expectedModelFilename: 'Models/litert-lm/gemma-4-E2B-it',
      isBackendLinked: true,
      isBundledModelPresent: true,
      isModelLoaded: true,
      reason: 'loaded',
      activeRuntimeProfile: 'phone_balanced',
      backendRequested: 'cpu',
      backendUsed: 'litert-lm',
      supportsTools: true,
      supportsVision: true,
      supportsAudio: true,
      localOnlyEnforced: true,
    );
    return TestLocalModelRuntime(
      status: status,
      loadStatus: loadStatus,
      responses: responses,
    );
  }

  final LocalModelRuntimeStatus status;
  final LocalModelRuntimeStatus loadStatus;
  final Queue<LocalModelResponse> _responses;
  final List<LocalModelRequest> generateRequests = [];
  final List<String?> loadProfiles = [];
  String? preferredBackend;

  static const readyResponse = LocalModelResponse(
    status: 'success',
    outputText: 'GutGuard is ready.',
    runtimeName: 'litert-lm-ios-gemma4',
    activeRuntimeProfile: 'phone_balanced',
    backendUsed: 'litert-lm',
    localOnlyVerified: true,
  );

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {
        'litert-lm': {'available': true},
      };

  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    generateRequests.add(request);
    if (_responses.isNotEmpty) {
      return _responses.removeFirst();
    }
    return readyResponse;
  }

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async => status;

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) async {
    loadProfiles.add(profile);
    return loadStatus;
  }

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) async {
    preferredBackend = backendId;
    return loadStatus;
  }
}

class TestHealthBridge extends MethodChannelHealthBridge {
  TestHealthBridge({
    required this.healthDataAvailable,
    required this.authorizationState,
    required this.authorizationStatus,
    Map<HealthMetricType, List<HealthSampleDto>> samplesByMetric = const {},
  }) : samplesByMetric = Map<HealthMetricType, List<HealthSampleDto>>.from(
          samplesByMetric,
        );

  factory TestHealthBridge.authorized({
    Map<HealthMetricType, List<HealthSampleDto>> samplesByMetric = const {},
  }) {
    return TestHealthBridge(
      healthDataAvailable: true,
      authorizationState: HealthAuthorizationState.authorized,
      authorizationStatus: 'success',
      samplesByMetric: samplesByMetric,
    );
  }

  factory TestHealthBridge.denied() {
    return TestHealthBridge(
      healthDataAvailable: true,
      authorizationState: HealthAuthorizationState.denied,
      authorizationStatus: 'denied',
    );
  }

  final bool healthDataAvailable;
  final HealthAuthorizationState authorizationState;
  final String authorizationStatus;
  final Map<HealthMetricType, List<HealthSampleDto>> samplesByMetric;
  final List<List<HealthMetricType>> authorizationRequests = [];
  final List<FetchSamplesRequest> fetchRequests = [];

  @override
  Future<FetchSamplesResponse> fetchSamples(FetchSamplesRequest request) async {
    fetchRequests.add(request);
    final samples = samplesByMetric[request.metricType] ?? const [];
    return FetchSamplesResponse(
      status: 'success',
      metricType: request.metricType,
      samples: samples,
      nextPageToken: null,
      sampleCount: samples.length,
    );
  }

  @override
  Future<AuthorizationStatusResponse> getAuthorizationStatus(
    AuthorizationStatusRequest request,
  ) async {
    return AuthorizationStatusResponse(
      healthDataAvailable: healthDataAvailable,
      typeStatuses: {
        for (final metric in request.requestedTypes) metric: authorizationState,
      },
      requestedAt: DateTime.utc(2026, 4, 20, 10),
    );
  }

  @override
  Future<RequestAuthorizationResponse> requestAuthorization(
    List<HealthMetricType> readTypes,
  ) async {
    authorizationRequests.add(readTypes);
    return RequestAuthorizationResponse(
      status: authorizationStatus,
      grantedTypes: authorizationStatus == 'success' ? readTypes : const [],
      notGrantedTypes: authorizationStatus == 'success' ? const [] : readTypes,
      requestedAt: DateTime.utc(2026, 4, 20, 10),
    );
  }
}

Map<HealthMetricType, List<HealthSampleDto>> buildAppleWatchBackfillSamples({
  required DateTime now,
  required int days,
  bool deterioratingTail = false,
}) {
  final samples = <HealthMetricType, List<HealthSampleDto>>{
    HealthMetricType.heartRateVariabilitySdnn: [],
    HealthMetricType.restingHeartRate: [],
    HealthMetricType.sleepAnalysis: [],
    HealthMetricType.stepCount: [],
    HealthMetricType.oxygenSaturation: [],
    HealthMetricType.appleSleepingWristTemperature: [],
  };
  final startDay = DateTime.utc(
    now.year,
    now.month,
    now.day,
  ).subtract(Duration(days: days));
  for (var offset = 0; offset < days; offset++) {
    final day = startDay.add(Duration(days: offset + 1));
    final isDeteriorated = deterioratingTail && offset >= days - 3;
    final dayString = _localDate(day);
    final baseTime = DateTime.utc(day.year, day.month, day.day, 8);
    samples[HealthMetricType.heartRateVariabilitySdnn]!.add(
      _sample(
        id: 'hrv-$dayString',
        metric: HealthMetricType.heartRateVariabilitySdnn,
        value: isDeteriorated ? 32 : 52,
        unit: 'ms',
        start: baseTime,
        minutes: 5,
      ),
    );
    samples[HealthMetricType.restingHeartRate]!.add(
      _sample(
        id: 'rhr-$dayString',
        metric: HealthMetricType.restingHeartRate,
        value: isDeteriorated ? 71 : 58,
        unit: 'bpm',
        start: baseTime.add(const Duration(minutes: 10)),
      ),
    );
    samples[HealthMetricType.stepCount]!.add(
      _sample(
        id: 'steps-$dayString',
        metric: HealthMetricType.stepCount,
        value: isDeteriorated ? 3800 : 8500,
        unit: 'count',
        start: baseTime,
        minutes: 720,
      ),
    );
    samples[HealthMetricType.oxygenSaturation]!.add(
      _sample(
        id: 'spo2-$dayString',
        metric: HealthMetricType.oxygenSaturation,
        value: 97,
        unit: '%',
        start: baseTime.add(const Duration(hours: 1)),
      ),
    );
    samples[HealthMetricType.appleSleepingWristTemperature]!.add(
      _sample(
        id: 'temp-$dayString',
        metric: HealthMetricType.appleSleepingWristTemperature,
        value: isDeteriorated ? 0.8 : 0.0,
        unit: 'degC',
        start: DateTime.utc(day.year, day.month, day.day, 3),
      ),
    );
    samples[HealthMetricType.sleepAnalysis]!.add(
      _sample(
        id: 'sleep-$dayString',
        metric: HealthMetricType.sleepAnalysis,
        value: 1,
        unit: 'category',
        start: DateTime.utc(
          day.year,
          day.month,
          day.day,
        ).subtract(const Duration(hours: 1, minutes: 30)),
        minutes: isDeteriorated ? 330 : 480,
      ),
    );
  }
  return samples;
}

HealthSampleDto _sample({
  required String id,
  required HealthMetricType metric,
  required double value,
  required String unit,
  required DateTime start,
  int minutes = 1,
}) {
  return HealthSampleDto(
    vendorSampleId: id,
    sourceName: 'apple_health',
    sourceDevice: 'AppleWatchSeries9',
    metricType: metric,
    value: value,
    unit: unit,
    startTime: start,
    endTime: start.add(Duration(minutes: minutes)),
    timezone: 'UTC',
    metadata: const {},
  );
}

String _localDate(DateTime date) => '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';
