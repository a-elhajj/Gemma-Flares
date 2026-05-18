import '../database/app_database.dart';
import 'diagnostic_log_service.dart';

class ProactiveOpenEvidence {
  const ProactiveOpenEvidence({
    this.hrvDrop = false,
    this.missedMedication = false,
    this.symptomEscalation = false,
    this.newLab = false,
    this.riskTrendRising = false,
    this.overdueCheckIn = false,
    this.allowDailyOpeningCheckIn = true,
  });

  final bool hrvDrop;
  final bool missedMedication;
  final bool symptomEscalation;
  final bool newLab;
  final bool riskTrendRising;
  final bool overdueCheckIn;
  final bool allowDailyOpeningCheckIn;
}

class ProactiveOpenDecision {
  const ProactiveOpenDecision({
    required this.shouldSpeakFirst,
    required this.reason,
    this.triggerType,
    this.openCountToday = 0,
    this.minutesSinceLastOpen,
  });

  final bool shouldSpeakFirst;
  final String reason;
  final String? triggerType;
  final int openCountToday;
  final int? minutesSinceLastOpen;
}

class ProactiveOpenService {
  ProactiveOpenService({
    required AppDatabase database,
    DiagnosticLogService? diagnosticLogService,
    DateTime Function()? nowProvider,
  })  : _database = database,
        _diagnosticLogService = diagnosticLogService,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  static const maxOpensPerDay = 3;
  static const cooldown = Duration(minutes: 240);

  final AppDatabase _database;
  final DiagnosticLogService? _diagnosticLogService;
  final DateTime Function() _nowProvider;

  Future<ProactiveOpenDecision> evaluate({
    required ProactiveOpenEvidence evidence,
  }) async {
    final now = _nowProvider().toUtc();
    final prefs = await _loadNotificationPreferences();
    if (prefs['global_off'] == 'true') {
      return const ProactiveOpenDecision(
        shouldSpeakFirst: false,
        reason: 'notifications_disabled',
      );
    }
    final snoozeUntil = DateTime.tryParse(prefs['snooze_until'] ?? '');
    if (snoozeUntil != null && snoozeUntil.isAfter(now)) {
      return const ProactiveOpenDecision(
        shouldSpeakFirst: false,
        reason: 'snoozed',
      );
    }
    final quietStart = int.tryParse(prefs['quiet_hours_start'] ?? '22') ?? 22;
    final quietEnd = int.tryParse(prefs['quiet_hours_end'] ?? '8') ?? 8;
    if (_insideQuietHours(now.toLocal().hour, quietStart, quietEnd)) {
      return const ProactiveOpenDecision(
        shouldSpeakFirst: false,
        reason: 'quiet_hours',
      );
    }

    final usage = await _loadUsage(now);
    if (usage.openCountToday >= maxOpensPerDay) {
      return ProactiveOpenDecision(
        shouldSpeakFirst: false,
        reason: 'daily_limit_reached',
        openCountToday: usage.openCountToday,
        minutesSinceLastOpen: usage.minutesSinceLastOpen,
      );
    }
    if (usage.lastOpenAt != null &&
        now.difference(usage.lastOpenAt!) < cooldown) {
      return ProactiveOpenDecision(
        shouldSpeakFirst: false,
        reason: 'cooldown_active',
        openCountToday: usage.openCountToday,
        minutesSinceLastOpen: usage.minutesSinceLastOpen,
      );
    }

    final trigger = _triggerType(evidence, usage.openCountToday);
    if (trigger == null) {
      return ProactiveOpenDecision(
        shouldSpeakFirst: false,
        reason: 'no_trigger',
        openCountToday: usage.openCountToday,
        minutesSinceLastOpen: usage.minutesSinceLastOpen,
      );
    }

    await _diagnosticLogService?.info(
      'proactive_open_allowed',
      category: DiagnosticLogService.categoryModelRuntime,
      message: 'Gemma Flares allowed an app-opening proactive message.',
      metadata: {
        'trigger_type': trigger,
        'open_count_today': usage.openCountToday,
        'minutes_since_last_open': usage.minutesSinceLastOpen,
      },
    );
    return ProactiveOpenDecision(
      shouldSpeakFirst: true,
      reason: 'triggered',
      triggerType: trigger,
      openCountToday: usage.openCountToday,
      minutesSinceLastOpen: usage.minutesSinceLastOpen,
    );
  }

