import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/rag_corpus_service.dart';
import 'package:gemma_flares/core/services/gemma_task_service.dart';
import 'package:gemma_flares/core/services/lab_logging_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/rag_memory_service.dart';
import 'package:gemma_flares/core/services/tool_audit_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const channel = MethodChannel('test.gemma_flares/lab_logging_rag');

  late Directory tempRoot;
  late AppDatabase database;
  late WearableSampleRepository repository;
  late Map<String, String> chunks;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('gemma_flares_lab_log_');
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

  test('saves confirmed lab candidates and records tool audit', () async {
    final service = LabLoggingService(
      repository: repository,
      toolAuditService: ToolAuditService(database: database),
      nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
    );

    final result = await service.saveCandidates(
      candidates: const [
        GemmaLabCandidate(
          labType: 'crp',
          valueNumeric: 12.4,
          unit: 'mg/L',
          drawnDate: '2026-04-19',
          referenceHigh: 5,
          abnormalFlag: true,
          confidence: 0.91,
          sourceTextSnippet: 'CRP 12.4 mg/L',
        ),
      ],
      source: 'test_chat_lab_review',
    );

    expect(result.savedLabs, hasLength(1));
    expect(result.savedLabs.single.id, isNotNull);
    expect(result.savedLabs.single.labType, 'crp');
    expect(result.analyticsRefreshStatus, 'not_configured');
    expect(result.ragIndexedByLabId.values.single, isFalse);

    final labs = await repository.getLabValues();
    expect(labs, hasLength(1));
    expect(labs.single.valueNumeric, 12.4);

    final audits = await ToolAuditService(database: database).latest();
    expect(audits, hasLength(1));
    expect(audits.single['tool_name'], 'ingest_lab_panel');
    expect(audits.single['validated'], 1);
  });

  test('saves imported labs with verified RAG transaction IDs', () async {
    // RagIndexService is now the write-side for LabLoggingService.
    // RagMemoryService still uses RagCorpusService.
    final service = LabLoggingService(
      repository: repository,
      ragMemoryService: RagMemoryService(
        repository: repository,
        corpusService: RagCorpusService(channel: channel),
        runtime: _FakeRuntime(isModelLoaded: true),
        nowProvider: () => DateTime.parse('2026-05-06T08:00:00Z'),
      ),
      toolAuditService: ToolAuditService(database: database),
      nowProvider: () => DateTime.parse('2026-05-06T08:00:00Z'),
    );

    final result = await service.saveCandidates(
      candidates: const [
        GemmaLabCandidate(
          labType: 'vitamin_d',
          valueNumeric: 29,
          unit: 'nmol/L',
          drawnDate: '2026-05-06',
          confidence: 0.86,
          sourceTextSnippet: '25-hydroxyvitamin D3 Result 29 nmol/L',
        ),
      ],
      source: 'lab_report_import',
    );

    final labId = result.savedLabs.single.id!;
    expect(result.ragIndexedByLabId[labId], isTrue);
    expect(result.ragStatusByLabId[labId], RagMemoryStatus.verified);
    expect(result.ragTransactionIdByLabId[labId], 'lab_tx_$labId');
    expect(result.ragValidatedByLabId[labId], isTrue);
    expect(result.ragValidationStatusByLabId[labId], RagMemoryStatus.verified);
    expect(
      result.ragValidationSnippetByLabId[labId],
      contains('lab_tx_$labId'),
    );
    expect(chunks['lab_tx_$labId'], contains('25-hydroxyvitamin'));

    final ledger = await repository.getRagMemoryTransaction('lab_tx_$labId');
    expect(ledger, isNotNull);
    expect(ledger!.status, RagMemoryStatus.verified);

    final audits = await ToolAuditService(database: database).latest();
    expect(audits.single['tool_name'], 'ingest_lab_panel');
    expect(audits.single['result_json'].toString(), contains('lab_tx_$labId'));
  });
}

class _FakeRuntime implements LocalModelRuntime {
  _FakeRuntime({required this.isModelLoaded});

  final bool isModelLoaded;

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
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async {
    return _status(isModelLoaded: isModelLoaded);
  }

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) async {
    return _status(isModelLoaded: true);
  }

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(String? backendId) async {
    return _status(isModelLoaded: isModelLoaded);
  }
}

LocalModelRuntimeStatus _status({required bool isModelLoaded}) {
  return LocalModelRuntimeStatus(
    status: 'ready',
    runtimeName: 'fake',
    backendStyle: 'litert-lm',
    modelId: 'gemma-4-e2b',
    quantization: 'q4',
    expectedModelFilename: 'model.gguf',
    isBackendLinked: true,
    isBundledModelPresent: true,
    isModelLoaded: isModelLoaded,
    reason: 'test',
  );
}
