import 'background_job_service.dart';
import 'hierarchical_summary_service.dart';
import 'proactive_open_service.dart';

class BackgroundOrchestrationService {
  BackgroundOrchestrationService({
    required BackgroundJobService backgroundJobs,
    required HierarchicalSummaryService summaries,
    required ProactiveOpenService proactiveOpen,
    DateTime Function()? nowProvider,
  })  : _backgroundJobs = backgroundJobs,
        _summaries = summaries,
        _proactiveOpen = proactiveOpen,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final BackgroundJobService _backgroundJobs;
  final HierarchicalSummaryService _summaries;
  final ProactiveOpenService _proactiveOpen;
  final DateTime Function() _nowProvider;

  Future<List<BackgroundJobRecord>> scheduleDailyMaintenance({
    DateTime? throughDate,
    int summaryLookbackDays = 7,
  }) async {
    final targetDate = (throughDate ?? _nowProvider()).toUtc();
    final now = _nowProvider().toUtc();
    final scheduled = <BackgroundJobRecord>[];
    scheduled.addAll(
      await _backgroundJobs.scheduleDailySummaries(
        throughDate: targetDate,
        lookbackDays: summaryLookbackDays,
      ),
    );
    scheduled.add(
      await _backgroundJobs.schedule(
        jobType: BackgroundJobService.jobProactivePlan,
        scheduledFor: now,
        idempotencyKey: 'proactive_plan:${_dateKey(now)}',
      ),
    );
    return scheduled;
  }

  Future<BackgroundJobRunResult> runDue({int maxJobs = 10}) {
    return _backgroundJobs.runDue(
      handlers: {
        BackgroundJobService.jobDailySummary: _runDailySummary,
        BackgroundJobService.jobProactivePlan: _runProactivePlan,
      },
      maxJobs: maxJobs,
      now: _nowProvider(),
    );
  }

  Future<void> _runDailySummary(BackgroundJobRecord job) async {
    final day =
        _dateFromIdempotencyKey(job.idempotencyKey) ?? job.scheduledFor.toUtc();
    await _summaries.generateForRange(
      level: 'daily',
      rangeStart: day,
      rangeEnd: day,
    );
  }

  Future<void> _runProactivePlan(BackgroundJobRecord job) async {
    await _proactiveOpen.evaluate(
      evidence: const ProactiveOpenEvidence(
        allowDailyOpeningCheckIn: false,
        overdueCheckIn: true,
      ),
    );
  }

  static DateTime? _dateFromIdempotencyKey(String key) {
    final rawDate = key.split(':').last;
    return DateTime.tryParse('${rawDate}T00:00:00Z');
  }

  static String _dateKey(DateTime value) {
    final utc = value.toUtc();
    return DateTime.utc(
      utc.year,
      utc.month,
      utc.day,
    ).toIso8601String().substring(0, 10);
  }
}
