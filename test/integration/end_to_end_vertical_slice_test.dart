@Tags(['slow'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/contracts/health_bridge_contracts.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/daily_summary_service.dart';
import 'package:gemma_flares/core/services/dashboard_snapshot_service.dart';
import 'package:gemma_flares/core/services/risk_engine_service.dart';
import 'package:gemma_flares/core/services/symptom_logging_service.dart';
import 'package:gemma_flares/core/services/symptom_parser_service.dart';
import 'package:gemma_flares/core/services/wearable_normalization_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// End-to-end integration test covering the full vertical slice:
/// normalize → summarize → baseline → score → symptom → rescore → dashboard snapshot
void main() {
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;
  late WearableSampleRepository repository;
  late DailySummaryService summaryService;
  late RiskEngineService riskEngine;
  late SymptomLoggingService symptomService;
  late DashboardSnapshotService dashboardService;

  final fixedNow = DateTime.parse('2026-04-20T10:00:00Z');

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('gemma_flares_e2e_test');
    database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    repository = WearableSampleRepository(database: database);
    summaryService = DailySummaryService(repository: repository);
    riskEngine = RiskEngineService(
      repository: repository,
      nowProvider: () => fixedNow,
    );
    symptomService = SymptomLoggingService(
      repository: repository,
      parser: const SymptomParserService(),
      riskEngineService: riskEngine,
      nowProvider: () => fixedNow,
    );
    dashboardService = DashboardSnapshotService(
      repository: repository,
      nowProvider: () => fixedNow,
    );
  });

  tearDown(() async {
    await database.close();
    await tempRoot.delete(recursive: true);
  });

  test(
    'full vertical slice: normalize → summarize → score → symptom → rescore → dashboard',
    () async {
      const normalization = WearableNormalizationService();
      final importedAt = fixedNow;
      final allNormalized = <NormalizedWearableSample>[];
      final allDirtyDates = <String>{};

      // --- Step 1: Simulate 15 days of HealthKit data ---
      for (var day = 1; day <= 15; day++) {
        final dateStr = '2026-04-${day.toString().padLeft(2, '0')}';
        final baseTime = DateTime.parse('${dateStr}T08:00:00Z');
        final isDegraded = day >= 13; // last 3 days show deterioration

        // HRV samples
        final hrvBatch = normalization.normalizeBatch(
          metricType: HealthMetricType.heartRateVariabilitySdnn,
          samples: [
            HealthSampleDto(
              vendorSampleId: 'hrv-$day',
              sourceName: 'apple_health',
              sourceDevice: 'AppleWatch',
              metricType: HealthMetricType.heartRateVariabilitySdnn,
              value: isDegraded ? 32.0 : 52.0,
              unit: 'ms',
              startTime: baseTime,
              endTime: baseTime.add(const Duration(minutes: 5)),
              timezone: 'UTC',
              metadata: const {},
            ),
          ],
          importedAt: importedAt,
        );

        // Resting HR
        final rhrBatch = normalization.normalizeBatch(
          metricType: HealthMetricType.restingHeartRate,
          samples: [
            HealthSampleDto(
              vendorSampleId: 'rhr-$day',
              sourceName: 'apple_health',
              sourceDevice: 'AppleWatch',
              metricType: HealthMetricType.restingHeartRate,
              value: isDegraded ? 70.0 : 58.0,
              unit: 'bpm',
              startTime: baseTime,
              endTime: baseTime.add(const Duration(minutes: 1)),
              timezone: 'UTC',
              metadata: const {},
            ),
          ],
          importedAt: importedAt,
        );

        // Sleep (overnight session)
        final sleepStart = DateTime.parse(
          '${dateStr}T22:30:00Z',
        ).subtract(const Duration(days: 1));
        final sleepEnd = DateTime.parse('${dateStr}T06:30:00Z');
        final sleepBatch = normalization.normalizeBatch(
          metricType: HealthMetricType.sleepAnalysis,
          samples: [
            HealthSampleDto(
              vendorSampleId: 'sleep-$day',
              sourceName: 'apple_health',
              sourceDevice: 'AppleWatch',
              metricType: HealthMetricType.sleepAnalysis,
              value: 1, // asleep category
              unit: 'category',
              startTime: sleepStart,
              endTime: sleepEnd,
              timezone: 'UTC',
              metadata: const {},
            ),
          ],
          importedAt: importedAt,
        );

        // Steps
        final stepsBatch = normalization.normalizeBatch(
          metricType: HealthMetricType.stepCount,
          samples: [
            HealthSampleDto(
              vendorSampleId: 'steps-$day',
              sourceName: 'apple_health',
              sourceDevice: 'AppleWatch',
              metricType: HealthMetricType.stepCount,
              value: isDegraded ? 4200.0 : 8500.0,
              unit: 'count',
              startTime: baseTime,
              endTime: baseTime.add(const Duration(hours: 12)),
              timezone: 'UTC',
              metadata: const {},
            ),
          ],
          importedAt: importedAt,
        );

        for (final batch in [hrvBatch, rhrBatch, sleepBatch, stepsBatch]) {
          allNormalized.addAll(batch.samples);
          for (final s in batch.samples) {
            allDirtyDates.add(s.localDate);
          }
        }
      }

      // Persist all normalized samples
      await repository.upsertSamples(allNormalized);

      // Set sync state so dashboard doesn't show stale warning
      await repository.updateSyncState(
        sourceName: 'apple_health',
        lastSyncAt: fixedNow,
        lastBackfillStart: DateTime.parse('2026-03-20T00:00:00Z'),
        lastBackfillEnd: fixedNow,
      );

      // --- Step 2: Compute daily summaries ---
      final summaryResult = await summaryService.recomputeDates(
        allDirtyDates.toList(),
      );
      expect(
        summaryResult.failedDates,
        isEmpty,
        reason: 'All daily summaries should compute',
      );
      expect(summaryResult.recomputedDates.length, greaterThanOrEqualTo(14));

      // --- Step 3: Compute baseline ---
      final baselineResult = await summaryService.recomputeBaseline(
        asOfDate: '2026-04-15',
      );
      expect(
        baselineResult,
        isNotNull,
        reason: 'Baseline should compute with 14+ days',
      );
      expect(
        baselineResult!.readinessState,
        isIn(['ready', 'mature']),
        reason: '14+ valid days should yield ready or mature baseline',
      );
      expect(baselineResult.validDays, greaterThanOrEqualTo(14));

      // --- Step 4: Compute risk score ---
      final scoreResult = await riskEngine.recomputeDates(const ['2026-04-15']);
      expect(scoreResult.failedDates, isEmpty);
      expect(scoreResult.recomputedDates, contains('2026-04-15'));

      final latestScore = await repository.getLatestFlareRiskScore();
      expect(latestScore, isNotNull, reason: 'A risk score must be persisted');
      expect(latestScore!.riskScore, greaterThan(0));
      expect(latestScore.riskBand, isNotEmpty);
      expect(latestScore.confidenceScore, greaterThan(0));
      final scoreBeforeSymptom = latestScore.riskScore;

      // --- Step 5: Log a symptom and verify rescore ---
      final symptomResult = await symptomService.saveTranscript(
        transcript: 'I had moderate cramping for about two hours after lunch',
      );
      expect(
        symptomResult.parseResult.structuredSymptom.symptomType,
        isNotEmpty,
      );
      expect(symptomResult.savedSymptom.symptomType, isNotEmpty);

      // Symptom should trigger a rescore
      final scoreAfterSymptom = await repository.getLatestFlareRiskScore();
      expect(scoreAfterSymptom, isNotNull);
      // After adding a symptom, the score should be >= the previous score
      // (symptom burden adds points)
      expect(
        scoreAfterSymptom!.riskScore,
        greaterThanOrEqualTo(scoreBeforeSymptom),
      );

      // --- Step 6: Verify dashboard snapshot ---
      final snapshot = await dashboardService.loadDashboardSnapshot();
      expect(
        snapshot.latestScore,
        isNotNull,
        reason: 'Dashboard must show the latest score',
      );
      expect(snapshot.latestScore?.riskScore ?? 0, greaterThan(0));
      expect(
        snapshot.latestSummary,
        isNotNull,
        reason: 'Dashboard must show a summary',
      );
      expect(snapshot.baselineStatusLabel, isNotEmpty);
      expect(snapshot.syncFreshnessLabel, isNotEmpty);
      expect(
        snapshot.driverChips,
        isNotEmpty,
        reason: 'Score should have driver chips',
      );

      // Verify trend cards exist
      expect(
        snapshot.trendCards,
        isNotEmpty,
        reason: 'Trend cards need data from 7+ days',
      );

      // Verify the symptom appears in the dashboard context
      expect(
        snapshot.latestSymptomSummary,
        isNot('No local symptom note saved yet.'),
      );
    },
  );
}
