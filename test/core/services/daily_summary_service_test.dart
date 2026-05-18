import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/contracts/health_bridge_contracts.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/daily_summary_service.dart';
import 'package:gemma_flares/core/services/wearable_normalization_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('sleep normalization anchors overnight segments to wake date', () {
    const normalization = WearableNormalizationService();
    final batch = normalization.normalizeBatch(
      metricType: HealthMetricType.sleepAnalysis,
      samples: [
        HealthSampleDto(
          vendorSampleId: 'sleep-overnight',
          sourceName: 'apple_health',
          sourceDevice: 'AppleWatch',
          metricType: HealthMetricType.sleepAnalysis,
          value: 1,
          unit: 'category',
          startTime: DateTime.parse('2026-04-10T23:00:00Z'),
          endTime: DateTime.parse('2026-04-11T07:00:00Z'),
          timezone: 'America/Toronto',
          metadata: const {},
        ),
      ],
      importedAt: DateTime.parse('2026-04-11T08:00:00Z'),
    );

    expect(batch.samples.single.localDate, '2026-04-11');
  });

  test('sleep normalization keeps same-day sleep on the start date', () {
    const normalization = WearableNormalizationService();
    final batch = normalization.normalizeBatch(
      metricType: HealthMetricType.sleepAnalysis,
      samples: [
        HealthSampleDto(
          vendorSampleId: 'sleep-sameday',
          sourceName: 'apple_health',
          sourceDevice: 'AppleWatch',
          metricType: HealthMetricType.sleepAnalysis,
          value: 1,
          unit: 'category',
          startTime: DateTime.parse('2026-04-11T18:30:00Z'),
          endTime: DateTime.parse('2026-04-11T20:00:00Z'),
          timezone: 'America/Toronto',
          metadata: const {},
        ),
      ],
      importedAt: DateTime.parse('2026-04-11T21:00:00Z'),
    );

    expect(batch.samples.single.localDate, '2026-04-11');
  });

  test(
    'recomputes daily summary and baseline readiness after 14 valid days',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_summary_test',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      const normalization = WearableNormalizationService();
      final summaryService = DailySummaryService(repository: repository);
      final importedAt = DateTime.parse('2026-04-20T00:00:00Z');

      final normalized = <NormalizedWearableSample>[];
      for (var day = 0; day < 14; day++) {
        final baseDate = DateTime.parse(
          '2026-04-01T08:00:00Z',
        ).add(Duration(days: day));
        normalized.addAll(
          normalization
              .normalizeBatch(
                metricType: HealthMetricType.heartRateVariabilitySdnn,
                samples: [
                  HealthSampleDto(
                    vendorSampleId: 'hrv-$day',
                    sourceName: 'apple_health',
                    sourceDevice: 'AppleWatch',
                    metricType: HealthMetricType.heartRateVariabilitySdnn,
                    value: 40 + day.toDouble(),
                    unit: 'ms',
                    startTime: baseDate,
                    endTime: baseDate.add(const Duration(minutes: 1)),
                    timezone: 'America/Toronto',
                    metadata: const {},
                  ),
                ],
                importedAt: importedAt,
              )
              .samples,
        );
        normalized.addAll(
          normalization
              .normalizeBatch(
                metricType: HealthMetricType.restingHeartRate,
                samples: [
                  HealthSampleDto(
                    vendorSampleId: 'rhr-$day',
                    sourceName: 'apple_health',
                    sourceDevice: 'AppleWatch',
                    metricType: HealthMetricType.restingHeartRate,
                    value: 58 + (day % 3).toDouble(),
                    unit: 'bpm',
                    startTime: baseDate.add(const Duration(hours: 1)),
                    endTime: baseDate.add(const Duration(hours: 1, minutes: 1)),
                    timezone: 'America/Toronto',
                    metadata: const {},
                  ),
                ],
                importedAt: importedAt,
              )
              .samples,
        );
        normalized.addAll(
          normalization
              .normalizeBatch(
                metricType: HealthMetricType.stepCount,
                samples: [
                  HealthSampleDto(
                    vendorSampleId: 'steps-$day',
                    sourceName: 'apple_health',
                    sourceDevice: 'AppleWatch',
                    metricType: HealthMetricType.stepCount,
                    value: 7000 + (day * 100).toDouble(),
                    unit: 'count',
                    startTime: baseDate.add(const Duration(hours: 2)),
                    endTime: baseDate.add(const Duration(hours: 2, minutes: 5)),
                    timezone: 'America/Toronto',
                    metadata: const {},
                  ),
                ],
                importedAt: importedAt,
              )
              .samples,
        );
        normalized.addAll(
          normalization
              .normalizeBatch(
                metricType: HealthMetricType.sleepAnalysis,
                samples: [
                  HealthSampleDto(
                    vendorSampleId: 'sleep-$day',
                    sourceName: 'apple_health',
                    sourceDevice: 'AppleWatch',
                    metricType: HealthMetricType.sleepAnalysis,
                    value: 1,
                    unit: 'category',
                    startTime: baseDate.subtract(const Duration(hours: 7)),
                    endTime: baseDate,
                    timezone: 'America/Toronto',
                    metadata: const {},
                  ),
                ],
                importedAt: importedAt,
              )
              .samples,
        );
      }

      final persist = await repository.upsertSamples(normalized);
      final summaryResult = await summaryService.recomputeDates(
        persist.touchedDates,
      );
      final baseline = await summaryService.recomputeBaseline(
        asOfDate: persist.touchedDates.last,
      );
      final latestSummary = await repository.getLatestDailySummary();

      expect(summaryResult.failedDates, isEmpty);
      expect(summaryResult.recomputedDates, hasLength(14));
      expect(latestSummary, isNotNull);
      expect(latestSummary!.summaryJson['sleep_total_minutes'], 420);
      expect(latestSummary.summaryJson['step_count_total'], isNotNull);
      expect(baseline, isNotNull);
      expect(baseline!.readinessState, 'ready');
      expect(baseline.validDays, 14);
      expect(baseline.baselineJson['baseline_hrv_sdnn'], isNotNull);

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test('baseline readiness transitions follow documented thresholds', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_baseline_state_test',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final repository = WearableSampleRepository(database: database);
    final summaryService = DailySummaryService(repository: repository);

    Future<void> seedSummaries(int days) async {
      for (var day = 0; day < days; day++) {
        final date = '2026-04-${(day + 1).toString().padLeft(2, '0')}';
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {
              'hrv_sdnn_mean': 40.0,
              'resting_hr_mean': 60.0,
              'sleep_total_minutes': 420,
              'step_count_total': 7000,
              'spo2_count': 3,
              'spo2_mean': 97.0,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-20T00:00:00Z'),
          ),
        );
      }
    }

    await seedSummaries(6);
    var baseline = await summaryService.recomputeBaseline(
      asOfDate: '2026-04-06',
    );
    expect(baseline!.readinessState, 'not_ready');

    await seedSummaries(7);
    baseline = await summaryService.recomputeBaseline(asOfDate: '2026-04-07');
    expect(baseline!.readinessState, 'low_confidence');

    await seedSummaries(14);
    baseline = await summaryService.recomputeBaseline(asOfDate: '2026-04-14');
    expect(baseline!.readinessState, 'ready');

    await seedSummaries(28);
    baseline = await summaryService.recomputeBaseline(asOfDate: '2026-04-28');
    expect(baseline!.readinessState, 'mature');

    await database.close();
    await tempRoot.delete(recursive: true);
  });
}
