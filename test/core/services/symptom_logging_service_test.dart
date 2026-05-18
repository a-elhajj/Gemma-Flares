import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/rag_corpus_service.dart';
import 'package:gemma_flares/core/services/local_model_runtime.dart';
import 'package:gemma_flares/core/services/rag_memory_service.dart';
import 'package:gemma_flares/core/services/risk_engine_service.dart';
import 'package:gemma_flares/core/services/symptom_logging_service.dart';
import 'package:gemma_flares/core/services/symptom_parser_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test(
    'saving a symptom persists it and refreshes the latest risk score',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_symptom_logging_test',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final riskEngine = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-16T08:00:00Z'),
      );
      final service = SymptomLoggingService(
        repository: repository,
        parser: const SymptomParserService(),
        riskEngineService: riskEngine,
        nowProvider: () => DateTime.parse('2026-04-16T08:00:00Z'),
      );

      for (var day = 1; day <= 15; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {
              'hrv_sdnn_mean': 48.0,
              'resting_hr_mean': 58.0,
              'sleep_total_minutes': 420,
              'step_count_total': 8000,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-16T08:00:00Z'),
          ),
        );
      }
      await repository.updateSyncState(
        sourceName: 'apple_health',
        lastSyncAt: DateTime.parse('2026-04-16T06:00:00Z'),
        lastBackfillStart: DateTime.parse('2026-03-17T06:00:00Z'),
        lastBackfillEnd: DateTime.parse('2026-04-16T06:00:00Z'),
      );

      final result = await service.saveTranscript(
        transcript: 'Had cramping after lunch, 6 out of 10',
        loggedAt: DateTime.parse('2026-04-16T08:00:00Z'),
      );

      expect(result.savedSymptom.id, isNotNull);
      expect(result.savedSymptom.symptomType, 'cramping');
      expect(result.updatedRiskScore, isNotNull);
      expect(result.updatedRiskScore!.contributionJson['symptom_points'], 20);

      final symptoms = await repository.getRecentSymptoms();
      expect(symptoms, hasLength(1));
      expect(symptoms.single.mealRelation, 'after_lunch');

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test(
    'symptom save writes a ledger transaction via RagMemoryService',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_symptom_rag_tx_test',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final riskEngine = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-16T08:00:00Z'),
      );
      final rag = _RecordingRagMemoryService(repository: repository);
      final service = SymptomLoggingService(
        repository: repository,
        parser: const SymptomParserService(),
        riskEngineService: riskEngine,
        ragMemoryService: rag,
        nowProvider: () => DateTime.parse('2026-04-16T08:00:00Z'),
      );

      await service.saveTranscript(
        transcript: 'cramping and urgency after lunch',
        loggedAt: DateTime.parse('2026-04-16T08:00:00Z'),
        preferGemma: false,
      );

      expect(rag.calls, isNotEmpty);
      expect(rag.calls.first['transaction_id'], startsWith('symptom_tx_'));
      expect(rag.calls.first['source_type'], 'symptom');

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );
}

class _RecordingRagMemoryService extends RagMemoryService {
  _RecordingRagMemoryService({required super.repository})
      : super(
          corpusService: RagCorpusService(),
          runtime: const UnavailableGemmaRuntime(),
        );

  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];

  @override
  Future<RagWriteResult> writeAndVerify({
    required String transactionId,
    required String sourceType,
    required String sourceId,
    required String text,
    Map<String, Object?> metadata = const {},
  }) async {
    calls.add({
      'transaction_id': transactionId,
      'source_type': sourceType,
      'source_id': sourceId,
      'text': text,
      'metadata': metadata,
    });
    return RagWriteResult(
      transactionId: transactionId,
      chunkId: transactionId,
      status: RagMemoryStatus.writtenToCorpus,
      verified: false,
    );
  }
}
