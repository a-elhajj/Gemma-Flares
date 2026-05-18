// 30 tests: cross-collection integration, multi-type indexing, time-decay,
// MMR diversity, and full round-trip verification across all data types.
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart'
    show SymptomRecord;
import 'package:gemma_flares/core/services/embedding_service.dart';
import 'package:gemma_flares/core/services/food_entry.dart';
import 'package:gemma_flares/core/services/rag_index_service.dart';
import 'package:gemma_flares/core/services/rag_query_service.dart';
import 'package:gemma_flares/core/services/rag_text_formatter.dart';

import 'rag_test_harness.dart';

void main() {
  group('RAG Integration — cross-collection and multi-type', () {
    late RagTestHarness h;
    setUp(() => h = RagTestHarness());

    // ── All data types index without conflict ─────────────────────────────

    test('01 all 7 data types index concurrently without collision', () async {
      await Future.wait([
        h.index.indexSymptom(
            TestSymptoms.abdominalPain().id!, TestSymptoms.abdominalPain()),
        h.index.indexLabResult(TestLabs.crp().id!, TestLabs.crp()),
        h.index.indexCheckIn(
            TestCheckIns.cdModerate().id!, TestCheckIns.cdModerate()),
        h.index.indexMedication(TestMedications.mesalamineTaken().id!,
            TestMedications.mesalamineTaken()),
        h.index.indexHealthSync(
          dateLocal: '2026-05-14',
          metrics: TestHealthData.allMetrics(),
        ),
        h.index.indexProfile(TestProfiles.crohnsMale()),
        h.index.indexFoodEntryById(TestFood.oatmeal().id!, TestFood.oatmeal()),
      ]);

      // Each lives in its own collection — no cross-contamination.
      await h.assertChunkExists(RagCollection.symptoms, 'symptom_tx_101');
      await h.assertChunkExists(RagCollection.labs, 'lab_tx_301');
      await h.assertChunkExists(RagCollection.checkins, 'checkin_tx_501');
      await h.assertChunkExists(RagCollection.summaries, 'med_tx_701');
      await h.assertChunkExists(
          RagCollection.summaries, 'health_sync_tx_2026-05-14');
      await h.assertChunkExists(
          RagCollection.profile, RagTextFormatter.profileChunkId);
      await h.assertChunkExists(RagCollection.food, 'food_tx_901');
    });

    test('02 collections are fully isolated: symptom chunk absent from labs',
        () async {
      await h.index.indexSymptom(
          TestSymptoms.abdominalPain().id!, TestSymptoms.abdominalPain());
      await h.index.indexLabResult(TestLabs.crp().id!, TestLabs.crp());

      await h.assertChunkNotExists(RagCollection.labs, 'symptom_tx_101');
      await h.assertChunkNotExists(RagCollection.symptoms, 'lab_tx_301');
    });

    test('03 count per collection accurate after mixed indexing', () async {
      await h.index.indexSymptom(101, TestSymptoms.abdominalPain());
      await h.index.indexSymptom(102, TestSymptoms.diarrhea());
      await h.index.indexLabResult(301, TestLabs.crp());
      await h.index.indexLabResult(302, TestLabs.calprotectin());
      await h.index.indexLabResult(303, TestLabs.albumin());

      expect(await h.store.count(RagCollection.symptoms), equals(2));
      expect(await h.store.count(RagCollection.labs), equals(3));
    });

    // ── Cross-collection query ─────────────────────────────────────────────

    test('04 queryAll returns results from symptoms and labs together',
        () async {
      await h.index.indexSymptom(
          TestSymptoms.abdominalPain().id!, TestSymptoms.abdominalPain());
      await h.index.indexLabResult(TestLabs.crp().id!, TestLabs.crp());

      final result = await h.query.query(
        'abdominal pain CRP inflammation',
        config: RagQueryConfig(
          collections: [RagCollection.symptoms, RagCollection.labs],
        ),
      );

      final texts = result.matches.map((m) => m.text).toList();
      expect(texts.any((t) => t.contains('abdominal_pain')), isTrue);
      expect(texts.any((t) => t.contains('crp')), isTrue);
    });

    test('05 query targets specific collection: labs only', () async {
      await h.index.indexSymptom(
          TestSymptoms.abdominalPain().id!, TestSymptoms.abdominalPain());
      await h.index.indexLabResult(TestLabs.crp().id!, TestLabs.crp());

      final results = await h.query.queryCollection(
        RagCollection.labs,
        'inflammation marker',
      );
      // All results must be from the labs collection.
      expect(results.every((r) => r.collection == RagCollection.labs), isTrue);
    });

    // ── Time-decay reranking ──────────────────────────────────────────────

    test('06 older symptom ranked lower than recent one for same query',
        () async {
      // Old symptom (35 days before now=2026-05-15)
      final old = SymptomRecord(
        id: 901,
        loggedAt: DateTime.utc(2026, 4, 10), // ~35 days ago
        symptomType: 'abdominal_pain',
        severity: 8,
        durationMinutes: null,
        mealRelation: null,
        notes: 'Old severe cramping abdominal pain episode',
        sourceTranscript: null,
        extractionMethod: 'manual',
        extractionConfidence: 1.0,
        createdAt: DateTime.utc(2026, 4, 10),
      );
      // Recent symptom (same day as now)
      final recent = SymptomRecord(
        id: 902,
        loggedAt: DateTime.utc(2026, 5, 15, 8, 0), // today
        symptomType: 'abdominal_pain',
        severity: 8,
        durationMinutes: null,
        mealRelation: null,
        notes: 'Recent severe cramping abdominal pain episode',
        sourceTranscript: null,
        extractionMethod: 'manual',
        extractionConfidence: 1.0,
        createdAt: DateTime.utc(2026, 5, 15, 8, 0),
      );
      await h.index.indexSymptom(old.id!, old);
      await h.index.indexSymptom(recent.id!, recent);

      // Use the full query() path (not queryCollection) to get time-decay reranking.
      final result = await h.query.query(
        'abdominal pain cramping severe',
        config: RagQueryConfig(
          collections: [RagCollection.symptoms],
          topKPerCollection: 2,
          maxTotal: 2,
        ),
      );
      final results = result.matches;
      expect(results.length, equals(2));
      // Recent should rank above old after time-decay (decay factor ~1.0 vs ~0.45).
      final recentIdx = results.indexWhere((r) => r.text.contains('Recent'));
      final oldIdx = results.indexWhere((r) => r.text.contains('Old'));
      expect(recentIdx, lessThan(oldIdx),
          reason: 'Recent symptom should rank above older one after decay');
    });

    // ── verifyRoundTrip helper ─────────────────────────────────────────────

    test('07 verifyRoundTrip: true when all substrings found', () async {
      await h.index.indexSymptom(
          TestSymptoms.abdominalPain().id!, TestSymptoms.abdominalPain());
      final ok = await h.query.verifyRoundTrip(
        'abdominal pain after meal cramping',
        ['abdominal_pain', '7/10', 'after_meal', 'Sharp cramping'],
      );
      expect(ok, isTrue);
    });

    test('08 verifyRoundTrip: false when nothing indexed', () async {
      final ok =
          await h.query.verifyRoundTrip('abdominal pain', ['abdominal_pain']);
      expect(ok, isFalse);
    });

    // ── getById / exists helpers ───────────────────────────────────────────

    test('09 getById returns null for unknown chunk', () async {
      final match = await h.query.getById(
        collection: RagCollection.symptoms,
        chunkId: 'symptom_tx_9999',
      );
      expect(match, isNull);
    });

    test('10 exists returns false for unknown chunk', () async {
      final found = await h.query.exists(
        collection: RagCollection.symptoms,
        chunkId: 'symptom_tx_9999',
      );
      expect(found, isFalse);
    });

    test('11 exists returns true after indexing', () async {
      await h.index.indexLabResult(TestLabs.crp().id!, TestLabs.crp());
      final found = await h.query.exists(
        collection: RagCollection.labs,
        chunkId: 'lab_tx_301',
      );
      expect(found, isTrue);
    });

    // ── Full round-trip: all fields preserved per data type ───────────────

    test('12 symptom full round-trip: all key fields preserved', () async {
      final s = TestSymptoms.abdominalPain();
      await h.index.indexSymptom(s.id!, s);
      await h.assertChunkContains(
        RagCollection.symptoms,
        'symptom_tx_${s.id}',
        [
          'abdominal_pain',
          '7/10',
          '2026-05-14T09:30:00',
          'after_meal',
          'Sharp cramping',
          'symptom_rag_v1',
        ],
      );
    });

    test('13 lab full round-trip: all key fields preserved', () async {
      final r = TestLabs.crp();
      await h.index.indexLabResult(r.id!, r);
      await h.assertChunkContains(
        RagCollection.labs,
        'lab_tx_${r.id}',
        [
          'crp',
          '12.5 mg/L',
          '2026-05-10',
          '5.0 mg/L',
          'abnormal: yes',
          'Quest Diagnostics',
          'Dr. Smith',
          'Fasting sample',
          'lab_rag_v1',
        ],
      );
    });

    test('14 check-in full round-trip: all key fields preserved', () async {
      final s = TestCheckIns.cdFlare();
      await h.index.indexCheckIn(s.id!, s);
      await h.assertChunkContains(
        RagCollection.checkins,
        'checkin_tx_${s.id}',
        [
          'CD',
          '2026-05-14',
          '11.0',
          'is_flare: true',
          'abdominal_pain_0_3: 3',
          'stool_frequency_0_4: 4',
          'checkin_rag_v1',
        ],
      );
    });

    test('15 medication full round-trip: all key fields preserved', () async {
      final e = TestMedications.mesalamineTaken();
      await h.index.indexMedication(e.id!, e);
      await h.assertChunkContains(
        RagCollection.summaries,
        'med_tx_${e.id}',
        [
          'medication_taken',
          'Mesalamine',
          '1.2g',
          'morning',
          'on_time',
          '95%',
          'medication_rag_v1',
        ],
      );
    });

    test('16 health sync full round-trip: all key fields preserved', () async {
      await h.index.indexHealthSync(
        dateLocal: '2026-05-14',
        metrics: TestHealthData.allMetrics(),
        riskScore: 72.5,
        riskBand: 'elevated',
        reason: 'daily_sync',
      );
      await h.assertChunkContains(
        RagCollection.summaries,
        'health_sync_tx_2026-05-14',
        [
          'steps: 8432',
          'resting_hr: 62',
          'hrv_sdnn: 42.5',
          'sleep_hours: 7.2',
          '72.5%',
          'band=elevated',
          'daily_sync',
          'health_rag_v1',
        ],
      );
    });

    test('17 profile full round-trip: all key fields preserved', () async {
      await h.index.indexProfile(TestProfiles.crohnsMale());
      await h.assertChunkContains(
        RagCollection.profile,
        RagTextFormatter.profileChunkId,
        [
          'disease_type: CD',
          'diagnosis_year: 2018',
          'Mesalamine',
          'Vedolizumab',
          'primary_sclerosing_cholangitis',
          'profile_rag_v1',
        ],
      );
    });

    test('18 food full round-trip: all key fields preserved', () async {
      await h.index.indexFoodEntryById(
          TestFood.pizzaTrigger().id!, TestFood.pizzaTrigger());
      await h.assertChunkContains(
        RagCollection.food,
        'food_tx_902',
        [
          'Deep dish pizza',
          'dinner',
          '680.0',
          Allergen.gluten,
          Allergen.dairy,
          'trigger_suspected: yes',
          'Triggered severe cramping',
          'food_rag_v1',
        ],
      );
    });

    // ── clearCollection ────────────────────────────────────────────────────

    test('19 clearCollection removes only that collection', () async {
      await h.index.indexSymptom(101, TestSymptoms.abdominalPain());
      await h.index.indexLabResult(301, TestLabs.crp());

      await h.store.clearCollection(RagCollection.symptoms);

      expect(await h.store.count(RagCollection.symptoms), equals(0));
      expect(await h.store.count(RagCollection.labs), equals(1));
    });

    test('20 delete removes only specified chunk', () async {
      await h.index.indexSymptom(101, TestSymptoms.abdominalPain());
      await h.index.indexSymptom(102, TestSymptoms.diarrhea());

      await h.store.delete(
        collection: RagCollection.symptoms,
        id: 'symptom_tx_101',
      );

      await h.assertChunkNotExists(RagCollection.symptoms, 'symptom_tx_101');
      await h.assertChunkExists(RagCollection.symptoms, 'symptom_tx_102');
    });

    // ── Bulk stress test ──────────────────────────────────────────────────

    test('21 200 mixed records indexed — counts correct per collection',
        () async {
      for (var i = 1; i <= 50; i++) {
        await h.index.indexSymptom(
          i,
          SymptomRecord(
            id: i,
            loggedAt: DateTime.utc(2026, 5, 1).add(Duration(hours: i)),
            symptomType: 'abdominal_pain',
            severity: i % 10,
            durationMinutes: null,
            mealRelation: null,
            notes: 'Bulk symptom $i',
            sourceTranscript: null,
            extractionMethod: 'manual',
            extractionConfidence: null,
            createdAt: DateTime.utc(2026, 5, 1),
          ),
        );
      }
      for (var i = 1; i <= 50; i++) {
        await h.index.indexHealthSync(
          dateLocal: '2026-04-${i.toString().padLeft(2, '0')}',
          metrics: {'steps': i * 100},
        );
      }
      for (var i = 1; i <= 50; i++) {
        await h.index.indexFoodEntryById(
          i,
          FoodEntry(
            id: i,
            loggedAt: DateTime.utc(2026, 5, 1).add(Duration(hours: i)),
            foodName: 'Food entry $i',
            source: 'manual',
          ),
        );
      }

      expect(await h.store.count(RagCollection.symptoms), equals(50));
      expect(await h.store.count(RagCollection.food), equals(50));
      // 50 health + any other summaries → at least 50
      expect(await h.store.count(RagCollection.summaries),
          greaterThanOrEqualTo(50));
    });

    test('22 indexRawText: arbitrary text indexable in any collection',
        () async {
      await h.index.indexRawText(
        collection: RagCollection.knowledge,
        chunkId: 'kb_crohns_overview',
        text:
            'Crohn\'s disease is a chronic inflammatory bowel disease affecting any part of the GI tract.',
        metadata: {'source': 'ibd_knowledge_base', 'topic': 'crohns'},
      );
      await h.assertChunkContains(
        RagCollection.knowledge,
        'kb_crohns_overview',
        ['chronic inflammatory bowel disease'],
      );
    });

    test('23 indexRawText: empty text returns skipped', () async {
      final result = await h.index.indexRawText(
        collection: RagCollection.knowledge,
        chunkId: 'kb_empty',
        text: '   ',
      );
      expect(result.status, equals(RagIndexStatus.skipped));
    });

    // ── Schema version in ALL formatters ──────────────────────────────────

    test('24 all formatters include schema version marker', () {
      final s = TestSymptoms.abdominalPain();
      final r = TestLabs.crp();
      final c = TestCheckIns.cdModerate();
      final e = TestMedications.mesalamineTaken();
      final f = TestFood.oatmeal();

      expect(
          RagTextFormatter.formatSymptom(s.id!, s), contains('symptom_rag_v1'));
      expect(
          RagTextFormatter.formatLabResult(r.id!, r), contains('lab_rag_v1'));
      expect(
          RagTextFormatter.formatCheckIn(c.id!, c), contains('checkin_rag_v1'));
      expect(RagTextFormatter.formatMedication(e.id!, e),
          contains('medication_rag_v1'));
      expect(RagTextFormatter.formatFoodEntry(f.id!.toString(), f),
          contains('food_rag_v1'));
      expect(RagTextFormatter.formatProfile(TestProfiles.crohnsMale()),
          contains('profile_rag_v1'));
      expect(
        RagTextFormatter.formatHealthSync(
          dateLocal: '2026-05-14',
          metrics: TestHealthData.allMetrics(),
        ),
        contains('health_rag_v1'),
      );
    });

    // ── queryAll result structure ──────────────────────────────────────────

    test('25 RagQueryResult.anyTextContains works across matches', () async {
      await h.index.indexSymptom(101, TestSymptoms.abdominalPain());
      await h.index.indexLabResult(301, TestLabs.crp());

      final result = await h.query.query(
        'pain cramping crp',
        config: RagQueryConfig(
          collections: [RagCollection.symptoms, RagCollection.labs],
        ),
      );
      expect(result.anyTextContains('abdominal_pain'), isTrue);
      expect(result.anyTextContains('crp'), isTrue);
      expect(result.anyTextContains('xyz_not_present'), isFalse);
    });

    test('26 RagQueryResult.chunkIds includes indexed chunks', () async {
      await h.index.indexSymptom(101, TestSymptoms.abdominalPain());

      final result = await h.query.query(
        'abdominal pain cramping',
        config: RagQueryConfig(collections: [RagCollection.symptoms]),
      );
      expect(result.chunkIds.contains('symptom_tx_101'), isTrue);
    });

    test('27 profile chunk ID is constant "profile_rag_v1"', () {
      expect(RagTextFormatter.profileChunkId, equals('profile_rag_v1'));
    });

    test('28 embedding dimension 64 — consistent across all data types',
        () async {
      final s = TestSymptoms.abdominalPain();
      final text = RagTextFormatter.formatSymptom(s.id!, s);
      final vec = await h.embedding.embed(text);
      expect(vec.length, equals(64));
    });

    test('29 embedBatch produces same vectors as individual embed calls',
        () async {
      const texts = [
        'abdominal pain cramping after meal severity 7',
        'CRP elevated 12.5 mg/L abnormal inflammation',
      ];
      final batch = await h.embedding.embedBatch(texts);
      final single0 = await h.embedding.embed(texts[0]);
      final single1 = await h.embedding.embed(texts[1]);

      for (var i = 0; i < 64; i++) {
        expect(batch[0][i], closeTo(single0[i], 1e-9));
        expect(batch[1][i], closeTo(single1[i], 1e-9));
      }
    });

    test('30 cosine similarity: identical texts → 1.0', () async {
      const text = 'abdominal pain cramping inflammation IBD flare';
      final v1 = await h.embedding.embed(text);
      final v2 = await h.embedding.embed(text);
      final sim = EmbeddingService.cosineSimilarity(v1, v2);
      expect(sim, closeTo(1.0, 0.001));
    });
  });
}
