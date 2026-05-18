import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gemma_flares/core/database/database_contracts.dart';

void main() {
  test('initial migration defines required base tables', () {
    final sql = File(
      DatabaseContracts.initialMigrationAsset,
    ).readAsStringSync();

    expect(sql, contains('CREATE TABLE IF NOT EXISTS wearable_samples'));
    expect(sql, contains('CREATE TABLE IF NOT EXISTS daily_summaries'));
    expect(sql, contains('CREATE TABLE IF NOT EXISTS flare_risk_scores'));
    expect(sql, contains('CREATE TABLE IF NOT EXISTS symptoms'));
    expect(sql, contains('CREATE TABLE IF NOT EXISTS timeline_events'));
    expect(sql, contains('CREATE TABLE IF NOT EXISTS sync_state'));
  });

  test('initial migration defines hot-path indexes', () {
    final sql = File(
      DatabaseContracts.initialMigrationAsset,
    ).readAsStringSync();

    expect(sql, contains('idx_wearable_samples_metric_start'));
    expect(sql, contains('idx_symptoms_logged_at'));
    expect(sql, contains('idx_timeline_events_date_time'));
  });

  test('v4 migration (paper replication) defines all 5 new tables', () {
    final migrationPath = DatabaseContracts.migrationAssets[4]!;
    final sql = File(migrationPath).readAsStringSync();

    // All 5 paper replication tables must be present
    expect(sql, contains('CREATE TABLE IF NOT EXISTS lab_values'));
    expect(sql, contains('CREATE TABLE IF NOT EXISTS pro2_surveys'));
    expect(sql, contains('CREATE TABLE IF NOT EXISTS flare_labels'));
    expect(sql, contains('CREATE TABLE IF NOT EXISTS cosinor_features'));
    expect(sql, contains('CREATE TABLE IF NOT EXISTS logistic_model_state'));
  });

  test('v4 migration defines indexes on date columns', () {
    final migrationPath = DatabaseContracts.migrationAssets[4]!;
    final sql = File(migrationPath).readAsStringSync();

    expect(sql, contains('idx_lab_values_drawn'));
    expect(sql, contains('idx_pro2_date'));
    expect(sql, contains('idx_flare_labels_date'));
    expect(sql, contains('idx_cosinor_date'));
  });

  test('v5 migration adds clinical records support', () {
    final migrationPath = DatabaseContracts.migrationAssets[5]!;
    final sql = File(migrationPath).readAsStringSync();

    expect(sql, contains('CREATE TABLE IF NOT EXISTS endoscopy_records'));
    expect(
      sql,
      contains('ADD COLUMN clinical_flare INTEGER NOT NULL DEFAULT 0'),
    );
    expect(sql, contains('idx_endoscopy_date'));
  });

  test('v6 migration adds lab source metadata', () {
    final migrationPath = DatabaseContracts.migrationAssets[6]!;
    final sql = File(migrationPath).readAsStringSync();

    expect(sql, contains('ADD COLUMN lab_name TEXT'));
    expect(sql, contains('ADD COLUMN ordering_provider TEXT'));
  });

  test('v7 migration adds production hardening tables and keys', () {
    final migrationPath = DatabaseContracts.migrationAssets[7]!;
    final sql = File(migrationPath).readAsStringSync();

    expect(sql, contains('PRIMARY KEY (date_local, model_version)'));
    expect(sql, contains('ADD COLUMN score_version TEXT NOT NULL'));
    expect(sql, contains('CREATE TABLE IF NOT EXISTS experiment_assignments'));
    expect(sql, contains('CREATE TABLE IF NOT EXISTS experiment_events'));
    expect(sql, contains('idx_flare_risk_scores_model_date'));
  });

  test('v8 migration adds local diagnostic log table', () {
    final migrationPath = DatabaseContracts.migrationAssets[8]!;
    final sql = File(migrationPath).readAsStringSync();

    expect(sql, contains('CREATE TABLE IF NOT EXISTS diagnostic_logs'));
    expect(sql, contains('metadata_json TEXT NOT NULL'));
    expect(sql, contains('idx_diagnostic_logs_category_time'));
    expect(sql, contains('idx_diagnostic_logs_level_time'));
  });

  test('v9 migration adds context attribution and validation tables', () {
    final migrationPath = DatabaseContracts.migrationAssets[9]!;
    final sql = File(migrationPath).readAsStringSync();

    expect(sql, contains('CREATE TABLE IF NOT EXISTS context_windows'));
    expect(sql, contains('CREATE TABLE IF NOT EXISTS daily_context_features'));
    expect(sql, contains('CREATE TABLE IF NOT EXISTS intake_events'));
    expect(
      sql,
      contains('CREATE TABLE IF NOT EXISTS healthkit_metric_registry'),
    );
    expect(sql, contains('CREATE TABLE IF NOT EXISTS clinical_record_imports'));
    expect(sql, contains('CREATE TABLE IF NOT EXISTS model_validation_runs'));
    expect(
      sql,
      contains('CREATE TABLE IF NOT EXISTS model_validation_metrics'),
    );
    expect(sql, contains('idx_context_windows_date_type'));
  });

  test('v10 migration adds Gemma structured task audit tables', () {
    final migrationPath = DatabaseContracts.migrationAssets[10]!;
    final sql = File(migrationPath).readAsStringSync();

    expect(sql, contains('CREATE TABLE IF NOT EXISTS gemma_task_runs'));
    expect(
      sql,
      contains('CREATE TABLE IF NOT EXISTS gemma_extraction_reviews'),
    );
    expect(sql, contains('CREATE TABLE IF NOT EXISTS doctor_summaries'));
    expect(sql, contains('idx_gemma_task_runs_type_time'));
    expect(sql, contains('idx_doctor_summaries_created'));
  });

  test('v11-v17 migrations add v2 memory and agent tables', () {
    final combinedSql = [
      for (var version = 11; version <= 17; version++)
        File(DatabaseContracts.migrationAssets[version]!).readAsStringSync(),
    ].join('\n');

    expect(combinedSql, contains('CREATE TABLE IF NOT EXISTS pinned_facts'));
    expect(combinedSql, contains('CREATE TABLE IF NOT EXISTS summaries'));
    expect(combinedSql, contains('CREATE TABLE IF NOT EXISTS tool_audit'));
    expect(
      combinedSql,
      contains('ALTER TABLE conversations RENAME TO messages'),
    );
    expect(
      combinedSql,
      contains('CREATE TABLE IF NOT EXISTS unrelated_symptoms'),
    );
    expect(
      combinedSql,
      contains('CREATE TABLE IF NOT EXISTS notification_preferences'),
    );
  });

  test('v18 migration adds runtime_events telemetry table', () {
    final sql = File(DatabaseContracts.migrationAssets[18]!).readAsStringSync();
    expect(sql, contains('CREATE TABLE IF NOT EXISTS runtime_events'));
    expect(sql, contains('idx_runtime_events_kind_time'));
  });

  test('v19 migration adds RAG memory transaction ledger', () {
    final sql = File(DatabaseContracts.migrationAssets[19]!).readAsStringSync();
    expect(sql, contains('CREATE TABLE IF NOT EXISTS rag_memory_transactions'));
    expect(sql, contains('idx_rag_memory_transactions_status'));
  });

  test('v20 migration adds score stability and lab contribution fields', () {
    final sql = File(DatabaseContracts.migrationAssets[20]!).readAsStringSync();
    expect(
      sql,
      contains('CREATE TABLE IF NOT EXISTS displayed_score_snapshots'),
    );
    expect(sql, contains('unit_normalized_value'));
    expect(sql, contains('is_paper_biomarker'));
    expect(sql, contains('triggered_by_user_action'));
  });

  test('v22 migration makes logistic training observations idempotent', () {
    final sql = File(DatabaseContracts.migrationAssets[22]!).readAsStringSync();
    expect(sql, contains('idx_lth_model_sample_unique'));
    expect(sql, contains('GROUP BY model_key, sample_date'));
  });

  test('v23 migration adds structured food entries', () {
    final sql = File(DatabaseContracts.migrationAssets[23]!).readAsStringSync();
    expect(sql, contains('CREATE TABLE IF NOT EXISTS food_entries'));
    expect(sql, contains('idx_food_entries_logged_at'));
    expect(sql, contains('idx_food_entries_trigger'));
  });

  test('v24 migration wipes local data', () {
    final sql = File(DatabaseContracts.migrationAssets[24]!).readAsStringSync();
    expect(sql, contains('DELETE FROM wearable_samples'));
    expect(sql, contains('DELETE FROM symptoms'));
    expect(sql, contains('DELETE FROM lab_values'));
    expect(sql, contains('DELETE FROM rag_memory_transactions'));
    expect(sql, contains('DELETE FROM app_settings'));
    expect(sql, contains('DELETE FROM sqlite_sequence'));
  });

  test('schema version is 24', () {
    expect(DatabaseContracts.currentSchemaVersion, 24);
  });

  test('all migration assets are present on disk', () {
    for (final entry in DatabaseContracts.migrationAssets.entries) {
      final file = File(entry.value);
      expect(
        file.existsSync(),
        isTrue,
        reason: 'Migration v${entry.key} file not found: ${entry.value}',
      );
    }
  });
}
