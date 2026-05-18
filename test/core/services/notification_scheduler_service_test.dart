import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/app_database.dart';
import 'package:gemma_flares/core/services/notification_scheduler_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempRoot;
  late AppDatabase database;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'gemma_flares_notifications_test',
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

  test('allows supported trigger outside limits', () async {
    final service = _service(database);

    final decision = await service.evaluateSchedule(
      triggerType: 'hrv_drop',
      desiredAt: DateTime.utc(2026, 5, 5, 13),
    );

    expect(decision.allowed, isTrue);
    expect(decision.reason, 'allowed');
  });

  test('blocks during quiet hours', () async {
    final service = _service(database);

    final decision = await service.evaluateSchedule(
      triggerType: 'missed_med',
      desiredAt: DateTime.utc(2026, 5, 5, 3),
    );

    expect(decision.allowed, isFalse);
    expect(decision.reason, 'quiet_hours');
  });

  test('blocks after max notifications per day', () async {
    final service = _service(database);
    await _insertScheduled(database, 'hrv_drop', DateTime.utc(2026, 5, 5, 9));
    await _insertScheduled(database, 'new_lab', DateTime.utc(2026, 5, 5, 10));

    final decision = await service.evaluateSchedule(
      triggerType: 'risk_trend',
      desiredAt: DateTime.utc(2026, 5, 5, 13),
    );

    expect(decision.allowed, isFalse);
    expect(decision.reason, 'daily_limit_reached');
    expect(decision.scheduledCountToday, 2);
  });

  test('blocks same trigger inside cooldown', () async {
    final service = _service(database);
    await _insertScheduled(
      database,
      'symptom_escalation',
      DateTime.utc(2026, 5, 5, 9),
    );

    final decision = await service.evaluateSchedule(
      triggerType: 'symptom_escalation',
      desiredAt: DateTime.utc(2026, 5, 5, 13),
    );

    expect(decision.allowed, isFalse);
    expect(decision.reason, 'trigger_cooldown_active');
    expect(decision.minutesSinceLastTrigger, 240);
  });

  test('schedule writes local pregenerated content', () async {
    final service = _service(database);

    final id = await service.schedule(
      ProactiveNotificationRequest(
        triggerType: 'new_lab',
        message: 'Your new lab is ready to review in Gemma Flares.',
        scheduleAt: DateTime.utc(2026, 5, 5, 13),
        promptSeed: 'new_lab:2026-05-05',
      ),
    );

    expect(id, isNotNull);
    final opened = await database.open();
    final rows = await opened.query('scheduled_notifications');
    expect(
      rows.single['gemma_content'],
      'Your new lab is ready to review in Gemma Flares.',
    );
    expect(rows.single['prompt_seed'], 'new_lab:2026-05-05');
  });
}

NotificationSchedulerService _service(AppDatabase database) {
  return NotificationSchedulerService(
    database: database,
    nowProvider: () => DateTime.utc(2026, 5, 5, 12),
  );
}

Future<void> _insertScheduled(
  AppDatabase appDatabase,
  String triggerType,
  DateTime scheduledAt,
) async {
  final database = await appDatabase.open();
  await database.insert('scheduled_notifications', {
    'scheduled_at': scheduledAt.toUtc().toIso8601String(),
    'trigger_type': triggerType,
    'gemma_content': 'Check in with Gemma Flares.',
    'prompt_seed': triggerType,
    'fired': 0,
    'dismissed': 0,
    'created_at': DateTime.utc(2026, 5, 5, 8).toIso8601String(),
  });
}
