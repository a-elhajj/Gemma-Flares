// 25 tests: medication/intake event round-trip indexing and content verification.
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart'
    show IntakeEventRecord;
import 'package:gemma_flares/core/services/rag_index_service.dart';
import 'package:gemma_flares/core/services/rag_text_formatter.dart';

import 'rag_test_harness.dart';

void main() {
  group('Medication RAG — round-trip indexing', () {
    late RagTestHarness h;
    setUp(() => h = RagTestHarness());

    // ── Basic round-trips ──────────────────────────────────────────────────

    test('01 mesalamine: event_type stored', () async {
      final e = TestMedications.mesalamineTaken();
      await h.index.indexMedication(e.id!, e);
      await h.assertChunkContains(
        RagCollection.summaries,
        'med_tx_${e.id}',
        ['medication_taken'],
      );
    });

    test('02 mesalamine: medication_name stored', () async {
      final e = TestMedications.mesalamineTaken();
      await h.index.indexMedication(e.id!, e);
      await h.assertChunkContains(
        RagCollection.summaries,
        'med_tx_${e.id}',
        ['Mesalamine'],
      );
    });

    test('03 mesalamine: dose stored', () async {
      final e = TestMedications.mesalamineTaken();
      await h.index.indexMedication(e.id!, e);
      await h.assertChunkContains(
        RagCollection.summaries,
        'med_tx_${e.id}',
        ['1.2g'],
      );
    });

    test('04 mesalamine: schedule stored', () async {
      final e = TestMedications.mesalamineTaken();
      await h.index.indexMedication(e.id!, e);
      await h.assertChunkContains(
        RagCollection.summaries,
        'med_tx_${e.id}',
        ['morning'],
      );
    });

    test('05 mesalamine: adherence_indicator stored', () async {
      final e = TestMedications.mesalamineTaken();
      await h.index.indexMedication(e.id!, e);
      await h.assertChunkContains(
        RagCollection.summaries,
        'med_tx_${e.id}',
        ['on_time'],
      );
    });

    test('06 prednisolone: skipped event type stored', () async {
      final e = TestMedications.prednisoloneSkipped();
      await h.index.indexMedication(e.id!, e);
      await h.assertChunkContains(
        RagCollection.summaries,
        'med_tx_${e.id}',
        ['medication_skipped', 'missed_dose'],
      );
    });

    test('07 prednisolone: medication and dose stored', () async {
      final e = TestMedications.prednisoloneSkipped();
      await h.index.indexMedication(e.id!, e);
      await h.assertChunkContains(
        RagCollection.summaries,
        'med_tx_${e.id}',
        ['Prednisolone', '20mg'],
      );
    });

    test('08 vedolizumab: IV dose stored', () async {
      final e = TestMedications.biologicInfusion();
      await h.index.indexMedication(e.id!, e);
      await h.assertChunkContains(
        RagCollection.summaries,
        'med_tx_${e.id}',
        ['Vedolizumab', '300mg IV'],
      );
    });

    test('09 mesalamine: date_local stored', () async {
      final e = TestMedications.mesalamineTaken();
      await h.index.indexMedication(e.id!, e);
      await h.assertChunkContains(
        RagCollection.summaries,
        'med_tx_${e.id}',
        ['2026-05-15'],
      );
    });

    test('10 mesalamine: confidence percentage stored', () async {
      final e = TestMedications.mesalamineTaken(); // confidence=0.95
      await h.index.indexMedication(e.id!, e);
      await h.assertChunkContains(
        RagCollection.summaries,
        'med_tx_${e.id}',
        ['95%'],
      );
    });

    test('11 mesalamine: notes stored', () async {
      final e = TestMedications.mesalamineTaken(); // has notes
      await h.index.indexMedication(e.id!, e);
      await h.assertChunkContains(
        RagCollection.summaries,
        'med_tx_${e.id}',
        ['Took Mesalamine'],
      );
    });

    test('12 indexMedication returns success', () async {
      final e = TestMedications.mesalamineTaken();
      final result = await h.index.indexMedication(e.id!, e);
      expect(result.status, equals(RagIndexStatus.success));
      expect(result.chunkId, equals('med_tx_701'));
      expect(result.collection, equals(RagCollection.summaries));
      expect(result.textLength, greaterThan(0));
    });

    test('13 stored in summaries collection (not labs)', () async {
      final e = TestMedications.mesalamineTaken();
      await h.index.indexMedication(e.id!, e);
      await h.assertChunkExists(RagCollection.summaries, 'med_tx_701');
      await h.assertChunkNotExists(RagCollection.labs, 'med_tx_701');
    });

    test('14 schema version marker in text', () async {
      final e = TestMedications.mesalamineTaken();
      await h.index.indexMedication(e.id!, e);
      final match = await h.query.getById(
        collection: RagCollection.summaries,
        chunkId: 'med_tx_701',
      );
      expect(match!.text, contains('medication_rag_v1'));
    });

    // ── Metadata ──────────────────────────────────────────────────────────

    test('15 metadata: event_type correct', () async {
      final e = TestMedications.mesalamineTaken();
      await h.index.indexMedication(e.id!, e);
      final match = await h.query.getById(
        collection: RagCollection.summaries,
        chunkId: 'med_tx_701',
      );
      expect(match!.metadata['event_type'], equals('medication_taken'));
    });

    test('16 metadata: medication_name from metadataJson', () async {
      final e = TestMedications.mesalamineTaken();
      await h.index.indexMedication(e.id!, e);
      final match = await h.query.getById(
        collection: RagCollection.summaries,
        chunkId: 'med_tx_701',
      );
      expect(match!.metadata['medication_name'], equals('Mesalamine'));
    });

    test('17 metadata: schema version correct', () async {
      final e = TestMedications.mesalamineTaken();
      await h.index.indexMedication(e.id!, e);
      final match = await h.query.getById(
        collection: RagCollection.summaries,
        chunkId: 'med_tx_701',
      );
      expect(match!.metadata['schema'], equals('medication_rag_v1'));
    });

    // ── Semantic query ─────────────────────────────────────────────────────

    test('18 query "biologic infusion vedolizumab" finds infusion', () async {
      await h.index.indexMedication(TestMedications.mesalamineTaken().id!,
          TestMedications.mesalamineTaken());
      await h.index.indexMedication(TestMedications.biologicInfusion().id!,
          TestMedications.biologicInfusion());
      final results = await h.query.queryCollection(
        RagCollection.summaries,
        'biologic infusion vedolizumab',
      );
      expect(results.any((r) => r.text.contains('Vedolizumab')), isTrue);
    });

    // ── Edge cases ─────────────────────────────────────────────────────────

    test('19 edge: empty metadataJson does not crash', () async {
      final e = TestMedications.emptyMetadata();
      final result = await h.index.indexMedication(e.id!, e);
      expect(result.status, equals(RagIndexStatus.success));
    });

    test('20 edge: empty metadataJson — no null fields in text', () async {
      final e = TestMedications.emptyMetadata();
      await h.index.indexMedication(e.id!, e);
      final match = await h.query.getById(
        collection: RagCollection.summaries,
        chunkId: 'med_tx_${e.id}',
      );
      expect(match!.text, isNot(contains('null')));
    });

    test('21 edge: null notes not written to text', () async {
      final e = TestMedications.biologicInfusion(); // notes is null
      await h.index.indexMedication(e.id!, e);
      final match = await h.query.getById(
        collection: RagCollection.summaries,
        chunkId: 'med_tx_${e.id}',
      );
      expect(match!.text, isNot(contains('null')));
    });

    test('22 edge: duplicate id overwrites with updated values', () async {
      final e1 = TestMedications.mesalamineTaken();
      final e2 = IntakeEventRecord(
        id: 701,
        eventType: 'medication_taken',
        loggedAt: DateTime.utc(2026, 5, 15, 20, 0), // updated
        dateLocal: '2026-05-15',
        source: 'manual',
        confidence: 0.99,
        notes: 'Evening dose taken',
        metadataJson: {
          'schema_version': 2,
          'medication_name': 'Mesalamine',
          'dose': '1.2g',
          'schedule': 'evening',
          'adherence_indicator': 'on_time',
          'user_confirmed': true,
          'event_type': 'medication_taken',
        },
        createdAt: DateTime.utc(2026, 5, 15, 20, 1),
      );
      await h.index.indexMedication(e1.id!, e1);
      await h.index.indexMedication(e2.id!, e2);
      await h.assertChunkContains(
        RagCollection.summaries,
        'med_tx_701',
        ['Evening dose taken', 'evening'],
      );
      final match = await h.query.getById(
        collection: RagCollection.summaries,
        chunkId: 'med_tx_701',
      );
      expect(match!.text.contains('morning'), isFalse);
    });

    test('23 medicationChunkId deterministic format', () {
      expect(RagTextFormatter.medicationChunkId(1), equals('med_tx_1'));
      expect(RagTextFormatter.medicationChunkId(9999), equals('med_tx_9999'));
    });

    test('24 formatMedication pure: same input → same output', () {
      final e = TestMedications.mesalamineTaken();
      final t1 = RagTextFormatter.formatMedication(e.id!, e);
      final t2 = RagTextFormatter.formatMedication(e.id!, e);
      expect(t1, equals(t2));
    });

    test('25 three medications indexed — all individually retrievable',
        () async {
      final meds = [
        TestMedications.mesalamineTaken(),
        TestMedications.prednisoloneSkipped(),
        TestMedications.biologicInfusion(),
      ];
      for (final e in meds) {
        await h.index.indexMedication(e.id!, e);
      }
      for (final e in meds) {
        await h.assertChunkExists(RagCollection.summaries, 'med_tx_${e.id}');
      }
    });
  });
}