  Future<ProactiveOpenDecision> evaluateFromGroundedContext(
    Map<String, Object?> context,
  ) {
    return evaluate(evidence: _evidenceFromContext(context));
  }

  ProactiveOpenEvidence _evidenceFromContext(Map<String, Object?> context) {
    final recentSymptoms = context['recent_symptoms'];
    final recentCheckins = context['recent_checkins'];
    final cachedRisk = context['cached_risk'];
    return ProactiveOpenEvidence(
      symptomEscalation: _hasHighSymptomSignal(recentSymptoms) ||
          _hasHighStoolFrequency(recentCheckins),
      riskTrendRising: _riskLooksElevated(cachedRisk),
      overdueCheckIn: _isEmptyList(recentCheckins),
      allowDailyOpeningCheckIn: true,
    );
  }

  Future<Map<String, String>> _loadNotificationPreferences() async {
    final database = await _database.open();
    final rows = await database.query('notification_preferences');
    return {
      for (final row in rows) row['key'] as String: row['value_json'] as String,
    };
  }

  Future<_ProactiveOpenUsage> _loadUsage(DateTime now) async {
    final database = await _database.open();
    final dayStart = DateTime.utc(now.year, now.month, now.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final rows = await database.query(
      'messages',
      columns: ['created_at'],
      where: '''
        created_at >= ? AND created_at < ? AND
        (is_proactive_open = 1 OR user_message = ?)
      ''',
      whereArgs: [
        dayStart.toIso8601String(),
        dayEnd.toIso8601String(),
        '[app_open_proactive_checkin]',
      ],
      orderBy: 'created_at DESC',
    );
    final lastOpenAt = rows.isEmpty
        ? null
        : DateTime.tryParse(rows.first['created_at'] as String)?.toUtc();
    return _ProactiveOpenUsage(
      openCountToday: rows.length,
      lastOpenAt: lastOpenAt,
      now: now,
    );
  }

  String? _triggerType(ProactiveOpenEvidence evidence, int openCountToday) {
    if (evidence.hrvDrop) return 'hrv_drop';
    if (evidence.missedMedication) return 'missed_med';
    if (evidence.symptomEscalation) return 'symptom_escalation';
    if (evidence.newLab) return 'new_lab';
    if (evidence.riskTrendRising) return 'risk_trend';
    if (evidence.overdueCheckIn) return 'overdue_checkin';
    if (evidence.allowDailyOpeningCheckIn && openCountToday == 0) {
      return 'daily_open_checkin';
    }
    return null;
  }

  bool _hasHighSymptomSignal(Object? value) {
    if (value is! List) return false;
    for (final item in value) {
      if (item is! Map) continue;
      final severity = item['severity'];
      if (severity is num && severity >= 3) return true;
      final text =
          '${item['symptom'] ?? item['symptom_type'] ?? item['notes'] ?? ''}'
              .toLowerCase();
      if (text.contains('blood') ||
          text.contains('severe') ||
          text.contains('worse') ||
          text.contains('cramp')) {
        return true;
      }
    }
    return false;
  }

  bool _hasHighStoolFrequency(Object? value) {
    if (value is! List) return false;
    for (final item in value) {
      if (item is! Map) continue;
      final frequency = item['cd_stool_frequency'] ??
          item['uc_stool_frequency'] ??
          item['stool_frequency'];
      if (frequency is num && frequency >= 2) return true;
    }
    return false;
  }

  bool _riskLooksElevated(Object? value) {
    if (value is! Map) return false;
    final riskScore =
        value['risk_score'] ?? value['score'] ?? value['riskScore'];
    if (riskScore is num && riskScore >= 0.5) return true;
    final riskBand =
        '${value['risk_band'] ?? value['band'] ?? ''}'.toLowerCase();
    return riskBand.contains('high') || riskBand.contains('elevated');
  }

  bool _isEmptyList(Object? value) => value is List && value.isEmpty;

  static bool _insideQuietHours(int hour, int start, int end) {
    if (start == end) return false;
    if (start < end) return hour >= start && hour < end;
    return hour >= start || hour < end;
  }
}

class _ProactiveOpenUsage {
  const _ProactiveOpenUsage({
    required this.openCountToday,
    required this.lastOpenAt,
    required this.now,
  });

  final int openCountToday;
  final DateTime? lastOpenAt;
  final DateTime now;

  int? get minutesSinceLastOpen =>
      lastOpenAt == null ? null : now.difference(lastOpenAt!).inMinutes;
}
