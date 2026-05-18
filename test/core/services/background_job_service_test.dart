import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/services/background_job_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_bg_jobs_test',
    );
    database = AppDatabase(
      migrationLoader: (assetPath) async => File(assetPath).readAsString(),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectoryProvider: () async => tempRoot.path,
    );
  });

  tearDown(() async {
    await database.close();
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test('schedule is idempotent by key', () async {
    final service = _service(database);

    final first = await service.schedule(
      jobType: BackgroundJobService.jobDailySummary,
      scheduledFor: DateTime.utc(2026, 5, 4, 23, 55),
      idempotencyKey: 'daily_summary:2026-05-04',
    );
    final second = await service.schedule(
      jobType: BackgroundJobService.jobDailySummary,
      scheduledFor: DateTime.utc(2026, 5, 4, 23, 55),
      idempotencyKey: 'daily_summary:2026-05-04',
    );

    expect(second.id, first.id);
    expect(await service.latest(), hasLength(1));
  });

  test('claimNextDue claims oldest pending due job', () async {
    final service = _service(database);
    await service.schedule(
      jobType: 'later',
      scheduledFor: DateTime.utc(2026, 5, 5, 14),
      idempotencyKey: 'later',
    );
    await service.schedule(
      jobType: 'now',
      scheduledFor: DateTime.utc(2026, 5, 5, 11),
      idempotencyKey: 'now',
    );

    final claimed = await service.claimNextDue(
      now: DateTime.utc(2026, 5, 5, 13),
    );

    expect(claimed, isNotNull);
    expect(claimed!.jobType, 'now');
    expect(claimed.status, BackgroundJobService.statusRunning);
    expect(claimed.startedAt, DateTime.utc(2026, 5, 5, 13));
  });

  test('runDue completes registered handler jobs', () async {
    final service = _service(database);
    await service.schedule(
      jobType: BackgroundJobService.jobDailySummary,
      scheduledFor: DateTime.utc(2026, 5, 5, 11),
      idempotencyKey: 'daily_summary:2026-05-05',
    );
    final handled = <String>[];

    final result = await service.runDue(
      handlers: {
        BackgroundJobService.jobDailySummary: (job) async {
          handled.add(job.idempotencyKey);
        },
      },
      now: DateTime.utc(2026, 5, 5, 13),
    );
    final job = (await service.latest()).single;

    expect(result.claimed, 1);
    expect(result.completed, 1);
    expect(handled, ['daily_summary:2026-05-05']);
    expect(job.status, BackgroundJobService.statusCompleted);
    expect(job.completedAt, DateTime.utc(2026, 5, 5, 13));
  });

  test('runDue retries failures then marks permanent failure', () async {
    final service = BackgroundJobService(
      database: database,
      nowProvider: () => DateTime.utc(2026, 5, 5, 13),
      retryDelay: const Duration(minutes: 10),
      maxRetries: 1,
    );
    final scheduled = await service.schedule(
      jobType: 'fragile',
      scheduledFor: DateTime.utc(2026, 5, 5, 11),
      idempotencyKey: 'fragile:1',
    );

    final first = await service.runDue(
      handlers: {'fragile': (_) async => throw StateError('boom')},
      now: DateTime.utc(2026, 5, 5, 13),
    );
    final afterRetry = await service.load(scheduled.id);

    expect(first.retried, 1);
    expect(afterRetry!.status, BackgroundJobService.statusPending);
    expect(afterRetry.retryCount, 1);
    expect(afterRetry.scheduledFor, DateTime.utc(2026, 5, 5, 13, 10));

    final second = await service.runDue(
      handlers: {'fragile': (_) async => throw StateError('boom again')},
      now: DateTime.utc(2026, 5, 5, 13, 10),
    );
    final failed = await service.load(scheduled.id);

    expect(second.failed, 1);
    expect(failed!.status, BackgroundJobService.statusFailed);
    expect(failed.retryCount, 2);
    expect(failed.error, contains('boom again'));
  });

  test('scheduleDailySummaries creates one job per day', () async {
    final service = _service(database);

    final jobs = await service.scheduleDailySummaries(
      throughDate: DateTime.utc(2026, 5, 5),
      lookbackDays: 3,
    );

    expect(jobs.map((job) => job.idempotencyKey), [
      'daily_summary:2026-05-03',
      'daily_summary:2026-05-04',
      'daily_summary:2026-05-05',
    ]);
  });
}

BackgroundJobService _service(AppDatabase database) {
  return BackgroundJobService(
    database: database,
    nowProvider: () => DateTime.utc(2026, 5, 5, 13),
  );
}
