// 35 tests: symptom round-trip indexing and content verification.
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart'
    show SymptomRecord;
import 'package:gemma_flares/core/services/rag_index_service.dart';
import 'package:gemma_flares/core/services/rag_text_formatter.dart';

import 'rag_test_harness.dart';

void main() {
  group('Symptom RAG — round-trip indexing', () {
    late RagTestHarness h;
    setUp(() => h = RagTestHarness());

    // ── Basic round-trips ──────────────────────────────────────────────────

    test('01 abdominal pain: symptom_type appears in stored text', () async {
      final s = TestSymptoms.abdominalPain();
      await h.index.indexSymptom(s.id!, s);
      await h.assertChunkContains(
        RagCollection.symptoms,
        'symptom_tx_${s.id}',
        ['abdominal_pain', 'symptom_tx_101'],
      );
    });

    test('02 abdominal pain: severity is stored verbatim', () async {
      final s = TestSymptoms.abdominalPain(severity: 7);
      await h.index.indexSymptom(s.id!, s);
      await h.assertChunkContains(
        RagCollection.symptoms,
        'symptom_tx_${s.id}',
        ['7/10'],
      );
    });

    test('03 abdominal pain: notes are in stored text', () async {
      final s = TestSymptoms.abdominalPain();
      await h.index.indexSymptom(s.id!, s);
      await h.assertChunkContains(
        RagCollection.symptoms,
        'symptom_tx_${s.id}',
        ['Sharp cramping lower right quadrant'],
      );
    });

    test('04 abdominal pain: meal_relation is stored', () async {
      final s = TestSymptoms.abdominalPain();
      await h.index.indexSymptom(s.id!, s);
      await h.assertChunkContains(
        RagCollection.symptoms,
        'symptom_tx_${s.id}',
        ['after_meal'],
      );
    });

    test('05 diarrhea: type and source_transcript stored', () async {
      final s = TestSymptoms.diarrhea();
      await h.index.indexSymptom(s.id!, s);
      await h.assertChunkContains(
        RagCollection.symptoms,
        'symptom_tx_${s.id}',
        ['diarrhea', 'diarrhea four times'],
      );
    });

    test('06 bloating: duration_minutes stored', () async {
      final s = TestSymptoms.bloating();
      await h.index.indexSymptom(s.id!, s);
      await h.assertChunkContains(
        RagCollection.symptoms,
        'symptom_tx_${s.id}',
        ['120'],
      );
    });

    test('07 indexSymptom returns success result', () async {
      final s = TestSymptoms.abdominalPain();
      final result = await h.index.indexSymptom(s.id!, s);
      expect(result.status, equals(RagIndexStatus.success));
      expect(result.chunkId, equals('symptom_tx_101'));
      expect(result.collection, equals(RagCollection.symptoms));
      expect(result.textLength, greaterThan(0));
    });

    test('08 chunk stored in symptoms collection (not labs)', () async {
      final s = TestSymptoms.abdominalPain();
      await h.index.indexSymptom(s.id!, s);
      await h.assertChunkExists(RagCollection.symptoms, 'symptom_tx_101');
      await h.assertChunkNotExists(RagCollection.labs, 'symptom_tx_101');
    });

    // ── Semantic query retrieval ───────────────────────────────────────────

    test('09 query for "abdominal pain" returns the indexed symptom', () async {
      final s = TestSymptoms.abdominalPain();
      await h.index.indexSymptom(s.id!, s);
      final results = await h.query.queryCollection(
        RagCollection.symptoms,
        'abdominal pain cramping',
      );
      expect(results, isNotEmpty);
      expect(
        results.any((r) => r.text.contains('abdominal_pain')),
        isTrue,
      );
    });

    test('10 query "diarrhea episodes" finds diarrhea entry', () async {
      await h.index.indexSymptom(
          TestSymptoms.abdominalPain().id!, TestSymptoms.abdominalPain());
      await h.index
          .indexSymptom(TestSymptoms.diarrhea().id!, TestSymptoms.diarrhea());
      final results = await h.query.queryCollection(
        RagCollection.symptoms,
        'diarrhea episodes multiple',
        topK: 5,
      );
      expect(results.any((r) => r.text.contains('diarrhea')), isTrue);
    });

    // ── Metadata verification ─────────────────────────────────────────────

    test('11 metadata contains symptom_type', () async {
      final s = TestSymptoms.abdominalPain();
      await h.index.indexSymptom(s.id!, s);
      final match = await h.query.getById(
          collection: RagCollection.symptoms, chunkId: 'symptom_tx_101');
      expect(match, isNotNull);
      expect(match!.metadata['symptom_type'], equals('abdominal_pain'));
    });

    test('12 metadata contains severity', () async {
      final s = TestSymptoms.abdominalPain(severity: 7);
      await h.index.indexSymptom(s.id!, s);
      final match = await h.query.getById(
          collection: RagCollection.symptoms, chunkId: 'symptom_tx_101');
      expect(match!.metadata['severity'], equals(7));
    });

    test('13 metadata contains logged_at ISO8601', () async {
      final s = TestSymptoms.abdominalPain();
      await h.index.indexSymptom(s.id!, s);
      final match = await h.query.getById(
          collection: RagCollection.symptoms, chunkId: 'symptom_tx_101');
      expect(match!.metadata['logged_at'], isA<String>());
      expect(
        (match.metadata['logged_at'] as String).contains('2026-05-14'),
        isTrue,
      );
    });

    // ── Edge cases ─────────────────────────────────────────────────────────

    test('14 edge: minimal symptom (all nulls) indexes without error',
        () async {
      final s = TestSymptoms.minimalSymptom();
      final result = await h.index.indexSymptom(s.id!, s);
      expect(result.status, equals(RagIndexStatus.success));
      await h.assertChunkContains(
        RagCollection.symptoms,
        'symptom_tx_${s.id}',
        ['fatigue'],
      );
    });

    test('15 edge: minimal symptom has no severity line when null', () async {
      final s = TestSymptoms.minimalSymptom();
      await h.index.indexSymptom(s.id!, s);
      final match = await h.query.getById(
        collection: RagCollection.symptoms,
        chunkId: 'symptom_tx_${s.id}',
      );
      // Severity is null — must NOT appear as "severity: null".
      expect(match!.text.contains('null'), isFalse);
    });

    test('16 edge: severity=0 (no pain) is preserved in text', () async {
      final s = TestSymptoms.zeroSeverity();
      await h.index.indexSymptom(s.id!, s);
      await h.assertChunkContains(
        RagCollection.symptoms,
        'symptom_tx_${s.id}',
        ['0/10', 'no pain today'],
      );
    });

    test('17 edge: long notes are preserved (no truncation)', () async {
      final s = TestSymptoms.longNotes();
      await h.index.indexSymptom(s.id!, s);
      final match = await h.query.getById(
        collection: RagCollection.symptoms,
        chunkId: 'symptom_tx_${s.id}',
      );
      // Notes are >1000 chars; entire notes field should be present.
      expect(match!.text, contains('Severe cramping.'));
      expect(match.text.length, greaterThan(100));
    });

    test('18 edge: unicode notes are preserved (no corruption)', () async {
      final s = TestSymptoms.unicodeNotes();
      await h.index.indexSymptom(s.id!, s);
      await h.assertChunkContains(
        RagCollection.symptoms,
        'symptom_tx_${s.id}',
        ['Douleur abdominale', 'très inconfortable'],
      );
    });

    test('19 edge: duplicate index (same id, new severity) overwrites',
        () async {
      final s1 = TestSymptoms.abdominalPain(severity: 4);
      final s2 = TestSymptoms.abdominalPain(severity: 9);
      // Both have id=101.
      await h.index.indexSymptom(s1.id!, s1);
      await h.index.indexSymptom(s2.id!, s2);
      await h.assertChunkContains(
        RagCollection.symptoms, 'symptom_tx_101',
        ['9/10'], // latest write wins
      );
      // Old value must not be present.
      final match = await h.query.getById(
        collection: RagCollection.symptoms,
        chunkId: 'symptom_tx_101',
      );
      expect(match!.text.contains('4/10'), isFalse);
    });

    test('20 edge: multiple symptoms in same collection, each retrievable',
        () async {
      final symptoms = [
        TestSymptoms.abdominalPain(),
        TestSymptoms.diarrhea(),
        TestSymptoms.bloating(),
        TestSymptoms.nausea(),
      ];
      for (final s in symptoms) {
        await h.index.indexSymptom(s.id!, s);
      }
      expect(await h.store.count(RagCollection.symptoms), equals(4));

      // Each chunk is individually retrievable.
      for (final s in symptoms) {
        await h.assertChunkExists(RagCollection.symptoms, 'symptom_tx_${s.id}');
      }
    });

    test('21 text format contains schema version marker', () async {
      final s = TestSymptoms.abdominalPain();
      await h.index.indexSymptom(s.id!, s);
      final match = await h.query.getById(
        collection: RagCollection.symptoms,
        chunkId: 'symptom_tx_101',
      );
      expect(match!.text, contains('symptom_rag_v1'));
    });

    test('22 extraction_method is stored in text', () async {
      final s = TestSymptoms.diarrhea();
      await h.index.indexSymptom(s.id!, s);
      await h.assertChunkContains(
        RagCollection.symptoms,
        'symptom_tx_${s.id}',
        ['gemma4_e2b_structured'],
      );
    });

    test('23 extraction_confidence is stored as percentage', () async {
      final s = TestSymptoms.diarrhea(); // confidence=0.88
      await h.index.indexSymptom(s.id!, s);
      await h.assertChunkContains(
        RagCollection.symptoms,
        'symptom_tx_${s.id}',
        ['88%'],
      );
    });

    test('24 formatSymptom is pure: same input → same output', () {
      final s = TestSymptoms.abdominalPain();
      final t1 = RagTextFormatter.formatSymptom(s.id!, s);
      final t2 = RagTextFormatter.formatSymptom(s.id!, s);
      expect(t1, equals(t2));
    });

    test('25 symptomChunkId is deterministic', () {
      expect(
        RagTextFormatter.symptomChunkId(42),
        equals('symptom_tx_42'),
      );
    });

    test('26 verifyRoundTrip helper returns true for exact chunk content',
        () async {
      final s = TestSymptoms.abdominalPain();
      await h.index.indexSymptom(s.id!, s);
      final ok = await h.query.verifyRoundTrip(
        'abdominal pain after meal',
        ['abdominal_pain', '7/10', 'after_meal'],
      );
      expect(ok, isTrue);
    });

    test('27 verifyRoundTrip returns false when content not indexed', () async {
      final ok = await h.query.verifyRoundTrip(
        'abdominal pain',
        ['abdominal_pain'],
      );
      expect(ok, isFalse); // nothing indexed yet
    });

    test('28 nausea symptom: before_meal relation stored', () async {
      final s = TestSymptoms.nausea();
      await h.index.indexSymptom(s.id!, s);
      await h.assertChunkContains(
        RagCollection.symptoms,
        'symptom_tx_${s.id}',
        ['nausea', 'before_meal', 'Mild nausea in morning'],
      );
    });

    test('29 embedding produces 64-dim unit vector', () async {
      final vec = await h.embedding.embed('abdominal pain cramping');
      expect(vec.length, equals(64));
      final norm = vec.fold<double>(0, (s, x) => s + x * x);
      expect(norm, closeTo(1.0, 0.001));
    });

    test('30 different symptom types have different embeddings', () async {
      final v1 = await h.embedding.embed('abdominal pain severe cramping meal');
      final v2 = await h.embedding.embed('nausea vomiting morning before meal');
      // Different texts should produce different vectors.
      // (Cosine may not be exactly 1.0 — just verify they differ.)
      bool allSame = true;
      for (var i = 0; i < v1.length; i++) {
        if ((v1[i] - v2[i]).abs() > 1e-6) {
          allSame = false;
          break;
        }
      }
      expect(allSame, isFalse);
    });

    test('31 schema version in metadata', () async {
      final s = TestSymptoms.abdominalPain();
      await h.index.indexSymptom(s.id!, s);
      final match = await h.query.getById(
        collection: RagCollection.symptoms,
        chunkId: 'symptom_tx_101',
      );
      expect(match!.metadata['schema'], equals('symptom_rag_v1'));
    });

    test('32 meal_relation null does not appear in text as "null"', () async {
      final s = TestSymptoms.diarrhea(); // mealRelation is null
      await h.index.indexSymptom(s.id!, s);
      final match = await h.query.getById(
        collection: RagCollection.symptoms,
        chunkId: 'symptom_tx_${s.id}',
      );
      expect(match!.text, isNot(contains('null')));
    });

    test('33 100 symptoms indexed — all retrievable by chunk id', () async {
      for (var i = 1; i <= 100; i++) {
        final s = SymptomRecord(
          id: i,
          loggedAt: DateTime.utc(2026, 5, 1).add(Duration(hours: i)),
          symptomType: i.isEven ? 'abdominal_pain' : 'diarrhea',
          severity: i % 10,
          durationMinutes: null,
          mealRelation: null,
          notes: 'Symptom entry number $i',
          sourceTranscript: null,
          extractionMethod: 'manual',
          extractionConfidence: null,
          createdAt: DateTime.utc(2026, 5, 1),
        );
        await h.index.indexSymptom(i, s);
      }
      expect(await h.store.count(RagCollection.symptoms), equals(100));
      // Spot check: entry 42 contains correct content.
      final match = await h.query.getById(
        collection: RagCollection.symptoms,
        chunkId: 'symptom_tx_42',
      );
      expect(match!.text, contains('Symptom entry number 42'));
    });

    test('34 chunk text contains logged_at in ISO8601 format', () async {
      final s = TestSymptoms.abdominalPain();
      await h.index.indexSymptom(s.id!, s);
      final match = await h.query.getById(
        collection: RagCollection.symptoms,
        chunkId: 'symptom_tx_101',
      );
      // Should contain UTC ISO8601 timestamp.
      expect(match!.text, contains('2026-05-14T09:30:00'));
    });

    test('35 chunk id format is consistent: symptom_tx_{int}', () {
      expect(RagTextFormatter.symptomChunkId(1), equals('symptom_tx_1'));
      expect(
          RagTextFormatter.symptomChunkId(99999), equals('symptom_tx_99999'));
    });
  });
}
