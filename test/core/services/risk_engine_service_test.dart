import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/contracts/health_bridge_contracts.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/logistic_risk_service.dart';
import 'package:gemma_flares/core/services/ibd_checkin_service.dart';
import 'package:gemma_flares/core/services/profile_service.dart';
import 'package:gemma_flares/core/services/risk_engine_service.dart';
import 'package:gemma_flares/core/services/wearable_normalization_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test(
    'risk engine persists deterministic high-risk score for deteriorating signals',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_risk_engine_test',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-16T08:00:00Z'),
      );

      for (var day = 1; day <= 15; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        final isDeteriorated = day >= 13;
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {
              'hrv_sdnn_mean': isDeteriorated ? 35.0 : 50.0,
              'resting_hr_mean': isDeteriorated ? 68.0 : 58.0,
              'sleep_total_minutes': isDeteriorated ? 330 : 420,
              'sleep_asleep_deep_minutes': isDeteriorated ? 40 : 75,
              'sleep_asleep_rem_minutes': isDeteriorated ? 45 : 90,
              'step_count_total': isDeteriorated ? 5000 : 8200,
              'spo2_mean': 97.0,
              'spo2_count': 3,
              'wrist_temp_mean': isDeteriorated ? 0.9 : 0.0,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-16T08:00:00Z'),
          ),
        );
      }

      await repository.updateSyncState(
        sourceName: 'apple_health',
        lastSyncAt: DateTime.parse('2026-04-16T06:00:00Z'),
        lastBackfillStart: DateTime.parse('2026-03-17T06:00:00Z'),
        lastBackfillEnd: DateTime.parse('2026-04-16T06:00:00Z'),
      );

      final result = await service.recomputeDates(const ['2026-04-15']);
      final latestScore = await repository.getLatestFlareRiskScore();

      expect(result.failedDates, isEmpty);
      expect(result.recomputedDates, contains('2026-04-15'));
      expect(latestScore, isNotNull);
      expect(latestScore!.dateLocal, '2026-04-15');
      expect(latestScore.riskBand, 'high');
      // PA-002 Improvement 5: when HRV is present (hrv_3d_pct_delta_vs_baseline
      // populated), sleep contribution is capped at 7 pts to avoid double-counting
      // the same physiological state. Pre-PA-002: sleep_points=10, total=66.
      // Post-PA-002 (HRV gated): sleep_points=7, total=63. The cap is correct per
      // Hirten et al. 2025 supplementary — HRV MESOR already captures the
      // overlapping sleep-disruption signal.
      expect(latestScore.riskScore.round(), 63);
      expect(latestScore.confidenceScore.round(), 96);
      expect(latestScore.contributionJson['hrv_points'], 25);
      expect(latestScore.contributionJson['resting_hr_points'], 20);
      expect(
        latestScore.contributionJson['sleep_points'],
        7,
        reason:
            'PA-002: sleep cap=7 when HRV present (avoids double-counting per Hirten 2025)',
      );
      expect(latestScore.contributionJson['steps_points'], 4);
      expect(latestScore.contributionJson['sparse_vitals_points'], 7);
      expect(latestScore.contributionJson['active_signal_family_count'], 4);
      final confidenceComponents =
          latestScore.contributionJson['confidence_components'] as Map;
      expect(confidenceComponents['baseline_maturity'], greaterThan(30));
      expect(
        confidenceComponents['signal_corroboration'],
        greaterThanOrEqualTo(9),
      );

      final opened = await database.open();
      final featureRows = await opened.query('daily_features');
      expect(featureRows, isNotEmpty);
      final featureJson = jsonDecode(featureRows.last['feature_json'] as String)
          as Map<String, Object?>;
      expect(
        (featureJson['hrv_3d_pct_delta_vs_baseline'] as num).toDouble(),
        greaterThan(20),
      );
      expect(
        (featureJson['rhr_3d_delta_vs_baseline'] as num).toDouble(),
        greaterThan(7),
      );
      expect((featureJson['sleep_deep_pct'] as num).toDouble(), lessThan(0.2));
      expect((featureJson['sleep_rem_pct'] as num).toDouble(), lessThan(0.2));
      expect((featureJson['hrv_14d_slope'] as num).toDouble(), lessThan(0));
      expect((featureJson['rhr_14d_slope'] as num).toDouble(), greaterThan(0));
      expect((featureJson['steps_14d_slope'] as num).toDouble(), lessThan(0));

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test(
    'risk engine lowers confidence when baseline is not ready and metrics are missing',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_risk_missingness_test',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-05T08:00:00Z'),
      );

      await repository.upsertDailySummary(
        DailySummaryRecord(
          dateLocal: '2026-04-04',
          summaryJson: {'resting_hr_mean': 61.0, 'step_count_total': 6400},
          syncQualityScore: 0.33,
          recomputedAt: DateTime.parse('2026-04-05T08:00:00Z'),
        ),
      );
      await repository.updateSyncState(
        sourceName: 'apple_health',
        lastSyncAt: DateTime.parse('2026-03-31T08:00:00Z'),
        lastBackfillStart: DateTime.parse('2026-03-01T08:00:00Z'),
        lastBackfillEnd: DateTime.parse('2026-03-31T08:00:00Z'),
      );

      await service.recomputeDates(const ['2026-04-04']);
      final latestScore = await repository.getLatestFlareRiskScore();

      expect(latestScore, isNotNull);
      expect(latestScore!.riskBand, 'low');
      expect(latestScore.riskScore.round(), 0);
      expect(latestScore.confidenceScore.round(), 21);
      final confidenceInputs =
          latestScore.contributionJson['confidence_inputs'] as Map;
      expect(confidenceInputs['available_metric_families'], 2);
      expect(confidenceInputs['stale_sync'], true);

      final opened = await database.open();
      final featureRows = await opened.query('daily_features');
      final missingnessJson =
          jsonDecode(featureRows.single['missingness_json'] as String)
              as Map<String, Object?>;
      expect(missingnessJson['baseline_not_ready'], true);
      expect(missingnessJson['missing_hrv'], true);
      expect(missingnessJson['missing_sleep'], true);
      expect(missingnessJson['stale_sync'], true);

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test(
    'risk engine voids wrist temperature for Apple Watch SE 2nd gen',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_watch_capability_test',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final profileService = ProfileService(repository: repository);
      await profileService.saveProfile(
        const UserProfile(
          diseaseType: 'CD',
          deviceType: 'Apple Watch',
          watchSeries: 'apple_watch_se_2',
        ),
      );
      final service = RiskEngineService(
        repository: repository,
        profileService: profileService,
        nowProvider: () => DateTime.parse('2026-04-16T08:00:00Z'),
      );

      for (var day = 1; day <= 15; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        final isWarm = day >= 13;
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {
              'hrv_sdnn_mean': 50.0,
              'resting_hr_mean': 58.0,
              'sleep_total_minutes': 420,
              'step_count_total': 8200,
              'spo2_mean': 97.0,
              'spo2_count': 3,
              'wrist_temp_mean': isWarm ? 0.9 : 0.0,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-16T08:00:00Z'),
          ),
        );
      }

      await repository.updateSyncState(
        sourceName: 'apple_health',
        lastSyncAt: DateTime.parse('2026-04-16T06:00:00Z'),
        lastBackfillStart: DateTime.parse('2026-03-17T06:00:00Z'),
        lastBackfillEnd: DateTime.parse('2026-04-16T06:00:00Z'),
      );

      await service.recomputeDates(const ['2026-04-15']);
      final latestScore = await repository.getLatestFlareRiskScore();
      final opened = await database.open();
      final featureRows = await opened.query('daily_features');
      final featureJson = jsonDecode(featureRows.last['feature_json'] as String)
          as Map<String, Object?>;
      final missingnessJson =
          jsonDecode(featureRows.last['missingness_json'] as String)
              as Map<String, Object?>;

      expect(latestScore, isNotNull);
      expect(latestScore!.contributionJson['sparse_vitals_points'], 0);
      expect(featureJson['watch_model_id'], 'apple_watch_se_2');
      expect(featureJson['temp_3d_mean'], isNull);
      expect(featureJson['temp_3d_delta_vs_baseline'], isNull);
      expect(featureJson['unsupported_wrist_temperature'], 1);
      expect(featureJson['unsupported_spo2'], 1);
      expect(missingnessJson['missing_temp'], isFalse);
      expect(missingnessJson['unsupported_temp'], isTrue);

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test(
    'risk engine includes user profile covariates in feature json',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_risk_profile_test',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final profileService = ProfileService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-16T08:00:00Z'),
      );
      await profileService.saveProfile(
        const UserProfile(
          dateOfBirth: '1990-04-10',
          biologicalSex: 'male',
          heightCm: 180.0,
          weightKg: 81.0,
          diseaseType: 'CD',
        ),
      );
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-16T08:00:00Z'),
        profileService: profileService,
      );

      for (var day = 1; day <= 15; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: const {
              'hrv_sdnn_mean': 50.0,
              'resting_hr_mean': 58.0,
              'sleep_total_minutes': 420,
              'sleep_asleep_deep_minutes': 75,
              'sleep_asleep_rem_minutes': 90,
              'step_count_total': 8200,
              'spo2_mean': 97.0,
              'spo2_count': 3,
              'wrist_temp_mean': 0.0,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-16T08:00:00Z'),
          ),
        );
      }

      await repository.updateSyncState(
        sourceName: 'apple_health',
        lastSyncAt: DateTime.parse('2026-04-16T06:00:00Z'),
        lastBackfillStart: DateTime.parse('2026-03-17T06:00:00Z'),
        lastBackfillEnd: DateTime.parse('2026-04-16T06:00:00Z'),
      );

      await service.recomputeDates(const ['2026-04-15']);

      final opened = await database.open();
      final featureRows = await opened.query('daily_features');
      final featureJson = jsonDecode(featureRows.last['feature_json'] as String)
          as Map<String, Object?>;
      expect(featureJson['user_age'], 36);
      expect(featureJson['user_sex_male'], 1);
      expect((featureJson['user_bmi'] as num).toDouble(), closeTo(25.0, 0.1));
      expect(featureJson['user_disease_cd'], 1);
      expect(featureJson['sleep_deep_pct'], isNotNull);
      expect(featureJson['logistic_p_flare_7d'], isNull);

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test(
    'risk engine persists all logistic model rows and deterministic horizon keys',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_risk_logistic_test',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final logisticService = LogisticRiskService(repository: repository);
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-16T08:00:00Z'),
        logisticRiskService: logisticService,
      );

      for (var day = 1; day <= 15; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: const {
              'hrv_sdnn_mean': 50.0,
              'resting_hr_mean': 58.0,
              'sleep_total_minutes': 420,
              'sleep_asleep_deep_minutes': 75,
              'sleep_asleep_rem_minutes': 90,
              'step_count_total': 8200,
              'spo2_mean': 97.0,
              'spo2_count': 3,
              'wrist_temp_mean': 0.0,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-16T08:00:00Z'),
          ),
        );
      }

      await service.recomputeDates(const ['2026-04-15']);

      final scores = await repository.getFlareRiskScores();
      expect(
        scores.where((score) => score.modelVersion == 'risk_v1'),
        hasLength(1),
      );
      expect(
        scores.where((score) => score.modelVersion.startsWith('logistic_v1_')),
        hasLength(14),
      );
      for (final horizon in LogisticRiskService.horizons) {
        expect(
          scores.map((score) => score.modelVersion),
          contains('logistic_v1_inflammatory_${horizon}d'),
        );
        expect(
          scores.map((score) => score.modelVersion),
          contains('logistic_v1_symptomatic_${horizon}d'),
        );
      }

      final feature = await repository.getDailyFeatureForDate('2026-04-15');
      expect(feature, isNotNull);
      for (final horizon in LogisticRiskService.horizons) {
        expect(feature!.featureJson, contains('logistic_p_flare_${horizon}d'));
        expect(
          feature.featureJson,
          contains('logistic_${horizon}d_cold_start'),
        );
      }

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test(
    'risk engine derives symptom semantic features from recent logs',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_risk_symptom_llm_test',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-16T08:00:00Z'),
      );

      for (var day = 1; day <= 15; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: const {
              'hrv_sdnn_mean': 50.0,
              'resting_hr_mean': 58.0,
              'sleep_total_minutes': 420,
              'sleep_asleep_deep_minutes': 75,
              'sleep_asleep_rem_minutes': 90,
              'step_count_total': 8200,
              'spo2_mean': 97.0,
              'spo2_count': 3,
              'wrist_temp_mean': 0.0,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-16T08:00:00Z'),
          ),
        );
      }

      await repository.insertSymptom(
        SymptomRecord(
          loggedAt: DateTime.parse('2026-04-15T09:00:00Z'),
          symptomType: 'abdominal_pain',
          severity: 7,
          mealRelation: 'after_dinner',
          sourceTranscript: 'Pain got worse after eating dinner.',
          extractionMethod: 'deterministic',
          extractionConfidence: 0.9,
          createdAt: DateTime.parse('2026-04-15T09:00:00Z'),
        ),
      );
      await repository.insertSymptom(
        SymptomRecord(
          loggedAt: DateTime.parse('2026-04-15T10:00:00Z'),
          symptomType: 'urgency',
          severity: 5,
          sourceTranscript: 'Had urgency and needed the bathroom fast.',
          extractionMethod: 'deterministic',
          extractionConfidence: 0.9,
          createdAt: DateTime.parse('2026-04-15T10:00:00Z'),
        ),
      );
      await repository.insertSymptom(
        SymptomRecord(
          loggedAt: DateTime.parse('2026-04-15T11:00:00Z'),
          symptomType: 'fatigue',
          severity: 6,
          sourceTranscript: 'Felt very fatigued today.',
          extractionMethod: 'deterministic',
          extractionConfidence: 0.9,
          createdAt: DateTime.parse('2026-04-15T11:00:00Z'),
        ),
      );

      await service.recomputeDates(const ['2026-04-15']);

      final opened = await database.open();
      final featureRows = await opened.query('daily_features');
      final featureJson = jsonDecode(featureRows.last['feature_json'] as String)
          as Map<String, Object?>;
      expect(
        (featureJson['llm_pain_intensity'] as num).toDouble(),
        closeTo(0.7, 0.01),
      );
      expect(featureJson['llm_urgency_present'], 1);
      expect(
        (featureJson['llm_fatigue_signal'] as num).toDouble(),
        closeTo(0.6, 0.01),
      );
      expect(featureJson['llm_dietary_trigger'], 1);

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test(
    'risk engine excludes non-IBD symptoms from flare symptom features',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_risk_non_ibd_symptom_filter',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-16T08:00:00Z'),
      );

      for (var day = 1; day <= 15; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: const {
              'hrv_sdnn_mean': 50.0,
              'resting_hr_mean': 58.0,
              'sleep_total_minutes': 420,
              'sleep_asleep_deep_minutes': 75,
              'sleep_asleep_rem_minutes': 90,
              'step_count_total': 8200,
              'spo2_mean': 97.0,
              'spo2_count': 3,
              'wrist_temp_mean': 0.0,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-16T08:00:00Z'),
          ),
        );
      }

      await repository.insertSymptom(
        SymptomRecord(
          loggedAt: DateTime.parse('2026-04-15T09:00:00Z'),
          symptomType: 'abdominal_pain',
          severity: 6,
          sourceTranscript: 'Cramping abdominal pain after breakfast.',
          extractionMethod: 'deterministic',
          extractionConfidence: 0.9,
          createdAt: DateTime.parse('2026-04-15T09:00:00Z'),
        ),
      );
      await repository.insertSymptom(
        SymptomRecord(
          loggedAt: DateTime.parse('2026-04-15T11:00:00Z'),
          symptomType: 'headache_migraine',
          severity: 9,
          sourceTranscript: 'Migraine and light sensitivity.',
          extractionMethod: 'deterministic',
          extractionConfidence: 0.9,
          createdAt: DateTime.parse('2026-04-15T11:00:00Z'),
        ),
      );

      await service.recomputeDates(const ['2026-04-15']);

      final feature = await repository.getDailyFeatureForDate('2026-04-15');
      expect(feature, isNotNull);
      final featureJson = feature!.featureJson;
      expect(featureJson['symptom_count_48h_all'], 2);
      expect(featureJson['symptom_count_48h_non_ibd'], 1);
      expect(featureJson['symptom_count_48h'], 1);
      expect(featureJson['symptom_weighted_sum_48h'], 6);
      expect(
        (featureJson['llm_pain_intensity'] as num).toDouble(),
        closeTo(0.6, 0.01),
      );

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test(
    'risk engine includes structured check-in features and confidence input',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_risk_checkin_test',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-16T08:00:00Z'),
      );

      for (var day = 1; day <= 15; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: const {
              'hrv_sdnn_mean': 50.0,
              'resting_hr_mean': 58.0,
              'sleep_total_minutes': 420,
              'sleep_asleep_deep_minutes': 75,
              'sleep_asleep_rem_minutes': 90,
              'step_count_total': 8200,
              'spo2_mean': 97.0,
              'spo2_count': 3,
              'wrist_temp_mean': 0.0,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-16T08:00:00Z'),
          ),
        );
      }
      await repository.insertPro2Survey(
        Pro2SurveyRecord(
          surveyDate: '2026-04-15',
          diseaseType: 'CD',
          cdAbdominalPain: 2,
          cdStoolFrequency: 2,
          pro2Score: 6,
          isFlare: false,
          scoreVersion: Pro2SurveyRecord.cdV2Pain2Stool1,
          notes: IbdCheckInService.encodeNotes(
            diseaseType: 'CD',
            dailyCore: const {'abdominal_pain_0_3': 2, 'loose_stool_bucket': 2},
            dailyDetails: const {
              'urgency_0_3': 2,
              'bloating_0_3': 1,
              'fatigue_0_3': 2,
              'blood_0_3': 0,
              'perianal_symptom_0_3': 0,
            },
            completedSections: const ['core', 'daily_details'],
          ),
          createdAt: DateTime.parse('2026-04-15T08:00:00Z'),
        ),
      );

      await service.recomputeDates(const ['2026-04-15']);

      final feature = await repository.getDailyFeatureForDate('2026-04-15');
      final score = await repository.getLatestFlareRiskScore();
      expect(feature, isNotNull);
      expect(feature!.featureJson['checkin_present_today'], 1);
      expect(feature.featureJson['checkin_pain_0_3'], 2);
      expect(feature.featureJson['checkin_urgency_0_3'], 2);
      expect(feature.featureJson['checkin_days_with_urgency_7d'], 1);
      expect(score!.contributionJson['checkin_symptom_points'], greaterThan(0));
      final inputs = score.contributionJson['confidence_inputs'] as Map;
      expect(inputs['checkin_present_today'], isTrue);

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test(
    'risk_v2 down-weights HR-only risk when workout explains HR context',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_risk_context_test',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-16T08:00:00Z'),
      );

      for (var day = 1; day <= 15; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {
              'hrv_sdnn_mean': 50.0,
              'resting_hr_mean': day == 15 ? 68.0 : 58.0,
              'sleep_total_minutes': 420,
              'sleep_asleep_deep_minutes': 75,
              'sleep_asleep_rem_minutes': 90,
              'step_count_total': 8200,
              'spo2_mean': 97.0,
              'spo2_count': 3,
              'wrist_temp_mean': 0.0,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-16T08:00:00Z'),
          ),
        );
      }
      await _insertContextSamples(repository);

      await service.recomputeDates(const ['2026-04-15']);
      final riskV1 = await repository.getLatestFlareRiskScore(
        modelVersion: 'risk_v1',
      );
      final riskV2 = await repository.getLatestFlareRiskScore(
        modelVersion: RiskEngineService.productionModelVersion,
      );

      expect(riskV1, isNotNull);
      expect(riskV2, isNotNull);
      expect(riskV2!.riskScore, lessThan(riskV1!.riskScore));
      expect(
        riskV2.contributionJson['context_attribution_reason'],
        'looks_workout_related',
      );

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test(
    'risk_v2 false-negative guard raises score when non-HR signals worsen',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_risk_fn_guard_test',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-16T08:00:00Z'),
      );

      for (var day = 1; day <= 15; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {
              'hrv_sdnn_mean': 50.0,
              'resting_hr_mean': 58.0,
              'sleep_total_minutes': day == 15 ? 330 : 420,
              'sleep_asleep_deep_minutes': day == 15 ? 30 : 75,
              'sleep_asleep_rem_minutes': day == 15 ? 35 : 90,
              'step_count_total': 8200,
              'spo2_mean': 97.0,
              'spo2_count': 3,
              'wrist_temp_mean': day == 15 ? 0.4 : 0.0,
              'respiratory_rate_mean': day == 15 ? 20.0 : 16.0,
              'respiratory_rate_count': 6,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-16T08:00:00Z'),
          ),
        );
      }
      await repository.insertSymptom(
        SymptomRecord(
          loggedAt: DateTime.parse('2026-04-15T10:00:00Z'),
          symptomType: 'diarrhea',
          severity: 6,
          extractionMethod: 'manual',
          extractionConfidence: 1,
          createdAt: DateTime.parse('2026-04-15T10:00:00Z'),
        ),
      );

      await service.recomputeDates(const ['2026-04-15']);
      final riskV2 = await repository.getLatestFlareRiskScore(
        modelVersion: RiskEngineService.productionModelVersion,
      );

      expect(riskV2, isNotNull);
      expect(riskV2!.riskScore, greaterThanOrEqualTo(50));
      expect(riskV2.contributionJson['false_negative_guard_triggered'], true);
      expect(
        riskV2.contributionJson['context_attribution_reason'],
        'symptoms_changed_even_with_quiet_heart_rate',
      );

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test(
    'logistic horizon guard caps sparse single-signal outlook spikes',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_risk_horizon_guard',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final logisticService = _DeterministicHighProbLogisticService(
        repository: repository,
      );
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-16T08:00:00Z'),
        logisticRiskService: logisticService,
      );

      for (var day = 1; day <= 15; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {
              'hrv_sdnn_mean': 50.0,
              'resting_hr_mean': day == 15 ? 66.0 : 58.0,
              'sleep_total_minutes': 420,
              'sleep_asleep_deep_minutes': 75,
              'sleep_asleep_rem_minutes': 90,
              'step_count_total': 8200,
              'spo2_mean': 97.0,
              'spo2_count': 3,
              'wrist_temp_mean': 0.0,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-16T08:00:00Z'),
          ),
        );
      }
      await repository.insertPro2Survey(
        Pro2SurveyRecord(
          surveyDate: '2026-04-15',
          diseaseType: 'CD',
          cdAbdominalPain: 0,
          cdStoolFrequency: 0,
          pro2Score: 0,
          isFlare: false,
          scoreVersion: Pro2SurveyRecord.cdV2Pain2Stool1,
          notes: IbdCheckInService.encodeNotes(
            diseaseType: 'CD',
            dailyCore: const {'abdominal_pain_0_3': 0, 'loose_stool_bucket': 0},
            dailyDetails: const {
              'urgency_0_3': 0,
              'blood_0_3': 0,
              'fatigue_0_3': 1,
            },
            completedSections: const ['core', 'daily_details'],
          ),
          createdAt: DateTime.parse('2026-04-15T08:00:00Z'),
        ),
      );

      await service.recomputeDates(const ['2026-04-15']);

      final feature = await repository.getDailyFeatureForDate('2026-04-15');
      expect(feature, isNotNull);
      expect(
        (feature!.featureJson['logistic_p_flare_7d'] as num).toDouble(),
        lessThanOrEqualTo(0.50),
      );
      expect(feature.featureJson['logistic_7d_signal_guard_applied'], 1);

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  test(
    'logistic horizon guard allows high outlook when signals corroborate',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_risk_horizon_guard_release',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      final logisticService = _DeterministicHighProbLogisticService(
        repository: repository,
      );
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-16T08:00:00Z'),
        logisticRiskService: logisticService,
      );

      for (var day = 1; day <= 15; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        final deteriorated = day >= 13;
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: {
              'hrv_sdnn_mean': deteriorated ? 32.0 : 50.0,
              'resting_hr_mean': deteriorated ? 69.0 : 58.0,
              'sleep_total_minutes': deteriorated ? 330 : 420,
              'sleep_asleep_deep_minutes': deteriorated ? 35 : 75,
              'sleep_asleep_rem_minutes': deteriorated ? 40 : 90,
              'step_count_total': deteriorated ? 5100 : 8200,
              'spo2_mean': deteriorated ? 94.0 : 97.0,
              'spo2_count': 3,
              'wrist_temp_mean': deteriorated ? 0.6 : 0.0,
            },
            syncQualityScore: 1,
            recomputedAt: DateTime.parse('2026-04-16T08:00:00Z'),
          ),
        );
      }

      await service.recomputeDates(const ['2026-04-15']);

      final feature = await repository.getDailyFeatureForDate('2026-04-15');
      final userFacing = await repository.getLatestUserFacingFlareRiskScore();
      expect(feature, isNotNull);
      expect(
        (feature!.featureJson['logistic_p_flare_7d'] as num).toDouble(),
        greaterThan(0.60),
      );
      expect(userFacing, isNotNull);
      expect(
        userFacing!.modelVersion,
        RiskEngineService.productionModelVersion,
      );
      expect(userFacing.featureSnapshotJson['logistic_p_flare_7d'], isNotNull);
      expect(userFacing.featureSnapshotJson['logistic_p_flare_14d'], isNotNull);
      expect(userFacing.featureSnapshotJson['logistic_p_flare_21d'], isNotNull);
      expect(userFacing.featureSnapshotJson['logistic_7d_cold_start'], 0);
      expect(userFacing.featureSnapshotJson['logistic_14d_cold_start'], 0);
      expect(userFacing.featureSnapshotJson['logistic_21d_cold_start'], 0);

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );

  // ── Cold-start: logistic_7d_cold_start=1 even when heuristic score is >0 ──
  // Regression guard for the riskScore/100 fallback bug: the cold_start flag
  // must be set so the display layer shows "Learning", not a fake percentage.
  test(
    'cold-start: logistic cold_start flag set to 1 even when heuristic score is non-zero',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'gemma_flares_cold_start_flag_test',
      );
      final database = AppDatabase(
        migrationLoader: (assetPath) async => File(assetPath).readAsString(),
        databaseFactoryOverride: databaseFactoryFfi,
        databaseDirectoryProvider: () async => tempRoot.path,
      );
      final repository = WearableSampleRepository(database: database);
      // Wire in LogisticRiskService with 0 training samples (cold-start).
      final logisticService = LogisticRiskService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-03T08:00:00Z'),
      );
      final service = RiskEngineService(
        repository: repository,
        nowProvider: () => DateTime.parse('2026-04-03T08:00:00Z'),
        logisticRiskService: logisticService,
      );

      // Seed 2 days so baseline is not_ready but a heuristic score can be computed.
      for (var day = 1; day <= 2; day++) {
        final date = '2026-04-${day.toString().padLeft(2, '0')}';
        await repository.upsertDailySummary(
          DailySummaryRecord(
            dateLocal: date,
            summaryJson: const {
              'hrv_sdnn_mean': 45.0,
              'resting_hr_mean': 70.0,
              'sleep_total_minutes': 300, // short sleep → some heuristic points
              'step_count_total': 3000,
            },
            syncQualityScore: 0.5,
            recomputedAt: DateTime.parse('2026-04-03T08:00:00Z'),
          ),
        );
      }
      await repository.updateSyncState(
        sourceName: 'apple_health',
        lastSyncAt: DateTime.parse('2026-04-03T06:00:00Z'),
        lastBackfillStart: DateTime.parse('2026-03-04T06:00:00Z'),
        lastBackfillEnd: DateTime.parse('2026-04-03T06:00:00Z'),
      );

      await service.recomputeDates(const ['2026-04-02']);

      final feature = await repository.getDailyFeatureForDate('2026-04-02');
      expect(
        feature,
        isNotNull,
        reason: 'feature record must exist after recompute',
      );

      // The heuristic risk_v2 score exists and may be > 0 (sparse data, reduced
      // sleep, low steps — normal even on first day with HealthKit history).
      final score = await repository.getLatestUserFacingFlareRiskScore();
      expect(
        score,
        isNotNull,
        reason: 'heuristic score must exist after recompute',
      );

      // THE CRITICAL ASSERTION: cold_start flag must be 1 for every logistic horizon.
      // This is what prevents the display layer from using riskScore/100 as a
      // probability fallback and showing a fake "25% flare chance".
      for (final horizon in LogisticRiskService.horizons) {
        final coldStartFlag =
            (feature!.featureJson['logistic_${horizon}d_cold_start'] as num?)
                ?.toInt();
        expect(
          coldStartFlag,
          equals(1),
          reason:
              'logistic_${horizon}d_cold_start must be 1 when trainingSamples < 14',
        );
      }

      // Calibrated probabilities stored in featureJson must reflect the baseline
      // prior (~0.119), not an inflated 0.5-pulled value (~0.367).
      // Any stored logistic_p_flare_7d must be near the baseline, not near 0.37.
      final storedP7 =
          (feature!.featureJson['logistic_p_flare_7d'] as num?)?.toDouble();
      if (storedP7 != null) {
        expect(
          storedP7,
          lessThan(0.25),
          reason:
              'cold-start stored probability must reflect baseline prior (~0.119), not inflated ~0.367',
        );
      }

      await database.close();
      await tempRoot.delete(recursive: true);
    },
  );
}

