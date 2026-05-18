class DatabaseContracts {
  static const databaseName = 'gemma_flares.sqlite3';
  static const initialMigrationAsset = 'db/migrations/001_initial.sql';
  static const currentSchemaVersion =
      24; // v24: wipe local data after seeded-data removal
  static const migrationAssets = <int, String>{
    1: initialMigrationAsset,
    2: 'db/migrations/002_wearable_normalization.sql',
    3: 'db/migrations/003_daily_summary_support.sql',
    4: 'db/migrations/004_paper_replication.sql',
    5: 'db/migrations/005_clinical_records.sql',
    6: 'db/migrations/006_lab_metadata_and_panel.sql',
    7: 'db/migrations/007_production_hardening.sql',
    8: 'db/migrations/008_diagnostic_logs.sql',
    9: 'db/migrations/009_context_attribution_and_healthkit_expansion.sql',
    10: 'db/migrations/010_gemma_structured_tasks.sql', // Gemma structured tasks
    11: 'db/migrations/011_memory_layer_core.sql',
    12: 'db/migrations/012_memory_controls.sql',
    13: 'db/migrations/013_tool_audit.sql',
    14: 'db/migrations/014_pinned_fact_history.sql',
    15: 'db/migrations/015_messages_rename.sql',
    16: 'db/migrations/016_unrelated_symptoms.sql',
    17: 'db/migrations/017_notification_preferences.sql',
    18: 'db/migrations/018_runtime_events.sql',
    19: 'db/migrations/019_rag_memory_transactions.sql',
    20: 'db/migrations/020_score_stability_and_lab_extended.sql', // v20: score stability gate table + lab extended columns
    21: 'db/migrations/021_auc_tracking.sql', // v21: logistic_training_history for per-model AUC
    22: 'db/migrations/022_idempotent_logistic_training.sql',
    23: 'db/migrations/023_food_entries.sql',
    24: 'db/migrations/024_wipe_local_data.sql',
  };

  static const timelineEventTypes = <String>{
    'risk_score_changed',
    'symptom_logged',
    'sync_completed',
    'sync_degraded',
    'lab_value_added',
    'procedure_added',
    'checkin_completed',
    'cosinor_computed',
  };
}
