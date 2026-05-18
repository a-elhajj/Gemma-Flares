import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/setup_state_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;
  late SetupStateService service;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_setup_state',
    );
    database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    service = SetupStateService(
      repository: WearableSampleRepository(database: database),
      nowProvider: () => DateTime.utc(2026, 5, 4, 12),
    );
  });

  tearDown(() async {
    await database.close();
    await tempRoot.delete(recursive: true);
  });

  test('loads empty status by default', () async {
    final status = await service.loadStatus();

    expect(status.completed, isFalse);
    expect(status.schemaVersion, SetupStatus.currentSchemaVersion);
    expect(status.hasValidatedProfile, isFalse);
    expect(status.hasValidatedModel, isFalse);
    expect(status.healthEnabled, isFalse);
  });

  test('stale completed setup schema is not ready for app use', () {
    final status = SetupStatus(
      completed: true,
      profileValidatedAt: DateTime.utc(2026, 5, 4, 12),
      modelValidatedAt: DateTime.utc(2026, 5, 4, 12),
      healthValidatedAt: DateTime.utc(2026, 5, 4, 12),
      schemaVersion: SetupStatus.currentSchemaVersion - 1,
    );

    expect(status.completed, isTrue);
    expect(status.isReadyForAppUse, isFalse);
  });

  test('persists profile and model validation metadata', () async {
    await service.markProfileValidated();
    await service.markModelValidated(
      runtimeProfile: 'phone_balanced',
      backend: 'litert-lm',
    );

    final status = await service.loadStatus();

    expect(status.completed, isFalse);
    expect(status.profileValidatedAt, DateTime.utc(2026, 5, 4, 12));
    expect(status.modelValidatedAt, DateTime.utc(2026, 5, 4, 12));
    expect(status.modelRuntimeProfile, 'phone_balanced');
    expect(status.modelBackend, 'litert-lm');
    expect(status.schemaVersion, SetupStatus.currentSchemaVersion);
  });

  test('completes setup with Health enabled', () async {
    await service.markProfileValidated();
    await service.markModelValidated(runtimeProfile: 'phone_balanced');
    await service.completeWithHealth(
      importedSamples: 42,
      lastBackfillAt: DateTime.utc(2026, 5, 4, 11, 45),
    );

    final status = await service.loadStatus();

    expect(status.completed, isTrue);
    expect(status.completedAt, DateTime.utc(2026, 5, 4, 12));
    expect(status.healthEnabled, isTrue);
    expect(status.healthImportedSamples, 42);
    expect(status.healthLastBackfillAt, DateTime.utc(2026, 5, 4, 11, 45));
  });

  test('completes setup without Health', () async {
    await service.markProfileValidated();
    await service.markModelValidated(runtimeProfile: 'phone_balanced');
    await service.completeWithoutHealth();

    final status = await service.loadStatus();

    expect(status.completed, isTrue);
    expect(status.healthEnabled, isFalse);
    expect(status.healthImportedSamples, 0);
    expect(status.healthValidatedAt, DateTime.utc(2026, 5, 4, 12));
  });

  test('model repair clears completion and model validation only', () async {
    await service.markProfileValidated();
    await service.markModelValidated(
      runtimeProfile: 'phone_balanced',
      backend: 'litert-lm',
    );
    await service.completeWithHealth(
      importedSamples: 42,
      lastBackfillAt: DateTime.utc(2026, 5, 4, 11, 45),
    );

    await service.markModelNeedsRepair();
    final status = await service.loadStatus();

    expect(status.completed, isFalse);
    expect(status.completedAt, isNull);
    expect(status.profileValidatedAt, DateTime.utc(2026, 5, 4, 12));
    expect(status.modelValidatedAt, isNull);
    expect(status.modelRuntimeProfile, isNull);
    expect(status.modelBackend, isNull);
    expect(status.healthValidatedAt, DateTime.utc(2026, 5, 4, 12));
    expect(status.healthEnabled, isTrue);
    expect(status.healthImportedSamples, 42);
  });

  test('clears setup status', () async {
    await service.markProfileValidated();
    await service.markModelValidated(runtimeProfile: 'phone_balanced');
    await service.completeWithoutHealth();
    expect((await service.loadStatus()).completed, isTrue);

    await service.clearStatus();

    expect((await service.loadStatus()).completed, isFalse);
  });
}
