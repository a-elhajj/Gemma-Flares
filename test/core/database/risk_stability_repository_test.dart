import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/wearable_normalization_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;
  late WearableSampleRepository repository;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_risk_stability_repo_',
    );
    database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    repository = WearableSampleRepository(database: database);
  });

  tearDown(() async {
    await database.close();
    await tempRoot.delete(recursive: true);
  });

  test('ignored wearable samples do not touch dates', () async {
    final sample = _normalizedSample(key: 'same', date: '2026-05-01');

    final first = await repository.upsertSamples([sample]);
    final second = await repository.upsertSamples([sample]);

    expect(first.inserted, 1);
    expect(first.touchedDates, ['2026-05-01']);
    expect(second.ignored, 1);
    expect(second.inserted, 0);
    expect(second.updated, 0);
    expect(second.touchedDates, isEmpty);
  });

  test('displayed score snapshot rehydrates horizon feature JSON', () async {
    final score = FlareRiskScoreRecord(
      dateLocal: '2026-05-01',
      riskScore: 42,
      riskBand: 'moderate',
      confidenceScore: 80,
      contributionJson: const {'driver': 'hrv'},
      featureSnapshotJson: const {
        'logistic_p_flare_7d': 0.31,
        'logistic_p_flare_14d': 0.36,
        'logistic_p_flare_21d': 0.41,
      },
      modelVersion: 'risk_v2_context_adjusted',
      createdAt: DateTime.utc(2026, 5, 1, 12),
    );
    await repository.upsertFlareRiskScore(score);
    await repository.upsertDisplayedScoreSnapshot(
      sessionId: 'sess',
      score: score,
      triggerReason: 'session_start',
      displayedAt: DateTime.utc(2026, 5, 1, 12, 1),
    );

    final displayed = await repository.getDisplayedSessionScore(
      sessionId: 'sess',
    );

    expect(displayed?.riskScore, 42);
    expect(displayed?.featureSnapshotJson['logistic_p_flare_7d'], 0.31);
    expect(displayed?.featureSnapshotJson['logistic_p_flare_14d'], 0.36);
    expect(displayed?.featureSnapshotJson['logistic_p_flare_21d'], 0.41);
    expect(displayed?.contributionJson['driver'], 'hrv');
  });

  test('clearLocalUserData also clears displayed score snapshots', () async {
    final score = FlareRiskScoreRecord(
      dateLocal: '2026-05-01',
      riskScore: 42,
      riskBand: 'moderate',
      confidenceScore: 80,
      contributionJson: const {'driver': 'hrv'},
      featureSnapshotJson: const {'logistic_p_flare_7d': 0.31},
      modelVersion: 'risk_v2_context_adjusted',
      createdAt: DateTime.utc(2026, 5, 1, 12),
    );
    await repository.upsertFlareRiskScore(score);
    await repository.upsertDisplayedScoreSnapshot(
      sessionId: 'sess',
      score: score,
      triggerReason: 'session_start',
      displayedAt: DateTime.utc(2026, 5, 1, 12, 1),
    );

    expect(
      await repository.getDisplayedSessionScore(sessionId: 'sess'),
      isNotNull,
    );

    await repository.clearLocalUserData();

    expect(
      await repository.getDisplayedSessionScore(sessionId: 'sess'),
      isNull,
    );
  });

  test('clearLocalUserData clears logistic training history markers', () async {
    await repository.insertTrainingHistoryRecordIfAbsent(
      LogisticTrainingHistoryRecord(
        modelKey: 'logistic_v1_inflammatory_7d',
        sampleDate: '2026-05-01',
        predictedProb: 0.42,
        actualLabel: 1,
        trainingN: 1,
        recordedAt: DateTime.utc(2026, 5, 8),
      ),
    );

    expect(
      await repository.hasTrainingHistoryRecord(
        modelKey: 'logistic_v1_inflammatory_7d',
        sampleDate: '2026-05-01',
      ),
      isTrue,
    );

    await repository.clearLocalUserData();

    expect(
      await repository.hasTrainingHistoryRecord(
        modelKey: 'logistic_v1_inflammatory_7d',
        sampleDate: '2026-05-01',
      ),
      isFalse,
    );
  });
}

NormalizedWearableSample _normalizedSample({
  required String key,
  required String date,
  double value = 42.0,
}) {
  return NormalizedWearableSample(
    sampleKey: key,
    localDate: date,
    vendorSampleId: key,
    sourceName: 'apple_health',
    sourceDevice: 'AppleWatch',
    metricName: 'hrv_sdnn',
    metricFamily: 'recovery',
    valueNumeric: value,
    unit: 'ms',
    startTimeUtc: DateTime.parse('${date}T08:00:00Z'),
    endTimeUtc: DateTime.parse('${date}T08:01:00Z'),
    timezone: 'America/Toronto',
    aggregationLevel: 'sample',
    isEstimated: false,
    isDeleted: false,
    metadata: const {},
    sourcePayload: const {},
    importedAt: DateTime.parse('2026-05-01T12:00:00Z'),
    updatedAt: DateTime.parse('2026-05-01T12:00:00Z'),
  );
}
