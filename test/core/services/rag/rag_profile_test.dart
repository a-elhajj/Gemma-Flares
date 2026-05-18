// 15 tests: user profile round-trip indexing and content verification.
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/rag_index_service.dart';
import 'package:gemma_flares/core/services/rag_text_formatter.dart';

import 'rag_test_harness.dart';

void main() {
  group('User Profile RAG — round-trip indexing', () {
    late RagTestHarness h;
    setUp(() => h = RagTestHarness());

    // ── Basic round-trips ──────────────────────────────────────────────────

    test('01 Crohns male: disease_type stored', () async {
      await h.index.indexProfile(TestProfiles.crohnsMale());
      await h.assertChunkContains(
        RagCollection.profile,
        RagTextFormatter.profileChunkId,
        ['disease_type: CD'],
      );
    });

    test('02 Crohns male: diagnosis_year stored', () async {
      await h.index.indexProfile(TestProfiles.crohnsMale());
      await h.assertChunkContains(
        RagCollection.profile,
        RagTextFormatter.profileChunkId,
        ['diagnosis_year: 2018'],
      );
    });

    test('03 Crohns male: medications stored', () async {
      await h.index.indexProfile(TestProfiles.crohnsMale());
      await h.assertChunkContains(
        RagCollection.profile,
        RagTextFormatter.profileChunkId,
        ['Mesalamine', 'Vedolizumab'],
      );
    });

    test('04 Crohns male: other_conditions stored', () async {
      await h.index.indexProfile(TestProfiles.crohnsMale());
      await h.assertChunkContains(
        RagCollection.profile,
        RagTextFormatter.profileChunkId,
        ['primary_sclerosing_cholangitis'],
      );
    });

    test('05 UC female: disease_type and extent stored', () async {
      await h.index.indexProfile(TestProfiles.ucFemale());
      await h.assertChunkContains(
        RagCollection.profile,
        RagTextFormatter.profileChunkId,
        ['disease_type: UC', 'uc_disease_extent: E2'],
      );
    });

    test('06 post-surgery: had_surgery and type stored', () async {
      await h.index.indexProfile(TestProfiles.postSurgery());
      await h.assertChunkContains(
        RagCollection.profile,
        RagTextFormatter.profileChunkId,
        ['had_surgery: yes', 'ileocolonic_resection', '2012'],
      );
    });

    test('07 indexProfile returns success with correct chunk id', () async {
      final result = await h.index.indexProfile(TestProfiles.crohnsMale());
      expect(result.status, equals(RagIndexStatus.success));
      expect(result.chunkId, equals(RagTextFormatter.profileChunkId));
      expect(result.collection, equals(RagCollection.profile));
      expect(result.textLength, greaterThan(0));
    });

    test('08 stored in profile collection (not symptoms)', () async {
      await h.index.indexProfile(TestProfiles.crohnsMale());
      await h.assertChunkExists(
          RagCollection.profile, RagTextFormatter.profileChunkId);
      await h.assertChunkNotExists(
          RagCollection.symptoms, RagTextFormatter.profileChunkId);
    });

    test('09 schema version marker in text', () async {
      await h.index.indexProfile(TestProfiles.crohnsMale());
      final match = await h.query.getById(
        collection: RagCollection.profile,
        chunkId: RagTextFormatter.profileChunkId,
      );
      expect(match!.text, contains('profile_rag_v1'));
    });

    test('10 metadata: disease_type correct', () async {
      await h.index.indexProfile(TestProfiles.crohnsMale());
      final match = await h.query.getById(
        collection: RagCollection.profile,
        chunkId: RagTextFormatter.profileChunkId,
      );
      expect(match!.metadata['disease_type'], equals('CD'));
      expect(match.metadata['schema'], equals('profile_rag_v1'));
    });

    test('11 metadata: medication_count correct', () async {
      await h.index.indexProfile(TestProfiles.crohnsMale()); // 2 medications
      final match = await h.query.getById(
        collection: RagCollection.profile,
        chunkId: RagTextFormatter.profileChunkId,
      );
      expect(match!.metadata['medication_count'], equals(2));
    });

    test('12 edge: empty profile indexes without crash', () async {
      final result = await h.index.indexProfile(TestProfiles.emptyProfile());
      expect(result.status, equals(RagIndexStatus.success));
    });

    test('13 edge: empty profile — no null fields in text', () async {
      await h.index.indexProfile(TestProfiles.emptyProfile());
      final match = await h.query.getById(
        collection: RagCollection.profile,
        chunkId: RagTextFormatter.profileChunkId,
      );
      expect(match!.text, isNot(contains('null')));
    });

    test('14 edge: profile is overwritten when re-indexed (same chunkId)',
        () async {
      await h.index.indexProfile(TestProfiles.crohnsMale()); // CD
      await h.index.indexProfile(TestProfiles.ucFemale()); // UC overwrites
      final match = await h.query.getById(
        collection: RagCollection.profile,
        chunkId: RagTextFormatter.profileChunkId,
      );
      expect(match!.text, contains('UC'));
      expect(match.text, isNot(contains('primary_sclerosing_cholangitis')));
    });

    test('15 formatProfile pure: same input → same output', () {
      final p = TestProfiles.crohnsMale();
      final t1 = RagTextFormatter.formatProfile(p);
      final t2 = RagTextFormatter.formatProfile(p);
      expect(t1, equals(t2));
    });
  });
}
