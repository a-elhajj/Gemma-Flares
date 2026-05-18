import 'dart:math' as math;

import '../database/wearable_sample_repository.dart';
import 'logistic_risk_service.dart';

class DashboardSnapshot {
  const DashboardSnapshot({
    required this.latestScore,
    required this.latestSummary,
    required this.latestBaseline,
    required this.syncState,
    required this.trendCards,
    required this.driverChips,
    required this.scoreTrend,
    required this.isSyncStale,
    required this.syncFreshnessLabel,
    required this.syncWarningLabel,
    required this.baselineStatusLabel,
    required this.recommendedAction,
    required this.latestSymptomSummary,
    // Paper replication additions
    this.latestCosinor,
    this.latestFlareLabel,
    this.logistic7dInflammatoryProb,
    this.logistic7dSymptomaticProb,
    this.logisticTrainingSamples,
    this.checkinStatusLabel,
    this.labStatusLabel,
    this.baselineCosinor,
    this.earlyWarningOutlook = const [],
  });

  final FlareRiskScoreRecord? latestScore;
  final DailySummaryRecord? latestSummary;
  final BaselineSnapshotRecord? latestBaseline;
  final SyncStateRecord? syncState;
  final List<TrendCardSnapshot> trendCards;
  final List<DriverChipSnapshot> driverChips;
  final List<double> scoreTrend;
  final bool isSyncStale;
  final String syncFreshnessLabel;
  final String? syncWarningLabel;
  final String baselineStatusLabel;
  final String recommendedAction;
  final String? latestSymptomSummary;

  // Circadian HRV parameters (paper Supplementary Eq. 1)
  final CosinorFeatureRecord? latestCosinor;
  // Today's computed ground-truth label (if lab / PRO-2 data exists)
  final FlareLabelRecord? latestFlareLabel;
  // Logistic model 7-day probability — null until enough labeled samples
  final double? logistic7dInflammatoryProb;
  final double? logistic7dSymptomaticProb;
  // Number of labeled training samples in the best logistic model
  final int? logisticTrainingSamples;
  // PRO-2 check-in status for today
  final String? checkinStatusLabel;
  // Most recent lab result summary
  final String? labStatusLabel;
  final CosinorComparisonSnapshot? baselineCosinor;
  final List<OutlookPointSnapshot> earlyWarningOutlook;
}

class CosinorComparisonSnapshot {
  const CosinorComparisonSnapshot({
    required this.mesor,
    required this.amplitude,
    required this.peakTimeHours,
    required this.sampleCount,
  });

  final double mesor;
  final double amplitude;
  final double peakTimeHours;
  final int sampleCount;
}

class OutlookPointSnapshot {
  const OutlookPointSnapshot({
    required this.horizonDays,
    required this.label,
    required this.probability,
    required this.trainingSamples,
    required this.isLearning,
  });

  final int horizonDays;
  final String label;
  final double probability;
  final int trainingSamples;
  final bool isLearning;
}

class TrendCardSnapshot {
  const TrendCardSnapshot({
    required this.label,
    required this.valueLabel,
    required this.deltaLabel,
  });

  final String label;
  final String valueLabel;
  final String deltaLabel;
}

class DriverChipSnapshot {
  const DriverChipSnapshot({
    required this.label,
    required this.valueLabel,
    required this.points,
  });

  final String label;
  final String valueLabel;
  final int points;
}

class TimelineGroup {
  const TimelineGroup({required this.dateLocal, required this.items});

  final String dateLocal;
  final List<TimelineItem> items;
}

class TimelineItem {
  const TimelineItem({
    required this.title,
    required this.detail,
    required this.tone,
    required this.category,
  });

  final String title;
  final String detail;
  final String tone;
  final String category;
}

