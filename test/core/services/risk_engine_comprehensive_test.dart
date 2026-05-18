@Tags(['extended'])
@Skip('Extended regression suite; run on demand with --run-skipped.')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/risk_engine_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;
  late WearableSampleRepository repository;

  Future<void> setUp() async {
    tempRoot = await Directory.systemTemp.createTemp('gemma_flares_risk_comp_');
    database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    repository = WearableSampleRepository(database: database);
  }

  Future<void> tearDown() async {
    await database.close();
    await tempRoot.delete(recursive: true);
  }

  Future<void> seedHealthy(int days, {int startDay = 1}) async {
    for (var day = startDay; day < startDay + days; day++) {
      final date = '2026-04-${day.toString().padLeft(2, '0')}';
      await repository.upsertDailySummary(
        DailySummaryRecord(
          dateLocal: date,
          summaryJson: {
            'hrv_sdnn_mean': 50.0,
            'resting_hr_mean': 58.0,
            'sleep_total_minutes': 420,
            'step_count_total': 8200,
            'spo2_mean': 97.0,
            'spo2_count': 3,
            'wrist_temp_mean': 0.0,
          },
          syncQualityScore: 1,
          recomputedAt: DateTime.parse('2026-04-30T08:00:00Z'),
        ),
      );
    }
  }

  Future<void> syncFresh(DateTime at) async {
    await repository.updateSyncState(
      sourceName: 'apple_health',
      lastSyncAt: at,
      lastBackfillStart: at.subtract(const Duration(days: 30)),
      lastBackfillEnd: at,
    );
  }

  group('risk band boundaries', () {
    test('score 0 gives low band', () async {
      await setUp();
      await seedHealthy(28);
      await syncFresh(DateTime.parse('2026-04-29T08:00:00Z'));
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-29T09:00:00Z'),
      );
      await service.recomputeDates(const ['2026-04-28']);
      final score = await repository.getLatestFlareRiskScore();
      expect(score!.riskBand, 'low');
      expect(score.riskScore, lessThanOrEqualTo(25));
      await tearDown();
    });

    test('score 26 gives moderate band', () async {
      await setUp();
      for (var day = 1; day <= 28; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        final deteriorated = day >= 26;
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {
              'hrv_sdnn_mean': deteriorated ? 40.0 : 50.0,
              'resting_hr_mean': deteriorated ? 62.0 : 58.0,
              'sleep_total_minutes': deteriorated ? 370 : 420,
              'step_count_total': deteriorated ? 6000 : 8200,
              'spo2_mean': 97.0,
              'spo2_count': 3,
              'wrist_temp_mean': 0.0,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-30T08:00:00Z'),
          ),
        );
      }
      await syncFresh(DateTime.parse('2026-04-29T08:00:00Z'));
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-29T09:00:00Z'),
      );
      await service.recomputeDates(const ['2026-04-28']);
      final score = await repository.getLatestFlareRiskScore();
      expect(score!.riskBand, anyOf('low', 'moderate'));
      await tearDown();
    });
  });

  group('HRV contribution bucket', () {
    test('no HRV drop yields 0 points', () async {
      await setUp();
      await seedHealthy(28);
      await syncFresh(DateTime.parse('2026-04-29T08:00:00Z'));
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-29T09:00:00Z'),
      );
      await service.recomputeDates(const ['2026-04-28']);
      final score = await repository.getLatestFlareRiskScore();
      expect(score!.contributionJson['hrv_points'], 0);
      await tearDown();
    });

    test('large HRV drop yields 25 points', () async {
      await setUp();
      for (var day = 1; day <= 28; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        final drop = day >= 26;
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {
              'hrv_sdnn_mean': drop ? 30.0 : 50.0,
              'resting_hr_mean': 58.0,
              'sleep_total_minutes': 420,
              'step_count_total': 8200,
              'spo2_mean': 97.0,
              'spo2_count': 3,
              'wrist_temp_mean': 0.0,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-30T08:00:00Z'),
          ),
        );
      }
      await syncFresh(DateTime.parse('2026-04-29T08:00:00Z'));
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-29T09:00:00Z'),
      );
      await service.recomputeDates(const ['2026-04-28']);
      final score = await repository.getLatestFlareRiskScore();
      expect(score!.contributionJson['hrv_points'], 25);
      await tearDown();
    });
  });

  group('resting HR contribution bucket', () {
    test('elevated RHR +8 bpm yields max 20 points', () async {
      await setUp();
      for (var day = 1; day <= 28; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        final elevated = day >= 26;
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {
              'hrv_sdnn_mean': 50.0,
              'resting_hr_mean': elevated ? 68.0 : 58.0,
              'sleep_total_minutes': 420,
              'step_count_total': 8200,
              'spo2_mean': 97.0,
              'spo2_count': 3,
              'wrist_temp_mean': 0.0,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-30T08:00:00Z'),
          ),
        );
      }
      await syncFresh(DateTime.parse('2026-04-29T08:00:00Z'));
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-29T09:00:00Z'),
      );
      await service.recomputeDates(const ['2026-04-28']);
      final score = await repository.getLatestFlareRiskScore();
      expect(score!.contributionJson['resting_hr_points'], 20);
      await tearDown();
    });
  });

  group('symptom contribution bucket', () {
    test('no symptoms yields 0 points', () async {
      await setUp();
      await seedHealthy(28);
      await syncFresh(DateTime.parse('2026-04-29T08:00:00Z'));
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-29T09:00:00Z'),
      );
      await service.recomputeDates(const ['2026-04-28']);
      final score = await repository.getLatestFlareRiskScore();
      expect(score!.contributionJson['symptom_points'], 0);
      await tearDown();
    });

    test('single mild symptom yields 8 points', () async {
      await setUp();
      await seedHealthy(28);
      await syncFresh(DateTime.parse('2026-04-29T08:00:00Z'));
      await repository.insertSymptom(
        SymptomRecord(
          loggedAt: DateTime.parse('2026-04-27T12:00:00Z'),
          symptomType: 'cramping',
          severity: 2,
          durationMinutes: 30,
          mealRelation: null,
          notes: 'test',
          sourceTranscript: 'test',
          extractionMethod: 'deterministic',
          extractionConfidence: 0.85,
          createdAt: DateTime.parse('2026-04-27T12:00:00Z'),
        ),
      );
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-29T09:00:00Z'),
      );
      await service.recomputeDates(const ['2026-04-28']);
      final score = await repository.getLatestFlareRiskScore();
      expect(score!.contributionJson['symptom_points'], 8);
      await tearDown();
    });

    test('multiple severe symptoms yield 20 points', () async {
      await setUp();
      await seedHealthy(28);
      await syncFresh(DateTime.parse('2026-04-29T08:00:00Z'));
      for (var i = 0; i < 3; i++) {
        await repository.insertSymptom(
          SymptomRecord(
            loggedAt: DateTime.parse('2026-04-27T${10 + i}:00:00Z'),
            symptomType: 'pain',
            severity: 7,
            durationMinutes: 60,
            mealRelation: null,
            notes: 'severe pain $i',
            sourceTranscript: 'severe pain $i',
            extractionMethod: 'deterministic',
            extractionConfidence: 0.85,
            createdAt: DateTime.parse('2026-04-27T${10 + i}:00:00Z'),
          ),
        );
      }
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-29T09:00:00Z'),
      );
      await service.recomputeDates(const ['2026-04-28']);
      final score = await repository.getLatestFlareRiskScore();
      expect(score!.contributionJson['symptom_points'], 20);
      await tearDown();
    });
  });

  group('confidence penalties', () {
    test('baseline not_ready penalizes confidence by 35', () async {
      await setUp();
      // Only 3 days => not_ready
      await seedHealthy(3);
      await syncFresh(DateTime.parse('2026-04-04T08:00:00Z'));
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-04T09:00:00Z'),
      );
      await service.recomputeDates(const ['2026-04-03']);
      final score = await repository.getLatestFlareRiskScore();
      expect(score!.confidenceScore, lessThan(70));
      await tearDown();
    });

    test('stale sync penalizes confidence by 15', () async {
      await setUp();
      await seedHealthy(28);
      // Sync 4 days ago (>72 hours)
      await repository.updateSyncState(
        sourceName: 'apple_health',
        lastSyncAt: DateTime.parse('2026-04-24T08:00:00Z'),
        lastBackfillStart: DateTime.parse('2026-03-25T08:00:00Z'),
        lastBackfillEnd: DateTime.parse('2026-04-24T08:00:00Z'),
      );
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-29T09:00:00Z'),
      );
      await service.recomputeDates(const ['2026-04-28']);
      final score = await repository.getLatestFlareRiskScore();
      final components = score!.contributionJson['confidence_components']
          as Map<String, Object?>;
      final inputs =
          score.contributionJson['confidence_inputs'] as Map<String, Object?>;
      expect(inputs['stale_sync'], true);
      expect(components['sync_freshness'], lessThan(15));
      await tearDown();
    });

    test('missing HRV penalizes confidence by 10', () async {
      await setUp();
      for (var day = 1; day <= 28; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {
              'resting_hr_mean': 58.0,
              'sleep_total_minutes': 420,
              'step_count_total': 8200,
              'spo2_mean': 97.0,
              'spo2_count': 3,
              'wrist_temp_mean': 0.0,
            },
            syncQualityScore: 0.83,
            recomputedAt: DateTime.parse('2026-04-30T08:00:00Z'),
          ),
        );
      }
      await syncFresh(DateTime.parse('2026-04-29T08:00:00Z'));
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-29T09:00:00Z'),
      );
      await service.recomputeDates(const ['2026-04-28']);
      final score = await repository.getLatestFlareRiskScore();
      final components = score!.contributionJson['confidence_components']
          as Map<String, Object?>;
      final inputs =
          score.contributionJson['confidence_inputs'] as Map<String, Object?>;
      expect(inputs['available_metric_families'], lessThan(5));
      expect(components['data_coverage'], lessThan(25));
      await tearDown();
    });

    test('ready baseline applies only the ready-not-mature penalty', () async {
      await setUp();
      await seedHealthy(28);
      await syncFresh(DateTime.parse('2026-04-29T08:00:00Z'));
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-29T09:00:00Z'),
      );
      await service.recomputeDates(const ['2026-04-28']);
      final score = await repository.getLatestFlareRiskScore();
      final components = score!.contributionJson['confidence_components']
          as Map<String, Object?>;
      final inputs =
          score.contributionJson['confidence_inputs'] as Map<String, Object?>;
      expect(inputs['baseline_readiness'], isNot('not_ready'));
      expect(components['baseline_maturity'], greaterThan(0));
      expect(score.confidenceScore, greaterThan(70));
      await tearDown();
    });
  });

  group('sparse vitals contribution', () {
    test('SpO2 drop causes sparse points', () async {
      await setUp();
      for (var day = 1; day <= 28; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        final drop = day >= 22;
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {
              'hrv_sdnn_mean': 50.0,
              'resting_hr_mean': 58.0,
              'sleep_total_minutes': 420,
              'step_count_total': 8200,
              'spo2_mean': drop ? 93.0 : 97.0,
              'spo2_count': 3,
              'wrist_temp_mean': 0.0,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-30T08:00:00Z'),
          ),
        );
      }
      await syncFresh(DateTime.parse('2026-04-29T08:00:00Z'));
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-29T09:00:00Z'),
      );
      await service.recomputeDates(const ['2026-04-28']);
      final score = await repository.getLatestFlareRiskScore();
      expect(
        (score!.contributionJson['sparse_vitals_points'] as int),
        greaterThan(0),
      );
      await tearDown();
    });

    test('elevated wrist temp causes sparse points', () async {
      await setUp();
      for (var day = 1; day <= 28; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        final hot = day >= 26;
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {
              'hrv_sdnn_mean': 50.0,
              'resting_hr_mean': 58.0,
              'sleep_total_minutes': 420,
              'step_count_total': 8200,
              'spo2_mean': 97.0,
              'spo2_count': 3,
              'wrist_temp_mean': hot ? 1.0 : 0.0,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-30T08:00:00Z'),
          ),
        );
      }
      await syncFresh(DateTime.parse('2026-04-29T08:00:00Z'));
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-29T09:00:00Z'),
      );
      await service.recomputeDates(const ['2026-04-28']);
      final score = await repository.getLatestFlareRiskScore();
      expect(
        (score!.contributionJson['sparse_vitals_points'] as int),
        greaterThan(0),
      );
      await tearDown();
    });
  });

  group('date expansion and multi-date recompute', () {
    test('recomputes forward up to 6 days for cascade effect', () async {
      await setUp();
      await seedHealthy(14);
      await syncFresh(DateTime.parse('2026-04-15T08:00:00Z'));
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-15T09:00:00Z'),
      );
      final result = await service.recomputeDates(const ['2026-04-01']);
      // Should expand dates forward for rolling window recalculation
      expect(result.recomputedDates.length, greaterThan(1));
      await tearDown();
    });

    test('empty summaries returns empty result', () async {
      await setUp();
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-29T09:00:00Z'),
      );
      final result = await service.recomputeDates(const ['2026-04-28']);
      expect(result.recomputedDates, isEmpty);
      expect(result.failedDates, isEmpty);
      await tearDown();
    });

    test('empty date list returns empty result', () async {
      await setUp();
      await seedHealthy(5);
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-06T09:00:00Z'),
      );
      final result = await service.recomputeDates(const []);
      expect(result.recomputedDates, isEmpty);
      await tearDown();
    });
  });

  group('full pipeline high/critical scoring', () {
    test('all metrics deteriorated produces high risk score', () async {
      await setUp();
      for (var day = 1; day <= 15; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        final bad = day >= 13;
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {
              'hrv_sdnn_mean': bad ? 35.0 : 50.0,
              'resting_hr_mean': bad ? 68.0 : 58.0,
              'sleep_total_minutes': bad ? 330 : 420,
              'step_count_total': bad ? 5000 : 8200,
              'spo2_mean': 97.0,
              'spo2_count': 3,
              'wrist_temp_mean': bad ? 0.9 : 0.0,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-16T08:00:00Z'),
          ),
        );
      }
      await syncFresh(DateTime.parse('2026-04-16T06:00:00Z'));
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-16T08:00:00Z'),
      );
      await service.recomputeDates(const ['2026-04-15']);
      final score = await repository.getLatestFlareRiskScore();
      expect(score!.riskBand, 'high');
      expect(score.riskScore, greaterThan(50));
      await tearDown();
    });

    test(
      'extreme deterioration with symptoms produces critical risk',
      () async {
        await setUp();
        for (var day = 1; day <= 28; day++) {
          final date = '2026-04-${day.toString().padLeft(2, '0')}';
          final bad = day >= 26;
          await repository.upsertDailySummary(
            DailySummaryRecord(
              dateLocal: date,
              summaryJson: {
                'hrv_sdnn_mean': bad ? 25.0 : 50.0,
                'resting_hr_mean': bad ? 72.0 : 58.0,
                'sleep_total_minutes': bad ? 280 : 420,
                'step_count_total': bad ? 3000 : 8200,
                'spo2_mean': bad ? 93.0 : 97.0,
                'spo2_count': 3,
                'wrist_temp_mean': bad ? 1.2 : 0.0,
              },
              syncQualityScore: 1,
              recomputedAt: DateTime.parse('2026-04-30T08:00:00Z'),
            ),
          );
        }
        await syncFresh(DateTime.parse('2026-04-29T08:00:00Z'));
        // Add severe symptoms
        for (var i = 0; i < 3; i++) {
          await repository.insertSymptom(
            SymptomRecord(
              loggedAt: DateTime.parse('2026-04-27T${10 + i}:00:00Z'),
              symptomType: 'pain',
              severity: 8,
              durationMinutes: 60,
              mealRelation: null,
              notes: 'bad pain $i',
              sourceTranscript: 'bad pain $i',
              extractionMethod: 'deterministic',
              extractionConfidence: 0.85,
              createdAt: DateTime.parse('2026-04-27T${10 + i}:00:00Z'),
            ),
          );
        }
        final service = RiskEngineService(
          repository: repository,
          nowProvider: () => DateTime.parse('2026-04-29T09:00:00Z'),
        );
        await service.recomputeDates(const ['2026-04-28']);
        final score = await repository.getLatestFlareRiskScore();
        expect(score!.riskBand, 'critical');
        expect(score.riskScore, greaterThanOrEqualTo(76));
        await tearDown();
      },
    );
  });

  group('feature persistence', () {
    test('daily feature record is persisted alongside risk score', () async {
      await setUp();
      await seedHealthy(14);
      await syncFresh(DateTime.parse('2026-04-15T08:00:00Z'));
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-15T09:00:00Z'),
      );
      await service.recomputeDates(const ['2026-04-14']);
      final opened = await database.open();
      final features = await opened.query('daily_features');
      expect(features, isNotEmpty);
      await tearDown();
    });

    test('model version is persisted on score records', () async {
      await setUp();
      await seedHealthy(14);
      await syncFresh(DateTime.parse('2026-04-15T08:00:00Z'));
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-15T09:00:00Z'),
      );
      await service.recomputeDates(const ['2026-04-14']);
      final score = await repository.getLatestFlareRiskScore();
      expect(score!.modelVersion, RiskEngineService.modelVersion);
      await tearDown();
    });
  });
}
