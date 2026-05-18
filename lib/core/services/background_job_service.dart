import '../database/app_database.dart';
import 'diagnostic_log_service.dart';

typedef BackgroundJobHandler = Future<void> Function(BackgroundJobRecord job);

class BackgroundJobRecord {
  const BackgroundJobRecord({
    required this.id,
    required this.jobType,
    required this.scheduledFor,
    required this.status,
    required this.retryCount,
    required this.idempotencyKey,
    this.startedAt,
    this.completedAt,
    this.error,
  });

  final int id;
  final String jobType;
  final DateTime scheduledFor;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final String status;
  final String? error;
  final int retryCount;
  final String idempotencyKey;

  bool get isTerminal => status == BackgroundJobService.statusCompleted;
}

class BackgroundJobRunResult {
  const BackgroundJobRunResult({
    required this.claimed,
    required this.completed,
    required this.failed,
    required this.retried,
  });

  final int claimed;
  final int completed;
  final int failed;
  final int retried;
}

class BackgroundJobService {
  BackgroundJobService({
    required AppDatabase database,
    DiagnosticLogService? diagnosticLogService,
    DateTime Function()? nowProvider,
    Duration retryDelay = const Duration(minutes: 15),
    int maxRetries = 3,
  })  : _database = database,
        _diagnosticLogService = diagnosticLogService,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc()),
        _retryDelay = retryDelay,
        _maxRetries = maxRetries;

  static const statusPending = 'pending';
  static const statusRunning = 'running';
  static const statusCompleted = 'completed';
  static const statusFailed = 'failed';

  static const jobDailySummary = 'daily_summary';
  static const jobProactivePlan = 'proactive_plan';
  static const jobNotificationPlan = 'notification_plan';
  static const jobHealthRefresh = 'health_refresh';

  final AppDatabase _database;
  final DiagnosticLogService? _diagnosticLogService;
  final DateTime Function() _nowProvider;
  final Duration _retryDelay;
  final int _maxRetries;

  Future<BackgroundJobRecord> schedule({
    required String jobType,
    required DateTime scheduledFor,
    required String idempotencyKey,
  }) async {
    final database = await _database.open();
    final existing = await database.query(
      'bg_jobs',
      where: 'idempotency_key = ?',
      whereArgs: [idempotencyKey],
      limit: 1,
    );
    if (existing.isNotEmpty) return _recordFromRow(existing.single);

    final id = await database.insert('bg_jobs', {
      'job_type': jobType,
      'scheduled_for': scheduledFor.toUtc().toIso8601String(),
      'status': statusPending,
      'retry_count': 0,
      'idempotency_key': idempotencyKey,
    });
    await _diagnosticLogService?.info(
      'background_job_scheduled',
      category: DiagnosticLogService.categoryApp,
      message: 'A local background job was scheduled.',
      metadata: {
        'job_type': jobType,
        'scheduled_for': scheduledFor.toUtc().toIso8601String(),
      },
    );
    return (await load(id))!;
  }

  Future<List<BackgroundJobRecord>> scheduleDailySummaries({
    required DateTime throughDate,
    int lookbackDays = 7,
  }) async {
    final scheduled = <BackgroundJobRecord>[];
    final anchor = DateTime.utc(
      throughDate.toUtc().year,
      throughDate.toUtc().month,
      throughDate.toUtc().day,
    );
    for (var offset = lookbackDays - 1; offset >= 0; offset--) {
      final day = anchor.subtract(Duration(days: offset));
      scheduled.add(
        await schedule(
          jobType: jobDailySummary,
          scheduledFor: day.add(const Duration(hours: 23, minutes: 55)),
          idempotencyKey: 'daily_summary:${_dateKey(day)}',
        ),
      );
    }
    return scheduled;
  }

  Future<BackgroundJobRecord?> claimNextDue({DateTime? now}) async {
    final database = await _database.open();
    final claimTime = (now ?? _nowProvider()).toUtc();
    return database.transaction((txn) async {
      final rows = await txn.query(
        'bg_jobs',
        where: 'status = ? AND scheduled_for <= ?',
        whereArgs: [statusPending, claimTime.toIso8601String()],
        orderBy: 'scheduled_for ASC, id ASC',
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      final id = (row['id'] as num).toInt();
      await txn.update(
        'bg_jobs',
        {
          'status': statusRunning,
          'started_at': claimTime.toIso8601String(),
          'error': null,
        },
        where: 'id = ? AND status = ?',
        whereArgs: [id, statusPending],
      );
      final updated = await txn.query(
        'bg_jobs',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      return _recordFromRow(updated.single);
    });
  }

  Future<BackgroundJobRunResult> runDue({
    required Map<String, BackgroundJobHandler> handlers,
    int maxJobs = 10,
    DateTime? now,
  }) async {
    var claimed = 0;
    var completed = 0;
    var failed = 0;
    var retried = 0;
    for (var index = 0; index < maxJobs; index++) {
      final job = await claimNextDue(now: now);
      if (job == null) break;
      claimed++;
      final handler = handlers[job.jobType];
      if (handler == null) {
        await markFailed(job.id, 'No handler registered for ${job.jobType}.');
        failed++;
        continue;
      }
      try {
        await handler(job);
        await markCompleted(job.id);
        completed++;
      } catch (error, stackTrace) {
        final didRetry = await markFailed(
          job.id,
          error.toString(),
          stackTrace: stackTrace,
        );
        if (didRetry) {
          retried++;
        } else {
          failed++;
        }
      }
    }
    return BackgroundJobRunResult(
      claimed: claimed,
      completed: completed,
      failed: failed,
      retried: retried,
    );
  }

  Future<void> markCompleted(int id) async {
    final database = await _database.open();
    final now = _nowProvider().toUtc();
    await database.update(
      'bg_jobs',
      {
        'status': statusCompleted,
        'completed_at': now.toIso8601String(),
        'error': null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<bool> markFailed(
    int id,
    String error, {
    StackTrace? stackTrace,
  }) async {
    final job = await load(id);
    if (job == null) return false;
    final now = _nowProvider().toUtc();
    final nextRetryCount = job.retryCount + 1;
    final shouldRetry = nextRetryCount <= _maxRetries;
    final database = await _database.open();
    await database.update(
      'bg_jobs',
      {
        'status': shouldRetry ? statusPending : statusFailed,
        'started_at': shouldRetry ? null : job.startedAt?.toIso8601String(),
        'completed_at': shouldRetry ? null : now.toIso8601String(),
        'scheduled_for': shouldRetry
            ? now.add(_retryDelay * nextRetryCount).toIso8601String()
            : job.scheduledFor.toIso8601String(),
        'error': _truncate(error, 500),
        'retry_count': nextRetryCount,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await _diagnosticLogService?.error(
      'background_job_failed',
      category: DiagnosticLogService.categoryApp,
      message: shouldRetry
          ? 'A local background job failed and will retry.'
          : 'A local background job failed permanently.',
      error: error,
      stackTrace: stackTrace,
      metadata: {
        'job_type': job.jobType,
        'retry_count': nextRetryCount,
        'will_retry': shouldRetry,
      },
    );
    return shouldRetry;
  }

  Future<BackgroundJobRecord?> load(int id) async {
    final database = await _database.open();
    final rows = await database.query(
      'bg_jobs',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _recordFromRow(rows.single);
  }

  Future<List<BackgroundJobRecord>> latest({int limit = 50}) async {
    final database = await _database.open();
    final rows = await database.query(
      'bg_jobs',
      orderBy: 'scheduled_for DESC, id DESC',
      limit: limit,
    );
    return rows.map(_recordFromRow).toList(growable: false);
  }

  BackgroundJobRecord _recordFromRow(Map<String, Object?> row) {
    return BackgroundJobRecord(
      id: (row['id'] as num).toInt(),
      jobType: row['job_type'] as String,
      scheduledFor: DateTime.parse(row['scheduled_for'] as String).toUtc(),
      startedAt: _parseDate(row['started_at']),
      completedAt: _parseDate(row['completed_at']),
      status: row['status'] as String,
      error: row['error'] as String?,
      retryCount: (row['retry_count'] as num).toInt(),
      idempotencyKey: row['idempotency_key'] as String,
    );
  }

  static DateTime? _parseDate(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  static String _dateKey(DateTime value) {
    final utc = value.toUtc();
    return DateTime.utc(
      utc.year,
      utc.month,
      utc.day,
    ).toIso8601String().substring(0, 10);
  }

  static String _truncate(String value, int maxLength) {
    if (value.length <= maxLength) return value;
    return value.substring(0, maxLength);
  }
}