class DashboardSnapshotService {
  DashboardSnapshotService({
    required WearableSampleRepository repository,
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final WearableSampleRepository _repository;
  final DateTime Function() _nowProvider;

  Future<DashboardSnapshot> loadDashboardSnapshot() async {
    final now = _nowProvider();
    final todayDate = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';

    // Load core data in parallel where independent.
    final futures = await Future.wait([
      _repository.getLatestUserFacingFlareRiskScore(), // 0
      _repository.getLatestDailySummary(), // 1
      _repository.getLatestBaselineSnapshot(), // 2
      _repository.getSyncState('apple_health'), // 3
      _repository.getDailySummaries(), // 4
      _repository.getFlareRiskScores(
        modelVersion: 'risk_v2_context_adjusted',
      ), // 5
      _repository.getRecentSymptoms(limit: 5), // 6
      _repository.getCosinorFeature(todayDate), // 7
      _repository.getFlareLabel(todayDate), // 8
      _repository.getRecentPro2Surveys(limit: 1), // 9
      _repository.getLabValues(labType: null), // 10
      _repository.getAllLogisticModelStates(), // 11
      _repository.getDailyFeatureForDate(todayDate), // 12
      _repository.getCosinorFeaturesInRange(
        _offsetDate(todayDate, -7),
        todayDate,
      ), // 13
    ]);

    final latestScore = futures[0] as FlareRiskScoreRecord?;
    final latestSummary = futures[1] as DailySummaryRecord?;
    final latestBaseline = futures[2] as BaselineSnapshotRecord?;
    final syncState = futures[3] as SyncStateRecord?;
    final allSummaries = futures[4] as List<DailySummaryRecord>;
    var allScores = futures[5] as List<FlareRiskScoreRecord>;
    if (allScores.isEmpty) {
      allScores = await _repository.getFlareRiskScores(modelVersion: 'risk_v1');
    }
    final recentSymptoms = futures[6] as List<SymptomRecord>;
    final latestCosinor = futures[7] as CosinorFeatureRecord?;
    final latestFlareLabel = futures[8] as FlareLabelRecord?;
    final recentPro2 = futures[9] as List<Pro2SurveyRecord>;
    final allLabs = futures[10] as List<LabValueRecord>;
    final modelStates = futures[11] as List<LogisticModelStateRecord>;
    final todayFeature = futures[12] as DailyFeatureRecord?;
    final recentCosinor = futures[13] as List<CosinorFeatureRecord>;

    final recentSummaries = allSummaries.takeLast(14).toList(growable: false);
    final recentScores = allScores.takeLast(7).toList(growable: false);
    final staleHours = _staleSyncHours(syncState);
    final latestSymptom = recentSymptoms.isEmpty ? null : recentSymptoms.first;

    // Logistic model 7-day predictions from stored weights + today's feature JSON
    double? logistic7dInflamProb;
    double? logistic7dSympProb;
    int? logisticTrainingSamples;
    final earlyWarningOutlook = <OutlookPointSnapshot>[];

    if (todayFeature != null && modelStates.isNotEmpty) {
      final features = LogisticRiskService.extractFromRiskFeatures(
        todayFeature.featureJson,
      );
      final inflam7 = modelStates
          .where((m) => m.horizonDays == 7 && m.flareType == 'inflammatory')
          .firstOrNull;
      final symp7 = modelStates
          .where((m) => m.horizonDays == 7 && m.flareType == 'symptomatic')
          .firstOrNull;
      if (inflam7 != null &&
          inflam7.trainingSamples >=
              LogisticPrediction.minimumTrainingSamples) {
        final rawProbability = LogisticRiskService.displayProbabilityFromLogit(
          _dotProduct(inflam7.coefficientsJson, features) + inflam7.intercept,
        );
        logistic7dInflamProb = LogisticRiskService.calibrateDisplayProbability(
          rawProbability: rawProbability,
          trainingSamples: inflam7.trainingSamples,
        );
      }
      if (symp7 != null &&
          symp7.trainingSamples >= LogisticPrediction.minimumTrainingSamples) {
        final rawProbability = LogisticRiskService.displayProbabilityFromLogit(
          _dotProduct(symp7.coefficientsJson, features) + symp7.intercept,
        );
        logistic7dSympProb = LogisticRiskService.calibrateDisplayProbability(
          rawProbability: rawProbability,
          trainingSamples: symp7.trainingSamples,
        );
      }
      for (final horizon in const [7, 14, 21, 28, 35, 42, 49]) {
        final inflammatoryState = modelStates
            .where(
              (m) => m.horizonDays == horizon && m.flareType == 'inflammatory',
            )
            .firstOrNull;
        final symptomaticState = modelStates
            .where(
              (m) => m.horizonDays == horizon && m.flareType == 'symptomatic',
            )
            .firstOrNull;
        final inflammatoryProb = inflammatoryState != null &&
                inflammatoryState.trainingSamples >=
                    LogisticPrediction.minimumTrainingSamples
            ? LogisticRiskService.displayProbabilityFromLogit(
                _dotProduct(inflammatoryState.coefficientsJson, features) +
                    inflammatoryState.intercept,
              )
            : null;
        final symptomaticProb = symptomaticState != null &&
                symptomaticState.trainingSamples >=
                    LogisticPrediction.minimumTrainingSamples
            ? LogisticRiskService.displayProbabilityFromLogit(
                _dotProduct(symptomaticState.coefficientsJson, features) +
                    symptomaticState.intercept,
              )
            : null;
        final trainingSamples = math.max(
          inflammatoryState?.trainingSamples ?? 0,
          symptomaticState?.trainingSamples ?? 0,
        );
        final rawProbability = math.max(
          inflammatoryProb ?? 0,
          symptomaticProb ?? 0,
        );
        if (rawProbability > 0) {
          final displayProbability =
              LogisticRiskService.calibrateDisplayProbability(
            rawProbability: rawProbability,
            trainingSamples: trainingSamples,
          );
          earlyWarningOutlook.add(
            OutlookPointSnapshot(
              horizonDays: horizon,
              label: _horizonLabel(horizon),
              probability: displayProbability,
              trainingSamples: trainingSamples,
              isLearning: LogisticRiskService.shouldUseLearningState(
                trainingSamples,
              ),
            ),
          );
        }
      }
      // Report training samples from the most-trained model for UI display
      logisticTrainingSamples = modelStates
          .map((m) => m.trainingSamples)
          .fold<int>(0, (a, b) => a > b ? a : b);
    }

    final validCosinor = recentCosinor
        .where((item) => item.fitValid)
        .where((item) => item.featureDate != todayDate)
        .toList(growable: false);
    final baselineMesor = _meanNullable(
      validCosinor.map((item) => item.mesor).whereType<double>(),
    );
    final baselineAmplitude = _meanNullable(
      validCosinor.map((item) => item.amplitude).whereType<double>(),
    );
    final baselinePeak = _meanNullable(
      validCosinor.map((item) => item.peakTimeHours).whereType<double>(),
    );
    final baselineCosinor = validCosinor.isEmpty ||
            baselineMesor == null ||
            baselineAmplitude == null ||
            baselinePeak == null
        ? null
        : CosinorComparisonSnapshot(
            mesor: baselineMesor,
            amplitude: baselineAmplitude,
            peakTimeHours: baselinePeak,
            sampleCount: validCosinor.length,
          );

    // Check-in status — did user complete PRO-2 today?
    String? checkinStatusLabel;
    if (recentPro2.isNotEmpty && recentPro2.first.surveyDate == todayDate) {
      final s = recentPro2.first;
      checkinStatusLabel =
          'Checked in today — symptom score ${s.pro2Score.toInt()}, '
          '${s.isFlare ? "flare" : "remission"}';
    } else {
      checkinStatusLabel = 'Daily check-in not yet completed';
    }

    // Lab status — most recent lab value
    String? labStatusLabel;
    if (allLabs.isNotEmpty) {
      allLabs.sort((a, b) => b.drawnDate.compareTo(a.drawnDate));
      final lab = allLabs.first;
      final elevated =
          lab.valueNumeric > (lab.referenceHigh ?? double.infinity);
      labStatusLabel = 'Last lab: ${lab.labType.toUpperCase()} '
          '${lab.valueNumeric.toStringAsFixed(1)} ${lab.unit} '
          '(${elevated ? "elevated" : "normal"}) on ${lab.drawnDate}';
    }

    return DashboardSnapshot(
      latestScore: latestScore,
      latestSummary: latestSummary,
      latestBaseline: latestBaseline,
      syncState: syncState,
      trendCards: [
        TrendCardSnapshot(
          label: 'Recovery signal',
          valueLabel: _formatNullable(
            _meanMetric(recentSummaries.takeLast(7), 'hrv_sdnn_mean'),
            suffix: ' ms',
          ),
          deltaLabel: _deltaLabel(
            current: _meanMetric(recentSummaries.takeLast(7), 'hrv_sdnn_mean'),
            previous: _meanMetric(
              recentSummaries.takePreviousWindow(7),
              'hrv_sdnn_mean',
            ),
          ),
        ),
        TrendCardSnapshot(
          label: 'Sleep pattern',
          valueLabel: _formatNullable(
            _meanMetric(recentSummaries.takeLast(7), 'sleep_total_minutes'),
            suffix: ' min',
          ),
          deltaLabel: _deltaLabel(
            current: _meanMetric(
              recentSummaries.takeLast(7),
              'sleep_total_minutes',
            ),
            previous: _meanMetric(
              recentSummaries.takePreviousWindow(7),
              'sleep_total_minutes',
            ),
          ),
        ),
        TrendCardSnapshot(
          label: 'Activity pattern',
          valueLabel: _formatNullable(
            _meanMetric(recentSummaries.takeLast(7), 'step_count_total'),
            digits: 0,
          ),
          deltaLabel: _deltaLabel(
            current: _meanMetric(
              recentSummaries.takeLast(7),
              'step_count_total',
            ),
            previous: _meanMetric(
              recentSummaries.takePreviousWindow(7),
              'step_count_total',
            ),
          ),
        ),
      ],
      driverChips: _driverChips(latestScore),
      scoreTrend:
          recentScores.map((item) => item.riskScore).toList(growable: false),
      isSyncStale: staleHours != null && staleHours > 72,
      syncFreshnessLabel: _syncFreshnessLabel(syncState),
      syncWarningLabel: _syncWarningLabel(syncState),
      baselineStatusLabel: _baselineStatusLabel(latestBaseline),
      recommendedAction: _recommendedAction(
        latestScore: latestScore,
        latestBaseline: latestBaseline,
        syncState: syncState,
        latestSymptom: latestSymptom,
      ),
      latestSymptomSummary:
          latestSymptom == null ? null : _symptomSummary(latestSymptom),
      latestCosinor: latestCosinor,
      latestFlareLabel: latestFlareLabel,
      logistic7dInflammatoryProb: logistic7dInflamProb,
      logistic7dSymptomaticProb: logistic7dSympProb,
      logisticTrainingSamples: logisticTrainingSamples,
      checkinStatusLabel: checkinStatusLabel,
      labStatusLabel: labStatusLabel,
      baselineCosinor: baselineCosinor,
      earlyWarningOutlook: earlyWarningOutlook,
    );
  }

  static String _horizonLabel(int horizon) {
    switch (horizon) {
      case 7:
        return 'Next 7 days';
      case 14:
        return 'Next 2 weeks';
      case 21:
        return 'Next 3 weeks';
      case 28:
        return 'Next 4 weeks';
      case 35:
        return 'Next 5 weeks';
      case 42:
        return 'Next 6 weeks';
      case 49:
        return 'Next 7 weeks';
      default:
        return 'Next $horizon days';
    }
  }

  String _offsetDate(String dateStr, int days) {
    final date = DateTime.parse(
      '${dateStr}T00:00:00Z',
    ).add(Duration(days: days));
    return _dateOnly(date);
  }

  double? _meanNullable(Iterable<double> values) {
    final list = values.toList(growable: false);
    if (list.isEmpty) {
      return null;
    }
    return list.fold<double>(0, (sum, value) => sum + value) / list.length;
  }

  // ── Logistic math (pure, no external deps) ─────────────────────────────────

  static double _dotProduct(
    Map<String, double> weights,
    Map<String, double> features,
  ) {
    var sum = 0.0;
    for (final entry in weights.entries) {
      sum += entry.value * (features[entry.key] ?? 0.0);
    }
    return sum;
  }

  Future<List<TimelineGroup>> loadTimelineGroups({int dayLimit = 10}) async {
    final summaries = (await _repository.getDailySummaries())
        .takeLast(dayLimit)
        .toList(growable: false);
    var scores = (await _repository.getFlareRiskScores(
      modelVersion: 'risk_v2_context_adjusted',
    ))
        .takeLast(dayLimit)
        .toList(growable: false);
    if (scores.isEmpty) {
      scores = (await _repository.getFlareRiskScores(
        modelVersion: 'risk_v1',
      ))
          .takeLast(dayLimit)
          .toList(growable: false);
    }
    final symptoms = await _repository.getRecentSymptoms(limit: dayLimit);
    final checkIns = await _repository.getRecentPro2Surveys(limit: dayLimit);
    final labs = (await _repository.getLabValues())
        .takeLast(dayLimit)
        .toList(growable: false);
    final procedures = (await _repository.getEndoscopyRecords())
        .takeLast(dayLimit)
        .toList(growable: false);
    final imports = (await _repository.getClinicalRecordImports(
      limit: dayLimit,
    ))
        .toList(growable: false);
    final intakeEvents = await _repository.getIntakeEventsBetween(
      start: _nowProvider().subtract(Duration(days: dayLimit)),
      end: _nowProvider(),
    );
    final syncState = await _repository.getSyncState('apple_health');
    final latestBaseline = await _repository.getLatestBaselineSnapshot();
    final grouped = <String, List<TimelineItem>>{};

    for (final summary in summaries.reversed) {
      grouped.putIfAbsent(summary.dateLocal, () => []);
      grouped[summary.dateLocal]!.add(
        TimelineItem(
          title: 'Daily summary ready',
          detail:
              'HRV ${_formatNullable((summary.summaryJson['hrv_sdnn_mean'] as num?)?.toDouble())}, sleep ${_formatNullable((summary.summaryJson['sleep_total_minutes'] as num?)?.toDouble(), digits: 0, suffix: ' min')}, steps ${_formatNullable((summary.summaryJson['step_count_total'] as num?)?.toDouble(), digits: 0)}.',
          tone: 'summary',
          category: 'summary',
        ),
      );
    }

    if (latestBaseline != null) {
      grouped.putIfAbsent(latestBaseline.snapshotDateLocal, () => []);
      grouped[latestBaseline.snapshotDateLocal]!.add(
        TimelineItem(
          title:
              'Baseline ${latestBaseline.readinessState.replaceAll('_', ' ')}',
          detail:
              '${latestBaseline.validDays} valid days captured for the local reference window.',
          tone: latestBaseline.readinessState == 'ready' ||
                  latestBaseline.readinessState == 'mature'
              ? 'baseline'
              : 'moderate',
          category: 'baseline',
        ),
      );
    }

    for (final score in scores.reversed) {
      grouped.putIfAbsent(score.dateLocal, () => []);
      grouped[score.dateLocal]!.insert(
        0,
        TimelineItem(
          title: 'Risk ${score.riskBand}',
          detail:
              '${score.riskScore.round()}/100 with confidence ${score.confidenceScore.round()}/100.',
          tone: score.riskBand,
          category: 'risk',
        ),
      );
    }

    for (final symptom in symptoms.reversed) {
      final symptomDate = _dateOnly(symptom.loggedAt);
      grouped.putIfAbsent(symptomDate, () => []);
      final severityLabel =
          symptom.severity == null ? 'severity n/a' : '${symptom.severity}/10';
      final mealLabel = symptom.mealRelation == null
          ? ''
          : ' ${symptom.mealRelation!.replaceAll('_', ' ')}';
      grouped[symptomDate]!.insert(
        0,
        TimelineItem(
          title: 'Symptom logged',
          detail: '${symptom.symptomType} $severityLabel$mealLabel'.trim(),
          tone: 'symptom',
          category: 'symptom',
        ),
      );
    }

    for (final checkIn in checkIns.reversed) {
      grouped.putIfAbsent(checkIn.surveyDate, () => []);
      grouped[checkIn.surveyDate]!.add(
        TimelineItem(
          title: 'Check-in submitted',
          detail:
              'PRO-2 score ${checkIn.pro2Score.toStringAsFixed(0)}${checkIn.isFlare ? ' (flare flagged)' : ''}.',
          tone: checkIn.isFlare ? 'moderate' : 'summary',
          category: 'checkin',
        ),
      );
    }

    for (final lab in labs.reversed) {
      grouped.putIfAbsent(lab.drawnDate, () => []);
      final elevated =
          lab.valueNumeric > (lab.referenceHigh ?? double.infinity);
      grouped[lab.drawnDate]!.add(
        TimelineItem(
          title: 'Lab ${lab.labType.toUpperCase()}',
          detail:
              '${lab.valueNumeric.toStringAsFixed(1)} ${lab.unit}${elevated ? ' (high)' : ''}',
          tone: elevated ? 'moderate' : 'summary',
          category: 'lab',
        ),
      );
    }

    for (final procedure in procedures.reversed) {
      grouped.putIfAbsent(procedure.procedureDate, () => []);
      grouped[procedure.procedureDate]!.add(
        TimelineItem(
          title: 'Procedure logged',
          detail: procedure.procedureType.replaceAll('_', ' '),
          tone: 'summary',
          category: 'procedure',
        ),
      );
    }

    for (final import in imports.reversed) {
      final createdDate = _dateOnly(import.createdAt);
      grouped.putIfAbsent(createdDate, () => []);
      grouped[createdDate]!.add(
        TimelineItem(
          title: 'Clinical report imported',
          detail: '${import.recordType.toUpperCase()} from ${import.source}',
          tone: 'summary',
          category: 'clinical',
        ),
      );
    }

    for (final intake in intakeEvents.reversed) {
      if (!intake.eventType.startsWith('medication_')) {
        continue;
      }
      final intakeDate = _dateOnly(intake.loggedAt);
      grouped.putIfAbsent(intakeDate, () => []);
      grouped[intakeDate]!.add(
        TimelineItem(
          title: intake.eventType == 'medication_skipped'
              ? 'Medication skipped'
              : 'Medication taken',
          detail: (intake.notes ?? 'Medication log').trim(),
          tone:
              intake.eventType == 'medication_skipped' ? 'moderate' : 'summary',
          category: 'medication',
        ),
      );
    }

    if (syncState?.lastSyncAt != null) {
      final syncDate = _dateOnly(syncState!.lastSyncAt!);
      grouped.putIfAbsent(syncDate, () => []);
      final staleHours = _staleSyncHours(syncState);
      grouped[syncDate]!.add(
        TimelineItem(
          title: 'Health sync completed',
          detail: _syncFreshnessLabel(syncState),
          tone: (syncState.lastError == null || syncState.lastError!.isEmpty) &&
                  (staleHours == null || staleHours <= 72)
              ? 'sync_ok'
              : 'sync_degraded',
          category: 'sync',
        ),
      );
    }

    final sortedDates = grouped.keys.toList()
      ..sort((left, right) => right.compareTo(left));
    return sortedDates
        .map((date) => TimelineGroup(dateLocal: date, items: grouped[date]!))
        .toList(growable: false);
  }

  double? _staleSyncHours(SyncStateRecord? syncState) {
    final lastSyncAt = syncState?.lastSyncAt;
    if (lastSyncAt == null) {
      return null;
    }
    return _nowProvider().difference(lastSyncAt.toUtc()).inMinutes / 60;
  }

  String _syncFreshnessLabel(SyncStateRecord? syncState) {
    final staleHours = _staleSyncHours(syncState);
    if (staleHours == null) {
      return 'No HealthKit sync recorded yet.';
    }
    final errorSuffix =
        (syncState?.lastError == null || syncState!.lastError!.isEmpty)
            ? ''
            : ' Last sync reported an error.';
    if (staleHours < 24) {
      return 'Synced ${staleHours.round()}h ago.$errorSuffix';
    }
    final staleDays = staleHours / 24;
    return 'Synced ${staleDays.toStringAsFixed(staleDays >= 10 ? 0 : 1)}d ago.$errorSuffix';
  }

  String? _syncWarningLabel(SyncStateRecord? syncState) {
    final staleHours = _staleSyncHours(syncState);
    if (syncState?.lastError != null && syncState!.lastError!.isNotEmpty) {
      return 'The last Health sync reported an error. Re-run sync before relying on missing signals.';
    }
    if (staleHours == null) {
      return 'No Health data has been imported yet. Run the initial sync before trusting the dashboard.';
    }
    if (staleHours > 72) {
      return 'Health data is older than 72 hours, so score confidence is reduced until you sync again.';
    }
    if (staleHours > 24) {
      return 'Health data is more than a day old. A fresh sync will improve trend quality.';
    }
    return null;
  }

  String _baselineStatusLabel(BaselineSnapshotRecord? baseline) {
    if (baseline == null) {
      return 'Baseline not started yet';
    }
    return switch (baseline.readinessState) {
      'not_ready' => 'Baseline building: need at least 7 valid days',
      'low_confidence' => 'Baseline building: early reference available',
      'ready' => 'Baseline ready for score comparisons',
      'mature' => 'Baseline mature with 28+ valid days',
      _ => 'Baseline state: ${baseline.readinessState}',
    };
  }

  String _recommendedAction({
    required FlareRiskScoreRecord? latestScore,
    required BaselineSnapshotRecord? latestBaseline,
    required SyncStateRecord? syncState,
    required SymptomRecord? latestSymptom,
  }) {
    final staleHours = _staleSyncHours(syncState);
    if (syncState?.lastSyncAt == null) {
      return 'Grant Health access and sync the last 30 days to populate local summaries.';
    }
    if (staleHours != null && staleHours > 72) {
      return 'Re-sync Apple Health before you interpret today\'s trend cards or score drivers.';
    }
    if (latestBaseline == null ||
        latestBaseline.readinessState == 'not_ready') {
      return 'Keep syncing daily to build a usable personal baseline.';
    }
    if (latestBaseline.readinessState == 'low_confidence') {
      return 'Keep collecting days so the baseline becomes stable enough for stronger comparisons.';
    }
    if (latestScore == null) {
      return 'Run sync again or save a symptom note to compute the next local score.';
    }
    final contextReason =
        latestScore.contributionJson['context_attribution_reason'] as String?;
    if (contextReason == 'looks_workout_related') {
      return 'Your score is reading recent activity as context. Check whether the pattern settles after recovery.';
    }
    if (contextReason == 'looks_meal_timed') {
      return 'Some changes line up with meal or intake timing. Keep logging symptoms so patterns become clearer.';
    }
    if (contextReason == 'symptoms_changed_even_with_quiet_heart_rate') {
      return 'Symptoms changed even though heart rate stayed quiet. Keep tracking and seek care if symptoms worsen.';
    }
    if (latestScore.riskBand == 'high' || latestScore.riskBand == 'critical') {
      return 'Review the biggest drivers and seek medical guidance if symptoms are worsening or concerning.';
    }
    if (latestSymptom == null) {
      return 'If GI symptoms show up today, log a short note so the score can incorporate them.';
    }
    return 'Open the grounded summary to review today\'s local pattern and recent drivers.';
  }

  String _symptomSummary(SymptomRecord symptom) {
    final severityLabel = symptom.severity == null
        ? 'severity not recorded'
        : '${symptom.severity}/10';
    final mealLabel = symptom.mealRelation == null
        ? ''
        : ' ${symptom.mealRelation!.replaceAll('_', ' ')}';
    return '${symptom.symptomType} $severityLabel$mealLabel'.trim();
  }

  List<DriverChipSnapshot> _driverChips(FlareRiskScoreRecord? score) {
    if (score == null) {
      return const <DriverChipSnapshot>[];
    }

    final labels = <String, String>{
      'hrv_points': 'Recovery shift',
      'resting_hr_points': 'Resting pulse',
      'sleep_points': 'Sleep dip',
      'symptom_points': 'Recent symptoms',
      'steps_points': 'Lower activity',
      'sparse_vitals_points': 'Limited signals',
      'respiratory_points': 'Breathing change',
      'mobility_points': 'Movement change',
      'medication_context_points': 'Medication context',
      'clinical_anchor_points': 'Clinical marker',
      'false_negative_guard_points': 'Guardrail check',
    };

    final drivers = score.contributionJson.entries
        .where(
          (entry) =>
              entry.key.endsWith('_points') && entry.key != 'total_points',
        )
        .map(
          (entry) =>
              (key: entry.key, points: (entry.value as num?)?.round() ?? 0),
        )
        .where((entry) => entry.points > 0)
        .toList(growable: false)
      ..sort((left, right) => right.points.compareTo(left.points));

    return drivers
        .take(4)
        .map(
          (entry) => DriverChipSnapshot(
            label: labels[entry.key] ?? entry.key.replaceAll('_', ' '),
            valueLabel: '+${entry.points} pts',
            points: entry.points,
          ),
        )
        .toList(growable: false);
  }

  String _dateOnly(DateTime value) {
    final utc = value.toUtc();
    final year = utc.year.toString().padLeft(4, '0');
    final month = utc.month.toString().padLeft(2, '0');
    final day = utc.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  double? _meanMetric(Iterable<DailySummaryRecord> summaries, String key) {
    final values = summaries
        .map((item) => item.summaryJson[key])
        .whereType<num>()
        .map((item) => item.toDouble())
        .toList(growable: false);
    if (values.isEmpty) {
      return null;
    }
    return values.reduce((left, right) => left + right) / values.length;
  }

  String _deltaLabel({required double? current, required double? previous}) {
    if (current == null || previous == null || previous == 0) {
      return 'Need more history';
    }
    final delta = ((current - previous) / previous) * 100;
    final prefix = delta > 0 ? '+' : '';
    return '$prefix${delta.toStringAsFixed(0)}% vs prior week';
  }

  String _formatNullable(double? value, {int digits = 1, String suffix = ''}) {
    if (value == null) {
      return 'n/a';
    }
    final rounded =
        digits == 0 ? value.round().toString() : value.toStringAsFixed(digits);
    return '$rounded$suffix';
  }
}

extension<T> on List<T> {
  Iterable<T> takeLast(int count) {
    if (isEmpty) {
      return List<T>.empty(growable: false);
    }
    final start = length > count ? length - count : 0;
    return sublist(start);
  }

  Iterable<T> takePreviousWindow(int count) {
    if (length <= count) {
      return List<T>.empty(growable: false);
    }
    final end = length - count;
    final start = end > count ? end - count : 0;
    return sublist(start, end);
  }
}
