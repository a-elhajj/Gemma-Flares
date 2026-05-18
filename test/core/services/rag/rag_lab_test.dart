// 30 tests: lab result round-trip indexing and content verification.
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart'
    show LabValueRecord;
import 'package:gemma_flares/core/services/rag_index_service.dart';
import 'package:gemma_flares/core/services/rag_text_formatter.dart';

import 'rag_test_harness.dart';

void main() {
  group('Lab Result RAG — round-trip indexing', () {
    late RagTestHarness h;
    setUp(() => h = RagTestHarness());

    // ── Basic round-trips ──────────────────────────────────────────────────

    test('01 CRP: lab_type stored', () async {
      final r = TestLabs.crp();
      await h.index.indexLabResult(r.id!, r);
      await h.assertChunkContains(
        RagCollection.labs,
        'lab_tx_${r.id}',
        ['crp'],
      );
    });

    test('02 CRP: value and unit stored verbatim', () async {
      final r = TestLabs.crp(value: 12.5);
      await h.index.indexLabResult(r.id!, r);
      await h.assertChunkContains(
        RagCollection.labs,
        'lab_tx_${r.id}',
        ['12.5 mg/L'],
      );
    });

    test('03 CRP: drawn_date stored', () async {
      final r = TestLabs.crp();
      await h.index.indexLabResult(r.id!, r);
      await h.assertChunkContains(
        RagCollection.labs,
        'lab_tx_${r.id}',
        ['2026-05-10'],
      );
    });

    test('04 CRP: reference_high stored', () async {
      final r = TestLabs.crp();
      await h.index.indexLabResult(r.id!, r);
      await h.assertChunkContains(
        RagCollection.labs,
        'lab_tx_${r.id}',
        ['5.0 mg/L'],
      );
    });

    test('05 CRP: abnormal flag calculated correctly for elevated value',
        () async {
      final r = TestLabs.crp(value: 12.5); // reference_high=5.0
      await h.index.indexLabResult(r.id!, r);
      await h.assertChunkContains(
        RagCollection.labs,
        'lab_tx_${r.id}',
        ['abnormal: yes'],
      );
    });

    test('06 normal CRP: abnormal flag shows no', () async {
      final r = TestLabs.normalCrp(); // value=1.2 < reference=5.0
      await h.index.indexLabResult(r.id!, r);
      await h.assertChunkContains(
        RagCollection.labs,
        'lab_tx_${r.id}',
        ['abnormal: no'],
      );
    });

    test('07 lab_name stored when present', () async {
      final r = TestLabs.crp();
      await h.index.indexLabResult(r.id!, r);
      await h.assertChunkContains(
        RagCollection.labs,
        'lab_tx_${r.id}',
        ['Quest Diagnostics'],
      );
    });

    test('08 ordering_provider stored when present', () async {
      final r = TestLabs.crp();
      await h.index.indexLabResult(r.id!, r);
      await h.assertChunkContains(
        RagCollection.labs,
        'lab_tx_${r.id}',
        ['Dr. Smith'],
      );
    });

    test('09 calprotectin: µg/g unit stored', () async {
      final r = TestLabs.calprotectin();
      await h.index.indexLabResult(r.id!, r);
      await h.assertChunkContains(
        RagCollection.labs,
        'lab_tx_${r.id}',
        ['fc', '287.0', 'µg/g'],
      );
    });

    test('10 albumin: no reference_high — abnormal line omitted', () async {
      final r = TestLabs.albumin(); // referenceHigh is null
      await h.index.indexLabResult(r.id!, r);
      final match = await h.query.getById(
        collection: RagCollection.labs,
        chunkId: 'lab_tx_${r.id}',
      );
      // referenceHigh is null → no reference_high line OR abnormal line.
      expect(match!.text.contains('abnormal'), isFalse);
    });

    test('11 indexLabResult returns success', () async {
      final r = TestLabs.crp();
      final result = await h.index.indexLabResult(r.id!, r);
      expect(result.status, equals(RagIndexStatus.success));
      expect(result.chunkId, equals('lab_tx_301'));
      expect(result.collection, equals(RagCollection.labs));
    });

    test('12 stored in labs collection (not symptoms)', () async {
      final r = TestLabs.crp();
      await h.index.indexLabResult(r.id!, r);
      await h.assertChunkExists(RagCollection.labs, 'lab_tx_301');
      await h.assertChunkNotExists(RagCollection.symptoms, 'lab_tx_301');
    });

    test('13 query "CRP elevated inflammation" finds CRP result', () async {
      await h.index.indexLabResult(TestLabs.crp().id!, TestLabs.crp());
      await h.index
          .indexLabResult(TestLabs.calprotectin().id!, TestLabs.calprotectin());
      final results = await h.query.queryCollection(
        RagCollection.labs,
        'CRP elevated inflammation marker',
      );
      expect(results.any((r) => r.text.contains('crp')), isTrue);
    });

    test('14 metadata: lab_type is correct', () async {
      final r = TestLabs.crp();
      await h.index.indexLabResult(r.id!, r);
      final match = await h.query.getById(
        collection: RagCollection.labs,
        chunkId: 'lab_tx_301',
      );
      expect(match!.metadata['lab_type'], equals('crp'));
    });

    test('15 metadata: drawn_date is stored', () async {
      final r = TestLabs.crp();
      await h.index.indexLabResult(r.id!, r);
      final match = await h.query.getById(
        collection: RagCollection.labs,
        chunkId: 'lab_tx_301',
      );
      expect(match!.metadata['drawn_date'], equals('2026-05-10'));
    });

    test('16 metadata: value_numeric is correct', () async {
      final r = TestLabs.crp(value: 12.5);
      await h.index.indexLabResult(r.id!, r);
      final match = await h.query.getById(
        collection: RagCollection.labs,
        chunkId: 'lab_tx_301',
      );
      expect(match!.metadata['value_numeric'], closeTo(12.5, 0.001));
    });

    // ── Edge cases ─────────────────────────────────────────────────────────

    test('17 edge: zero value stores 0.0 without abnormal yes', () async {
      final r = TestLabs.zeroValue(); // value=0.0, reference=5.0
      await h.index.indexLabResult(r.id!, r);
      await h.assertChunkContains(
        RagCollection.labs,
        'lab_tx_${r.id}',
        ['0.0 mg/L', 'abnormal: no'],
      );
    });

    test('18 edge: extreme value (289.6 mg/L CRP) stores correctly', () async {
      final r = TestLabs.extremeValue();
      await h.index.indexLabResult(r.id!, r);
      await h.assertChunkContains(
        RagCollection.labs,
        'lab_tx_${r.id}',
        ['289.6', 'abnormal: yes', 'Acute phase response'],
      );
    });

    test('19 edge: future drawn_date stored as-is (no validation error)',
        () async {
      final r = TestLabs.futureDate();
      final result = await h.index.indexLabResult(r.id!, r);
      expect(result.status, equals(RagIndexStatus.success));
      await h.assertChunkContains(
        RagCollection.labs,
        'lab_tx_${r.id}',
        ['2027-01-01', 'esr'],
      );
    });

    test('20 edge: null lab_name not written to text', () async {
      final r = TestLabs.calprotectin(); // labName is null
      await h.index.indexLabResult(r.id!, r);
      final match = await h.query.getById(
        collection: RagCollection.labs,
        chunkId: 'lab_tx_${r.id}',
      );
      expect(match!.text.contains('null'), isFalse);
    });

    test('21 edge: null ordering_provider not written to text', () async {
      final r = TestLabs.calprotectin(); // orderingProvider is null
      await h.index.indexLabResult(r.id!, r);
      final match = await h.query.getById(
        collection: RagCollection.labs,
        chunkId: 'lab_tx_${r.id}',
      );
      expect(match!.text.contains('null'), isFalse);
    });

    test('22 duplicate lab id overwrites with new value', () async {
      final r1 = TestLabs.crp(value: 5.5);
      final r2 = TestLabs.crp(value: 18.9); // same id=301
      await h.index.indexLabResult(r1.id!, r1);
      await h.index.indexLabResult(r2.id!, r2);
      await h.assertChunkContains(
        RagCollection.labs,
        'lab_tx_301',
        ['18.9'],
      );
      final match = await h.query.getById(
        collection: RagCollection.labs,
        chunkId: 'lab_tx_301',
      );
      expect(match!.text.contains('5.5'), isFalse);
    });

    test('23 text format has schema version', () async {
      final r = TestLabs.crp();
      await h.index.indexLabResult(r.id!, r);
      final match = await h.query.getById(
        collection: RagCollection.labs,
        chunkId: 'lab_tx_301',
      );
      expect(match!.text, contains('lab_rag_v1'));
    });

    test('24 formatLabResult pure: same input → same output', () {
      final r = TestLabs.crp();
      final t1 = RagTextFormatter.formatLabResult(r.id!, r);
      final t2 = RagTextFormatter.formatLabResult(r.id!, r);
      expect(t1, equals(t2));
    });

    test('25 labChunkId format: lab_tx_{int}', () {
      expect(RagTextFormatter.labChunkId(1), equals('lab_tx_1'));
      expect(RagTextFormatter.labChunkId(9999), equals('lab_tx_9999'));
    });

    test('26 notes stored for CRP (fasting sample note)', () async {
      final r = TestLabs.crp(); // notes='Fasting sample'
      await h.index.indexLabResult(r.id!, r);
      await h.assertChunkContains(
        RagCollection.labs,
        'lab_tx_${r.id}',
        ['Fasting sample'],
      );
    });

    test('27 four different lab types all indexable', () async {
      final labs = [
        TestLabs.crp(),
        TestLabs.calprotectin(),
        TestLabs.albumin(),
        TestLabs.normalCrp(),
      ];
      for (final r in labs) {
        await h.index.indexLabResult(r.id!, r);
      }
      expect(await h.store.count(RagCollection.labs), equals(4));
    });

    test('28 schema marker in metadata', () async {
      final r = TestLabs.crp();
      await h.index.indexLabResult(r.id!, r);
      final match = await h.query.getById(
        collection: RagCollection.labs,
        chunkId: 'lab_tx_301',
      );
      expect(match!.metadata['schema'], equals('lab_rag_v1'));
    });

    test('29 abnormal percentage stored in text for elevated CRP', () async {
      // value=12.5, reference=5.0 → 250% of limit
      final r = TestLabs.crp(value: 12.5);
      await h.index.indexLabResult(r.id!, r);
      final match = await h.query.getById(
        collection: RagCollection.labs,
        chunkId: 'lab_tx_301',
      );
      expect(match!.text, contains('250%'));
    });

    test('30 50 lab results — all individually retrievable', () async {
      for (var i = 1; i <= 50; i++) {
        final r = LabValueRecord(
          id: i,
          drawnDate: '2026-0${(i % 5) + 1}-${(i % 28) + 1}'.padLeft(10, '0'),
          labType: i.isEven ? 'crp' : 'fc',
          valueNumeric: i * 2.5,
          unit: i.isEven ? 'mg/L' : 'µg/g',
          referenceHigh: i.isEven ? 5.0 : 150.0,
          labName: null,
          orderingProvider: null,
          notes: 'Lab entry $i',
          createdAt: DateTime.utc(2026, 5, 1),
          updatedAt: DateTime.utc(2026, 5, 1),
        );
        await h.index.indexLabResult(i, r);
      }
      expect(await h.store.count(RagCollection.labs), equals(50));
      final spot = await h.query.getById(
        collection: RagCollection.labs,
        chunkId: 'lab_tx_25',
      );
      expect(spot!.text, contains('Lab entry 25'));
    });
  });
}
