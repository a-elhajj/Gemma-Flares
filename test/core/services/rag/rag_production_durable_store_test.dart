import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart'
    show SymptomRecord;
import 'package:gemma_flares/core/services/deterministic_embedding_service.dart';
import 'package:gemma_flares/core/services/rag_index_service.dart';
import 'package:gemma_flares/core/services/rag_query_service.dart';
import 'package:gemma_flares/core/services/rag_store.dart';
import 'package:gemma_flares/core/services/rag_text_formatter.dart';

import 'rag_test_harness.dart';

void main() {
  late Directory tempRoot;
  late DurableVectorStore store;
  late DeterministicEmbeddingService embedding;
  late RagIndexService index;
  late RagQueryService query;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('gutguard_rag_store_');
    store = DurableVectorStore(rootDirectory: tempRoot);
    embedding = DeterministicEmbeddingService(dimensions: 64);
    index = RagIndexService(embedding: embedding, store: store);
    query = RagQueryService(
      embedding: embedding,
      store: store,
      now: () => DateTime.utc(2026, 5, 15, 12),
    );
  });

  tearDown(() async {
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  test('symptom logger prompt round-trips through durable RAG by unique id',
      () async {
    const originalPrompt =
        'Log symptom: sharp lower right abdominal pain severity 7 after lunch for 45 minutes.';
    final symptom = SymptomRecord(
      id: 9001,
      loggedAt: DateTime.utc(2026, 5, 16, 14, 30),
      symptomType: 'abdominal_pain',
      severity: 7,
      durationMinutes: 45,
      mealRelation: 'after_meal',
      notes: 'Sharp lower right pain after lunch',
      sourceTranscript: originalPrompt,
      extractionMethod: 'gemma4_e2b_structured',
      extractionConfidence: 0.97,
      createdAt: DateTime.utc(2026, 5, 16, 14, 31),
    );

    final write = await index.indexSymptom(symptom.id!, symptom);
    expect(write.status, RagIndexStatus.success);
    expect(write.chunkId, 'symptom_tx_9001');

    final direct = await query.getById(
      collection: RagCollection.symptoms,
      chunkId: 'symptom_tx_9001',
    );
    expect(direct, isNotNull);
    expect(direct!.text, contains('chunk_id: symptom_tx_9001'));
    expect(direct.text, contains('source_transcript: $originalPrompt'));

    final retrieved = await query.query(
      originalPrompt,
      config: const RagQueryConfig(collections: [RagCollection.symptoms]),
    );
    expect(retrieved.matches, isNotEmpty);
    expect(retrieved.matches.first.id, 'symptom_tx_9001');
    expect(retrieved.matches.first.text, contains(originalPrompt));
  });

  test(
      'all user health data types receive stable ids and exact readable chunks',
      () async {
    final symptom = TestSymptoms.abdominalPain();
    final lab = TestLabs.crp();
    final checkIn = TestCheckIns.cdFlare();
    final medication = TestMedications.mesalamineTaken();
    final food = TestFood.oatmeal();
    final procedure = TestProcedures.colonoscopyCd();
    final profile = TestProfiles.crohnsMale();

    final writes = [
      await index.indexSymptom(symptom.id!, symptom),
      await index.indexLabResult(lab.id!, lab),
      await index.indexCheckIn(checkIn.id!, checkIn),
      await index.indexMedication(medication.id!, medication),
      await index.indexFoodEntryById(food.id!, food),
      await index.indexEndoscopyRecord(id: procedure.id!, record: procedure),
      await index.indexProfile(profile),
      await index.indexHealthSync(
        dateLocal: '2026-05-14',
        metrics: TestHealthData.allMetrics(),
        riskScore: 39,
        riskBand: 'moderate',
        reason: 'daily_health_sync',
      ),
    ];

    expect(writes.every((result) => result.status == RagIndexStatus.success),
        isTrue);

    const expected = <({String collection, String chunkId})>[
      (collection: RagCollection.symptoms, chunkId: 'symptom_tx_101'),
      (collection: RagCollection.labs, chunkId: 'lab_tx_301'),
      (collection: RagCollection.checkins, chunkId: 'checkin_tx_502'),
      (collection: RagCollection.summaries, chunkId: 'med_tx_701'),
      (collection: RagCollection.food, chunkId: 'food_tx_901'),
      (collection: RagCollection.procedures, chunkId: 'endoscopy_tx_1102'),
      (collection: RagCollection.profile, chunkId: 'profile_rag_v1'),
      (
        collection: RagCollection.summaries,
        chunkId: 'health_sync_tx_2026-05-14',
      ),
    ];

    for (final entry in expected) {
      final match = await query.getById(
          collection: entry.collection, chunkId: entry.chunkId);
      expect(match, isNotNull, reason: '${entry.chunkId} missing');
      expect(match!.text, isNotEmpty);
    }

    expect(
      (await query.getById(
        collection: RagCollection.labs,
        chunkId: 'lab_tx_301',
      ))!
          .text,
      contains('lab_type: crp'),
    );
    expect(
      (await query.getById(
        collection: RagCollection.food,
        chunkId: 'food_tx_901',
      ))!
          .text,
      contains('food_name: Oatmeal with blueberries'),
    );
    expect(await store.count(RagCollection.symptoms), 1);
    expect(await store.count(RagCollection.labs), 1);
  });
}
