import '../database/wearable_sample_repository.dart';
import 'cosinor_service.dart';
import 'daily_summary_service.dart';
import 'diagnostic_log_service.dart';
import 'flare_label_service.dart';
import 'risk_engine_service.dart';

class AnalyticsRefreshResult {
  const AnalyticsRefreshResult({
    required this.reason,
    required this.primaryDate,
    required this.recomputedScoreDates,
    required this.labelStartDate,
    required this.labelEndDate,
    required this.createdPrimarySummary,
  });

  final String reason;
  final String primaryDate;
  final List<String> recomputedScoreDates;
  final String? labelStartDate;
  final String? labelEndDate;
  final bool createdPrimarySummary;
}

class AnalyticsRefreshService {
  AnalyticsRefreshService({
    required WearableSampleRepository repository,
    required DailySummaryService dailySummaryService,
    required FlareLabelService flareLabelService,
    required CosinorService cosinorService,
    required RiskEngineService riskEngineService,
    DiagnosticLogService? diagnosticLogService,
    DateTime Function()? nowProvider,
  })  : _repository = repository,
        _dailySummaryService = dailySummaryService,
        _flareLabelService = flareLabelService,
        _cosinorService = cosinorService,
        _riskEngineService = riskEngineService,
        _diagnosticLogService = diagnosticLogService,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final WearableSampleRepository _repository;
  final DailySummaryService _dailySummaryService;
  final FlareLabelService _flareLabelService;
  final CosinorService _cosinorService;
  final RiskEngineService _riskEngineService;
  final DiagnosticLogService? _diagnosticLogService;
  final DateTime Function() _nowProvider;

  Future<AnalyticsRefreshResult> refreshForSymptom({
    required DateTime loggedAt,
    String? sessionId,
    bool isUserAction = true,
  }) {
    final primaryDate = _dateOnly(loggedAt.toUtc());
    return _refresh(
      reason: 'symptom_logged',
      primaryDate: primaryDate,
      scoreStartDate: primaryDate,
      scoreEndDate: primaryDate,
      sessionId: sessionId,
      isUserAction: isUserAction,
    );
  }

  Future<AnalyticsRefreshResult> refreshForCheckIn({
    required String surveyDate,
    String? sessionId,
    bool isUserAction = true,
  }) {
    return _refresh(
      reason: 'checkin_saved',
      primaryDate: surveyDate,
      labelStartDate: surveyDate,
      labelEndDate: _offsetDate(surveyDate, 6),
      scoreStartDate: surveyDate,
      scoreEndDate: _offsetDate(surveyDate, 6),
      sessionId: sessionId,
      isUserAction: isUserAction,
    );
  }

  Future<AnalyticsRefreshResult> refreshForLab({
    required String drawnDate,
    String? sessionId,
    bool isUserAction = true,
  }) {
    return _refresh(
      reason: 'lab_saved',
      primaryDate: drawnDate,
      labelStartDate: _offsetDate(drawnDate, -7),
      labelEndDate: _offsetDate(drawnDate, 7),
      scoreStartDate: _offsetDate(drawnDate, -7),
      scoreEndDate: _offsetDate(drawnDate, 7),
      sessionId: sessionId,
      isUserAction: isUserAction,
    );
  }

  Future<AnalyticsRefreshResult> refreshForLabDates({
    required Iterable<String> drawnDates,
    String? sessionId,
    bool isUserAction = true,
  }) {
    final dates = drawnDates.toSet().toList(growable: false)..sort();
    if (dates.isEmpty) {
      return Future.value(
        const AnalyticsRefreshResult(
          reason: 'lab_batch_saved',
          primaryDate: '',
          recomputedScoreDates: [],
          labelStartDate: null,
          labelEndDate: null,
          createdPrimarySummary: false,
        ),
      );
    }
    return _refresh(
      reason: 'lab_batch_saved',
      primaryDate: dates.last,
      labelStartDate: _offsetDate(dates.first, -7),
      labelEndDate: _offsetDate(dates.last, 7),
      scoreStartDate: _offsetDate(dates.first, -7),
      scoreEndDate: _offsetDate(dates.last, 7),
      sessionId: sessionId,
      isUserAction: isUserAction,
    );
  }

