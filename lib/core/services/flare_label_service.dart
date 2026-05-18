import '../database/wearable_sample_repository.dart';
import 'pro2_score_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// FlareLabelService
//
// Computes ground-truth flare labels from user-entered clinical data,
// exactly matching the definitions used in Hirten et al. 2025:
//
// INFLAMMATORY FLARE:
//   CRP > 5 mg/dL  OR  ESR > 30 mm/h  OR  FC > 150 μg/g
//   within a ±7-day window around each lab draw date.
//   (Paper rationale: lab values reflect a period around the collection date,
//   not just the exact day — Section "Symptomatic and Inflammatory Flare Criteria")
//
// SYMPTOMATIC FLARE:
//   In a rolling 7-day window ending on each date:
//     - ≥ 4 surveys answered
//     - ≥ 2 surveys meeting the flare threshold for disease type
//   CD flare threshold: stored symptom score ≥ 8
//   UC flare threshold: stored symptom score > 1 OR rectal_bleeding > 0 OR stool_freq > 1
//
// CLINICAL FLARE:
//   Endoscopy evidence of active disease applies from procedure_date through
//   procedure_date + 30 days.
//   Qualifying procedures: Mayo endoscopic score ≥ 2, SES-CD ≥ 7,
//   or biopsy_result = active_inflammation.
//
// COMBINED FLARE: inflammatory_flare AND symptomatic_flare both true.
// ─────────────────────────────────────────────────────────────────────────────

class FlareLabelComputationResult {
  const FlareLabelComputationResult({
    required this.recomputedDates,
    required this.inflammatoryCount,
    required this.symptomaticCount,
    required this.combinedCount,
  });

  final List<String> recomputedDates;
  final int inflammatoryCount;
  final int symptomaticCount;
  final int combinedCount;
}

