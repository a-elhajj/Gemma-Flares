import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/contracts/health_bridge_contracts.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/context_attribution_service.dart';
import 'package:gemma_flares/core/services/wearable_normalization_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('creates workout recovery and meal context windows', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_context_',
    );
    final database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    final repository = WearableSampleRepository(database: database);
    const normalizer = WearableNormalizationService();
    final importedAt = DateTime.parse('2026-04-11T13:00:00Z');

    await repository.upsertSamples([
      ...normalizer
          .normalizeBatch(
            metricType: HealthMetricType.workout,
            samples: [
              _sample(
                type: HealthMetricType.workout,
                value: 45,
                vendorId: 'workout',
                start: DateTime.parse('2026-04-11T10:00:00Z'),
                end: DateTime.parse('2026-04-11T10:45:00Z'),
                metadata: const {'workoutActivityType': 52},
              ),
            ],
            importedAt: importedAt,
          )
          .samples,
      ...normalizer
          .normalizeBatch(
            metricType: HealthMetricType.heartRate,
            samples: [
              _sample(
                type: HealthMetricType.heartRate,
                value: 135,
                vendorId: 'hr-workout',
                start: DateTime.parse('2026-04-11T10:10:00Z'),
                end: DateTime.parse('2026-04-11T10:11:00Z'),
              ),
            ],
            importedAt: importedAt,
          )
          .samples,
    ]);
    await repository.insertSymptom(
      SymptomRecord(
        loggedAt: DateTime.parse('2026-04-11T12:30:00Z'),
        symptomType: 'abdominal_pain',
        severity: 5,
        mealRelation: 'after_lunch',
        extractionMethod: 'deterministic',
        extractionConfidence: 0.9,
        createdAt: DateTime.parse('2026-04-11T12:31:00Z'),
      ),
    );

    final service = ContextAttributionService(
      repository: repository,
      nowProvider: () => DateTime.parse('2026-04-11T13:00:00Z'),
    );
    final result = await service.recomputeDate('2026-04-11');
    final windows = await repository.getContextWindows(dateLocal: '2026-04-11');

    expect(
      windows.map((w) => w.contextType),
      containsAll(['exercise', 'recovery', 'meal']),
    );
    final recovery = windows.singleWhere((w) => w.contextType == 'recovery');
    expect(recovery.endTimeUtc, DateTime.parse('2026-04-11T12:45:00Z'));
    expect(result.featureJson['context_recovery_present'], 1);
    expect(result.featureJson['context_meal_present'], 1);
    expect(
      (result.featureJson['context_hr_exercise_explained_pct'] as num)
          .toDouble(),
      1.0,
    );

    await database.close();
    await tempRoot.delete(recursive: true);
  });
}

HealthSampleDto _sample({
  required HealthMetricType type,
  required double value,
  required String vendorId,
  required DateTime start,
  DateTime? end,
  Map<String, Object?> metadata = const {},
}) {
  return HealthSampleDto(
    vendorSampleId: vendorId,
    sourceName: 'apple_health',
    sourceDevice: 'AppleWatch',
    metricType: type,
    value: value,
    unit: '',
    startTime: start,
    endTime: end ?? start.add(const Duration(minutes: 1)),
    timezone: 'America/Toronto',
    metadata: metadata,
  );
}
