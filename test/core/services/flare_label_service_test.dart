import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/flare_label_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ─────────────────────────────────────────────────────────────────────────────
// FlareLabelService tests
//
// Exercises the exact paper flare definitions from Hirten et al. 2025:
//   Inflammatory: CRP > 5 mg/dL OR ESR > 30 mm/h OR FC > 150 μg/g
//                 within ±7-day window of label date
//   Symptomatic:  ≥4 surveys in 7-day window AND ≥2 meeting threshold
//                 CD: score ≥ 8; UC: score > 1 OR bleeding > 0 OR stool > 1
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  sqfliteFfiInit();

  String marchDate(int day) => '2026-03-${day.toString().padLeft(2, '0')}';

  Future<(WearableSampleRepository, FlareLabelService)> setup() async {
    final tempDir = await Directory.systemTemp.createTemp(
      'gemma_flares_flare_test',
    );
    final database = AppDatabase(
      migrationLoader: (path) async => File(path).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempDir.path,
    );
    final repo = WearableSampleRepository(database: database);
    final service = FlareLabelService(
      repository: repo,
      nowProvider: () => DateTime.parse('2026-04-01T12:00:00Z'),
    );
    return (repo, service);
  }

  Future<LabValueRecord> labRecord(
    String date,
    String type,
    double value,
  ) async {
    final thresholds = {'crp': 5.0, 'esr': 30.0, 'fc': 150.0};
    final units = {'crp': 'mg/dL', 'esr': 'mm/h', 'fc': 'μg/g'};
    return LabValueRecord(
      drawnDate: date,
      labType: type,
      valueNumeric: value,
      unit: units[type]!,
      referenceHigh: thresholds[type],
      createdAt: DateTime.parse('${date}T10:00:00Z'),
      updatedAt: DateTime.parse('${date}T10:00:00Z'),
    );
  }

  Future<Pro2SurveyRecord> pro2Record(
    String date,
    String diseaseType,
    double score, {
    int bleeding = 0,
    int stool = 0,
    String? scoreVersion,
  }) async {
    return Pro2SurveyRecord(
      surveyDate: date,
      diseaseType: diseaseType,
      cdAbdominalPain: null,
      cdStoolFrequency: diseaseType == 'CD' ? null : stool,
      ucRectalBleeding: diseaseType == 'UC' ? bleeding : null,
      ucStoolFrequency: diseaseType == 'UC' ? stool : null,
      pro2Score: score,
      isFlare: diseaseType == 'CD'
          ? score >= 8
          : score > 1 || bleeding > 0 || stool > 1,
      scoreVersion: scoreVersion ??
          (diseaseType == 'UC'
              ? Pro2SurveyRecord.ucV1BleedingStool
              : Pro2SurveyRecord.cdV1Pain7Stool1),
      createdAt: DateTime.parse('${date}T09:00:00Z'),
    );
  }

  // ── Inflammatory flare tests ──────────────────────────────────────────────

  group('Inflammatory flare — CRP', () {
    test('CRP > 5 on date marks ±7 day window as inflammatory', () async {
      final (repo, service) = await setup();
      await repo.upsertLabValue(await labRecord('2026-03-20', 'crp', 6.5));

      await service.recomputeLabels(
        startDate: '2026-03-20',
        endDate: '2026-03-20',
      );

      final label = await repo.getFlareLabel('2026-03-20');
      expect(label, isNotNull);
      expect(label!.inflammatoryFlare, isTrue);
      expect(label.labelSource, 'lab');
    });

    test(
      'CRP = 5.0 (not above threshold) does NOT mark inflammatory',
      () async {
        final (repo, service) = await setup();
        await repo.upsertLabValue(await labRecord('2026-03-20', 'crp', 5.0));

        await service.recomputeLabels(
          startDate: '2026-03-20',
          endDate: '2026-03-20',
        );

        final label = await repo.getFlareLabel('2026-03-20');
        expect(label?.inflammatoryFlare, isFalse);
      },
    );

    test(
      'CRP > 5 on day-6 affects label 6 days later (within 7d window)',
      () async {
        final (repo, service) = await setup();
        await repo.upsertLabValue(await labRecord('2026-03-14', 'crp', 8.0));

        // 6 days later should still be in the ±7d window
        await service.recomputeLabels(
          startDate: '2026-03-20',
          endDate: '2026-03-20',
        );

        final label = await repo.getFlareLabel('2026-03-20');
        expect(label?.inflammatoryFlare, isTrue);
      },
    );

    test(
      'CRP > 5 on day-8 does NOT affect label (outside 7d window)',
      () async {
        final (repo, service) = await setup();
        await repo.upsertLabValue(await labRecord('2026-03-12', 'crp', 8.0));

        await service.recomputeLabels(
          startDate: '2026-03-20',
          endDate: '2026-03-20',
        );

        final label = await repo.getFlareLabel('2026-03-20');
        expect(label?.inflammatoryFlare, isFalse);
      },
    );
  });

  group('Inflammatory flare — ESR and FC', () {
    test('ESR > 30 marks inflammatory flare', () async {
      final (repo, service) = await setup();
      await repo.upsertLabValue(await labRecord('2026-03-20', 'esr', 35.0));

      await service.recomputeLabels(
        startDate: '2026-03-20',
        endDate: '2026-03-20',
      );

      expect(
        (await repo.getFlareLabel('2026-03-20'))?.inflammatoryFlare,
        isTrue,
      );
    });

    test('FC > 150 marks inflammatory flare', () async {
      final (repo, service) = await setup();
      await repo.upsertLabValue(await labRecord('2026-03-20', 'fc', 200.0));

      await service.recomputeLabels(
        startDate: '2026-03-20',
        endDate: '2026-03-20',
      );

      expect(
        (await repo.getFlareLabel('2026-03-20'))?.inflammatoryFlare,
        isTrue,
      );
    });

    test('ESR = 30.0 (at threshold) does NOT mark inflammatory', () async {
      final (repo, service) = await setup();
      await repo.upsertLabValue(await labRecord('2026-03-20', 'esr', 30.0));

      await service.recomputeLabels(
        startDate: '2026-03-20',
        endDate: '2026-03-20',
      );

      expect(
        (await repo.getFlareLabel('2026-03-20'))?.inflammatoryFlare,
        isFalse,
      );
    });
  });

  // ── Symptomatic flare tests ───────────────────────────────────────────────

  group('Symptomatic flare — CD PRO-2', () {
    test('4 surveys with 2 CD scores ≥ 8 marks symptomatic flare', () async {
      final (repo, service) = await setup();
      // 4 surveys in last 7 days, 2 meeting CD threshold (≥8)
      for (var i = 0; i < 2; i++) {
        await repo.insertPro2Survey(
          await pro2Record(marchDate(17 + i), 'CD', 10.0),
        );
      }
      for (var i = 0; i < 2; i++) {
        await repo.insertPro2Survey(
          await pro2Record(marchDate(19 + i), 'CD', 4.0),
        ); // not flare
      }

      await service.recomputeLabels(
        startDate: '2026-03-20',
        endDate: '2026-03-20',
      );

      expect(
        (await repo.getFlareLabel('2026-03-20'))?.symptomaticFlare,
        isTrue,
      );
    });

    test('only 3 surveys (below minimum 4) → no symptomatic flare', () async {
      final (repo, service) = await setup();
      for (var i = 0; i < 3; i++) {
        await repo.insertPro2Survey(
          await pro2Record(marchDate(18 + i), 'CD', 10.0),
        );
      }

      await service.recomputeLabels(
        startDate: '2026-03-20',
        endDate: '2026-03-20',
      );

      expect(
        (await repo.getFlareLabel('2026-03-20'))?.symptomaticFlare,
        isFalse,
      );
    });

    test('4 surveys but only 1 CD score ≥ 8 → no symptomatic flare', () async {
      final (repo, service) = await setup();
      await repo.insertPro2Survey(
        await pro2Record('2026-03-17', 'CD', 10.0),
      ); // flare
      for (var i = 0; i < 3; i++) {
        await repo.insertPro2Survey(
          await pro2Record(marchDate(18 + i), 'CD', 3.0),
        ); // not flare
      }

      await service.recomputeLabels(
        startDate: '2026-03-20',
        endDate: '2026-03-20',
      );

      expect(
        (await repo.getFlareLabel('2026-03-20'))?.symptomaticFlare,
        isFalse,
      );
    });

    test(
      'new CD pain2 scoring does not silently use legacy pain7 math',
      () async {
        final (repo, service) = await setup();
        for (var i = 0; i < 4; i++) {
          await repo.insertPro2Survey(
            Pro2SurveyRecord(
              surveyDate: marchDate(17 + i),
              diseaseType: 'CD',
              cdAbdominalPain: 2,
              cdStoolFrequency: 2,
              pro2Score: 6,
              isFlare: false,
              scoreVersion: Pro2SurveyRecord.cdV2Pain2Stool1,
              createdAt: DateTime.parse('${marchDate(17 + i)}T09:00:00Z'),
            ),
          );
        }

        await service.recomputeLabels(
          startDate: '2026-03-20',
          endDate: '2026-03-20',
        );

        expect(
          (await repo.getFlareLabel('2026-03-20'))?.symptomaticFlare,
          isFalse,
        );
      },
    );

    test(
      'legacy CD pain7 scoring remains preserved for historical rows',
      () async {
        final (repo, service) = await setup();
        for (var i = 0; i < 2; i++) {
          await repo.insertPro2Survey(
            Pro2SurveyRecord(
              surveyDate: marchDate(17 + i),
              diseaseType: 'CD',
              cdAbdominalPain: 1,
              cdStoolFrequency: 1,
              pro2Score: 8,
              isFlare: true,
              scoreVersion: Pro2SurveyRecord.cdV1Pain7Stool1,
              createdAt: DateTime.parse('${marchDate(17 + i)}T09:00:00Z'),
            ),
          );
        }
        for (var i = 0; i < 2; i++) {
          await repo.insertPro2Survey(
            Pro2SurveyRecord(
              surveyDate: marchDate(19 + i),
              diseaseType: 'CD',
              cdAbdominalPain: 1,
              cdStoolFrequency: 1,
              pro2Score: 3,
              isFlare: false,
              scoreVersion: Pro2SurveyRecord.cdV2Pain2Stool1,
              createdAt: DateTime.parse('${marchDate(19 + i)}T09:00:00Z'),
            ),
          );
        }

        await service.recomputeLabels(
          startDate: '2026-03-20',
          endDate: '2026-03-20',
        );

        expect(
          (await repo.getFlareLabel('2026-03-20'))?.symptomaticFlare,
          isTrue,
        );
      },
    );
  });

  group('Symptomatic flare — UC PRO-2', () {
    test('UC score > 1 counts as flare survey', () async {
      final (repo, service) = await setup();
      for (var i = 0; i < 2; i++) {
        await repo.insertPro2Survey(
          await pro2Record(marchDate(17 + i), 'UC', 2.0, stool: 2),
        ); // flare
      }
      for (var i = 0; i < 2; i++) {
        await repo.insertPro2Survey(
          await pro2Record(marchDate(19 + i), 'UC', 1.0),
        ); // not flare
      }

      await service.recomputeLabels(
        startDate: '2026-03-20',
        endDate: '2026-03-20',
      );

      expect(
        (await repo.getFlareLabel('2026-03-20'))?.symptomaticFlare,
        isTrue,
      );
    });

    test('UC rectal bleeding > 0 triggers flare threshold', () async {
      final (repo, service) = await setup();
      // 4 surveys, 2 with bleeding > 0
      for (var i = 0; i < 2; i++) {
        await repo.insertPro2Survey(
          await pro2Record(marchDate(17 + i), 'UC', 0.0, bleeding: 1),
        );
      }
      for (var i = 0; i < 2; i++) {
        await repo.insertPro2Survey(
          await pro2Record(marchDate(19 + i), 'UC', 1.0),
        ); // not flare
      }

      await service.recomputeLabels(
        startDate: '2026-03-20',
        endDate: '2026-03-20',
      );

      expect(
        (await repo.getFlareLabel('2026-03-20'))?.symptomaticFlare,
        isTrue,
      );
    });
  });

  // ── Combined flare ────────────────────────────────────────────────────────

  group('Clinical flare — endoscopy window', () {
    test(
      'active endoscopy marks procedure date through 30 days as clinical flare',
      () async {
        final (repo, service) = await setup();
        await repo.insertEndoscopyRecord(
          EndoscopyRecord(
            procedureDate: '2026-03-20',
            procedureType: 'colonoscopy',
            mayoEndoscopicScore: 2,
            biopsiesTaken: true,
            biopsyResult: 'active_inflammation',
            createdAt: DateTime.parse('2026-03-20T11:00:00Z'),
          ),
        );

        await service.recomputeLabels(
          startDate: '2026-03-20',
          endDate: '2026-04-19',
        );

        expect((await repo.getFlareLabel('2026-03-20'))?.clinicalFlare, isTrue);
        expect((await repo.getFlareLabel('2026-04-19'))?.clinicalFlare, isTrue);
        expect(
          (await repo.getFlareLabel('2026-03-20'))?.labelSource,
          'endoscopy',
        );
      },
    );

    test(
      'clinical flare does not extend beyond 30 days after procedure',
      () async {
        final (repo, service) = await setup();
        await repo.insertEndoscopyRecord(
          EndoscopyRecord(
            procedureDate: '2026-03-20',
            procedureType: 'colonoscopy',
            sesCdScore: 9,
            biopsiesTaken: false,
            createdAt: DateTime.parse('2026-03-20T11:00:00Z'),
          ),
        );

        await service.recomputeLabels(
          startDate: '2026-04-20',
          endDate: '2026-04-20',
        );

        expect(
          (await repo.getFlareLabel('2026-04-20'))?.clinicalFlare,
          isFalse,
        );
      },
    );

    test('non-active procedure does not mark clinical flare', () async {
      final (repo, service) = await setup();
      await repo.insertEndoscopyRecord(
        EndoscopyRecord(
          procedureDate: '2026-03-20',
          procedureType: 'colonoscopy',
          mayoEndoscopicScore: 1,
          biopsiesTaken: true,
          biopsyResult: 'remission',
          createdAt: DateTime.parse('2026-03-20T11:00:00Z'),
        ),
      );

      await service.recomputeLabels(
        startDate: '2026-03-20',
        endDate: '2026-03-20',
      );

      expect((await repo.getFlareLabel('2026-03-20'))?.clinicalFlare, isFalse);
    });
  });

  group('Combined flare', () {
    test(
      'combined flare is true only when both inflammatory AND symptomatic',
      () async {
        final (repo, service) = await setup();
        // Lab: elevated CRP
        await repo.upsertLabValue(await labRecord('2026-03-20', 'crp', 8.0));
        // 4 CD surveys with 2 flare responses
        for (var i = 0; i < 2; i++) {
          await repo.insertPro2Survey(
            await pro2Record(marchDate(17 + i), 'CD', 12.0),
          );
        }
        for (var i = 0; i < 2; i++) {
          await repo.insertPro2Survey(
            await pro2Record(marchDate(19 + i), 'CD', 2.0),
          );
        }

        await service.recomputeLabels(
          startDate: '2026-03-20',
          endDate: '2026-03-20',
        );

        final label = await repo.getFlareLabel('2026-03-20');
        expect(label?.inflammatoryFlare, isTrue);
        expect(label?.symptomaticFlare, isTrue);
        expect(label?.combinedFlare, isTrue);
        expect(label?.labelSource, 'combined');
      },
    );

    test('combined flare is false when only inflammatory', () async {
      final (repo, service) = await setup();
      await repo.upsertLabValue(await labRecord('2026-03-20', 'crp', 8.0));

      await service.recomputeLabels(
        startDate: '2026-03-20',
        endDate: '2026-03-20',
      );

      final label = await repo.getFlareLabel('2026-03-20');
      expect(label?.inflammatoryFlare, isTrue);
      expect(label?.symptomaticFlare, isFalse);
      expect(label?.combinedFlare, isFalse);
    });
  });

  // ── Confidence label ──────────────────────────────────────────────────────
  //
  // PA-002 Improvement 4: PRO-2 corroboration changes the confidence contract.
  // A single lab elevation without symptom corroboration may be non-IBD in
  // origin (viral infection, exercise, lab error). The new contract:
  //   - Lab + corroborating survey within 3d → 'high'
  //   - Lab + corroborating survey 4–7d     → 'medium'
  //   - Lab with NO surveys in ±7d window   → 'low' (lab-only; uncertain)
  //   - No labs, no endoscopy               → 'low'

  group('Confidence (PA-002: PRO-2 corroborated)', () {
    test(
      'high confidence when lab within 3d AND survey corroborates',
      () async {
        final (repo, service) = await setup();
        await repo.upsertLabValue(await labRecord('2026-03-20', 'crp', 8.0));
        // 4 surveys, 2 at flare threshold within ±7d of 2026-03-20
        for (var i = 0; i < 2; i++) {
          await repo.insertPro2Survey(
            await pro2Record(marchDate(17 + i), 'CD', 12.0),
          );
        }
        for (var i = 0; i < 2; i++) {
          await repo.insertPro2Survey(
            await pro2Record(marchDate(19 + i), 'CD', 9.0),
          );
        }

        await service.recomputeLabels(
          startDate: '2026-03-20',
          endDate: '2026-03-20',
        );

        final label = await repo.getFlareLabel('2026-03-20');
        expect(label?.confidence, 'high');
      },
    );

    test(
      'medium confidence when lab 4–7d away AND survey corroborates',
      () async {
        final (repo, service) = await setup();
        await repo.upsertLabValue(await labRecord('2026-03-15', 'crp', 8.0));
        // Survey on 2026-03-18 (3d before label date, within ±7d of lab)
        for (var i = 0; i < 2; i++) {
          await repo.insertPro2Survey(
            await pro2Record(marchDate(17 + i), 'CD', 12.0),
          );
        }
        for (var i = 0; i < 2; i++) {
          await repo.insertPro2Survey(
            await pro2Record(marchDate(19 + i), 'CD', 9.0),
          );
        }

        await service.recomputeLabels(
          startDate: '2026-03-20',
          endDate: '2026-03-20',
        );

        final label = await repo.getFlareLabel('2026-03-20');
        // 5 days away → medium
        expect(label?.confidence, 'medium');
      },
    );

    test(
      'low confidence when lab present but NO surveys in window (PA-002 contract)',
      () async {
        // INTENT: a single lab elevation without symptom corroboration may be
        // non-IBD (viral, exercise, lab error). The system must down-weight this
        // training sample by emitting 'low' confidence, not 'high'/'medium'.
        // This test fails if the lab-only confidence regression is reintroduced.
        final (repo, service) = await setup();
        await repo.upsertLabValue(await labRecord('2026-03-20', 'crp', 8.0));

        await service.recomputeLabels(
          startDate: '2026-03-20',
          endDate: '2026-03-20',
        );

        final label = await repo.getFlareLabel('2026-03-20');
        expect(
          label?.inflammatoryFlare,
          isTrue,
          reason: 'lab signal preserved even without survey corroboration',
        );
        expect(
          label?.confidence,
          'low',
          reason:
              'lab-only inflammatory labels must be down-weighted via low confidence',
        );
      },
    );
  });

  // ── PRO-2 corroboration tests (PA-002 Improvement 4) ─────────────────────
  // Inflammatory flare rule: elevated lab AND (if surveys exist in window)
  // at least one survey at flare threshold. If no surveys exist in window,
  // the label is still set to true (lab signal preserved) but confidence='low'.

  group('PRO-2 corroboration (PA-002 Improvement 4)', () {
    test(
      'elevated lab + flare-threshold survey in window → inflammatory=true',
      () async {
        final (repo, service) = await setup();
        await repo.upsertLabValue(await labRecord('2026-03-20', 'crp', 8.0));
        await repo.insertPro2Survey(await pro2Record('2026-03-19', 'CD', 12.0));

        await service.recomputeLabels(
          startDate: '2026-03-20',
          endDate: '2026-03-20',
        );

        final label = await repo.getFlareLabel('2026-03-20');
        expect(label?.inflammatoryFlare, isTrue);
      },
    );

    test(
      'elevated lab + surveys present but NONE at flare threshold → inflammatory=false',
      () async {
        // INTENT: when surveys exist in window AND none meet flare threshold,
        // the user's own report refutes the lab signal — likely non-IBD.
        final (repo, service) = await setup();
        await repo.upsertLabValue(await labRecord('2026-03-20', 'crp', 8.0));
        for (var i = 0; i < 3; i++) {
          await repo.insertPro2Survey(
            await pro2Record(marchDate(17 + i), 'CD', 2.0),
          );
        }

        await service.recomputeLabels(
          startDate: '2026-03-20',
          endDate: '2026-03-20',
        );

        final label = await repo.getFlareLabel('2026-03-20');
        expect(
          label?.inflammatoryFlare,
          isFalse,
          reason: 'surveys-present-but-none-at-threshold refutes lab signal',
        );
      },
    );

    test(
      'elevated lab + no surveys in window → inflammatory=true, confidence=low',
      () async {
        // INTENT: lab signal preserved when no survey data exists; downstream
        // training can use the low-confidence signal to down-weight the sample.
        final (repo, service) = await setup();
        await repo.upsertLabValue(await labRecord('2026-03-20', 'crp', 8.0));

        await service.recomputeLabels(
          startDate: '2026-03-20',
          endDate: '2026-03-20',
        );

        final label = await repo.getFlareLabel('2026-03-20');
        expect(label?.inflammatoryFlare, isTrue);
        expect(label?.confidence, 'low');
      },
    );
  });
}
