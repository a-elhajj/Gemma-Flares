@Tags(['extended'])
@Skip('Extended regression suite; run on demand with --run-skipped.')
library;

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

  late Directory tempRoot;
  late AppDatabase database;
  late WearableSampleRepository repository;
  late DailySummaryService summaryService;
  const normalization = WearableNormalizationService();

  Future<void> setUp() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_summary_comp_',
    );
    database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    repository = WearableSampleRepository(database: database);
    summaryService = DailySummaryService(repository: repository);
  }

  Future<void> tearDown() async {
    await database.close();
    await tempRoot.delete(recursive: true);
  }

  HealthSampleDto sample({
    required HealthMetricType type,
    required double value,
    required String vendorId,
    required DateTime start,
    Duration duration = const Duration(minutes: 1),
  }) {
    return HealthSampleDto(
      vendorSampleId: vendorId,
      sourceName: 'apple_health',
      sourceDevice: 'AppleWatch',
      metricType: type,
      value: value,
      unit: 'ms',
      startTime: start,
      endTime: start.add(duration),
      timezone: 'America/Toronto',
      metadata: const {},
    );
  }

  group('HRV summary aggregation', () {
    test(
      'computes mean and median for multiple HRV samples in a day',
      () async {
        await setUp();
        final importedAt = DateTime.parse('2026-04-12T00:00:00Z');
        final baseDate = DateTime(2026, 4, 11, 8);
        final samples = <NormalizedWearableSample>[];
        var minuteOffset = 0;
        for (final val in [30.0, 40.0, 50.0, 60.0, 70.0]) {
          samples.addAll(
            normalization
                .normalizeBatch(
                  metricType: HealthMetricType.heartRateVariabilitySdnn,
                  samples: [
                    sample(
                      type: HealthMetricType.heartRateVariabilitySdnn,
                      value: val,
                      vendorId: 'hrv-${val.round()}',
                      start: baseDate.add(Duration(minutes: minuteOffset++)),
                    ),
                  ],
                  importedAt: importedAt,
                )
                .samples,
          );
        }
        await repository.upsertSamples(samples);
        await summaryService.recomputeDates(const ['2026-04-11']);
        final summary = await repository.getLatestDailySummary();
        expect(summary!.summaryJson['hrv_sdnn_mean'], 50.0);
        expect(summary.summaryJson['hrv_sdnn_median'], 50.0);
        expect(summary.summaryJson['hrv_sdnn_count'], 5);
        await tearDown();
      },
    );

    test('median for even count is average of two middle values', () async {
      await setUp();
      final importedAt = DateTime.parse('2026-04-12T00:00:00Z');
      final baseDate = DateTime(2026, 4, 11, 8);
      final samples = <NormalizedWearableSample>[];
      var minuteOffset = 0;
      for (final val in [30.0, 40.0, 60.0, 70.0]) {
        samples.addAll(
          normalization
              .normalizeBatch(
                metricType: HealthMetricType.heartRateVariabilitySdnn,
                samples: [
                  sample(
                    type: HealthMetricType.heartRateVariabilitySdnn,
                    value: val,
                    vendorId: 'hrv-${val.round()}',
                    start: baseDate.add(Duration(minutes: minuteOffset++)),
                  ),
                ],
                importedAt: importedAt,
              )
              .samples,
        );
      }
      await repository.upsertSamples(samples);
      await summaryService.recomputeDates(const ['2026-04-11']);
      final summary = await repository.getLatestDailySummary();
      expect(summary!.summaryJson['hrv_sdnn_median'], 50.0); // (40+60)/2
      await tearDown();
    });
  });

  group('sleep summary aggregation', () {
    test('calculates sleep total from asleep categories 1,3,4,5', () async {
      await setUp();
      final importedAt = DateTime.parse('2026-04-12T00:00:00Z');
      final samples = <NormalizedWearableSample>[];
      // Category 1 (asleep) - 4 hours
      samples.addAll(
        normalization
            .normalizeBatch(
              metricType: HealthMetricType.sleepAnalysis,
              samples: [
                sample(
                  type: HealthMetricType.sleepAnalysis,
                  value: 1,
                  vendorId: 'sleep-asleep',
                  start: DateTime(2026, 4, 10, 23),
                  duration: const Duration(hours: 4),
                ),
              ],
              importedAt: importedAt,
            )
            .samples,
      );
      // Category 3 (core) - 2 hours
      samples.addAll(
        normalization
            .normalizeBatch(
              metricType: HealthMetricType.sleepAnalysis,
              samples: [
                sample(
                  type: HealthMetricType.sleepAnalysis,
                  value: 3,
                  vendorId: 'sleep-core',
                  start: DateTime(2026, 4, 11, 3),
                  duration: const Duration(hours: 2),
                ),
              ],
              importedAt: importedAt,
            )
            .samples,
      );
      // Category 4 (deep) - 1 hour
      samples.addAll(
        normalization
            .normalizeBatch(
              metricType: HealthMetricType.sleepAnalysis,
              samples: [
                sample(
                  type: HealthMetricType.sleepAnalysis,
                  value: 4,
                  vendorId: 'sleep-deep',
                  start: DateTime(2026, 4, 11, 5),
                  duration: const Duration(hours: 1),
                ),
              ],
              importedAt: importedAt,
            )
            .samples,
      );
      // Category 5 (REM) - 30 min
      samples.addAll(
        normalization
            .normalizeBatch(
              metricType: HealthMetricType.sleepAnalysis,
              samples: [
                sample(
                  type: HealthMetricType.sleepAnalysis,
                  value: 5,
                  vendorId: 'sleep-rem',
                  start: DateTime(2026, 4, 11, 6),
                  duration: const Duration(minutes: 30),
                ),
              ],
              importedAt: importedAt,
            )
            .samples,
      );
      await repository.upsertSamples(samples);
      await summaryService.recomputeDates(const ['2026-04-11']);
      final summary = await repository.getLatestDailySummary();
      expect(summary!.summaryJson['sleep_total_minutes'], 450); // 240+120+60+30
      expect(summary.summaryJson['sleep_asleep_core_minutes'], 120);
      expect(summary.summaryJson['sleep_asleep_deep_minutes'], 60);
      expect(summary.summaryJson['sleep_asleep_rem_minutes'], 30);
      await tearDown();
    });

    test('in-bed category 0 tracked separately', () async {
      await setUp();
      final importedAt = DateTime.parse('2026-04-12T00:00:00Z');
      final samples = <NormalizedWearableSample>[];
      // Category 0 (in-bed) - 30 mins
      samples.addAll(
        normalization
            .normalizeBatch(
              metricType: HealthMetricType.sleepAnalysis,
              samples: [
                sample(
                  type: HealthMetricType.sleepAnalysis,
                  value: 0,
                  vendorId: 'sleep-inbed',
                  start: DateTime(2026, 4, 11, 6, 30),
                  duration: const Duration(minutes: 30),
                ),
              ],
              importedAt: importedAt,
            )
            .samples,
      );
      // Category 1 (asleep) - 7 hours
      samples.addAll(
        normalization
            .normalizeBatch(
              metricType: HealthMetricType.sleepAnalysis,
              samples: [
                sample(
                  type: HealthMetricType.sleepAnalysis,
                  value: 1,
                  vendorId: 'sleep-asleep',
                  start: DateTime(2026, 4, 10, 23),
                  duration: const Duration(hours: 7),
                ),
              ],
              importedAt: importedAt,
            )
            .samples,
      );
      await repository.upsertSamples(samples);
      await summaryService.recomputeDates(const ['2026-04-11']);
      final summary = await repository.getLatestDailySummary();
      expect(
        summary!.summaryJson['sleep_total_minutes'],
        420,
      ); // 7 hours asleep only
      expect(summary.summaryJson['sleep_in_bed_minutes'], 30);
      await tearDown();
    });
  });

  group('step count aggregation', () {
    test('sums step count across multiple samples in a day', () async {
      await setUp();
      final importedAt = DateTime.parse('2026-04-12T00:00:00Z');
      final baseDate = DateTime.parse('2026-04-11T08:00:00Z');
      final samples = <NormalizedWearableSample>[];
      for (var i = 0; i < 4; i++) {
        samples.addAll(
          normalization
              .normalizeBatch(
                metricType: HealthMetricType.stepCount,
                samples: [
                  sample(
                    type: HealthMetricType.stepCount,
                    value: 2000,
                    vendorId: 'steps-$i',
                    start: baseDate.add(Duration(hours: i * 3)),
                  ),
                ],
                importedAt: importedAt,
              )
              .samples,
        );
      }
      await repository.upsertSamples(samples);
      await summaryService.recomputeDates(const ['2026-04-11']);
      final summary = await repository.getLatestDailySummary();
      expect(summary!.summaryJson['step_count_total'], 8000);
      await tearDown();
    });

    test('no steps in day gives null step_count_total', () async {
      await setUp();
      final importedAt = DateTime.parse('2026-04-12T00:00:00Z');
      final baseDate = DateTime.parse('2026-04-11T08:00:00Z');
      final samples = normalization
          .normalizeBatch(
            metricType: HealthMetricType.heartRateVariabilitySdnn,
            samples: [
              sample(
                type: HealthMetricType.heartRateVariabilitySdnn,
                value: 45.0,
                vendorId: 'hrv-only',
                start: baseDate,
              ),
            ],
            importedAt: importedAt,
          )
          .samples;
      await repository.upsertSamples(samples);
      await summaryService.recomputeDates(const ['2026-04-11']);
      final summary = await repository.getLatestDailySummary();
      expect(summary!.summaryJson['step_count_total'], isNull);
      await tearDown();
    });
  });

  group('sync quality score', () {
    test('all 6 metric types present gives 1.0', () async {
      await setUp();
      final importedAt = DateTime.parse('2026-04-12T00:00:00Z');
      final baseDate = DateTime.parse('2026-04-11T08:00:00Z');
      final samples = <NormalizedWearableSample>[];
      for (final spec in [
        (HealthMetricType.heartRateVariabilitySdnn, 45.0, 'hrv-1'),
        (HealthMetricType.restingHeartRate, 60.0, 'rhr-1'),
        (HealthMetricType.stepCount, 8000.0, 'steps-1'),
        (HealthMetricType.oxygenSaturation, 0.97, 'spo2-1'),
        (HealthMetricType.appleSleepingWristTemperature, 0.2, 'temp-1'),
      ]) {
        samples.addAll(
          normalization
              .normalizeBatch(
                metricType: spec.$1,
                samples: [
                  sample(
                    type: spec.$1,
                    value: spec.$2,
                    vendorId: spec.$3,
                    start: baseDate,
                  ),
                ],
                importedAt: importedAt,
              )
              .samples,
        );
      }
      // Add sleep
      samples.addAll(
        normalization
            .normalizeBatch(
              metricType: HealthMetricType.sleepAnalysis,
              samples: [
                sample(
                  type: HealthMetricType.sleepAnalysis,
                  value: 1,
                  vendorId: 'sleep-1',
                  start: DateTime(2026, 4, 10, 23),
                  duration: const Duration(hours: 7),
                ),
              ],
              importedAt: importedAt,
            )
            .samples,
      );
      await repository.upsertSamples(samples);
      await summaryService.recomputeDates(const ['2026-04-11']);
      final summary = await repository.getLatestDailySummary();
      expect(summary!.syncQualityScore, 1.0);
      await tearDown();
    });

    test('only HRV present gives ~0.17 quality', () async {
      await setUp();
      final importedAt = DateTime.parse('2026-04-12T00:00:00Z');
      final baseDate = DateTime.parse('2026-04-11T08:00:00Z');
      final samples = normalization
          .normalizeBatch(
            metricType: HealthMetricType.heartRateVariabilitySdnn,
            samples: [
              sample(
                type: HealthMetricType.heartRateVariabilitySdnn,
                value: 42.0,
                vendorId: 'hrv-q',
                start: baseDate,
              ),
            ],
            importedAt: importedAt,
          )
          .samples;
      await repository.upsertSamples(samples);
      await summaryService.recomputeDates(const ['2026-04-11']);
      final summary = await repository.getLatestDailySummary();
      expect(summary!.syncQualityScore, closeTo(1 / 6, 0.01));
      await tearDown();
    });
  });

  group('missing metrics tracking', () {
    test('identifies missing HRV, sleep, steps when absent', () async {
      await setUp();
      final importedAt = DateTime.parse('2026-04-12T00:00:00Z');
      final baseDate = DateTime.parse('2026-04-11T08:00:00Z');
      // Only resting HR present
      final samples = normalization
          .normalizeBatch(
            metricType: HealthMetricType.restingHeartRate,
            samples: [
              sample(
                type: HealthMetricType.restingHeartRate,
                value: 60.0,
                vendorId: 'rhr-miss',
                start: baseDate,
              ),
            ],
            importedAt: importedAt,
          )
          .samples;
      await repository.upsertSamples(samples);
      await summaryService.recomputeDates(const ['2026-04-11']);
      final summary = await repository.getLatestDailySummary();
      final missing = summary!.summaryJson['missing_metrics_json'] as String;
      expect(missing, contains('missing_hrv'));
      expect(missing, contains('missing_sleep'));
      expect(missing, contains('missing_steps'));
      expect(missing, isNot(contains('missing_resting_hr')));
      await tearDown();
    });
  });

  group('baseline computation', () {
    test('baseline returns null when no summaries exist', () async {
      await setUp();
      final result = await summaryService.recomputeBaseline(
        asOfDate: '2026-04-01',
      );
      expect(result, isNull);
      await tearDown();
    });

    test('baseline uses last 28 days window', () async {
      await setUp();
      for (var day = 1; day <= 35; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {
              'hrv_sdnn_mean': 40.0 + day,
              'resting_hr_mean': 60.0,
              'sleep_total_minutes': 420,
              'step_count_total': 7000,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-05-10T00:00:00Z'),
          ),
        );
      }
      final result = await summaryService.recomputeBaseline(
        asOfDate: '2026-05-05',
      );
      expect(result!.readinessState, 'mature');
      expect(result.validDays, 28);
      // Should use last 28 days (days 8-35), not all 35
      final baselineHrv = result.baselineJson['baseline_hrv_sdnn'] as double?;
      expect(baselineHrv, isNotNull);
      expect(baselineHrv!, greaterThan(47)); // avg of days 8-35 should be > 47
      await tearDown();
    });

    test('winsorized mean clips outliers for large series', () async {
      await setUp();
      for (var day = 1; day <= 28; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        double hrv;
        if (day == 1) {
          hrv = 10.0; // extreme outlier low
        } else if (day == 28) {
          hrv = 200.0; // extreme outlier high
        } else {
          hrv = 50.0; // normal
        }
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {
              'hrv_sdnn_mean': hrv,
              'resting_hr_mean': 60.0,
              'sleep_total_minutes': 420,
              'step_count_total': 7000,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-05-01T00:00:00Z'),
          ),
        );
      }
      final result = await summaryService.recomputeBaseline(
        asOfDate: '2026-04-28',
      );
      final baselineHrv = result!.baselineJson['baseline_hrv_sdnn'] as double;
      // Winsorized mean should be very close to 50 since outliers are clipped
      expect(baselineHrv, closeTo(50.0, 15.0));
      await tearDown();
    });

    test('fewer than 5 data points uses simple mean', () async {
      await setUp();
      for (var day = 1; day <= 3; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {
              'hrv_sdnn_mean': 40.0 + day * 10,
              'resting_hr_mean': 60.0,
              'sleep_total_minutes': 420,
              'step_count_total': 7000,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-05T00:00:00Z'),
          ),
        );
      }
      final result = await summaryService.recomputeBaseline(
        asOfDate: '2026-04-03',
      );
      final baselineHrv = result!.baselineJson['baseline_hrv_sdnn'] as double;
      // Simple mean of 50, 60, 70 = 60
      expect(baselineHrv, 60.0);
      await tearDown();
    });

    test('readiness transitions at exact thresholds', () async {
      await setUp();
      Future<void> seedDays(int count) async {
        for (var day = 1; day <= count; day++) {
          final date = '2026-04-${day.toString().padLeft(2, '0')}';
          await repository.upsertDailySummary(
            DailySummaryRecord(
              dateLocal: date,
              summaryJson: {
                'hrv_sdnn_mean': 50.0,
                'resting_hr_mean': 60.0,
                'sleep_total_minutes': 420,
                'step_count_total': 7000,
              },
              syncQualityScore: 1,
              recomputedAt: DateTime.parse('2026-05-01T00:00:00Z'),
            ),
          );
        }
      }

      // 6 days → not_ready
      await seedDays(6);
      var r = await summaryService.recomputeBaseline(asOfDate: '2026-04-06');
      expect(r!.readinessState, 'not_ready');

      // 7 days → low_confidence
      await seedDays(7);
      r = await summaryService.recomputeBaseline(asOfDate: '2026-04-07');
      expect(r!.readinessState, 'low_confidence');

      // 13 days → still low_confidence
      await seedDays(13);
      r = await summaryService.recomputeBaseline(asOfDate: '2026-04-13');
      expect(r!.readinessState, 'low_confidence');

      // 14 days → ready
      await seedDays(14);
      r = await summaryService.recomputeBaseline(asOfDate: '2026-04-14');
      expect(r!.readinessState, 'ready');

      // 27 days → ready
      await seedDays(27);
      r = await summaryService.recomputeBaseline(asOfDate: '2026-04-27');
      expect(r!.readinessState, 'ready');

      // 28 days → mature
      await seedDays(28);
      r = await summaryService.recomputeBaseline(asOfDate: '2026-04-28');
      expect(r!.readinessState, 'mature');

      await tearDown();
    });

    test('days with < 3 core metrics do not count as valid', () async {
      await setUp();
      for (var day = 1; day <= 10; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        // Only 2 core metrics → should not count
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {'hrv_sdnn_mean': 50.0, 'resting_hr_mean': 60.0},
            syncQualityScore: 0.33,
            recomputedAt: DateTime.parse('2026-05-01T00:00:00Z'),
          ),
        );
      }
      final result = await summaryService.recomputeBaseline(
        asOfDate: '2026-04-10',
      );
      expect(result!.readinessState, 'not_ready');
      expect(result.validDays, 0);
      await tearDown();
    });
  });

  group('recomputeDates', () {
    test('deduplicates and sorts input dates', () async {
      await setUp();
      final importedAt = DateTime.parse('2026-04-15T00:00:00Z');
      final baseDate = DateTime.parse('2026-04-11T08:00:00Z');
      for (var i = 0; i < 3; i++) {
        final date = baseDate.add(Duration(days: i));
        final samples = normalization
            .normalizeBatch(
              metricType: HealthMetricType.heartRateVariabilitySdnn,
              samples: [
                sample(
                  type: HealthMetricType.heartRateVariabilitySdnn,
                  value: 42.0,
                  vendorId: 'hrv-dedup-$i',
                  start: date,
                ),
              ],
              importedAt: importedAt,
            )
            .samples;
        await repository.upsertSamples(samples);
      }
      // Duplicate the first date
      final result = await summaryService.recomputeDates(const [
        '2026-04-13',
        '2026-04-11',
        '2026-04-11',
        '2026-04-12',
      ]);
      expect(result.recomputedDates, [
        '2026-04-11',
        '2026-04-12',
        '2026-04-13',
      ]);
      await tearDown();
    });

    test('empty date list returns empty result', () async {
      await setUp();
      final result = await summaryService.recomputeDates(const []);
      expect(result.recomputedDates, isEmpty);
      expect(result.failedDates, isEmpty);
      await tearDown();
    });
  });
}
