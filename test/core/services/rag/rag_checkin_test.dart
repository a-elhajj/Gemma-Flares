// 25 tests: check-in survey round-trip indexing and content verification.
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart'
    show Pro2SurveyRecord;
import 'package:gemma_flares/core/services/rag_index_service.dart';
import 'package:gemma_flares/core/services/rag_text_formatter.dart';

import 'rag_test_harness.dart';

void main() {
  group('Check-in Survey RAG — round-trip indexing', () {
    late RagTestHarness h;
    setUp(() => h = RagTestHarness());

    // ── Basic round-trips ──────────────────────────────────────────────────

    test('01 CD moderate: disease_type stored', () async {
      final s = TestCheckIns.cdModerate();
      await h.index.indexCheckIn(s.id!, s);
      await h.assertChunkContains(
        RagCollection.checkins,
        'checkin_tx_${s.id}',
        ['CD'],
      );
    });

    test('02 CD moderate: survey_date stored', () async {
      final s = TestCheckIns.cdModerate();
      await h.index.indexCheckIn(s.id!, s);
      await h.assertChunkContains(
        RagCollection.checkins,
        'checkin_tx_${s.id}',
        ['2026-05-15'],
      );
    });

    test('03 CD moderate: pro2_score stored', () async {
      final s = TestCheckIns.cdModerate();
      await h.index.indexCheckIn(s.id!, s);
      await h.assertChunkContains(
        RagCollection.checkins,
        'checkin_tx_${s.id}',
        ['6.0'],
      );
    });

    test('04 CD moderate: is_flare=false stored', () async {
      final s = TestCheckIns.cdModerate();
      await h.index.indexCheckIn(s.id!, s);
      await h.assertChunkContains(
        RagCollection.checkins,
        'checkin_tx_${s.id}',
        ['is_flare: false'],
      );
    });

    test('05 CD flare: is_flare=true stored', () async {
      final s = TestCheckIns.cdFlare();
      await h.index.indexCheckIn(s.id!, s);
      await h.assertChunkContains(
        RagCollection.checkins,
        'checkin_tx_${s.id}',
        ['is_flare: true'],
      );
    });

    test('06 CD flare: abdominal_pain score stored', () async {
      final s = TestCheckIns.cdFlare(); // cdAbdominalPain=3
      await h.index.indexCheckIn(s.id!, s);
      await h.assertChunkContains(
        RagCollection.checkins,
        'checkin_tx_${s.id}',
        ['abdominal_pain_0_3: 3'],
      );
    });

    test('07 CD flare: stool_frequency score stored', () async {
      final s = TestCheckIns.cdFlare(); // cdStoolFrequency=4
      await h.index.indexCheckIn(s.id!, s);
      await h.assertChunkContains(
        RagCollection.checkins,
        'checkin_tx_${s.id}',
        ['stool_frequency_0_4: 4'],
      );
    });

    test('08 UC mild: rectal_bleeding score stored', () async {
      final s = TestCheckIns.ucMild(); // ucRectalBleeding=1
      await h.index.indexCheckIn(s.id!, s);
      await h.assertChunkContains(
        RagCollection.checkins,
        'checkin_tx_${s.id}',
        ['rectal_bleeding_0_3: 1'],
      );
    });

    test('09 UC mild: uc_stool_frequency stored', () async {
      final s = TestCheckIns.ucMild(); // ucStoolFrequency=2
      await h.index.indexCheckIn(s.id!, s);
      await h.assertChunkContains(
        RagCollection.checkins,
        'checkin_tx_${s.id}',
        ['uc_stool_frequency_0_3: 2'],
      );
    });

    test('10 IBS severe: pro2_score=310 stored', () async {
      final s = TestCheckIns.ibsSevere();
      await h.index.indexCheckIn(s.id!, s);
      await h.assertChunkContains(
        RagCollection.checkins,
        'checkin_tx_${s.id}',
        ['310.0', 'IBS'],
      );
    });

    test('11 indexCheckIn returns success', () async {
      final s = TestCheckIns.cdModerate();
      final result = await h.index.indexCheckIn(s.id!, s);
      expect(result.status, equals(RagIndexStatus.success));
      expect(result.chunkId, equals('checkin_tx_501'));
      expect(result.collection, equals(RagCollection.checkins));
      expect(result.textLength, greaterThan(0));
    });

    test('12 stored in checkins collection (not symptoms)', () async {
      final s = TestCheckIns.cdModerate();
      await h.index.indexCheckIn(s.id!, s);
      await h.assertChunkExists(RagCollection.checkins, 'checkin_tx_501');
      await h.assertChunkNotExists(RagCollection.symptoms, 'checkin_tx_501');
    });

    test('13 schema version marker in text', () async {
      final s = TestCheckIns.cdModerate();
      await h.index.indexCheckIn(s.id!, s);
      final match = await h.query.getById(
        collection: RagCollection.checkins,
        chunkId: 'checkin_tx_501',
      );
      expect(match!.text, contains('checkin_rag_v1'));
    });

    // ── Metadata ──────────────────────────────────────────────────────────

    test('14 metadata: disease_type correct', () async {
      final s = TestCheckIns.cdModerate();
      await h.index.indexCheckIn(s.id!, s);
      final match = await h.query.getById(
        collection: RagCollection.checkins,
        chunkId: 'checkin_tx_501',
      );
      expect(match!.metadata['disease_type'], equals('CD'));
    });

    test('15 metadata: pro2_score correct', () async {
      final s = TestCheckIns.cdModerate();
      await h.index.indexCheckIn(s.id!, s);
      final match = await h.query.getById(
        collection: RagCollection.checkins,
        chunkId: 'checkin_tx_501',
      );
      expect(match!.metadata['pro2_score'], closeTo(6.0, 0.001));
    });

    test('16 metadata: is_flare stored as bool', () async {
      final s = TestCheckIns.cdFlare();
      await h.index.indexCheckIn(s.id!, s);
      final match = await h.query.getById(
        collection: RagCollection.checkins,
        chunkId: 'checkin_tx_502',
      );
      expect(match!.metadata['is_flare'], isTrue);
    });

    test('17 metadata: schema version correct', () async {
      final s = TestCheckIns.cdModerate();
      await h.index.indexCheckIn(s.id!, s);
      final match = await h.query.getById(
        collection: RagCollection.checkins,
        chunkId: 'checkin_tx_501',
      );
      expect(match!.metadata['schema'], equals('checkin_rag_v1'));
    });

    // ── Semantic query ─────────────────────────────────────────────────────

    test('18 query "CD flare abdominal pain" finds flare entry', () async {
      await h.index.indexCheckIn(
          TestCheckIns.cdModerate().id!, TestCheckIns.cdModerate());
      await h.index
          .indexCheckIn(TestCheckIns.cdFlare().id!, TestCheckIns.cdFlare());
      final results = await h.query.queryCollection(
        RagCollection.checkins,
        'CD flare abdominal pain',
      );
      expect(results.any((r) => r.text.contains('is_flare: true')), isTrue);
    });

    // ── Edge cases ─────────────────────────────────────────────────────────

    test('19 edge: CD remission zero scores stored', () async {
      final s = TestCheckIns.cdRemission(); // pro2_score=0.0
      await h.index.indexCheckIn(s.id!, s);
      await h.assertChunkContains(
        RagCollection.checkins,
        'checkin_tx_${s.id}',
        ['0.0', 'is_flare: false'],
      );
    });

    test('20 edge: notes_json stored when present', () async {
      final s = TestCheckIns.cdFlare(); // has notes JSON
      await h.index.indexCheckIn(s.id!, s);
      await h.assertChunkContains(
        RagCollection.checkins,
        'checkin_tx_${s.id}',
        ['notes_json:'],
      );
    });

    test('21 edge: null notes not rendered as "null"', () async {
      final s = TestCheckIns.cdModerate(); // notes is null
      await h.index.indexCheckIn(s.id!, s);
      final match = await h.query.getById(
        collection: RagCollection.checkins,
        chunkId: 'checkin_tx_${s.id}',
      );
      expect(match!.text, isNot(contains('null')));
    });

    test('22 edge: duplicate id overwrites with new score', () async {
      final s1 = TestCheckIns.cdModerate(); // pro2_score=6.0
      final s2 = Pro2SurveyRecord(
        id: 501,
        surveyDate: '2026-05-15',
        diseaseType: 'CD',
        cdAbdominalPain: 3,
        cdStoolFrequency: 4,
        ucRectalBleeding: null,
        ucStoolFrequency: null,
        pro2Score: 11.0,
        isFlare: true,
        scoreVersion: Pro2SurveyRecord.cdV2Pain2Stool1,
        notes: null,
        createdAt: DateTime.utc(2026, 5, 15),
      );
      await h.index.indexCheckIn(s1.id!, s1);
      await h.index.indexCheckIn(s2.id!, s2);
      await h.assertChunkContains(
        RagCollection.checkins,
        'checkin_tx_501',
        ['11.0', 'is_flare: true'],
      );
      final match = await h.query.getById(
        collection: RagCollection.checkins,
        chunkId: 'checkin_tx_501',
      );
      expect(match!.text.contains('6.0'), isFalse);
    });

    test('23 formatCheckIn pure: same input → same output', () {
      final s = TestCheckIns.cdModerate();
      final t1 = RagTextFormatter.formatCheckIn(s.id!, s);
      final t2 = RagTextFormatter.formatCheckIn(s.id!, s);
      expect(t1, equals(t2));
    });

    test('24 checkinChunkId deterministic format', () {
      expect(RagTextFormatter.checkinChunkId(1), equals('checkin_tx_1'));
      expect(RagTextFormatter.checkinChunkId(9999), equals('checkin_tx_9999'));
    });

    test('25 four different check-in types all indexable', () async {
      final surveys = [
        TestCheckIns.cdModerate(),
        TestCheckIns.cdFlare(),
        TestCheckIns.ucMild(),
        TestCheckIns.ibsSevere(),
      ];
      for (final s in surveys) {
        await h.index.indexCheckIn(s.id!, s);
      }
      expect(await h.store.count(RagCollection.checkins), equals(4));
      for (final s in surveys) {
        await h.assertChunkExists(RagCollection.checkins, 'checkin_tx_${s.id}');
      }
    });
  });
}
