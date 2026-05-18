import '../database/app_database.dart';
import 'diagnostic_log_service.dart';

class MemoryControlsService {
  MemoryControlsService({
    required AppDatabase database,
    DiagnosticLogService? diagnosticLogService,
    DateTime Function()? nowProvider,
  })  : _database = database,
        _diagnosticLogService = diagnosticLogService,
        _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  final AppDatabase _database;
  final DiagnosticLogService? _diagnosticLogService;
  final DateTime Function() _nowProvider;

  Future<int> softDelete({
    required String table,
    required int rowId,
    required String reason,
    String initiator = 'user',
    Duration gracePeriod = const Duration(days: 30),
  }) async {
    final now = _nowProvider().toUtc();
    final hardDeleteAfter = now.add(gracePeriod);
    final db = await _database.open();
    final id = await db.insert('tombstones', {
      'target_table': table,
      'target_row_id': rowId,
      'deleted_at': now.toIso8601String(),
      'hard_delete_after': hardDeleteAfter.toIso8601String(),
      'deletion_reason': reason,
      'initiator': initiator,
    });
    await _diagnosticLogService?.info(
      'memory_soft_deleted',
      category: DiagnosticLogService.categorySettings,
      message: 'A local memory item was soft-deleted.',
      metadata: {
        'target_table': table,
        'target_row_id': rowId,
        'initiator': initiator,
      },
    );
    return id;
  }

  Future<int> hardDeleteExpired() async {
    final now = _nowProvider().toUtc().toIso8601String();
    final db = await _database.open();
    final rows = await db.query(
      'tombstones',
      where: 'hard_delete_after <= ?',
      whereArgs: [now],
    );
    var deleted = 0;
    await db.transaction((txn) async {
      for (final row in rows) {
        final table = row['target_table'] as String;
        final rowId = (row['target_row_id'] as num).toInt();
        deleted += await txn.delete(table, where: 'id = ?', whereArgs: [rowId]);
        await txn.delete('tombstones', where: 'id = ?', whereArgs: [row['id']]);
      }
    });
    if (deleted > 0) {
      await _diagnosticLogService?.info(
        'memory_hard_delete_completed',
        category: DiagnosticLogService.categorySettings,
        message: 'Expired memory tombstones were hard-deleted.',
        metadata: {'deleted_count': deleted},
      );
    }
    return deleted;
  }

  Future<List<Map<String, Object?>>> pendingDeletes({int limit = 100}) async {
    final db = await _database.open();
    final rows = await db.query(
      'tombstones',
      orderBy: 'deleted_at DESC',
      limit: limit,
    );
    return rows.map(Map<String, Object?>.from).toList(growable: false);
  }
}