Future<void> _insertContextSamples(WearableSampleRepository repository) async {
  const normalizer = WearableNormalizationService();
  final importedAt = DateTime.parse('2026-04-15T13:00:00Z');
  await repository.upsertSamples([
    ...normalizer
        .normalizeBatch(
          metricType: HealthMetricType.workout,
          samples: [
            _sample(
              type: HealthMetricType.workout,
              value: 45,
              vendorId: 'workout-risk',
              start: DateTime.parse('2026-04-15T10:00:00Z'),
              end: DateTime.parse('2026-04-15T10:45:00Z'),
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
              vendorId: 'hr-risk',
              start: DateTime.parse('2026-04-15T10:10:00Z'),
            ),
          ],
          importedAt: importedAt,
        )
        .samples,
  ]);
}

HealthSampleDto _sample({
  required HealthMetricType type,
  required double value,
  required String vendorId,
  required DateTime start,
  DateTime? end,
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
    metadata: const {},
  );
}

class _DeterministicHighProbLogisticService extends LogisticRiskService {
  _DeterministicHighProbLogisticService({required super.repository});

  @override
  Future<List<LogisticPrediction>> recomputeForDateWithFeatures(
    String date,
    Map<String, Object?> riskFeatureJson,
  ) async {
    final predictions = <LogisticPrediction>[];
    for (final horizon in LogisticRiskService.horizons) {
      predictions.add(
        LogisticPrediction(
          modelKey: 'fake_inflammatory_${horizon}d',
          horizonDays: horizon,
          flareType: 'inflammatory',
          probability: 0.96,
          trainingSamples: 48,
        ),
      );
      predictions.add(
        LogisticPrediction(
          modelKey: 'fake_symptomatic_${horizon}d',
          horizonDays: horizon,
          flareType: 'symptomatic',
          probability: 0.93,
          trainingSamples: 48,
        ),
      );
    }
    return predictions;
  }
}
