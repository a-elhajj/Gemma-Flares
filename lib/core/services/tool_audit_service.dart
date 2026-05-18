import 'dart:convert';

import '../database/app_database.dart';

class ToolAuditService {
  ToolAuditService({required AppDatabase database}) : _database = database;

  final AppDatabase _database;

  Future<int> record({
    int? turnId,
    required String toolName,
    required Map<String, Object?> args,
    Object? result,
    Object? error,
    int? latencyMs,
    String? modelRole,
    String? promptVersion,
    bool validated = false,
    int retryCount = 0,
    DateTime? calledAt,
  }) async {
    final db = await _database.open();
    return db.insert('tool_audit', {
      'turn_id': turnId,
      'tool_name': toolName,
      'args_json': jsonEncode(args),
      'result_json': result == null ? null : jsonEncode(result),
      'error': error?.toString(),
      'latency_ms': latencyMs,
      'called_at': (calledAt ?? DateTime.now().toUtc()).toIso8601String(),
      'model_role': modelRole,
      'prompt_version': promptVersion,
      'validated': validated ? 1 : 0,
      'retry_count': retryCount,
    });
  }

  Future<List<Map<String, Object?>>> latest({int limit = 50}) async {
    final db = await _database.open();
    final rows = await db.query(
      'tool_audit',
      orderBy: 'called_at DESC',
      limit: limit,
    );
    return rows.map(Map<String, Object?>.from).toList(growable: false);
  }
}
