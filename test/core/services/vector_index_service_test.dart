import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/vector_index_service.dart';

void main() {
  group('VectorIndexService pure-Dart compatibility index', () {
    test('initializes deterministic embedding dimensions', () async {
      final service = VectorIndexService();

      await service.initialize();

      expect(service.embeddingDim, equals(384));
    });

    test('indexes and retrieves the nearest matching document', () async {
      final service = VectorIndexService();
      await service.initialize();

      await service.addToIndex(
        collection: 'symptoms',
        id: 'symptom-1',
        text: 'Severe abdominal cramping after spicy dinner.',
        metadata: {'source': 'symptom_logger'},
      );
      await service.addToIndex(
        collection: 'symptoms',
        id: 'symptom-2',
        text: 'Slept well and had normal energy.',
        metadata: {'source': 'checkin'},
      );

      final query = await service.embed('abdominal cramping after dinner');
      final results = await service.query(
        collection: 'symptoms',
        queryEmbedding: query,
        topK: 1,
      );

      expect(results, hasLength(1));
      expect(results.single.id, equals('symptom-1'));
      expect(results.single.metadata['source'], equals('symptom_logger'));
      expect(results.single.embedding, isNotNull);
    });

    test('upserts by id and respects topK', () async {
      final service = VectorIndexService();
      await service.initialize();

      await service.addToIndex(
        collection: 'messages',
        id: 'same-id',
        text: 'old text about fatigue',
      );
      await service.addToIndex(
        collection: 'messages',
        id: 'same-id',
        text: 'new text about medication timing',
      );
      await service.addToIndex(
        collection: 'messages',
        id: 'other-id',
        text: 'food trigger notes',
      );

      final query = await service.embed('medication timing');
      final results = await service.query(
        collection: 'messages',
        queryEmbedding: query,
        topK: 1,
      );

      expect(results, hasLength(1));
      expect(results.single.id, equals('same-id'));
      expect(results.single.text, contains('new text'));
    });

    test('handles invalid input without throwing', () async {
      final service = VectorIndexService();

      await service.addToIndex(collection: 'messages', id: '', text: 'ignored');
      await service.addToIndex(collection: 'messages', id: 'id', text: '   ');

      expect(
        await service.query(
          collection: 'messages',
          queryEmbedding: const [],
        ),
        isEmpty,
      );
      expect(
        await service.query(
          collection: 'messages',
          queryEmbedding: await service.embed('anything'),
          topK: 0,
        ),
        isEmpty,
      );
    });
  });
}