  Future<AnalyticsRefreshResult> refreshForProcedure({
    required String procedureDate,
    String? sessionId,
    bool isUserAction = true,
  }) {
    return _refresh(
      reason: 'procedure_saved',
      primaryDate: procedureDate,
      labelStartDate: procedureDate,
      labelEndDate: _offsetDate(procedureDate, 30),
      scoreStartDate: procedureDate,
      scoreEndDate: _offsetDate(procedureDate, 30),
      sessionId: sessionId,
      isUserAction: isUserAction,
    );
  }

  Future<AnalyticsRefreshResult> refreshForIntakeEvent({
    required DateTime loggedAt,
    String? sessionId,
    bool isUserAction = true,
  }) {
    final primaryDate = _dateOnly(loggedAt.toUtc());
    return _refresh(
      reason: 'intake_event_saved',
      primaryDate: primaryDate,
      scoreStartDate: primaryDate,
      scoreEndDate: primaryDate,
      sessionId: sessionId,
      isUserAction: isUserAction,
    );
  }

  Future<AnalyticsRefreshResult> _refresh({
    required String reason,
    required String primaryDate,
    required String scoreStartDate,
    required String scoreEndDate,
    String? labelStartDate,
    String? labelEndDate,
    String? sessionId,
    bool isUserAction = false,
  }) async {
    if (primaryDate.isEmpty) {
      return AnalyticsRefreshResult(
        reason: reason,
        primaryDate: primaryDate,
        recomputedScoreDates: const [],
        labelStartDate: labelStartDate,
        labelEndDate: labelEndDate,
        createdPrimarySummary: false,
      );
    }

    if (labelStartDate != null && labelEndDate != null) {
      await _flareLabelService.recomputeLabels(
        startDate: labelStartDate,
        endDate: labelEndDate,
      );
    }

    final requestedDates = _enumerateDates(scoreStartDate, scoreEndDate);
    final existingSummaries = await _repository.getDailySummaries();
    final existingSummaryDates =
        existingSummaries.map((item) => item.dateLocal).toSet();
    final shouldCreatePrimarySummary =
        primaryDate == _dateOnly(_nowProvider().toUtc()) &&
            existingSummaryDates.isNotEmpty;

    final scoreDates = requestedDates
        .where(existingSummaryDates.contains)
        .toList(growable: true);
    if (shouldCreatePrimarySummary && !scoreDates.contains(primaryDate)) {
      scoreDates.add(primaryDate);
    }
    scoreDates.sort();

    if (scoreDates.isNotEmpty) {
      await _dailySummaryService.recomputeDates(scoreDates);
      final latestSummary = await _repository.getLatestDailySummary();
      if (latestSummary != null) {
        await _dailySummaryService.recomputeBaseline(
          asOfDate: latestSummary.dateLocal,
        );
      }
      await _cosinorService.recomputeDates(scoreDates);
      await _riskEngineService.recomputeDates(
        scoreDates,
        sessionId: sessionId,
        triggerReason: reason,
        isUserAction: isUserAction,
      );
    }

    if (_diagnosticLogService != null) {
      try {
        await _diagnosticLogService.info(
          'analytics_refresh_completed',
          category: DiagnosticLogService.categoryRiskEngine,
          message: 'Analytics refresh completed after a local data change.',
          metadata: {
            'reason': reason,
            'primary_date': primaryDate,
            'label_start_date': labelStartDate,
            'label_end_date': labelEndDate,
            'score_start_date': scoreStartDate,
            'score_end_date': scoreEndDate,
            'recomputed_score_date_count': scoreDates.length,
            'created_primary_summary':
                shouldCreatePrimarySummary && scoreDates.contains(primaryDate),
          },
        );
      } catch (_) {
        // Local analytics refresh must not fail because diagnostic logging is unavailable.
      }
    }

    return AnalyticsRefreshResult(
      reason: reason,
      primaryDate: primaryDate,
      recomputedScoreDates: scoreDates,
      labelStartDate: labelStartDate,
      labelEndDate: labelEndDate,
      createdPrimarySummary:
          shouldCreatePrimarySummary && scoreDates.contains(primaryDate),
    );
  }

  List<String> _enumerateDates(String startDate, String endDate) {
    final dates = <String>[];
    for (var current = startDate;
        current.compareTo(endDate) <= 0;
        current = _offsetDate(current, 1)) {
      dates.add(current);
    }
    return dates;
  }

  String _offsetDate(String dateStr, int days) {
    final date = DateTime.parse(
      '${dateStr}T00:00:00Z',
    ).add(Duration(days: days));
    return _dateOnly(date);
  }

  String _dateOnly(DateTime date) {
    final utc = date.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')}';
  }
}
