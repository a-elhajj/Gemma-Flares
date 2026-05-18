import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/logistic_risk_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;
  late WearableSampleRepository repository;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_logistic_idem_',
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

  test('same model and sample date trains at most once', () async {
    final service = LogisticRiskService(
      repository: repository,
      nowProvider: () => DateTime.utc(2026, 5, 1, 12),
    );
    await repository.upsertFlareLabel(
      FlareLabelRecord(
        labelDate: '2026-05-08',
        inflammatoryFlare: true,
        symptomaticFlare: false,
        combinedFlare: false,
        labelSource: 'test',
        confidence: 'high',
        recomputedAt: DateTime.utc(2026, 5, 1, 12),
      ),
    );

    await service.recomputeForDateWithFeatures('2026-05-01', const {});
    final firstState = await repository.getLogisticModelState(
      'logistic_v1_inflammatory_7d',
    );
    final firstHistory = await repository.getTrainingHistory(
      'logistic_v1_inflammatory_7d',
    );

    await service.recomputeForDateWithFeatures('2026-05-01', const {});
    final secondState = await repository.getLogisticModelState(
      'logistic_v1_inflammatory_7d',
    );
    final secondHistory = await repository.getTrainingHistory(
      'logistic_v1_inflammatory_7d',
    );

    expect(firstState?.trainingSamples, 1);
    expect(secondState?.trainingSamples, 1);
    expect(firstHistory, hasLength(1));
    expect(secondHistory, hasLength(1));
    expect(secondHistory.single.sampleDate, '2026-05-01');
  });
}
