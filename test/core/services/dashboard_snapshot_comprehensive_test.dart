@Tags(['extended'])
@Skip('Extended regression suite; run on demand with --run-skipped.')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/dashboard_snapshot_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;
  late WearableSampleRepository repository;

  Future<DashboardSnapshotService> setUp({DateTime? now}) async {
    tempRoot = await Directory.systemTemp.createTemp('gemma_flares_dash_comp_');
    database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    repository = WearableSampleRepository(database: database);
    return DashboardSnapshotService(
      repository: repository,
      nowProvider: () => now ?? DateTime.parse('2026-04-20T08:00:00Z'),
    );
  }

  Future<void> tearDown() async {
    await database.close();
    await tempRoot.delete(recursive: true);
  }

  group('empty state snapshot', () {
    test('returns empty snapshot when no data exists', () async {
      final service = await setUp();
      final snapshot = await service.loadDashboardSnapshot();
      expect(snapshot.latestScore, isNull);
      expect(snapshot.latestSummary, isNull);
      expect(snapshot.latestBaseline, isNull);
      expect(snapshot.syncState, isNull);
      expect(snapshot.trendCards, hasLength(3));
      expect(snapshot.driverChips, isEmpty);
      expect(snapshot.scoreTrend, isEmpty);
      expect(snapshot.isSyncStale, isFalse);
      expect(snapshot.syncFreshnessLabel, contains('No HealthKit sync'));
      expect(snapshot.latestSymptomSummary, isNull);
      await tearDown();
    });

    test('returns empty timeline when no data exists', () async {
      final service = await setUp();
      final groups = await service.loadTimelineGroups();
      expect(groups, isEmpty);
      await tearDown();
    });
  });

  group('sync freshness labels', () {
    test('recent sync shows hours', () async {
      final service = await setUp(now: DateTime.parse('2026-04-20T12:00:00Z'));
      await repository.updateSyncState(
        sourceName: 'apple_health',
        lastSyncAt: DateTime.parse('2026-04-20T05:00:00Z'),
        lastBackfillStart: DateTime.parse('2026-03-20T00:00:00Z'),
        lastBackfillEnd: DateTime.parse('2026-04-20T05:00:00Z'),
      );
      final snapshot = await service.loadDashboardSnapshot();
      expect(snapshot.syncFreshnessLabel, contains('h ago'));
      expect(snapshot.isSyncStale, isFalse);
      expect(snapshot.syncWarningLabel, isNull);
      await tearDown();
    });

    test('stale sync shows days and warning', () async {
      final service = await setUp(now: DateTime.parse('2026-04-20T08:00:00Z'));
      await repository.updateSyncState(
        sourceName: 'apple_health',
        lastSyncAt: DateTime.parse('2026-04-15T08:00:00Z'),
        lastBackfillStart: DateTime.parse('2026-03-16T08:00:00Z'),
        lastBackfillEnd: DateTime.parse('2026-04-15T08:00:00Z'),
      );
      final snapshot = await service.loadDashboardSnapshot();
      expect(snapshot.isSyncStale, isTrue);
      expect(snapshot.syncFreshnessLabel, contains('d ago'));
      expect(snapshot.syncWarningLabel, isNotNull);
      expect(snapshot.syncWarningLabel, contains('older than'));
      await tearDown();
    });
  });

  group('baseline status labels', () {
    test('no baseline shows need sync message', () async {
      final service = await setUp();
      final snapshot = await service.loadDashboardSnapshot();
      expect(snapshot.baselineStatusLabel, contains('not started'));
      await tearDown();
    });

    test('not_ready baseline shows need days message', () async {
      final service = await setUp();
      await repository.upsertBaselineSnapshot(
        BaselineSnapshotRecord(
          snapshotDateLocal: '2026-04-19',
          readinessState: 'not_ready',
          baselineJson: const {},
          validDays: 3,
          createdAt: DateTime.parse('2026-04-20T00:00:00Z'),
        ),
      );
      final snapshot = await service.loadDashboardSnapshot();
      expect(snapshot.baselineStatusLabel, contains('7 valid days'));
      await tearDown();
    });

    test('ready baseline shows ready message', () async {
      final service = await setUp();
      await repository.upsertBaselineSnapshot(
        BaselineSnapshotRecord(
          snapshotDateLocal: '2026-04-19',
          readinessState: 'ready',
          baselineJson: const {},
          validDays: 14,
          createdAt: DateTime.parse('2026-04-20T00:00:00Z'),
        ),
      );
      final snapshot = await service.loadDashboardSnapshot();
      expect(snapshot.baselineStatusLabel, contains('ready'));
      await tearDown();
    });

    test('mature baseline shows mature message', () async {
      final service = await setUp();
      await repository.upsertBaselineSnapshot(
        BaselineSnapshotRecord(
          snapshotDateLocal: '2026-04-19',
          readinessState: 'mature',
          baselineJson: const {},
          validDays: 28,
          createdAt: DateTime.parse('2026-04-20T00:00:00Z'),
        ),
      );
      final snapshot = await service.loadDashboardSnapshot();
      expect(snapshot.baselineStatusLabel, contains('mature'));
      await tearDown();
    });
  });

  group('trend cards', () {
    test('HRV trend card shows value and delta', () async {
      final service = await setUp();
      for (var day = 1; day <= 14; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {
              'hrv_sdnn_mean': 40.0 + day,
              'sleep_total_minutes': 400 + day,
              'step_count_total': 7000 + (day * 100),
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-20T00:00:00Z'),
          ),
        );
      }
      final snapshot = await service.loadDashboardSnapshot();
      expect(snapshot.trendCards, hasLength(3));
      // Recovery card
      expect(snapshot.trendCards[0].label, 'Recovery signal');
      expect(snapshot.trendCards[0].valueLabel, contains('ms'));
      // Sleep card
      expect(snapshot.trendCards[1].label, 'Sleep pattern');
      expect(snapshot.trendCards[1].valueLabel, contains('min'));
      // Steps card
      expect(snapshot.trendCards[2].label, 'Activity pattern');
      await tearDown();
    });
  });

  group('driver chips', () {
    test('driver chips sorted by contribution points descending', () async {
      final service = await setUp();
      await repository.upsertFlareRiskScore(
        FlareRiskScoreRecord(
          dateLocal: '2026-04-19',
          riskScore: 55,
          riskBand: 'high',
          confidenceScore: 90,
          contributionJson: const {
            'hrv_points': 25,
            'resting_hr_points': 12,
            'sleep_points': 10,
            'symptom_points': 8,
            'steps_points': 0,
            'sparse_vitals_points': 0,
            'total_points': 55,
          },
          featureSnapshotJson: const {},
          modelVersion: 'risk_v1',
          createdAt: DateTime.parse('2026-04-20T00:00:00Z'),
        ),
      );
      final snapshot = await service.loadDashboardSnapshot();
      expect(snapshot.driverChips, isNotEmpty);
      // First chip should be highest contributor (HRV)
      expect(
        snapshot.driverChips.first.points,
        greaterThanOrEqualTo(snapshot.driverChips.last.points),
      );
      await tearDown();
    });

    test('only non-zero chips are included', () async {
      final service = await setUp();
      await repository.upsertFlareRiskScore(
        FlareRiskScoreRecord(
          dateLocal: '2026-04-19',
          riskScore: 8,
          riskBand: 'low',
          confidenceScore: 90,
          contributionJson: const {
            'hrv_points': 8,
            'resting_hr_points': 0,
            'sleep_points': 0,
            'symptom_points': 0,
            'steps_points': 0,
            'sparse_vitals_points': 0,
            'total_points': 8,
          },
          featureSnapshotJson: const {},
          modelVersion: 'risk_v1',
          createdAt: DateTime.parse('2026-04-20T00:00:00Z'),
        ),
      );
      final snapshot = await service.loadDashboardSnapshot();
      for (final chip in snapshot.driverChips) {
        expect(chip.points, greaterThan(0));
      }
      await tearDown();
    });
  });

  group('score trend', () {
    test('returns last 7 scores in order', () async {
      final service = await setUp();
      for (var day = 1; day <= 10; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        await repository.upsertFlareRiskScore(
          FlareRiskScoreRecord(
            dateLocal: date,
            riskScore: 10.0 + day,
            riskBand: 'low',
            confidenceScore: 90,
            contributionJson: const {},
            featureSnapshotJson: const {},
            modelVersion: 'risk_v1',
            createdAt: DateTime.parse('2026-04-20T00:00:00Z'),
          ),
        );
      }
      final snapshot = await service.loadDashboardSnapshot();
      expect(snapshot.scoreTrend, hasLength(7));
      // Should be last 7: days 4-10 → scores 14-20
      expect(snapshot.scoreTrend.first, 14.0);
      expect(snapshot.scoreTrend.last, 20.0);
      await tearDown();
    });
  });

  group('symptom summary', () {
    test('formats latest symptom with type and severity', () async {
      final service = await setUp();
      await repository.insertSymptom(
        SymptomRecord(
          loggedAt: DateTime.parse('2026-04-19T12:00:00Z'),
          symptomType: 'cramping',
          severity: 6,
          durationMinutes: 45,
          mealRelation: 'after_lunch',
          notes: 'cramping after lunch',
          sourceTranscript: 'cramping after lunch',
          extractionMethod: 'deterministic',
          extractionConfidence: 0.9,
          createdAt: DateTime.parse('2026-04-19T12:01:00Z'),
        ),
      );
      final snapshot = await service.loadDashboardSnapshot();
      expect(snapshot.latestSymptomSummary, isNotNull);
      expect(snapshot.latestSymptomSummary, contains('cramping'));
      await tearDown();
    });

    test('no symptoms returns null summary', () async {
      final service = await setUp();
      final snapshot = await service.loadDashboardSnapshot();
      expect(snapshot.latestSymptomSummary, isNull);
      await tearDown();
    });
  });

  group('recommended action', () {
    test('recommends sync when stale', () async {
      final service = await setUp(now: DateTime.parse('2026-04-20T08:00:00Z'));
      await repository.updateSyncState(
        sourceName: 'apple_health',
        lastSyncAt: DateTime.parse('2026-04-15T08:00:00Z'),
        lastBackfillStart: DateTime.parse('2026-03-16T08:00:00Z'),
        lastBackfillEnd: DateTime.parse('2026-04-15T08:00:00Z'),
      );
      final snapshot = await service.loadDashboardSnapshot();
      expect(snapshot.recommendedAction.toLowerCase(), contains('sync'));
      await tearDown();
    });
  });

  group('timeline groups', () {
    test('groups events by date in descending order', () async {
      final service = await setUp();
      for (var day = 8; day <= 10; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {'hrv_sdnn_mean': 42.0},
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-20T00:00:00Z'),
          ),
        );
        await repository.upsertFlareRiskScore(
          FlareRiskScoreRecord(
            dateLocal: date,
            riskScore: 20,
            riskBand: 'low',
            confidenceScore: 90,
            contributionJson: const {},
            featureSnapshotJson: const {},
            modelVersion: 'risk_v1',
            createdAt: DateTime.parse('2026-04-20T00:00:00Z'),
          ),
        );
      }
      final groups = await service.loadTimelineGroups();
      expect(groups, hasLength(3));
      // Descending order
      expect(groups[0].dateLocal, '2026-04-10');
      expect(groups[1].dateLocal, '2026-04-09');
      expect(groups[2].dateLocal, '2026-04-08');
      await tearDown();
    });

    test('timeline includes risk, summary, symptom, sync items', () async {
      final service = await setUp(now: DateTime.parse('2026-04-10T08:00:00Z'));
      await repository.upsertDailySummary(
        DailySummaryRecord(
          dateLocal: '2026-04-09',
          summaryJson: {
            'hrv_sdnn_mean': 42.0,
            'sleep_total_minutes': 400,
            'step_count_total': 7000,
          },
          syncQualityScore: 1,
          recomputedAt: DateTime.parse('2026-04-10T00:00:00Z'),
        ),
      );
      await repository.upsertFlareRiskScore(
        FlareRiskScoreRecord(
          dateLocal: '2026-04-09',
          riskScore: 25,
          riskBand: 'low',
          confidenceScore: 90,
          contributionJson: const {},
          featureSnapshotJson: const {},
          modelVersion: 'risk_v1',
          createdAt: DateTime.parse('2026-04-10T00:00:00Z'),
        ),
      );
      await repository.insertSymptom(
        SymptomRecord(
          loggedAt: DateTime.parse('2026-04-09T12:00:00Z'),
          symptomType: 'pain',
          severity: 5,
          durationMinutes: null,
          mealRelation: null,
          notes: 'test',
          sourceTranscript: 'test',
          extractionMethod: 'deterministic',
          extractionConfidence: 0.7,
          createdAt: DateTime.parse('2026-04-09T12:01:00Z'),
        ),
      );
      await repository.updateSyncState(
        sourceName: 'apple_health',
        lastSyncAt: DateTime.parse('2026-04-09T06:00:00Z'),
        lastBackfillStart: DateTime.parse('2026-03-10T00:00:00Z'),
        lastBackfillEnd: DateTime.parse('2026-04-09T06:00:00Z'),
      );
      final groups = await service.loadTimelineGroups();
      final titles = groups.expand((g) => g.items.map((i) => i.title)).toList();
      expect(titles, contains('Risk low'));
      expect(titles, contains('Daily summary ready'));
      expect(titles, contains('Symptom logged'));
      expect(titles, contains('Health sync completed'));
      await tearDown();
    });

    test('risk tone matches risk band', () async {
      final service = await setUp();
      await repository.upsertFlareRiskScore(
        FlareRiskScoreRecord(
          dateLocal: '2026-04-09',
          riskScore: 55,
          riskBand: 'high',
          confidenceScore: 80,
          contributionJson: const {},
          featureSnapshotJson: const {},
          modelVersion: 'risk_v1',
          createdAt: DateTime.parse('2026-04-10T00:00:00Z'),
        ),
      );
      final groups = await service.loadTimelineGroups();
      final riskItem = groups.first.items.firstWhere(
        (i) => i.title.contains('Risk'),
      );
      expect(riskItem.tone, 'high');
      await tearDown();
    });

    test('sync item tone is sync_ok for fresh sync without errors', () async {
      final service = await setUp(now: DateTime.parse('2026-04-10T08:00:00Z'));
      await repository.updateSyncState(
        sourceName: 'apple_health',
        lastSyncAt: DateTime.parse('2026-04-10T06:00:00Z'),
        lastBackfillStart: DateTime.parse('2026-03-11T00:00:00Z'),
        lastBackfillEnd: DateTime.parse('2026-04-10T06:00:00Z'),
      );
      final groups = await service.loadTimelineGroups();
      final syncItem = groups.first.items.firstWhere(
        (i) => i.title.contains('sync'),
      );
      expect(syncItem.tone, 'sync_ok');
      await tearDown();
    });
  });
}
