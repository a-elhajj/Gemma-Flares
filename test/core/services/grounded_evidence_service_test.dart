import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/grounded_evidence_service.dart';
import 'package:gemma_flares/core/services/ibd_checkin_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;
  late WearableSampleRepository repository;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_evidence_test',
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

  test('builds a PHI-safe evidence bundle and receipt', () async {
    await repository.upsertDailyFeature(
      DailyFeatureRecord(
        featureDateLocal: '2026-04-18',
        featureJson: const {
          'hrv_3d_pct_delta_vs_baseline': -12.0,
          'provider_name': 'Should be stripped',
        },
        missingnessJson: const {},
        recomputedAt: DateTime.utc(2026, 4, 18, 10),
      ),
    );
    await repository.insertSymptom(
      SymptomRecord(
        loggedAt: DateTime.utc(2026, 4, 18, 12),
        symptomType: 'cramping',
        severity: 6,
        notes: 'private free text',
        extractionMethod: 'deterministic',
        extractionConfidence: 0.8,
        createdAt: DateTime.utc(2026, 4, 18, 12),
      ),
    );
    await repository.insertPro2Survey(
      Pro2SurveyRecord(
        surveyDate: '2026-04-18',
        diseaseType: 'CD',
        cdAbdominalPain: 2,
        cdStoolFrequency: 1,
        pro2Score: 5,
        isFlare: false,
        scoreVersion: Pro2SurveyRecord.cdV2Pain2Stool1,
        notes: IbdCheckInService.encodeNotes(
          diseaseType: 'CD',
          dailyCore: const {'abdominal_pain_0_3': 2, 'loose_stool_bucket': 1},
          dailyDetails: const {'bloating_0_3': 1},
          completedSections: const ['core', 'daily_details'],
        ),
        createdAt: DateTime.utc(2026, 4, 18, 8),
      ),
    );
    final service = GroundedEvidenceService(
      repository: repository,
      nowProvider: () => DateTime.utc(2026, 4, 18, 13),
    );

    final bundle = await service.buildLatestBundle();

    expect(bundle.dateLocal, '2026-04-18');
    expect(bundle.evidenceHash.length, 64);
    expect(bundle.receipt['symptom_count'], 1);
    final features = bundle.evidence['daily_features_full'] as Map;
    expect(features['hrv_3d_pct_delta_vs_baseline'], -12.0);
    expect(features.containsKey('provider_name'), isFalse);
    final symptoms = bundle.evidence['symptoms'] as List;
    expect((symptoms.single as Map).containsKey('notes'), isFalse);
    final checkins = bundle.evidence['checkins'] as List;
    expect((checkins.single as Map)['summary'], contains('Crohn'));
    expect(bundle.receipt['checkin_count'], 1);
  });
}
