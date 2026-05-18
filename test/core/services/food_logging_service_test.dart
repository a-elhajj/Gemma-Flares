import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/deterministic_embedding_service.dart';
import 'package:gemma_flares/core/services/food_entry.dart';
import 'package:gemma_flares/core/services/food_logging_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/rag_corpus_service.dart';
import 'package:gemma_flares/core/services/rag_index_service.dart';
import 'package:gemma_flares/core/services/rag_memory_service.dart';
import 'package:gemma_flares/core/services/rag_store.dart';
import 'package:gemma_flares/core/services/rag_text_formatter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;
  late WearableSampleRepository repository;
  late InMemoryVectorStore vectorStore;
  late FoodLoggingService service;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('gutguard_food_log_');
    database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    repository = WearableSampleRepository(database: database);
    vectorStore = InMemoryVectorStore();
    service = FoodLoggingService(
      repository: repository,
      ragIndexService: RagIndexService(
        embedding: DeterministicEmbeddingService(),
        store: vectorStore,
      ),
      ragMemoryService: RagMemoryService(
        repository: repository,
        corpusService: RagCorpusService(
          rootDirectory: Directory('${tempRoot.path}/rag_corpus'),
        ),
        runtime: _FakeRuntime(isModelLoaded: true),
        nowProvider: () => DateTime.utc(2026, 5, 16, 12),
      ),
    );
  });

  tearDown(() async {
    await database.close();
    await tempRoot.delete(recursive: true);
  });

  test('saves food to structured DB, corpus ledger, and vector RAG', () async {
    final result = await service.saveFoodEntry(
      FoodEntry(
        loggedAt: DateTime.parse('2026-05-16T15:30:00Z'),
        foodName: ' Spicy tofu rice bowl ',
        description: 'Lunch bowl with chili oil',
        mealType: 'lunch',
        calories: 640,
        isSpicy: true,
        isHighFat: false,
        allergens: const [' Soy ', 'sesame', 'soy'],
        notes: 'Cramps started about 90 minutes later.',
        triggerSuspected: true,
        source: 'manual',
      ),
    );

    final id = result.savedEntry.id!;
    expect(result.savedEntry.foodName, 'Spicy tofu rice bowl');
    expect(result.ragIndexed, isTrue);
    expect(result.ragStatus, RagMemoryStatus.verified);
    expect(result.ragTransactionId, 'food_tx_$id');
    expect(result.ragVerified, isTrue);

    final saved = await repository.getFoodEntry(id);
    expect(saved, isNotNull);
    expect(saved!.foodName, 'Spicy tofu rice bowl');
    expect(saved.mealType, MealType.lunch);
    expect(saved.isSpicy, isTrue);
    expect(saved.triggerSuspected, isTrue);
    expect(saved.allergens, ['soy', 'sesame']);

    final transaction = await repository.getRagMemoryTransaction('food_tx_$id');
    expect(transaction, isNotNull);
    expect(transaction!.sourceType, 'food_entry');
    expect(transaction.sourceId, '$id');

    final chunk = await vectorStore.get(
      collection: RagCollection.food,
      id: RagTextFormatter.foodChunkIdFromInt(id),
    );
    expect(chunk, isNotNull);
    expect(chunk!.text, contains('food_name: Spicy tofu rice bowl'));
    expect(chunk.text, contains('trigger_suspected: yes'));

    final query = await vectorStore.query(
      collection: RagCollection.food,
      queryEmbedding: await DeterministicEmbeddingService()
          .embed('spicy tofu cramps lunch'),
      topK: 1,
    );
    expect(query.single.id, 'food_tx_$id');
  });

  test('rejects empty food names before writing DB or RAG', () async {
    expect(
      () => service.saveFoodEntry(
        FoodEntry(
          loggedAt: DateTime.parse('2026-05-16T15:30:00Z'),
          foodName: '   ',
        ),
      ),
      throwsArgumentError,
    );
    expect(await vectorStore.count(RagCollection.food), 0);
  });
}

class _FakeRuntime implements LocalModelRuntime {
  const _FakeRuntime({required this.isModelLoaded});

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
  Future<LocalModelRuntimeStatus> getRuntimeStatus() async =>
      _status(isModelLoaded: isModelLoaded);

  @override
  Future<LocalModelRuntimeStatus> loadBundledModel({String? profile}) async =>
      _status(isModelLoaded: true);

  @override
  Future<LocalModelRuntimeStatus> setPreferredBackend(
          String? backendId) async =>
      _status(isModelLoaded: isModelLoaded);
}

LocalModelRuntimeStatus _status({required bool isModelLoaded}) {
  return LocalModelRuntimeStatus(
    status: 'ready',
    runtimeName: 'fake',
    backendStyle: 'litert-lm',
    modelId: 'gemma-4-e2b',
    quantization: 'q4',
    expectedModelFilename: 'model.litertlm',
    isBackendLinked: true,
    isBundledModelPresent: true,
    isModelLoaded: isModelLoaded,
    reason: 'test',
  );
}
