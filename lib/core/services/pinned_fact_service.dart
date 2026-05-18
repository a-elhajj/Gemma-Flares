import 'dart:convert';

import '../database/app_database.dart';

/// A single field in the pinned-fact card.
class PinnedFact {
  const PinnedFact({
    required this.id,
    required this.schemaVersion,
    required this.content,
    required this.updatedAt,
    required this.updatedBy,
    this.promptVersion,
    this.modelVersion,
    this.changeSummary,
  });

  final int id;
  final int schemaVersion;
  final Map<String, Object?> content;
  final DateTime updatedAt;
  final String updatedBy;
  final String? promptVersion;
  final String? modelVersion;
  final String? changeSummary;

  factory PinnedFact.fromRow(Map<String, Object?> row) {
    return PinnedFact(
      id: row['id'] as int,
      schemaVersion: row['schema_version'] as int? ?? 1,
      content: Map<String, Object?>.from(
        jsonDecode(row['content_json'] as String) as Map,
      ),
      updatedAt: DateTime.parse(row['updated_at'] as String),
      updatedBy: row['updated_by'] as String? ?? 'system',
      promptVersion: row['prompt_version'] as String?,
      modelVersion: row['model_version'] as String?,
      changeSummary: row['change_summary'] as String?,
    );
  }
}

/// Manages the pinned fact card (Tier 1 memory).
///
/// Provides CRUD with:
/// - Conflict detection: if a field was modified since last read, the caller
///   must confirm before overwriting.
/// - Audit trail: every write snapshots the prior state to [pinned_fact_history].
class PinnedFactService {
  PinnedFactService({required AppDatabase database}) : _database = database;

  final AppDatabase _database;

  // -------------------------------------------------------------------------
  // Read
  // -------------------------------------------------------------------------

  /// Returns the current pinned fact card, or null if none has been created.
  Future<PinnedFact?> load() async {
    final db = await _database.open();
    final rows = await db.query('pinned_facts', orderBy: 'id DESC', limit: 1);
    if (rows.isEmpty) return null;
    return PinnedFact.fromRow(rows.first);
  }

  // -------------------------------------------------------------------------
  // Write
  // -------------------------------------------------------------------------

  /// Updates a subset of fields in the pinned fact card.
  ///
  /// [updates] is a partial map of field-path → new-value.
  /// [updatedBy] identifies the initiator (`user` or `gemma_model_id`).
  /// [checkConflict] if true, compares [lastReadAt] against the record's
  /// [updated_at] and throws [PinnedFactConflictException] when stale.
  Future<PinnedFact> update({
    required Map<String, Object?> updates,
    required String updatedBy,
    DateTime? lastReadAt,
    bool checkConflict = true,
    String? promptVersion,
    String? modelVersion,
    String? changeSummary,
  }) async {
    final db = await _database.open();
    final existing = await load();

    if (checkConflict && existing != null && lastReadAt != null) {
      if (existing.updatedAt.isAfter(lastReadAt)) {
        throw PinnedFactConflictException(
          conflictingField: updates.keys.first,
          serverValue: existing.content[updates.keys.first],
          clientValue: updates.values.first,
        );
      }
    }

    final now = DateTime.now().toUtc();
    final merged = Map<String, Object?>.from(existing?.content ?? {})
      ..addAll(updates);
    final contentJson = jsonEncode(merged);

    await db.transaction((txn) async {
      // Archive existing snapshot before overwriting.
      if (existing != null) {
        await txn.insert('pinned_fact_history', {
          'snapshot_json': jsonEncode(existing.content),
          'changed_at': now.toIso8601String(),
          'changed_by': updatedBy,
          'field_path': updates.keys.join(','),
          'old_value': jsonEncode({
            for (final k in updates.keys) k: existing.content[k],
          }),
          'new_value': jsonEncode(updates),
          'conflict_detected': checkConflict ? 0 : 0,
          'user_confirmed': null,
        });
      }

      if (existing == null) {
        await txn.insert('pinned_facts', {
          'schema_version': 1,
          'content_json': contentJson,
          'updated_at': now.toIso8601String(),
          'updated_by': updatedBy,
          'prompt_version': promptVersion,
          'model_version': modelVersion,
          'change_summary': changeSummary,
        });
      } else {
        await txn.update(
          'pinned_facts',
          {
            'content_json': contentJson,
            'updated_at': now.toIso8601String(),
            'updated_by': updatedBy,
            'prompt_version': promptVersion,
            'model_version': modelVersion,
            'change_summary': changeSummary,
          },
          where: 'id = ?',
          whereArgs: [existing.id],
        );
      }
    });

    return (await load())!;
  }

  /// Deletes the pinned fact card (user-initiated erasure only).
  Future<void> delete({required String deletedBy}) async {
    final db = await _database.open();
    final existing = await load();
    if (existing == null) return;

    final now = DateTime.now().toUtc();
    await db.transaction((txn) async {
      await txn.insert('pinned_fact_history', {
        'snapshot_json': jsonEncode(existing.content),
        'changed_at': now.toIso8601String(),
        'changed_by': deletedBy,
        'field_path': '*',
        'old_value': jsonEncode(existing.content),
        'new_value': 'null',
        'conflict_detected': 0,
        'user_confirmed': 1,
      });
      await txn.delete(
        'pinned_facts',
        where: 'id = ?',
        whereArgs: [existing.id],
      );
    });
  }
}

/// Thrown by [PinnedFactService.update] when a conflict is detected.
class PinnedFactConflictException implements Exception {
  const PinnedFactConflictException({
    required this.conflictingField,
    required this.serverValue,
    required this.clientValue,
  });

  final String conflictingField;
  final Object? serverValue;
  final Object? clientValue;

  @override
  String toString() =>
      'PinnedFactConflictException: field "$conflictingField" was modified '
      'remotely. serverValue=$serverValue, clientValue=$clientValue';
}
