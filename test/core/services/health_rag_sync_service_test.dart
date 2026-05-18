import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/contracts/health_bridge_contracts.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/rag_corpus_service.dart';
import 'package:gemma_flares/core/services/health_rag_sync_service.dart';
import 'package:gemma_flares/core/services/health_sync_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/rag_memory_service.dart';
import 'package:gemma_flares/core/services/wearable_normalization_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const channel = MethodChannel('test.gemma_flares/health_rag_sync');
  late Directory tempRoot;
  late AppDatabase database;
  late WearableSampleRepository repository;
  late Map<String, String> chunks;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_health_rag_',
    );
    database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    repository = WearableSampleRepository(database: database);
    chunks = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'writeCorpusChunk':
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          chunks[args['chunkId'] as String] = args['text'] as String;
          return true;
        case 'readCorpusChunk':
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          final text = chunks[args['chunkId'] as String];
          return text == null ? {'ok': false} : {'ok': true, 'text': text};
        case 'getCorpusStats':
          return {
            'rag_enabled': true,
            'chunk_count': chunks.length,
            'total_bytes': chunks.values.fold<int>(
              0,
              (total, text) => total + text.length,
            ),
          };
        case 'ragContainsTransaction':
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          final tx = args['transactionId'] as String;
          return {
            'contains': chunks.values.any((text) => text.contains(tx)),
          };
      }
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await database.close();
    await tempRoot.delete(recursive: true);
  });

  test('indexes touched Health dates into RAG ledger', () async {
    final now = DateTime.parse('2026-05-06T12:00:00Z');
    await repository.upsertSamples([
      NormalizedWearableSample(
        sampleKey: 'hrv-1',
        localDate: '2026-05-06',
        vendorSampleId: 'hk-1',
        sourceName: 'Apple Health',
        sourceDevice: 'Apple Watch',
        metricName: 'hrv_sdnn_ms',
        metricFamily: 'recovery',
        valueNumeric: 44,
        unit: 'ms',
        startTimeUtc: now.subtract(const Duration(hours: 2)),
        endTimeUtc: now.subtract(const Duration(hours: 2)),
        timezone: 'UTC',
        aggregationLevel: 'sample',
        isEstimated: false,
        isDeleted: false,
        metadata: const {'source': 'test'},
        sourcePayload: const {'raw': 'fixture'},
        importedAt: now,
        updatedAt: now,
      ),
    ]);
    await repository.upsertDailySummary(
      DailySummaryRecord(
        dateLocal: '2026-05-06',
        summaryJson: const {'hrv_sdnn_mean': 44, 'step_count_total': 7000},
        syncQualityScore: 0.92,
        recomputedAt: now,
      ),
    );
    await repository.upsertDailyFeature(
      DailyFeatureRecord(
        featureDateLocal: '2026-05-06',
        featureJson: const {'hrv_delta': -8, 'sleep_minutes': 410},
        missingnessJson: const {'missing_count': 0},
        recomputedAt: now,
      ),
    );

    final service = HealthRagSyncService(
      repository: repository,
      ragMemoryService: RagMemoryService(
        repository: repository,
        corpusService: RagCorpusService(channel: channel),
        runtime: _FakeRuntime(),
        nowProvider: () => now,
      ),
    );
    final result = HealthSyncRunResult(
      startedAt: now.subtract(const Duration(seconds: 5)),
      endedAt: now,
      metricResults: const [
        MetricSyncResult(
          metricType: HealthMetricType.heartRateVariabilitySdnn,
          status: 'ok',
          fetched: 1,
          inserted: 1,
          updated: 0,
          ignored: 0,
          invalid: 0,
          touchedDates: ['2026-05-06'],
        ),
      ],
    );

    final writes = await service.indexSyncRun(
      result: result,
      reason: 'open_ready_app_launch',
    );

    expect(writes, hasLength(1));
    expect(writes.single.transactionId, 'health_sync_tx_2026-05-06');
    expect(writes.single.status, RagMemoryStatus.verified);
    expect(chunks['health_sync_tx_2026-05-06'], contains('hrv_sdnn_ms'));
    expect(chunks['health_sync_tx_2026-05-06'], contains('step_count_total'));

    final ledger = await repository.getRagMemoryTransaction(
      'health_sync_tx_2026-05-06',
    );
    expect(ledger, isNotNull);
    expect(ledger!.sourceType, 'apple_health_sync');
    expect(ledger.status, RagMemoryStatus.verified);
  });

  test('verifies Health RAG ledger rows split across corpus chunks', () async {
    final now = DateTime.parse('2026-05-06T12:00:00Z');
    final samples = List<NormalizedWearableSample>.generate(180, (index) {
      final timestamp = now.subtract(Duration(minutes: index));
      return NormalizedWearableSample(
        sampleKey: 'hr-$index',
        localDate: '2026-05-06',
        vendorSampleId: 'hk-large-$index',
        sourceName: 'Apple Health',
        sourceDevice: 'Apple Watch',
        metricName: 'heart_rate_bpm',
        metricFamily: 'heart',
        valueNumeric: 72 + (index % 8),
        unit: 'bpm',
        startTimeUtc: timestamp,
        endTimeUtc: timestamp,
        timezone: 'UTC',
        aggregationLevel: 'sample',
        isEstimated: false,
        isDeleted: false,
        metadata: {'source': 'large_fixture', 'index': index},
        sourcePayload: {'raw': 'fixture-$index'.padRight(80, 'x')},
        importedAt: now,
        updatedAt: now,
      );
    });
    await repository.upsertSamples(samples);
    await repository.upsertDailySummary(
      DailySummaryRecord(
        dateLocal: '2026-05-06',
        summaryJson: {
          'large_health_context': List<String>.generate(
            260,
            (index) => 'heart_rate_bpm sample context $index'.padRight(90, 'x'),
          ),
        },
        syncQualityScore: 0.88,
        recomputedAt: now,
      ),
    );

    final service = HealthRagSyncService(
      repository: repository,
      ragMemoryService: RagMemoryService(
        repository: repository,
        corpusService: RagCorpusService(channel: channel),
        runtime: _FakeRuntime(),
        nowProvider: () => now,
      ),
    );
    final result = HealthSyncRunResult(
      startedAt: now.subtract(const Duration(seconds: 5)),
      endedAt: now,
      metricResults: const [
        MetricSyncResult(
          metricType: HealthMetricType.heartRate,
          status: 'ok',
          fetched: 180,
          inserted: 180,
          updated: 0,
          ignored: 0,
          invalid: 0,
          touchedDates: ['2026-05-06'],
        ),
      ],
    );

    final writes = await service.indexSyncRun(
      result: result,
      reason: 'open_ready_app_launch',
    );

    expect(writes.single.status, RagMemoryStatus.verified);
    expect(chunks.keys, contains('health_sync_tx_2026-05-06_p1'));
    expect(chunks.keys, contains('health_sync_tx_2026-05-06_p2'));
    final ledger = await repository.getRagMemoryTransaction(
      'health_sync_tx_2026-05-06',
    );
    expect(ledger!.status, RagMemoryStatus.verified);
    expect(ledger.lastError, isNull);
  });
}

class _FakeRuntime implements LocalModelRuntime {
  @override
  Future<LocalModelResponse> generate(LocalModelRequest request) async {
    return const LocalModelResponse(
      status: 'ok',
      outputText: '',
      runtimeName: 'fake',
    );
  }

  @override
  Future<Map<String, dynamic>> getAvailableBackends() async => const {};

  @override
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async => _status();

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) async =>
      _status();

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(
    String? backendId,
  ) async =>
      _status();
}

LocalModelRuntimeStatus _status() {
  return const LocalModelRuntimeStatus(
    status: 'ready',
    runtimeName: 'fake',
    backendStyle: 'litert-lm',
    modelId: 'gemma-4-e2b',
    quantization: 'q4',
    expectedModelFilename: 'model.gguf',
    isBackendLinked: true,
    isBundledModelPresent: true,
    isModelLoaded: true,
    reason: 'test',
  );
}
