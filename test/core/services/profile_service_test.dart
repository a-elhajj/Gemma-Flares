import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/profile_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;
  late WearableSampleRepository repository;
  late ProfileService service;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_profile_test',
    );
    database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
    repository = WearableSampleRepository(database: database);
    service = ProfileService(
      repository: repository,
      nowProvider: () => DateTime.parse('2026-04-13T12:00:00Z'),
    );
  });

  tearDown(() async {
    await database.close();
    await tempRoot.delete(recursive: true);
  });

  test('loads empty profile by default', () async {
    final profile = await service.loadProfile();
    expect(profile, UserProfile.empty);
    expect(profile.hasProfileData, isFalse);
  });

  test('saves and reloads full profile', () async {
    const profile = UserProfile(
      dateOfBirth: '1990-04-10',
      biologicalSex: 'female',
      heightCm: 165.0,
      weightKg: 61.5,
      heightUnitPreference: 'cm',
      weightUnitPreference: 'kg',
      diseaseType: 'CD',
      cdDiseaseLocation: 'L3 Ileocolon',
      cdDiseaseBehavior: 'B1 Inflammatory',
      cdPerianalInvolvement: false,
      diagnosisYear: 2014,
      hadSurgery: true,
      surgeryType: 'Ileocecal resection',
      surgeryYear: 2018,
      medications: [
        MedicationEntry(
          name: 'Adalimumab',
          dose: '40 mg',
          frequency: 'Every 2 weeks',
          startDate: '2025-01-01',
        ),
      ],
      otherConditions: ['Asthma'],
      deviceType: 'Apple Watch',
      watchSeries: 'Series 9',
    );

    await service.saveProfile(profile);
    final loaded = await service.loadProfile();

    expect(loaded.dateOfBirth, profile.dateOfBirth);
    expect(loaded.biologicalSex, profile.biologicalSex);
    expect(loaded.heightCm, profile.heightCm);
    expect(loaded.weightKg, profile.weightKg);
    expect(loaded.diseaseType, profile.diseaseType);
    expect(loaded.cdDiseaseLocation, profile.cdDiseaseLocation);
    expect(loaded.medications.single.name, 'Adalimumab');
    expect(loaded.watchSeries, 'Series 9');
  });

  test('computes BMI and model covariates', () async {
    await service.saveProfile(
      const UserProfile(
        dateOfBirth: '1992-10-20',
        biologicalSex: 'male',
        heightCm: 180.0,
        weightKg: 81.0,
        diseaseType: 'UC',
      ),
    );

    final profile = await service.loadProfile();
    final covariates = await service.getCovariates();

    expect(profile.bmi, closeTo(25.0, 0.1));
    expect(covariates.age, 33);
    expect(covariates.sexMale, isTrue);
    expect(covariates.bmi, closeTo(25.0, 0.1));
    expect(covariates.diseaseCd, isFalse);
    expect(covariates.toFeatureJson()['user_disease_cd'], 0);
  });

  test('clearProfile removes persisted data', () async {
    await service.saveProfile(const UserProfile(diseaseType: 'CD'));
    expect((await service.loadProfile()).hasProfileData, isTrue);

    await service.clearProfile();

    final profile = await service.loadProfile();
    expect(profile, UserProfile.empty);
  });
}
