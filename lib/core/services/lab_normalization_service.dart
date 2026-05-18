// =============================================================================
// LabNormalizationService — pure, stateless unit conversion for lab values
// =============================================================================
// Converts raw user-entered lab units to canonical units used by
// LabRiskContributionService. No DB access. Fully unit-testable.
//
// Paper reference: Hirten et al., Gastroenterology 2025 (Mount-Sinai IBD
// Forecast Study). Canonical thresholds: CRP 5 mg/dL, ESR 30 mm/h, FC 150 μg/g.
// =============================================================================

import '../database/wearable_sample_repository.dart';

class LabNormalizationService {
  const LabNormalizationService();

  /// Canonical output unit per labType.
  static const Map<String, String> canonicalUnit = {
    'crp': 'mg/dL',
    'esr': 'mm/h',
    'fc': 'μg/g',
    'albumin': 'g/dL',
    'hemoglobin': 'g/dL',
    'vitamin_d': 'ng/mL',
    'wbc': 'K/μL',
    'platelet': 'K/μL',
    'ferritin': 'ng/mL',
  };

  /// Paper biomarker types used in Hirten et al. Gastroenterology 2025.
  static const Set<String> paperBiomarkers = {'crp', 'esr', 'fc'};

  /// Returns value in canonical unit, or null if unit is unrecognized.
  double? normalize({
    required double value,
    required String rawUnit,
    required String labType,
  }) {
    final u = rawUnit.trim().toLowerCase();
    switch (labType) {
      case 'crp':
        return _normalizeCrp(value, u);
      case 'esr':
        return _normalizeEsr(value, u);
      case 'fc':
        return _normalizeFc(value, u);
      case 'albumin':
        return _normalizeAlbumin(value, u);
      case 'hemoglobin':
        return _normalizeHemoglobin(value, u);
      case 'vitamin_d':
        return _normalizeVitaminD(value, u);
      case 'wbc':
      case 'platelet':
        return _normalizeKuL(value, u);
      case 'ferritin':
        return _normalizeFerritin(value, u);
      default:
        return null;
    }
  }

  /// For paper biomarkers: returns the record with the highest normalized value
  /// (worst-case semantics — most clinically significant wins).
  /// For non-paper: returns the record with the most recent updatedAt.
  /// Throws [ArgumentError] if [sameTypeSameDay] is empty.
  LabValueRecord resolveConflict(List<LabValueRecord> sameTypeSameDay) {
    if (sameTypeSameDay.isEmpty) {
      throw ArgumentError('sameTypeSameDay must not be empty');
    }
    if (sameTypeSameDay.length == 1) return sameTypeSameDay.first;

    final labType = sameTypeSameDay.first.labType;
    if (paperBiomarkers.contains(labType)) {
      // Highest normalized value wins (paper biomarkers: worst case)
      LabValueRecord best = sameTypeSameDay.first;
      double bestNormalized = normalize(
            value: best.unitNormalizedValue ?? best.valueNumeric,
            rawUnit: best.unitNormalizedUnit ?? best.unit,
            labType: labType,
          ) ??
          best.unitNormalizedValue ??
          best.valueNumeric;
      for (final record in sameTypeSameDay.skip(1)) {
        final v = normalize(
              value: record.unitNormalizedValue ?? record.valueNumeric,
              rawUnit: record.unitNormalizedUnit ?? record.unit,
              labType: labType,
            ) ??
            record.unitNormalizedValue ??
            record.valueNumeric;
        if (v > bestNormalized) {
          best = record;
          bestNormalized = v;
        }
      }
      return best;
    } else {
      // Most recent updatedAt wins (non-paper: latest data)
      return sameTypeSameDay.reduce(
        (a, b) => a.updatedAt.isAfter(b.updatedAt) ? a : b,
      );
    }
  }

  // ── CRP: canonical mg/dL ────────────────────────────────────────────────────
  double? _normalizeCrp(double value, String u) {
    if (u == 'mg/dl') return value;
    if (u == 'mg/l') return value / 10.0;
    if (u == 'nmol/l') return value * 0.010;
    return null;
  }

  // ── ESR: canonical mm/h ─────────────────────────────────────────────────────
  double? _normalizeEsr(double value, String u) {
    if (u == 'mm/h' || u == 'mm/hr') return value;
    return null;
  }

  // ── FC (fecal calprotectin): canonical μg/g ──────────────────────────────────
  double? _normalizeFc(double value, String u) {
    // μg/g ≡ ug/g ≡ mg/kg
    if (u == 'μg/g' || u == 'ug/g' || u == 'mg/kg') return value;
    if (u == 'mg/g') return value * 1000.0;
    return null;
  }

  // ── Albumin: canonical g/dL ─────────────────────────────────────────────────
  double? _normalizeAlbumin(double value, String u) {
    if (u == 'g/dl') return value;
    if (u == 'g/l') return value / 10.0;
    return null;
  }

  // ── Hemoglobin: canonical g/dL ──────────────────────────────────────────────
  double? _normalizeHemoglobin(double value, String u) {
    if (u == 'g/dl') return value;
    if (u == 'g/l') return value / 10.0;
    return null;
  }

  // ── Vitamin D: canonical ng/mL ──────────────────────────────────────────────
  double? _normalizeVitaminD(double value, String u) {
    if (u == 'ng/ml') return value;
    if (u == 'nmol/l') return value / 2.496; // 1 nmol/L = 0.4006 ng/mL
    return null;
  }

  // ── K/μL (WBC, platelet) ────────────────────────────────────────────────────
  double? _normalizeKuL(double value, String u) {
    if (u == 'k/μl' || u == 'k/ul' || u == '10^3/μl' || u == '10^3/ul') {
      return value;
    }
    if (u == '/μl' || u == '/ul') return value / 1000.0;
    return null;
  }

  // ── Ferritin: canonical ng/mL ───────────────────────────────────────────────
  double? _normalizeFerritin(double value, String u) {
    if (u == 'ng/ml' || u == 'μg/l' || u == 'ug/l') return value;
    return null;
  }
}
