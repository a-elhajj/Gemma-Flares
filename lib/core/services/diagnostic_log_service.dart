import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../database/wearable_sample_repository.dart';

class DiagnosticLogService {
  DiagnosticLogService({
    required WearableSampleRepository repository,
    DateTime Function()? nowProvider,
    String? sessionId,
    int maxRows = 1000,
    Duration retention = const Duration(days: 14),
    bool swallowFailures = true,
  })  : _repository = repository,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc()),
        _sessionId = sessionId,
        _maxRows = maxRows,
        _retention = retention,
        _swallowFailures = swallowFailures;

  static const levelDebug = 'debug';
  static const levelInfo = 'info';
  static const levelWarning = 'warning';
  static const levelError = 'error';

  static const categoryApp = 'app';
  static const categoryExport = 'export';
  static const categoryChat = 'chat';
  static const categoryModelRuntime = 'model_runtime';
  static const categoryHealthSync = 'health_sync';
  static const categoryRiskEngine = 'risk_engine';
  static const categorySettings = 'settings';

  static const _forbiddenMetadataFragments = [
    'health',
    'hrv',
    'heart',
    'symptom',
    'transcript',
    'conversation',
    'message',
    'chat',
    'lab',
    'crp',
    'esr',
    'fecal',
    'calprotectin',
    'procedure',
    'endoscopy',
    'score',
    'risk',
    'pain',
    'stool',
    'bleeding',
    'sleep',
    'steps',
    'spo2',
    'temperature',
    'weight',
    'height',
    'bmi',
    'birth',
    'name',
    'email',
    'phone',
    'address',
    'provider',
    'medication',
    'diagnosis',
  ];

  static const _allowedRuntimeMetadataKeys = {
    'available_memory_mb_before_load',
    'memory_warning_count',
  };

  final WearableSampleRepository _repository;
  final DateTime Function() _nowProvider;
  final String? _sessionId;
  final int _maxRows;
  final Duration _retention;
  final bool _swallowFailures;

  String? _resolvedSessionId;

  Future<void> debug(
    String eventName, {
    String category = categoryApp,
    String message = '',
    Map<String, Object?> metadata = const {},
  }) {
    return record(
      level: levelDebug,
      category: category,
      eventName: eventName,
      message: message,
      metadata: metadata,
    );
  }

  Future<void> info(
    String eventName, {
    String category = categoryApp,
    String message = '',
    Map<String, Object?> metadata = const {},
  }) {
    return record(
      level: levelInfo,
      category: category,
      eventName: eventName,
      message: message,
      metadata: metadata,
    );
  }

  Future<void> warning(
    String eventName, {
    String category = categoryApp,
    String message = '',
    Map<String, Object?> metadata = const {},
  }) {
    return record(
      level: levelWarning,
      category: category,
      eventName: eventName,
      message: message,
      metadata: metadata,
    );
  }

  Future<void> error(
    String eventName, {
    String category = categoryApp,
    String message = '',
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> metadata = const {},
  }) {
    return recordError(
      eventName: eventName,
      category: category,
      message: message,
      error: error,
      stackTrace: stackTrace,
      metadata: metadata,
    );
  }

  Future<void> record({
    required String level,
    required String category,
    required String eventName,
    String message = '',
    Map<String, Object?> metadata = const {},
    String source = 'app',
  }) async {
    try {
      final now = _nowProvider().toUtc();
      await _repository.insertDiagnosticLog(
        DiagnosticLogRecord(
          createdAt: now,
          sessionId: _getSessionId(now),
          level: _normalizeToken(level, fallback: levelInfo),
          category: _normalizeToken(category, fallback: categoryApp),
          eventName: _normalizeToken(eventName, fallback: 'unknown_event'),
          message: _scrubString(message, maxLength: 240),
          metadataJson: _scrubMetadata(metadata),
          source: _normalizeToken(source, fallback: 'app'),
        ),
      );
      await prune();
    } catch (_) {
      if (!_swallowFailures) {
        rethrow;
      }
    }
  }

  Future<void> recordError({
    required String eventName,
    required String category,
    String message = '',
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> metadata = const {},
  }) {
    final stackHash =
        stackTrace == null ? null : _hashValue(stackTrace.toString());
    final errorType = error?.runtimeType.toString();
    return record(
      level: levelError,
      category: category,
      eventName: eventName,
      message: message.isEmpty ? 'A local error was recorded.' : message,
      metadata: {
        ...metadata,
        if (errorType != null) 'error_type': errorType,
        if (stackHash != null) 'stack_hash': stackHash,
      },
    );
  }

  Future<void> prune() async {
    final cutoff = _nowProvider().toUtc().subtract(_retention);
    await _repository.deleteDiagnosticLogsOlderThan(cutoff);
    await _repository.trimDiagnosticLogs(maxRows: _maxRows);
  }

  Future<Map<String, Object?>> buildDiagnosticSummary({int limit = 50}) async {
    final logs = await _repository.getDiagnosticLogs(limit: limit);
    final countsByLevel = <String, int>{};
    final countsByCategory = <String, int>{};
    for (final log in logs) {
      countsByLevel[log.level] = (countsByLevel[log.level] ?? 0) + 1;
      countsByCategory[log.category] =
          (countsByCategory[log.category] ?? 0) + 1;
    }
    return {
      'session_id': _resolvedSessionId ?? _sessionId,
      'sample_size': logs.length,
      'counts_by_level': countsByLevel,
      'counts_by_category': countsByCategory,
      'latest': logs.map(_logToJson).toList(growable: false),
    };
  }

  Map<String, Object?> _logToJson(DiagnosticLogRecord record) {
    return {
      'id': record.id,
      'created_at': record.createdAt.toUtc().toIso8601String(),
      'session_id': record.sessionId,
      'level': record.level,
      'category': record.category,
      'event_name': record.eventName,
      'message': record.message,
      'metadata_json': record.metadataJson,
      'source': record.source,
    };
  }

  Map<String, Object?> _scrubMetadata(Map<String, Object?> metadata) {
    final scrubbed = <String, Object?>{};
    for (final entry in metadata.entries) {
      final key = _normalizeToken(entry.key, fallback: 'metadata');
      final normalizedKey = key.toLowerCase();
      final isAllowedRuntimeMetric = _allowedRuntimeMetadataKeys.contains(
        normalizedKey,
      );
      final isForbidden = _forbiddenMetadataFragments.any(
        normalizedKey.contains,
      );
      if (isForbidden && !isAllowedRuntimeMetric) {
        scrubbed[key] = '[redacted]';
        continue;
      }
      final value = entry.value;
      if (value == null || value is num || value is bool) {
        scrubbed[key] = value;
      } else if (value is String) {
        scrubbed[key] = _scrubString(value, maxLength: 160);
      } else {
        scrubbed[key] = '[redacted]';
      }
    }
    return scrubbed;
  }

  String _scrubString(String value, {required int maxLength}) {
    var scrubbed = value
        .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
        .replaceAll(RegExp(r'\b[\w.+-]+@[\w.-]+\.\w+\b'), '[redacted-email]')
        .replaceAll(RegExp(r'\+?\d[\d\s().-]{7,}\d'), '[redacted-phone]')
        .trim();
    if (scrubbed.length > maxLength) {
      scrubbed = '${scrubbed.substring(0, maxLength)}...';
    }
    return scrubbed;
  }

  String _normalizeToken(String value, {required String fallback}) {
    final normalized = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_.-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    if (normalized.isEmpty) {
      return fallback;
    }
    return normalized.length <= 64 ? normalized : normalized.substring(0, 64);
  }

  String _getSessionId(DateTime now) {
    final existing = _resolvedSessionId ?? _sessionId;
    if (existing != null && existing.isNotEmpty) {
      _resolvedSessionId = existing;
      return existing;
    }
    final seed = 'gemma_flares-session:${now.microsecondsSinceEpoch}';
    _resolvedSessionId = _hashValue(seed).substring(0, 16);
    return _resolvedSessionId!;
  }

  String _hashValue(String value) {
    return sha256.convert(utf8.encode(value)).toString();
  }
}
