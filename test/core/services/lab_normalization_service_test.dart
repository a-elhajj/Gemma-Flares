// ignore_for_file: lines_longer_than_80_chars
import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/wearable_sample_repository.dart';
import 'package:gemma_flares/core/services/lab_normalization_service.dart';

LabValueRecord _lab({
  required String labType,
  required double value,
  required String unit,
  String? drawnDate,
  DateTime? updatedAt,
}) {
  final now = DateTime.utc(2026, 5, 13);
  return LabValueRecord(
    drawnDate: drawnDate ?? '2026-05-13',
    labType: labType,
    valueNumeric: value,
    unit: unit,
    createdAt: now,
    updatedAt: updatedAt ?? now,
  );
}

void main() {
  const sut = LabNormalizationService();

  // ── CRP unit conversions ────────────────────────────────────────────────────

  group('CRP normalize', () {
    test('mg/dL identity', () {
      expect(
        sut.normalize(value: 5.0, rawUnit: 'mg/dL', labType: 'crp'),
        closeTo(5.0, 0.001),
      );
    });
    test('mg/dL case insensitive', () {
      expect(
        sut.normalize(value: 5.0, rawUnit: 'MG/DL', labType: 'crp'),
        closeTo(5.0, 0.001),
      );
    });
    test('mg/dL whitespace trimmed', () {
      expect(
        sut.normalize(value: 5.0, rawUnit: ' mg/dL ', labType: 'crp'),
        closeTo(5.0, 0.001),
      );
    });
    test('mg/L → mg/dL ÷10', () {
      expect(
        sut.normalize(value: 50.0, rawUnit: 'mg/L', labType: 'crp'),
        closeTo(5.0, 0.001),
      );
    });
    test('mg/L case insensitive', () {
      expect(
        sut.normalize(value: 100.0, rawUnit: 'MG/L', labType: 'crp'),
        closeTo(10.0, 0.001),
      );
    });
    test('nmol/L → mg/dL ×0.010', () {
      expect(
        sut.normalize(value: 500.0, rawUnit: 'nmol/L', labType: 'crp'),
        closeTo(5.0, 0.001),
      );
    });
    test('nmol/L small value', () {
      expect(
        sut.normalize(value: 100.0, rawUnit: 'nmol/L', labType: 'crp'),
        closeTo(1.0, 0.001),
      );
    });
    test('unrecognized unit → null', () {
      expect(sut.normalize(value: 5.0, rawUnit: 'g/L', labType: 'crp'), isNull);
    });
    test('zero value', () {
      expect(
        sut.normalize(value: 0.0, rawUnit: 'mg/dL', labType: 'crp'),
        closeTo(0.0, 0.001),
      );
    });
    test('very large value', () {
      expect(
        sut.normalize(value: 10000.0, rawUnit: 'mg/L', labType: 'crp'),
        closeTo(1000.0, 0.001),
      );
    });
  });

  // ── ESR unit conversions ────────────────────────────────────────────────────

  group('ESR normalize', () {
    test('mm/h identity', () {
      expect(
        sut.normalize(value: 30.0, rawUnit: 'mm/h', labType: 'esr'),
        closeTo(30.0, 0.001),
      );
    });
    test('mm/hr accepted', () {
      expect(
        sut.normalize(value: 30.0, rawUnit: 'mm/hr', labType: 'esr'),
        closeTo(30.0, 0.001),
      );
    });
    test('MM/H case insensitive', () {
      expect(
        sut.normalize(value: 30.0, rawUnit: 'MM/H', labType: 'esr'),
        closeTo(30.0, 0.001),
      );
    });
    test('unrecognized unit → null', () {
      expect(
        sut.normalize(value: 30.0, rawUnit: 'mm/min', labType: 'esr'),
        isNull,
      );
    });
  });

  // ── FC unit conversions ─────────────────────────────────────────────────────

  group('FC normalize', () {
    test('μg/g identity', () {
      expect(
        sut.normalize(value: 320.0, rawUnit: 'μg/g', labType: 'fc'),
        closeTo(320.0, 0.001),
      );
    });
    test('ug/g == μg/g', () {
      expect(
        sut.normalize(value: 320.0, rawUnit: 'ug/g', labType: 'fc'),
        closeTo(320.0, 0.001),
      );
    });
    test('mg/kg == μg/g', () {
      expect(
        sut.normalize(value: 320.0, rawUnit: 'mg/kg', labType: 'fc'),
        closeTo(320.0, 0.001),
      );
    });
    test('mg/g → μg/g ×1000', () {
      expect(
        sut.normalize(value: 0.32, rawUnit: 'mg/g', labType: 'fc'),
        closeTo(320.0, 0.001),
      );
    });
    test('ug/g case insensitive', () {
      expect(
        sut.normalize(value: 150.0, rawUnit: 'UG/G', labType: 'fc'),
        closeTo(150.0, 0.001),
      );
    });
    test('unrecognized unit → null', () {
      expect(
        sut.normalize(value: 320.0, rawUnit: 'ng/mL', labType: 'fc'),
        isNull,
      );
    });
    test('mg/g large value', () {
      expect(
        sut.normalize(value: 0.5, rawUnit: 'mg/g', labType: 'fc'),
        closeTo(500.0, 0.001),
      );
    });
  });

  // ── Albumin unit conversions ────────────────────────────────────────────────

  group('Albumin normalize', () {
    test('g/dL identity', () {
      expect(
        sut.normalize(value: 3.5, rawUnit: 'g/dL', labType: 'albumin'),
        closeTo(3.5, 0.001),
      );
    });
    test('g/L → g/dL ÷10', () {
      expect(
        sut.normalize(value: 35.0, rawUnit: 'g/L', labType: 'albumin'),
        closeTo(3.5, 0.001),
      );
    });
    test('G/DL case insensitive', () {
      expect(
        sut.normalize(value: 4.0, rawUnit: 'G/DL', labType: 'albumin'),
        closeTo(4.0, 0.001),
      );
    });
    test('unrecognized unit → null', () {
      expect(
        sut.normalize(value: 3.5, rawUnit: 'mg/dL', labType: 'albumin'),
        isNull,
      );
    });
  });

  // ── Hemoglobin unit conversions ─────────────────────────────────────────────

  group('Hemoglobin normalize', () {
    test('g/dL identity', () {
      expect(
        sut.normalize(value: 13.5, rawUnit: 'g/dL', labType: 'hemoglobin'),
        closeTo(13.5, 0.001),
      );
    });
    test('g/L → g/dL ÷10', () {
      expect(
        sut.normalize(value: 135.0, rawUnit: 'g/L', labType: 'hemoglobin'),
        closeTo(13.5, 0.001),
      );
    });
    test('G/L case insensitive', () {
      expect(
        sut.normalize(value: 120.0, rawUnit: 'G/L', labType: 'hemoglobin'),
        closeTo(12.0, 0.001),
      );
    });
    test('unrecognized unit → null', () {
      expect(
        sut.normalize(value: 13.5, rawUnit: 'g/mL', labType: 'hemoglobin'),
        isNull,
      );
    });
  });

  // ── Vitamin D unit conversions ──────────────────────────────────────────────

  group('Vitamin D normalize', () {
    test('ng/mL identity', () {
      expect(
        sut.normalize(value: 25.0, rawUnit: 'ng/mL', labType: 'vitamin_d'),
        closeTo(25.0, 0.001),
      );
    });
    test('ng/mL case insensitive', () {
      expect(
        sut.normalize(value: 25.0, rawUnit: 'NG/ML', labType: 'vitamin_d'),
        closeTo(25.0, 0.001),
      );
    });
    test('nmol/L → ng/mL ÷2.496', () {
      expect(
        sut.normalize(value: 62.4, rawUnit: 'nmol/L', labType: 'vitamin_d'),
        closeTo(25.0, 0.1),
      );
    });
    test('unrecognized unit → null', () {
      expect(
        sut.normalize(value: 25.0, rawUnit: 'μg/mL', labType: 'vitamin_d'),
        isNull,
      );
    });
  });

  // ── Unknown lab type ────────────────────────────────────────────────────────

  test('unknown labType → null', () {
    expect(
      sut.normalize(value: 100.0, rawUnit: 'mg/dL', labType: 'mystery_marker'),
      isNull,
    );
  });

  // ── Conflict resolution ─────────────────────────────────────────────────────

  group('resolveConflict', () {
    test('throws ArgumentError on empty list', () {
      expect(() => sut.resolveConflict([]), throwsArgumentError);
    });

    test('single element returns that element', () {
      final lab = _lab(labType: 'crp', value: 5.0, unit: 'mg/dL');
      expect(sut.resolveConflict([lab]), same(lab));
    });

    test('paper biomarker (fc): highest normalized value wins', () {
      final lo = _lab(labType: 'fc', value: 100.0, unit: 'μg/g');
      final hi = _lab(labType: 'fc', value: 320.0, unit: 'μg/g');
      expect(sut.resolveConflict([lo, hi]), same(hi));
      expect(sut.resolveConflict([hi, lo]), same(hi));
    });

    test('paper biomarker (fc): highest with unit conversion wins', () {
      final loMgG = _lab(
        labType: 'fc',
        value: 0.15,
        unit: 'mg/g',
      ); // = 150 μg/g
      final hiUgG = _lab(labType: 'fc', value: 320.0, unit: 'μg/g');
      expect(sut.resolveConflict([loMgG, hiUgG]), same(hiUgG));
    });

    test('paper biomarker (crp): highest wins', () {
      final lo = _lab(labType: 'crp', value: 3.0, unit: 'mg/dL');
      final hi = _lab(labType: 'crp', value: 15.0, unit: 'mg/dL');
      expect(sut.resolveConflict([lo, hi]), same(hi));
    });

    test('paper biomarker (esr): highest wins', () {
      final lo = _lab(labType: 'esr', value: 20.0, unit: 'mm/h');
      final hi = _lab(labType: 'esr', value: 55.0, unit: 'mm/h');
      expect(sut.resolveConflict([lo, hi]), same(hi));
    });

    test('non-paper biomarker: most recent updatedAt wins', () {
      final old = _lab(
        labType: 'albumin',
        value: 3.5,
        unit: 'g/dL',
        updatedAt: DateTime.utc(2026, 5, 1),
      );
      final newer = _lab(
        labType: 'albumin',
        value: 3.2,
        unit: 'g/dL',
        updatedAt: DateTime.utc(2026, 5, 10),
      );
      expect(sut.resolveConflict([old, newer]), same(newer));
      expect(sut.resolveConflict([newer, old]), same(newer));
    });

    test('non-paper biomarker: most recent wins even with lower value', () {
      final old = _lab(
        labType: 'hemoglobin',
        value: 14.0,
        unit: 'g/dL',
        updatedAt: DateTime.utc(2026, 4, 1),
      );
      final newer = _lab(
        labType: 'hemoglobin',
        value: 11.0,
        unit: 'g/dL',
        updatedAt: DateTime.utc(2026, 5, 10),
      );
      expect(sut.resolveConflict([old, newer]), same(newer));
    });

    test('20 FC values same day — highest wins', () {
      final labs = List.generate(
        20,
        (i) =>
            _lab(labType: 'fc', value: (i * 10 + 10).toDouble(), unit: 'μg/g'),
      );
      final winner = sut.resolveConflict(labs);
      expect(winner.valueNumeric, equals(200.0)); // highest = 10+10*19 = 200
    });

    test(
      'paper biomarker: CRP in mg/L vs mg/dL — normalized comparison correct',
      () {
        // 50 mg/L = 5 mg/dL; 6 mg/dL should win
        final mgL = _lab(
          labType: 'crp',
          value: 50.0,
          unit: 'mg/L',
        ); // = 5 mg/dL
        final mgDL = _lab(labType: 'crp', value: 6.0, unit: 'mg/dL');
        expect(sut.resolveConflict([mgL, mgDL]), same(mgDL));
      },
    );
  });

  // ── canonicalUnit map completeness ─────────────────────────────────────────

  test('canonicalUnit has entry for all expected lab types', () {
    const expected = [
      'crp',
      'esr',
      'fc',
      'albumin',
      'hemoglobin',
      'vitamin_d',
      'wbc',
      'platelet',
      'ferritin',
    ];
    for (final t in expected) {
      expect(
        LabNormalizationService.canonicalUnit.containsKey(t),
        isTrue,
        reason: 'missing $t',
      );
    }
  });

  test('paperBiomarkers contains crp, esr, fc', () {
    expect(
      LabNormalizationService.paperBiomarkers,
      containsAll(['crp', 'esr', 'fc']),
    );
  });

  // ── Edge cases ─────────────────────────────────────────────────────────────

  test('mg/dL with extra spaces normalizes correctly for CRP', () {
    expect(
      sut.normalize(value: 5.0, rawUnit: '  mg/dL  ', labType: 'crp'),
      closeTo(5.0, 0.001),
    );
  });

  test('mixed-case mg/L CRP normalizes to mg/dL', () {
    expect(
      sut.normalize(value: 80.0, rawUnit: 'Mg/L', labType: 'crp'),
      closeTo(8.0, 0.001),
    );
  });

  test('ferritin ng/mL identity', () {
    expect(
      sut.normalize(value: 200.0, rawUnit: 'ng/mL', labType: 'ferritin'),
      closeTo(200.0, 0.001),
    );
  });

  test('ferritin ug/l = ng/mL identity', () {
    expect(
      sut.normalize(value: 200.0, rawUnit: 'ug/l', labType: 'ferritin'),
      closeTo(200.0, 0.001),
    );
  });

  test('WBC K/μL identity', () {
    expect(
      sut.normalize(value: 7.5, rawUnit: 'K/μL', labType: 'wbc'),
      closeTo(7.5, 0.001),
    );
  });

  test('WBC K/uL accepted', () {
    expect(
      sut.normalize(value: 7.5, rawUnit: 'K/uL', labType: 'wbc'),
      closeTo(7.5, 0.001),
    );
  });

  test('WBC /μL per-microliter → K/μL ÷1000', () {
    expect(
      sut.normalize(value: 7500.0, rawUnit: '/μL', labType: 'wbc'),
      closeTo(7.5, 0.001),
    );
  });
}
