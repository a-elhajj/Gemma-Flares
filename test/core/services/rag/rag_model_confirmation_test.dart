// 12 tests: model installation confirmation round-trip indexing.
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/services/rag_index_service.dart';
import 'package:gemma_flares/core/services/rag_text_formatter.dart';
import 'package:gemma_flares/core/services/setup_state_service.dart';

import 'rag_test_harness.dart';

const _kProvider = 'litert-lm';
const _kModelId = 'gemma-4-e2b-litert';
const _kChunkId = 'model_install_litert-lm_gemma_4_e2b_litert';

void main() {
  group('Model Installation RAG — round-trip indexing', () {
    late RagTestHarness h;
    setUp(() => h = RagTestHarness());

    test('01 engine_provider stored', () async {
      await h.index.indexModelInstallation(
        engineProvider: _kProvider,
        modelId: _kModelId,
        installedAt: DateTime.utc(2026, 5, 15, 9, 55),
        validated: true,
        runtimeProfile: 'phone_safe',
        backend: 'gpu',
      );
      await h.assertChunkContains(
        RagCollection.modelEvents,
        _kChunkId,
        ['litert-lm'],
      );
    });

    test('02 model_id stored', () async {
      await h.index.indexModelInstallation(
        engineProvider: _kProvider,
        modelId: _kModelId,
        installedAt: DateTime.utc(2026, 5, 15, 9, 55),
        validated: true,
      );
      await h.assertChunkContains(
        RagCollection.modelEvents,
        _kChunkId,
        ['gemma-4-e2b-litert'],
      );
    });

    test('03 validated=true stored', () async {
      await h.index.indexModelInstallation(
        engineProvider: _kProvider,
        modelId: _kModelId,
        installedAt: DateTime.utc(2026, 5, 15, 9, 55),
        validated: true,
      );
      await h.assertChunkContains(
        RagCollection.modelEvents,
        _kChunkId,
        ['validated: true'],
      );
    });

    test('04 runtime_profile and backend stored when present', () async {
      await h.index.indexModelInstallation(
        engineProvider: _kProvider,
        modelId: _kModelId,
        installedAt: DateTime.utc(2026, 5, 15, 9, 55),
        validated: true,
        runtimeProfile: 'phone_safe',
        backend: 'gpu',
      );
      await h.assertChunkContains(
        RagCollection.modelEvents,
        _kChunkId,
        ['runtime_profile: phone_safe', 'backend: gpu'],
      );
    });

    test('05 indexModelInstallation returns success', () async {
      final result = await h.index.indexModelInstallation(
        engineProvider: _kProvider,
        modelId: _kModelId,
        installedAt: DateTime.utc(2026, 5, 15, 9, 55),
        validated: true,
      );
      expect(result.status, equals(RagIndexStatus.success));
      expect(result.chunkId, equals(_kChunkId));
      expect(result.collection, equals(RagCollection.modelEvents));
    });

    test('06 stored in model_events (not summaries)', () async {
      await h.index.indexModelInstallation(
        engineProvider: _kProvider,
        modelId: _kModelId,
        installedAt: DateTime.utc(2026, 5, 15, 9, 55),
        validated: true,
      );
      await h.assertChunkExists(RagCollection.modelEvents, _kChunkId);
      await h.assertChunkNotExists(RagCollection.summaries, _kChunkId);
    });

    test('07 schema version marker in text', () async {
      await h.index.indexModelInstallation(
        engineProvider: _kProvider,
        modelId: _kModelId,
        installedAt: DateTime.utc(2026, 5, 15, 9, 55),
        validated: true,
      );
      final match = await h.query.getById(
        collection: RagCollection.modelEvents,
        chunkId: _kChunkId,
      );
      expect(match!.text, contains('model_event_rag_v1'));
    });

    test('08 metadata: engine, model, validated, profile, backend all stored',
        () async {
      await h.index.indexModelInstallation(
        engineProvider: _kProvider,
        modelId: _kModelId,
        installedAt: DateTime.utc(2026, 5, 15, 9, 55),
        validated: true,
        runtimeProfile: 'phone_safe',
        backend: 'gpu',
      );
      final match = await h.query.getById(
        collection: RagCollection.modelEvents,
        chunkId: _kChunkId,
      );
      expect(match!.metadata['engine_provider'], equals('litert-lm'));
      expect(match.metadata['model_id'], equals('gemma-4-e2b-litert'));
      expect(match.metadata['validated'], isTrue);
      expect(match.metadata['runtime_profile'], equals('phone_safe'));
      expect(match.metadata['backend'], equals('gpu'));
      expect(match.metadata['schema'], equals('model_event_rag_v1'));
    });

    test('09 indexModelInstallationFromSetup: completedSetup indexes correctly',
        () async {
      final setup = TestModelEvents.completedSetup();
      final result = await h.index.indexModelInstallationFromSetup(setup);
      expect(result.status, equals(RagIndexStatus.success));
      await h.assertChunkContains(
        RagCollection.modelEvents,
        result.chunkId,
        ['litert-lm', 'gemma-4-e2b-litert', 'validated: true'],
      );
    });

    test('10 indexModelInstallationFromSetup: null modelValidatedAt → skipped',
        () async {
      const setup = SetupStatus(); // modelValidatedAt is null
      final result = await h.index.indexModelInstallationFromSetup(setup);
      expect(result.status, equals(RagIndexStatus.skipped));
    });

    test('11 extra fields in extra map stored in text', () async {
      await h.index.indexModelInstallation(
        engineProvider: _kProvider,
        modelId: _kModelId,
        installedAt: DateTime.utc(2026, 5, 15, 9, 55),
        validated: true,
        extra: {'sha256_match': true, 'model_size_mb': 2048},
      );
      await h.assertChunkContains(
        RagCollection.modelEvents,
        _kChunkId,
        ['sha256_match: true', 'model_size_mb: 2048'],
      );
    });

    test('12 modelInstallChunkId sanitizes dashes in modelId to underscores',
        () {
      expect(
        RagTextFormatter.modelInstallChunkId('litert-lm', 'gemma-4-e2b-litert'),
        equals('model_install_litert-lm_gemma_4_e2b_litert'),
      );
    });
  });
}
