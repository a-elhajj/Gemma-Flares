-- Migration 024: wipe local data after removing seeded-data infrastructure.
-- Intentionally destructive: clears local user data and generated state so
-- rows seeded by older builds cannot survive the upgrade.

DELETE FROM gemma_extraction_reviews;
DELETE FROM doctor_summaries;
DELETE FROM gemma_task_runs;
DELETE FROM model_validation_metrics;
DELETE FROM model_validation_runs;
DELETE FROM displayed_score_snapshots;
DELETE FROM logistic_training_history;
DELETE FROM logistic_model_state;
DELETE FROM cosinor_features;
DELETE FROM flare_labels;
DELETE FROM pro2_surveys;
DELETE FROM lab_values;
DELETE FROM endoscopy_records;
DELETE FROM intake_events;
DELETE FROM symptoms;
DELETE FROM unrelated_symptoms;
DELETE FROM food_entries;
DELETE FROM daily_context_features;
DELETE FROM context_windows;
DELETE FROM flare_risk_scores;
DELETE FROM daily_features;
DELETE FROM baseline_snapshots;
DELETE FROM daily_summaries;
DELETE FROM wearable_samples;
DELETE FROM rag_memory_transactions;
DELETE FROM pinned_fact_history;
DELETE FROM pinned_facts;
DELETE FROM summaries;
DELETE FROM vector_index_meta;
DELETE FROM tombstones;
DELETE FROM bg_jobs;
DELETE FROM scheduled_notifications;
DELETE FROM notification_preferences;
DELETE FROM runtime_events;
DELETE FROM tool_audit;
DELETE FROM diagnostic_logs;
DELETE FROM experiment_events;
DELETE FROM experiment_assignments;
DELETE FROM timeline_events;
DELETE FROM sync_state;
DELETE FROM app_settings;
DELETE FROM clinical_record_imports;
DELETE FROM healthkit_capability_status;
DELETE FROM healthkit_metric_registry;

DELETE FROM sqlite_sequence WHERE name IN (
  'wearable_samples',
  'daily_summaries',
  'baseline_snapshots',
  'daily_features',
  'flare_risk_scores',
  'symptoms',
  'messages',
  'timeline_events',
  'lab_values',
  'pro2_surveys',
  'flare_labels',
  'cosinor_features',
  'endoscopy_records',
  'flare_risk_scores_v7',
  'experiment_events',
  'diagnostic_logs',
  'context_windows',
  'intake_events',
  'clinical_record_imports',
  'model_validation_runs',
  'model_validation_metrics',
  'gemma_task_runs',
  'gemma_extraction_reviews',
  'doctor_summaries',
  'pinned_facts',
  'summaries',
  'tombstones',
  'bg_jobs',
  'scheduled_notifications',
  'tool_audit',
  'pinned_fact_history',
  'unrelated_symptoms',
  'runtime_events',
  'rag_memory_transactions',
  'displayed_score_snapshots',
  'logistic_training_history',
  'food_entries'
);
