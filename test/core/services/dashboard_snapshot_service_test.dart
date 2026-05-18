import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/dashboard_snapshot_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('dashboard snapshot exposes trend cards and stale sync state', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_dashboard_snapshot_test',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final repository = WearableSampleRepository(database: database);
    final service = DashboardSnapshotService(
      repository: repository,
      nowProvider: () => DateTime.parse('2026-04-20T08:00:00Z'),
    );

    for (var day = 1; day <= 8; day++) {
      final date = '2026-04-${day.toString().padLeft(2, '0')}';
      await repository.upsertDailySummary(
        DailySummaryRecord(
          dateLocal: date,
          summaryJson: {
            'hrv_sdnn_mean': 40 + day.toDouble(),
            'sleep_total_minutes': 400 + day,
            'step_count_total': 7000 + (day * 100),
          },
          syncQualityScore: 1,
          recomputedAt: DateTime.parse('2026-04-20T08:00:00Z'),
        ),
      );
      await repository.upsertFlareRiskScore(
        FlareRiskScoreRecord(
          dateLocal: date,
          riskScore: 20 + day.toDouble(),
          riskBand: day >= 7 ? 'moderate' : 'low',
          confidenceScore: 90,
          contributionJson: const {
            'resting_hr_points': 14,
            'sleep_points': 7,
            'total_points': 31,
          },
          featureSnapshotJson: const {},
          modelVersion: 'risk_v1',
          createdAt: DateTime.parse('2026-04-20T08:00:00Z'),
        ),
      );
    }
    await repository.upsertBaselineSnapshot(
      BaselineSnapshotRecord(
        snapshotDateLocal: '2026-04-08',
        readinessState: 'ready',
        baselineJson: const {},
        validDays: 8,
        createdAt: DateTime.parse('2026-04-20T08:00:00Z'),
      ),
    );
    await repository.updateSyncState(
      sourceName: 'apple_health',
      lastSyncAt: DateTime.parse('2026-04-16T08:00:00Z'),
      lastBackfillStart: DateTime.parse('2026-03-16T08:00:00Z'),
      lastBackfillEnd: DateTime.parse('2026-04-16T08:00:00Z'),
    );
    await repository.insertSymptom(
      SymptomRecord(
        loggedAt: DateTime.parse('2026-04-18T08:00:00Z'),
        symptomType: 'cramping',
        severity: 4,
        durationMinutes: 30,
        mealRelation: 'after_lunch',
        notes: 'Cramping after lunch',
        sourceTranscript: 'Cramping after lunch',
        extractionMethod: 'deterministic',
        extractionConfidence: 0.9,
        createdAt: DateTime.parse('2026-04-18T08:01:00Z'),
      ),
    );

    final snapshot = await service.loadDashboardSnapshot();

    expect(snapshot.latestScore, isNotNull);
    expect(snapshot.latestSummary, isNotNull);
    expect(snapshot.trendCards, hasLength(3));
    expect(snapshot.driverChips, isNotEmpty);
    expect(snapshot.scoreTrend, hasLength(7));
    expect(snapshot.scoreTrend.first.round(), 22);
    expect(snapshot.scoreTrend.last.round(), 28);
    expect(snapshot.isSyncStale, isTrue);
    expect(snapshot.syncFreshnessLabel, contains('4.0d ago'));
    expect(snapshot.syncWarningLabel, contains('older than 72 hours'));
    expect(snapshot.baselineStatusLabel, contains('Baseline ready'));
    expect(snapshot.latestSymptomSummary, contains('cramping'));
    expect(snapshot.recommendedAction, contains('Re-sync Apple Health'));

    await database.close();
    await tempRoot.delete(recursive: true);
  });

  test('timeline groups risk, summary, and sync items by date', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_timeline_snapshot_test',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final repository = WearableSampleRepository(database: database);
    final service = DashboardSnapshotService(
      repository: repository,
      nowProvider: () => DateTime.parse('2026-04-10T08:00:00Z'),
    );

    await repository.upsertDailySummary(
      DailySummaryRecord(
        dateLocal: '2026-04-09',
        summaryJson: {
          'hrv_sdnn_mean': 45.0,
          'sleep_total_minutes': 410,
          'step_count_total': 7600,
        },
        syncQualityScore: 1,
        recomputedAt: DateTime.parse('2026-04-10T08:00:00Z'),
      ),
    );
    await repository.upsertFlareRiskScore(
      FlareRiskScoreRecord(
        dateLocal: '2026-04-09',
        riskScore: 31,
        riskBand: 'moderate',
        confidenceScore: 88,
        contributionJson: const {},
        featureSnapshotJson: const {},
        modelVersion: 'risk_v1',
        createdAt: DateTime.parse('2026-04-10T08:00:00Z'),
      ),
    );
    await repository.upsertBaselineSnapshot(
      BaselineSnapshotRecord(
        snapshotDateLocal: '2026-04-09',
        readinessState: 'ready',
        baselineJson: const {},
        validDays: 14,
        createdAt: DateTime.parse('2026-04-10T08:00:00Z'),
      ),
    );
    await repository.insertSymptom(
      SymptomRecord(
        loggedAt: DateTime.parse('2026-04-09T13:30:00Z'),
        symptomType: 'urgency',
        severity: 6,
        durationMinutes: 45,
        mealRelation: 'after_dinner',
        notes: 'Urgency after dinner',
        sourceTranscript: 'Urgency after dinner',
        extractionMethod: 'deterministic',
        extractionConfidence: 0.88,
        createdAt: DateTime.parse('2026-04-09T13:31:00Z'),
      ),
    );
    await repository.updateSyncState(
      sourceName: 'apple_health',
      lastSyncAt: DateTime.parse('2026-04-09T12:00:00Z'),
      lastBackfillStart: DateTime.parse('2026-03-10T12:00:00Z'),
      lastBackfillEnd: DateTime.parse('2026-04-09T12:00:00Z'),
    );

    final groups = await service.loadTimelineGroups();

    expect(groups, isNotEmpty);
    expect(groups.first.dateLocal, '2026-04-09');
    expect(
      groups.first.items.map((item) => item.title),
      containsAll(<String>[
        'Risk moderate',
        'Daily summary ready',
        'Baseline ready',
        'Symptom logged',
        'Health sync completed',
      ]),
    );

    await database.close();
    await tempRoot.delete(recursive: true);
  });
}
