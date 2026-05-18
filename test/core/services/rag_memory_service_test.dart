import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/rag_corpus_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/rag_memory_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const channel = MethodChannel('test.gemma_flares/local_model_rag_memory');
  late Directory tempRoot;
  late AppDatabase database;
  late WearableSampleRepository repository;
  late Map<String, String> chunks;
  late bool ragEnabled;
  late RagMemoryService Function({required bool isModelLoaded}) serviceFactory;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_rag_memory_',
    );
    database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    repository = WearableSampleRepository(database: database);
    serviceFactory = ({required bool isModelLoaded}) {
      return RagMemoryService(
        repository: repository,
        corpusService: RagCorpusService(channel: channel),
        runtime: _FakeRuntime(isModelLoaded: isModelLoaded),
        nowProvider: () => DateTime.utc(2026, 5, 6, 12),
      );
    };
    chunks = <String, String>{};
    ragEnabled = false;
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
          if (text == null) return {'ok': false};
          return {'ok': true, 'text': text};
        case 'listCorpusChunks':
          return chunks.keys
              .map(
                (id) => {
                  'chunk_id': id,
                  'bytes': chunks[id]!.length,
                  'modified_at': '2026-05-06T00:00:00Z',
                },
              )
              .toList(growable: false);
        case 'getCorpusStats':
          return {
            'rag_enabled': ragEnabled,
            'corpus_dir_exists': true,
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
            'contains':
                ragEnabled && chunks.values.any((text) => text.contains(tx)),
          };
        case 'deleteAllCorpusChunks':
          chunks.clear();
          return true;
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

  test(
    'durable corpus write is not called verified until RAG query confirms',
    () async {
      final service = serviceFactory(isModelLoaded: true);

      final result = await service.writeAndVerify(
        transactionId: 'tx_lab_1',
        sourceType: 'lab_value',
        sourceId: '1',
        text: 'CRP 12.4 mg/L on 2026-05-05',
      );

      expect(result.status, RagMemoryStatus.writtenToCorpus);
      expect(result.verified, isFalse);
      expect(
        chunks['tx_lab_1'],
        contains('Gemma Flares memory transaction: tx_lab_1'),
      );

      final row = await repository.getRagMemoryTransaction('tx_lab_1');
      expect(row, isNotNull);
      expect(row!.status, RagMemoryStatus.writtenToCorpus);
    },
  );

  test(
    'loaded RAG query confirmation promotes transaction to verified',
    () async {
      ragEnabled = true;
      final service = serviceFactory(isModelLoaded: true);

      final result = await service.writeAndVerify(
        transactionId: 'tx_symptom_1',
        sourceType: 'symptom',
        sourceId: '1',
        text: 'Urgency improved after dinner.',
      );

      expect(result.status, RagMemoryStatus.verified);
      expect(result.verified, isTrue);

      final row = await repository.getRagMemoryTransaction('tx_symptom_1');
      expect(row!.verifiedAt, isNotNull);
    },
  );

  test('export includes ledger rows and corpus previews', () async {
    final service = serviceFactory(isModelLoaded: false);
    await service.writeAndVerify(
      transactionId: 'tx_export_1',
      sourceType: 'lab_value',
      sourceId: '7',
      text: 'Fecal calprotectin 220 ug/g.',
    );

    final export = await service.exportRagContents();

    expect(export.payload['transactions'].toString(), contains('tx_export_1'));
    expect(export.payload['chunks'].toString(), contains('Fecal calprotectin'));
    expect(export.payload['corpus_stats'].toString(), contains('chunk_count'));
  });

  test('delete clears corpus and tombstones ledger rows', () async {
    final service = serviceFactory(isModelLoaded: false);
    await service.writeAndVerify(
      transactionId: 'tx_delete_1',
      sourceType: 'lab_value',
      sourceId: '9',
      text: 'ESR 33 mm/h.',
    );

    await service.deleteAllRagContents();

    expect(chunks, isEmpty);
    final row = await repository.getRagMemoryTransaction('tx_delete_1');
    expect(row!.status, RagMemoryStatus.deleted);
  });

  test(
    'setup profile transaction is idempotent and upserts ledger row',
    () async {
      final service = serviceFactory(isModelLoaded: false);

      final first = await service.writeAndVerify(
        transactionId: RagMemoryService.setupProfileTransactionId,
        sourceType: 'setup',
        sourceId: 'user_profile',
        text: 'Gemma Flares setup profile anchor. Disease: UC.',
        metadata: const {'setup_phase': 'profile'},
      );
      final second = await service.writeAndVerify(
        transactionId: RagMemoryService.setupProfileTransactionId,
        sourceType: 'setup',
        sourceId: 'user_profile',
        text: 'Gemma Flares setup profile anchor. Disease: CD.',
        metadata: const {'setup_phase': 'profile', 'retry': true},
      );

      expect(first.transactionId, RagMemoryService.setupProfileTransactionId);
      expect(second.transactionId, RagMemoryService.setupProfileTransactionId);

      final rows = await repository.getRagMemoryTransactions();
      final setupRows = rows
          .where(
            (row) =>
                row.transactionId == RagMemoryService.setupProfileTransactionId,
          )
          .toList(growable: false);
      expect(setupRows.length, 1);
      expect(setupRows.single.sourceType, 'setup');
      expect(setupRows.single.sourceId, 'user_profile');

      final chunk = chunks[setupRows.single.chunkId] ?? '';
      expect(chunk, contains('Disease: CD.'));
    },
  );

  test(
    'setup health transaction upgrades to verified after runtime is loaded',
    () async {
      final service = serviceFactory(isModelLoaded: false);

      final write = await service.writeAndVerify(
        transactionId: RagMemoryService.setupHealthTransactionId,
        sourceType: 'setup',
        sourceId: 'apple_health',
        text: 'Gemma Flares setup health anchor. Imported samples: 24.',
        metadata: const {'setup_phase': 'health', 'imported_samples': 24},
      );
      expect(write.status, RagMemoryStatus.writtenToCorpus);
      expect(write.verified, isFalse);

      ragEnabled = true;
      final verifyingService = serviceFactory(isModelLoaded: true);
      final verification = await verifyingService.verifyTransaction(
        RagMemoryService.setupHealthTransactionId,
      );

      expect(verification.verified, isTrue);
      expect(verification.status, RagMemoryStatus.verified);
      expect(verification.queryVerified, isTrue);
    },
  );
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
