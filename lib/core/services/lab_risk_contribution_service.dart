// =============================================================================
// LabRiskContributionService — deterministic lab-to-risk-score mapping
// =============================================================================
// Pure value computation: takes pre-fetched normalized labs + baselines and
// returns a LabRiskContribution value object for use by RiskEngineService.
//
// Paper reference: Hirten et al., Gastroenterology 2025 (Mount-Sinai IBD
// Forecast Study). Paper biomarker thresholds:
//   FC  ≥ 150 μg/g  (flare threshold)
//   CRP ≥   5 mg/dL (flare threshold)
//   ESR ≥  30 mm/h  (flare threshold)
//
// IBS note: the Hirten cohort was exclusively CD/UC. For IBS patients,
// thresholds are doubled to avoid over-penalizing the non-IBD population.
// =============================================================================

import '../database/wearable_sample_repository.dart';
import 'lab_normalization_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Value object returned by computeContribution
// ─────────────────────────────────────────────────────────────────────────────

class LabRiskContribution {
  const LabRiskContribution({
    required this.points,
    required this.confidenceBoost,
    required this.dominantLabType,
    required this.dominantLabValue,
    required this.dominantLabUnit,
    required this.decayFactor,
    required this.narrativeKey,
    required this.labsPresent,
    required this.contributionJson,
  });

  /// Total lab risk points added to rawScore. Clamped [0, 30].
  final int points;

  /// Confidence boost added to weightedConfidence. In [0, 8].
  final int confidenceBoost;

  /// Which lab type drove the score. 'fc'|'crp'|'esr'|'albumin'|'none'.
  final String dominantLabType;

  /// Normalized value of dominant lab.
  final double dominantLabValue;

  /// Canonical unit of dominant lab.
  final String dominantLabUnit;

  /// Time-based decay factor applied to raw paper points. In [0.0, 1.0].
  final double decayFactor;

  /// Key into Gemma narrative template registry.
  final String narrativeKey;

  /// Whether any valid labs were present in the 30-day window.
  final bool labsPresent;

  /// Full breakdown for contributionJson / audit log.
  final Map<String, Object?> contributionJson;

