import '../database/app_database.dart';
import 'diagnostic_log_service.dart';

class ProactiveNotificationRequest {
  const ProactiveNotificationRequest({
    required this.triggerType,
    required this.message,
    required this.scheduleAt,
    this.promptSeed,
  });

  final String triggerType;
  final String message;
  final DateTime scheduleAt;
  final String? promptSeed;
}

class NotificationScheduleDecision {
  const NotificationScheduleDecision({
    required this.allowed,
    required this.reason,
    this.triggerType,
    this.scheduledCountToday = 0,
    this.minutesSinceLastTrigger,
  });

  final bool allowed;
  final String reason;
  final String? triggerType;
  final int scheduledCountToday;
  final int? minutesSinceLastTrigger;
}

class NotificationSchedulerService {
  NotificationSchedulerService({
    required AppDatabase database,
    DiagnosticLogService? diagnosticLogService,
    DateTime Function()? nowProvider,
  })  : _database = database,
        _diagnosticLogService = diagnosticLogService,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final AppDatabase _database;
  final DiagnosticLogService? _diagnosticLogService;
  final DateTime Function() _nowProvider;

  static const supportedTriggerTypes = {
    'hrv_drop',
    'missed_med',
    'symptom_escalation',
    'new_lab',
    'overdue_checkin',
    'risk_trend',
    'daily_open_checkin',
  };

  static const _defaultTriggerCooldowns = <String, Duration>{
    'hrv_drop': Duration(hours: 12),
    'missed_med': Duration(hours: 8),
    'symptom_escalation': Duration(hours: 8),
    'new_lab': Duration(hours: 24),
    'overdue_checkin': Duration(hours: 24),
    'risk_trend': Duration(hours: 12),
    'daily_open_checkin': Duration(hours: 24),
  };

  Future<bool> canSchedule(DateTime desiredAt) async {
    final decision = await evaluateSchedule(
      triggerType: 'unspecified',
      desiredAt: desiredAt,
    );
    return decision.allowed;
  }

  Future<NotificationScheduleDecision> evaluateSchedule({
    required String triggerType,
    required DateTime desiredAt,
  }) async {
    final db = await _database.open();
    final prefs = await db.query('notification_preferences');
    final prefMap = {
      for (final row in prefs)
        row['key'] as String: row['value_json'] as String,
    };
    if (prefMap['global_off'] == 'true') {
      return const NotificationScheduleDecision(
        allowed: false,
        reason: 'notifications_disabled',
      );
    }
    if (prefMap['snooze_until'] != null && prefMap['snooze_until'] != 'null') {
      final snoozeUntil = DateTime.tryParse(prefMap['snooze_until']!);
      if (snoozeUntil != null && snoozeUntil.isAfter(_nowProvider())) {
        return const NotificationScheduleDecision(
          allowed: false,
          reason: 'snoozed',
        );
      }
    }

    final hour = desiredAt.toLocal().hour;
    final quietStart = int.tryParse(prefMap['quiet_hours_start'] ?? '22') ?? 22;
    final quietEnd = int.tryParse(prefMap['quiet_hours_end'] ?? '8') ?? 8;
    if (_insideQuietHours(hour, quietStart, quietEnd)) {
      return const NotificationScheduleDecision(
        allowed: false,
        reason: 'quiet_hours',
      );
    }

    final normalizedDesiredAt = desiredAt.toUtc();
    final dayStart = DateTime.utc(
      normalizedDesiredAt.year,
      normalizedDesiredAt.month,
      normalizedDesiredAt.day,
    );
    final dayEnd = dayStart.add(const Duration(days: 1));
    final rows = await db.query(
      'scheduled_notifications',
      where: 'scheduled_at >= ? AND scheduled_at < ?',
      whereArgs: [dayStart.toIso8601String(), dayEnd.toIso8601String()],
    );
    final maxPerDay = int.tryParse(prefMap['max_per_day'] ?? '2') ?? 2;
    if (rows.length >= maxPerDay) {
      return NotificationScheduleDecision(
        allowed: false,
        reason: 'daily_limit_reached',
        triggerType: triggerType,
        scheduledCountToday: rows.length,
      );
    }

    if (supportedTriggerTypes.contains(triggerType)) {
      final lastRows = await db.query(
        'scheduled_notifications',
        columns: ['scheduled_at'],
        where: 'trigger_type = ?',
        whereArgs: [triggerType],
        orderBy: 'scheduled_at DESC',
        limit: 1,
      );
      if (lastRows.isNotEmpty) {
        final lastAt = DateTime.tryParse(
          lastRows.single['scheduled_at'] as String,
        )?.toUtc();
        final cooldown = _defaultTriggerCooldowns[triggerType];
        if (lastAt != null &&
            cooldown != null &&
            normalizedDesiredAt.difference(lastAt) < cooldown) {
          return NotificationScheduleDecision(
            allowed: false,
            reason: 'trigger_cooldown_active',
            triggerType: triggerType,
            scheduledCountToday: rows.length,
            minutesSinceLastTrigger:
                normalizedDesiredAt.difference(lastAt).inMinutes,
          );
        }
      }
    }

    return NotificationScheduleDecision(
      allowed: true,
      reason: 'allowed',
      triggerType: triggerType,
      scheduledCountToday: rows.length,
    );
  }

  Future<int?> schedule(ProactiveNotificationRequest request) async {
    final decision = await evaluateSchedule(
      triggerType: request.triggerType,
      desiredAt: request.scheduleAt,
    );
    if (!decision.allowed) {
      await _diagnosticLogService?.info(
        'notification_schedule_blocked',
        category: DiagnosticLogService.categorySettings,
        message: 'A local proactive notification was not scheduled.',
        metadata: {
          'trigger_type': request.triggerType,
          'reason': decision.reason,
          'scheduled_count_today': decision.scheduledCountToday,
        },
      );
      return null;
    }
    final db = await _database.open();
    final id = await db.insert('scheduled_notifications', {
      'scheduled_at': request.scheduleAt.toUtc().toIso8601String(),
      'trigger_type': request.triggerType,
      'gemma_content': request.message,
      'prompt_seed': request.promptSeed,
      'fired': 0,
      'dismissed': 0,
      'created_at': _nowProvider().toUtc().toIso8601String(),
    });
    await _diagnosticLogService?.info(
      'notification_scheduled',
      category: DiagnosticLogService.categorySettings,
      message: 'A local proactive notification was scheduled.',
      metadata: {'trigger_type': request.triggerType},
    );
    return id;
  }

  static bool _insideQuietHours(int hour, int start, int end) {
    if (start == end) return false;
    if (start < end) return hour >= start && hour < end;
    return hour >= start || hour < end;
  }
}
