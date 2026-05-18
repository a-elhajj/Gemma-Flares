// 20 tests: food entry round-trip indexing and content verification.
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/food_entry.dart';
import 'package:gemma_flares/core/services/rag_index_service.dart';
import 'package:gemma_flares/core/services/rag_text_formatter.dart';

import 'rag_test_harness.dart';

void main() {
  group('Food Entry RAG — round-trip indexing', () {
    late RagTestHarness h;
    setUp(() => h = RagTestHarness());

    // ── Basic round-trips ──────────────────────────────────────────────────

    test('01 oatmeal: food_name stored', () async {
      final f = TestFood.oatmeal();
      await h.index.indexFoodEntryById(f.id!, f);
      await h.assertChunkContains(
        RagCollection.food,
        'food_tx_${f.id}',
        ['Oatmeal with blueberries'],
      );
    });

    test('02 oatmeal: meal_type stored', () async {
      final f = TestFood.oatmeal();
      await h.index.indexFoodEntryById(f.id!, f);
      await h.assertChunkContains(
        RagCollection.food,
        'food_tx_${f.id}',
        ['breakfast'],
      );
    });

    test('03 oatmeal: calories stored', () async {
      final f = TestFood.oatmeal();
      await h.index.indexFoodEntryById(f.id!, f);
      await h.assertChunkContains(
        RagCollection.food,
        'food_tx_${f.id}',
        ['320.0'],
      );
    });

    test('04 oatmeal: dietary flags stored', () async {
      final f = TestFood.oatmeal(); // lactose_free, dairy_free, high_fiber
      await h.index.indexFoodEntryById(f.id!, f);
      await h.assertChunkContains(
        RagCollection.food,
        'food_tx_${f.id}',
        ['lactose_free', 'dairy_free', 'high_fiber'],
      );
    });

    test('05 pizza trigger: trigger_suspected stored', () async {
      final f = TestFood.pizzaTrigger();
      await h.index.indexFoodEntryById(f.id!, f);
      await h.assertChunkContains(
        RagCollection.food,
        'food_tx_${f.id}',
        ['trigger_suspected: yes'],
      );
    });

    test('06 pizza trigger: allergens stored', () async {
      final f = TestFood.pizzaTrigger(); // gluten, dairy
      await h.index.indexFoodEntryById(f.id!, f);
      await h.assertChunkContains(
        RagCollection.food,
        'food_tx_${f.id}',
        [Allergen.gluten, Allergen.dairy],
      );
    });

    test('07 pizza trigger: high_fat and spicy flags stored', () async {
      final f = TestFood.pizzaTrigger();
      await h.index.indexFoodEntryById(f.id!, f);
      await h.assertChunkContains(
        RagCollection.food,
        'food_tx_${f.id}',
        ['high_fat', 'spicy'],
      );
    });

    test('08 pizza trigger: notes stored', () async {
      final f = TestFood.pizzaTrigger();
      await h.index.indexFoodEntryById(f.id!, f);
      await h.assertChunkContains(
        RagCollection.food,
        'food_tx_${f.id}',
        ['Triggered severe cramping'],
      );
    });

    test('09 oatmeal: macros stored', () async {
      final f = TestFood.oatmeal();
      await h.index.indexFoodEntryById(f.id!, f);
      await h.assertChunkContains(
        RagCollection.food,
        'food_tx_${f.id}',
        ['fiber_g: 8.5', 'protein_g: 12.0', 'carb_g: 58.0'],
      );
    });

    test('10 indexFoodEntryById returns success', () async {
      final f = TestFood.oatmeal();
      final result = await h.index.indexFoodEntryById(f.id!, f);
      expect(result.status, equals(RagIndexStatus.success));
      expect(result.chunkId, equals('food_tx_901'));
      expect(result.collection, equals(RagCollection.food));
      expect(result.textLength, greaterThan(0));
    });

    test('11 stored in food collection (not symptoms)', () async {
      final f = TestFood.oatmeal();
      await h.index.indexFoodEntryById(f.id!, f);
      await h.assertChunkExists(RagCollection.food, 'food_tx_901');
      await h.assertChunkNotExists(RagCollection.symptoms, 'food_tx_901');
    });

    test('12 schema version marker in text', () async {
      final f = TestFood.oatmeal();
      await h.index.indexFoodEntryById(f.id!, f);
      final match = await h.query.getById(
        collection: RagCollection.food,
        chunkId: 'food_tx_901',
      );
      expect(match!.text, contains('food_rag_v1'));
    });

    // ── Metadata ──────────────────────────────────────────────────────────

    test('13 metadata: food_name correct', () async {
      final f = TestFood.oatmeal();
      await h.index.indexFoodEntryById(f.id!, f);
      final match = await h.query.getById(
        collection: RagCollection.food,
        chunkId: 'food_tx_901',
      );
      expect(match!.metadata['food_name'], equals('Oatmeal with blueberries'));
    });

    test('14 metadata: trigger_suspected correct', () async {
      final f = TestFood.pizzaTrigger();
      await h.index.indexFoodEntryById(f.id!, f);
      final match = await h.query.getById(
        collection: RagCollection.food,
        chunkId: 'food_tx_902',
      );
      expect(match!.metadata['trigger_suspected'], isTrue);
    });

    test('15 metadata: schema version correct', () async {
      final f = TestFood.oatmeal();
      await h.index.indexFoodEntryById(f.id!, f);
      final match = await h.query.getById(
        collection: RagCollection.food,
        chunkId: 'food_tx_901',
      );
      expect(match!.metadata['schema'], equals('food_rag_v1'));
    });

    // ── Edge cases ─────────────────────────────────────────────────────────

    test('16 edge: minimal food (no macros, no flags) indexes without crash',
        () async {
      final f = TestFood.minimalFood();
      final result = await h.index.indexFoodEntryById(f.id!, f);
      expect(result.status, equals(RagIndexStatus.success));
      await h.assertChunkContains(
        RagCollection.food,
        'food_tx_${f.id}',
        ['Unknown snack'],
      );
    });

    test('17 edge: minimal food — no null fields in text', () async {
      final f = TestFood.minimalFood();
      await h.index.indexFoodEntryById(f.id!, f);
      final match = await h.query.getById(
        collection: RagCollection.food,
        chunkId: 'food_tx_${f.id}',
      );
      expect(match!.text, isNot(contains('null')));
    });

    test('18 edge: allergen bomb — all 9 allergens stored', () async {
      final f = TestFood.allergenBomb();
      await h.index.indexFoodEntryById(f.id!, f);
      await h.assertChunkContains(
        RagCollection.food,
        'food_tx_${f.id}',
        [
          Allergen.gluten,
          Allergen.dairy,
          Allergen.nuts,
          Allergen.soy,
          Allergen.eggs,
          Allergen.shellfish,
        ],
      );
    });

    test('19 edge: duplicate food id overwrites', () async {
      final f1 = TestFood.oatmeal(); // 320 kcal
      final f2 = FoodEntry(
        id: 901,
        loggedAt: DateTime.utc(2026, 5, 15, 8, 30),
        foodName: 'Oatmeal with banana',
        mealType: 'breakfast',
        calories: 410.0,
        source: 'manual',
      );
      await h.index.indexFoodEntryById(f1.id!, f1);
      await h.index.indexFoodEntryById(f2.id!, f2);
      final match = await h.query.getById(
        collection: RagCollection.food,
        chunkId: 'food_tx_901',
      );
      expect(match!.text, contains('410.0'));
      expect(match.text, isNot(contains('320.0')));
    });

    test('20 formatFoodEntry pure: same input → same output', () {
      final f = TestFood.oatmeal();
      final t1 = RagTextFormatter.formatFoodEntry(f.id!.toString(), f);
      final t2 = RagTextFormatter.formatFoodEntry(f.id!.toString(), f);
      expect(t1, equals(t2));
    });
  });
}