  static const LabRiskContribution empty = LabRiskContribution(
    points: 0,
    confidenceBoost: 0,
    dominantLabType: 'none',
    dominantLabValue: 0,
    dominantLabUnit: '',
    decayFactor: 0,
    narrativeKey: 'no_labs_available',
    labsPresent: false,
    contributionJson: {},
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────

class LabRiskContributionService {
  const LabRiskContributionService({
    LabNormalizationService normalizationService =
        const LabNormalizationService(),
  }) : _norm = normalizationService;

  final LabNormalizationService _norm;

  /// Computes the lab contribution to flare risk for [dateLocal].
  ///
  /// [candidateLabs] must already be filtered to drawn ≤30 days before
  /// [dateLocal]. [userBaselineByLabType] is the winsorized mean per labType
  /// from historical data (requires ≥3 values to be populated).
  LabRiskContribution computeContribution({
    required String dateLocal,
    required List<LabValueRecord> candidateLabs,
    required Map<String, double> userBaselineByLabType,
    String diagnosisCategory = 'cd', // 'cd'|'uc'|'ic'|'ibs'|'unknown'
    String? userSex, // 'm'|'f'|null
  }) {
    if (candidateLabs.isEmpty) return LabRiskContribution.empty;

    final targetDate = DateTime.tryParse(dateLocal);
    if (targetDate == null) return LabRiskContribution.empty;

    final isIbs = diagnosisCategory == 'ibs';
    // 'unknown': no confirmed diagnosis — apply standard IBD thresholds (same as
    // CD/UC, no IBS 2× multiplier) but reduce confidence by 2 since clinical
    // interpretation is less certain without a confirmed diagnosis. 'ic'
    // (indeterminate colitis) is treated identically to 'cd'/'uc' — no penalty.
    final isDiagnosisUnconfirmed = diagnosisCategory == 'unknown';

    // ── Group by (labType, drawnDate) and resolve conflicts ──────────────────
    final grouped = _groupByTypeAndDate(candidateLabs);
    final resolved = <_ResolvedLab>[];
    for (final entry in grouped.entries) {
      final winner = _norm.resolveConflict(entry.value);
      final normalized = _norm.normalize(
        value: winner.valueNumeric,
        rawUnit: winner.unit,
        labType: winner.labType,
      );
      if (normalized == null) continue; // unrecognized unit
      final drawn = DateTime.tryParse(winner.drawnDate);
      if (drawn == null) continue;
      final daysAgo = targetDate.difference(drawn).inDays;
      if (daysAgo < 0) continue; // future-dated lab — skip
      final decay = _decayFactor(daysAgo);
      resolved.add(
        _ResolvedLab(
          record: winner,
          labType: winner.labType,
          normalizedValue: normalized,
          daysAgo: daysAgo,
          decayFactor: decay,
          unit: LabNormalizationService.canonicalUnit[winner.labType] ??
              winner.unit,
        ),
      );
    }

    if (resolved.isEmpty) return LabRiskContribution.empty;

    // ── Paper biomarker scoring ───────────────────────────────────────────────
    _ResolvedLab? dominantLab;
    int maxPaperRaw = 0;
    final paperDetails = <String, Map<String, Object?>>{};

    for (final lab in resolved) {
      if (!LabNormalizationService.paperBiomarkers.contains(lab.labType)) {
        continue;
      }
      int rawPoints = _paperRawPoints(
        lab.labType,
        lab.normalizedValue,
        isIbs: isIbs,
      );

      // Baseline-relative attenuation
      final baseline = userBaselineByLabType[lab.labType];
      if (baseline != null && baseline > 0) {
        if (lab.normalizedValue < baseline) {
          rawPoints = 0; // below personal normal — no contribution
        } else {
          final relativeDelta =
              (lab.normalizedValue - baseline).abs() / baseline;
          if (relativeDelta < 0.20) {
            rawPoints = (rawPoints * 0.4).round(); // within 20% of normal
          }
        }
      }

      final decayedPoints = (rawPoints * lab.decayFactor).round();
      paperDetails[lab.labType] = {
        'raw_points': rawPoints,
        'decayed_points': decayedPoints,
        'normalized_value': lab.normalizedValue,
        'unit': lab.unit,
        'days_ago': lab.daysAgo,
        'decay_factor': lab.decayFactor,
      };

      if (decayedPoints > maxPaperRaw) {
        maxPaperRaw = decayedPoints;
        dominantLab = lab;
      }
    }

    // ── Non-paper secondary bucket ────────────────────────────────────────────
    int albumin = 0, hgb = 0, vitD = 0;
    for (final lab in resolved) {
      switch (lab.labType) {
        case 'albumin':
          albumin = _albumin(lab.normalizedValue);
          break;
        case 'hemoglobin':
          hgb = _hemoglobin(lab.normalizedValue, userSex);
          break;
        case 'vitamin_d':
          vitD = _vitaminD(lab.normalizedValue);
          break;
      }
    }
    final secondaryBucket = (albumin + hgb + vitD).clamp(0, 8);

    // If no paper biomarkers, pick best secondary lab as dominant
    if (dominantLab == null) {
      for (final lab in resolved) {
        if (lab.labType == 'albumin' ||
            lab.labType == 'hemoglobin' ||
            lab.labType == 'vitamin_d') {
          dominantLab = lab;
          break;
        }
      }
    }

    // ── Total and confidence ──────────────────────────────────────────────────
    final totalPoints = (maxPaperRaw + secondaryBucket).clamp(0, 30);
    final hasPaper = maxPaperRaw > 0;
    final minDaysAgo =
        resolved.map((l) => l.daysAgo).reduce((a, b) => a < b ? a : b);
    final confidenceBoost = totalPoints > 0 ? (minDaysAgo <= 7 ? 8 : 5) : 0;

    // IBS confidence reduction when FC is dominant (cohort was CD/UC only).
    // Unknown diagnosis also reduces confidence since we cannot confirm IBD context.
    int finalConfidence = confidenceBoost;
    if (isIbs && dominantLab?.labType == 'fc') {
      finalConfidence = (confidenceBoost - 3).clamp(0, 8);
    } else if (isDiagnosisUnconfirmed) {
      finalConfidence = (confidenceBoost - 2).clamp(0, 8);
    }

    final narrativeKey = _narrativeKey(dominantLab: dominantLab, isIbs: isIbs);

    return LabRiskContribution(
      points: totalPoints,
      confidenceBoost: finalConfidence,
      dominantLabType: dominantLab?.labType ?? 'none',
      dominantLabValue: dominantLab?.normalizedValue ?? 0,
      dominantLabUnit: dominantLab?.unit ?? '',
      decayFactor: dominantLab?.decayFactor ?? 0,
      narrativeKey: narrativeKey,
      labsPresent: true,
      contributionJson: {
        'total_points': totalPoints,
        'paper_points': maxPaperRaw,
        'secondary_bucket_points': secondaryBucket,
        'has_paper_biomarker': hasPaper,
        'dominant_lab_type': dominantLab?.labType ?? 'none',
        'dominant_lab_value': dominantLab?.normalizedValue ?? 0,
        'dominant_lab_unit': dominantLab?.unit ?? '',
        'dominant_lab_days_ago': dominantLab?.daysAgo ?? 0,
        'dominant_lab_decay': dominantLab?.decayFactor ?? 0,
        'paper_details': paperDetails,
        'albumin_points': albumin,
        'hemoglobin_points': hgb,
        'vitamin_d_points': vitD,
        'confidence_boost': finalConfidence,
        'narrative_key': narrativeKey,
      },
    );
  }

  // ── Decay function ────────────────────────────────────────────────────────

  static double _decayFactor(int daysAgo) {
    if (daysAgo <= 7) return 1.00;
    if (daysAgo <= 14) return 0.80;
    if (daysAgo <= 21) return 0.55;
    if (daysAgo <= 30) return 0.30;
    return 0.05;
  }

  // ── Paper biomarker raw points (before decay, before baseline adjustment) ──

  static int _paperRawPoints(
    String labType,
    double value, {
    required bool isIbs,
  }) {
    // IBS: double the thresholds (cohort was CD/UC only)
    final multiplier = isIbs ? 2.0 : 1.0;
    switch (labType) {
      case 'fc':
        return _fcPoints(value / multiplier);
      case 'crp':
        return _crpPoints(value / multiplier);
      case 'esr':
        return _esrPoints(value / multiplier);
      default:
        return 0;
    }
  }

  static int _fcPoints(double v) {
    if (v < 75) return 0;
    if (v < 150) return 8;
    if (v < 300) return 18;
    if (v < 500) return 24;
    return 30;
  }

  static int _crpPoints(double v) {
    if (v < 3) return 0;
    if (v < 5) return 5;
    if (v < 10) return 12;
    if (v < 20) return 18;
    return 24;
  }

  static int _esrPoints(double v) {
    if (v < 20) return 0;
    if (v < 30) return 4;
    if (v < 50) return 8;
    if (v < 80) return 12;
    return 16;
  }

  // ── Non-paper secondary bucket ────────────────────────────────────────────

  static int _albumin(double v) {
    if (v > 3.5) return 0;
    if (v >= 3.0) return 3;
    if (v >= 2.5) return 6;
    return 8;
  }

  static int _hemoglobin(double v, String? sex) {
    final s = sex?.toLowerCase();
    if (s == 'm') {
      if (v >= 13.5) return 0;
      if (v >= 12.0) return 3;
      if (v >= 10.0) return 6;
      return 8;
    } else if (s == 'f') {
      if (v >= 12.0) return 0;
      if (v >= 11.0) return 3;
      if (v >= 9.0) return 6;
      return 8;
    } else {
      // Unknown sex — use conservative unisex thresholds
      if (v >= 12.0) return 0;
      if (v >= 10.0) return 4;
      return 7;
    }
  }

  static int _vitaminD(double v) {
    if (v > 30) return 0;
    if (v >= 20) return 1;
    if (v >= 10) return 2;
    return 3;
  }

  // ── Narrative key assignment ──────────────────────────────────────────────

  static String _narrativeKey({
    required _ResolvedLab? dominantLab,
    required bool isIbs,
  }) {
    if (dominantLab == null) return 'no_labs_available';
    switch (dominantLab.labType) {
      case 'fc':
        final v = dominantLab.normalizedValue;
        final d = dominantLab.daysAgo;
        if (v >= 500 && d <= 7) return 'fc_markedly_elevated_recent';
        if (v >= 150 && d <= 7) return 'fc_elevated_recent';
        if (v >= 150 && d <= 21) return 'fc_elevated_older';
        if (v >= 75 && d <= 7) return 'fc_borderline_recent';
        return 'secondary_labs_only';
      case 'crp':
        if (dominantLab.normalizedValue >= 5 && dominantLab.daysAgo <= 7) {
          return 'crp_elevated_recent';
        }
        return 'secondary_labs_only';
      case 'esr':
        if (dominantLab.normalizedValue >= 30) return 'esr_elevated_recent';
        return 'secondary_labs_only';
      default:
        return 'secondary_labs_only';
    }
  }

  // ── Grouping helper ───────────────────────────────────────────────────────

  static Map<String, List<LabValueRecord>> _groupByTypeAndDate(
    List<LabValueRecord> labs,
  ) {
    final map = <String, List<LabValueRecord>>{};
    for (final lab in labs) {
      final key = '${lab.labType}__${lab.drawnDate}';
      map.putIfAbsent(key, () => []).add(lab);
    }
    return map;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal data carrier (not part of the public API)
// ─────────────────────────────────────────────────────────────────────────────

class _ResolvedLab {
  const _ResolvedLab({
    required this.record,
    required this.labType,
    required this.normalizedValue,
    required this.daysAgo,
    required this.decayFactor,
    required this.unit,
  });

  final LabValueRecord record;
  final String labType;
  final double normalizedValue;
  final int daysAgo;
  final double decayFactor;
  final String unit;
}