class FlareLabelService {
  FlareLabelService({
    required WearableSampleRepository repository,
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final WearableSampleRepository _repository;
  final DateTime Function() _nowProvider;

  // Paper thresholds (Hirten et al. 2025, Methods section)
  static const _crpThreshold = 5.0; // mg/dL
  static const _esrThreshold = 30.0; // mm/h
  static const _fcThreshold = 150.0; // μg/g
  static const _labWindowDays = 7; // ±7 days around each lab draw
  static const _surveysRequired = 4; // surveys needed per 7-day window
  static const _flaresSufficient =
      2; // flare surveys needed to classify as flare
  static const _clinicalWindowDays = 30;

  // ── Public ──────────────────────────────────────────────────────────────────

  /// Recomputes flare labels for all dates that have any lab value or PRO-2 data.
  /// If [startDate]/[endDate] are provided, scopes the recompute to that range.
  Future<FlareLabelComputationResult> recomputeLabels({
    String? startDate,
    String? endDate,
  }) async {
    final now = _nowProvider();
    final effectiveEnd = endDate ?? _dateString(now);
    // Start 60 days back by default to capture ±7d lab windows
    final effectiveStart =
        startDate ?? _dateString(now.subtract(const Duration(days: 60)));

    // Load lab values with extra ±7d padding on each side
    final labPaddedStart = _offsetDate(effectiveStart, -_labWindowDays);
    final labPaddedEnd = _offsetDate(effectiveEnd, _labWindowDays);
    final labValues = await _repository.getLabValuesInRange(
      labPaddedStart,
      labPaddedEnd,
    );

    // Load surveys with 7-day lookback padding
    final surveyStart = _offsetDate(effectiveStart, -_labWindowDays);
    final surveys = await _repository.getPro2SurveysInRange(
      surveyStart,
      effectiveEnd,
    );
    final clinicalStart = _offsetDate(effectiveStart, -_clinicalWindowDays);
    final procedures = await _repository.getEndoscopyRecordsInRange(
      clinicalStart,
      effectiveEnd,
    );

    // Build lookup maps for fast access
    final labByDate = _groupLabsByDate(labValues);
    final surveysByDate = _groupSurveysByDate(surveys);

    // Enumerate every calendar date in [effectiveStart, effectiveEnd]
    final dates = _enumerateDates(effectiveStart, effectiveEnd);

    var inflammatoryCount = 0;
    var symptomaticCount = 0;
    var combinedCount = 0;

    for (final date in dates) {
      final inflammatory = _computeInflammatory(date, labByDate, surveysByDate);
      final symptomatic = _computeSymptomatic(date, surveysByDate);
      final clinical = _computeClinical(date, procedures);
      final combined = inflammatory && symptomatic;

      if (inflammatory) inflammatoryCount++;
      if (symptomatic) symptomaticCount++;
      if (combined) combinedCount++;

      final source = _labelSource(inflammatory, symptomatic, clinical);
      final confidence = _labelConfidence(
        date,
        labByDate,
        procedures,
        surveysByDate,
      );

      await _repository.upsertFlareLabel(
        FlareLabelRecord(
          labelDate: date,
          inflammatoryFlare: inflammatory,
          symptomaticFlare: symptomatic,
          clinicalFlare: clinical,
          combinedFlare: combined,
          labelSource: source,
          confidence: confidence,
          recomputedAt: now,
        ),
      );
    }

    return FlareLabelComputationResult(
      recomputedDates: dates,
      inflammatoryCount: inflammatoryCount,
      symptomaticCount: symptomaticCount,
      combinedCount: combinedCount,
    );
  }

  // ── Inflammatory flare logic ─────────────────────────────────────────────

  /// Returns true when an elevated lab (CRP>5, ESR>30, FC>150) exists within
  /// ±7 days AND at least one PRO-2 survey in the same window meets the flare
  /// threshold.
  ///
  /// If surveys ARE present in the window but none meet the flare threshold,
  /// returns false — the lab elevation is likely non-IBD (infection, exercise,
  /// lab error) and the user's own symptom report refutes it.
  ///
  /// If NO surveys exist in the ±7d window, the label is still set to true
  /// (lab signal preserved) but _labelConfidence will return 'low', so the
  /// downstream logistic model can down-weight this noisier training sample.
  bool _computeInflammatory(
    String date,
    Map<String, List<LabValueRecord>> labByDate,
    Map<String, List<Pro2SurveyRecord>> surveysByDate,
  ) {
    final windowStart = _offsetDate(date, -_labWindowDays);
    final windowEnd = _offsetDate(date, _labWindowDays);

    // Phase 1: check for any elevated lab in ±7d window
    bool hasElevatedLab = false;
    for (var d = windowStart;
        d.compareTo(windowEnd) <= 0;
        d = _offsetDate(d, 1)) {
      for (final lab in labByDate[d] ?? const <LabValueRecord>[]) {
        if (_isElevated(lab)) {
          hasElevatedLab = true;
          break;
        }
      }
      if (hasElevatedLab) break;
    }
    if (!hasElevatedLab) return false;

    // Phase 2: check for PRO-2 corroboration in same ±7d window
    bool hasSurveysInWindow = false;
    bool hasFlareThresholdSurvey = false;
    for (var d = windowStart;
        d.compareTo(windowEnd) <= 0;
        d = _offsetDate(d, 1)) {
      final surveys = surveysByDate[d] ?? const <Pro2SurveyRecord>[];
      if (surveys.isNotEmpty) hasSurveysInWindow = true;
      for (final s in surveys) {
        if (_surveyIsFlare(s)) {
          hasFlareThresholdSurvey = true;
          break;
        }
      }
      if (hasFlareThresholdSurvey) break;
    }

    // No surveys at all → lab-only label (true but low confidence)
    if (!hasSurveysInWindow) return true;

    // Surveys present but none at flare level → user's report refutes the lab
    return hasFlareThresholdSurvey;
  }

  bool _isElevated(LabValueRecord lab) {
    switch (lab.labType) {
      case 'crp':
        return lab.valueNumeric > _crpThreshold;
      case 'esr':
        return lab.valueNumeric > _esrThreshold;
      case 'fc':
        return lab.valueNumeric > _fcThreshold;
      default:
        return false;
    }
  }

  // ── Symptomatic flare logic ──────────────────────────────────────────────

  /// Checks a 7-day window ending on [date].
  /// Returns true if ≥4 surveys answered AND ≥2 surveys meet flare threshold.
  bool _computeSymptomatic(
    String date,
    Map<String, List<Pro2SurveyRecord>> surveysByDate,
  ) {
    final windowStart = _offsetDate(date, -6); // 7 days: [date-6, date]
    final windowSurveys = <Pro2SurveyRecord>[];

    for (var d = windowStart; d.compareTo(date) <= 0; d = _offsetDate(d, 1)) {
      windowSurveys.addAll(surveysByDate[d] ?? const []);
    }

    if (windowSurveys.length < _surveysRequired) return false;

    final flareCount = windowSurveys.where(_surveyIsFlare).length;
    return flareCount >= _flaresSufficient;
  }

  bool _computeClinical(String date, List<EndoscopyRecord> procedures) {
    final currentDate = DateTime.parse('${date}T00:00:00Z');
    for (final procedure in procedures) {
      if (!_isClinicallyActive(procedure)) {
        continue;
      }
      final procedureDate = DateTime.parse(
        '${procedure.procedureDate}T00:00:00Z',
      );
      final windowEnd = procedureDate.add(
        const Duration(days: _clinicalWindowDays),
      );
      if (!currentDate.isBefore(procedureDate) &&
          !currentDate.isAfter(windowEnd)) {
        return true;
      }
    }
    return false;
  }

  bool _isClinicallyActive(EndoscopyRecord procedure) {
    if ((procedure.mayoEndoscopicScore ?? -1) >= 2) {
      return true;
    }
    if ((procedure.sesCdScore ?? -1) >= 7) {
      return true;
    }
    return procedure.biopsyResult == 'active_inflammation';
  }

  /// Returns true if a PRO-2 survey response meets the flare threshold.
  ///
  /// CD: score ≥ 8  (paper: CD PRO-2 remission defined as score < 8)
  /// UC: score > 1 OR rectal_bleeding > 0 OR stool_frequency > 1
  ///     (paper: UC remission = score ≤1 AND bleeding=0 AND stool_freq≤1)
  bool _surveyIsFlare(Pro2SurveyRecord survey) {
    return Pro2ScoreService.isFlareSurvey(survey);
  }

  // ── Metadata helpers ─────────────────────────────────────────────────────

  String _labelSource(bool inflammatory, bool symptomatic, bool clinical) {
    if ((inflammatory && symptomatic) ||
        (clinical && (inflammatory || symptomatic))) {
      return 'combined';
    }
    if (clinical) return 'endoscopy';
    if (inflammatory) return 'lab';
    if (symptomatic) return 'pro2';
    return 'none';
  }

  /// Confidence reflects data quality: endoscopy > lab+survey > lab-only > no data.
  /// Lab-only inflammatory labels (no survey corroboration) get 'low' confidence
  /// because a single lab elevation may be non-IBD in origin.
  String _labelConfidence(
    String date,
    Map<String, List<LabValueRecord>> labByDate,
    List<EndoscopyRecord> procedures,
    Map<String, List<Pro2SurveyRecord>> surveysByDate,
  ) {
    for (final procedure in procedures) {
      if (!_isClinicallyActive(procedure)) {
        continue;
      }
      final daysBetween = DateTime.parse('${date}T00:00:00Z')
          .difference(DateTime.parse('${procedure.procedureDate}T00:00:00Z'))
          .inDays;
      if (daysBetween >= 0 && daysBetween <= 7) {
        return 'high';
      }
      if (daysBetween > 7 && daysBetween <= _clinicalWindowDays) {
        return 'medium';
      }
    }

    // Check whether any surveys exist in the ±7d window (corroboration check)
    final windowStart = _offsetDate(date, -_labWindowDays);
    final windowEnd = _offsetDate(date, _labWindowDays);
    bool hasSurveyInWindow = false;
    for (var d = windowStart;
        d.compareTo(windowEnd) <= 0;
        d = _offsetDate(d, 1)) {
      if ((surveysByDate[d] ?? const []).isNotEmpty) {
        hasSurveyInWindow = true;
        break;
      }
    }

    for (var d = 0; d <= _labWindowDays; d++) {
      if ((labByDate[_offsetDate(date, -d)] ?? []).isNotEmpty ||
          (labByDate[_offsetDate(date, d)] ?? []).isNotEmpty) {
        if (!hasSurveyInWindow) {
          return 'low'; // lab-only: no survey corroboration
        }
        return d <= 3 ? 'high' : 'medium';
      }
    }
    return 'low';
  }

  // ── Date utilities ────────────────────────────────────────────────────────

  String _dateString(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  String _offsetDate(String dateStr, int days) {
    final dt = DateTime.parse('${dateStr}T00:00:00Z');
    return _dateString(dt.add(Duration(days: days)));
  }

  List<String> _enumerateDates(String startDate, String endDate) {
    final dates = <String>[];
    var current = startDate;
    while (current.compareTo(endDate) <= 0) {
      dates.add(current);
      current = _offsetDate(current, 1);
    }
    return dates;
  }

  Map<String, List<LabValueRecord>> _groupLabsByDate(
    List<LabValueRecord> labs,
  ) {
    final map = <String, List<LabValueRecord>>{};
    for (final lab in labs) {
      map.putIfAbsent(lab.drawnDate, () => []).add(lab);
    }
    return map;
  }

  Map<String, List<Pro2SurveyRecord>> _groupSurveysByDate(
    List<Pro2SurveyRecord> surveys,
  ) {
    final map = <String, List<Pro2SurveyRecord>>{};
    for (final s in surveys) {
      map.putIfAbsent(s.surveyDate, () => []).add(s);
    }
    return map;
  }
}
