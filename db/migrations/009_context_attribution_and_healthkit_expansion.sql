-- Migration 009: Context attribution and expanded HealthKit production signals
-- Adds local-only production safety tables for workout/meal/medication/clinical
-- context, HealthKit capability tracking, and model validation audit outputs.

CREATE TABLE IF NOT EXISTS context_windows (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  date_local TEXT NOT NULL,
  start_time_utc TEXT NOT NULL,
  end_time_utc TEXT NOT NULL,
  context_type TEXT NOT NULL,
  source TEXT NOT NULL,
  confidence REAL NOT NULL DEFAULT 0,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS daily_context_features (
  date_local TEXT PRIMARY KEY,
  feature_json TEXT NOT NULL,
  quality_json TEXT NOT NULL,
  recomputed_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS intake_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_type TEXT NOT NULL,
  logged_at TEXT NOT NULL,
  date_local TEXT NOT NULL,
  source TEXT NOT NULL,
  confidence REAL NOT NULL DEFAULT 1,
  notes TEXT,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS healthkit_capability_status (
  metric_key TEXT PRIMARY KEY,
  healthkit_identifier TEXT NOT NULL,
  availability TEXT NOT NULL,
  permission_status TEXT NOT NULL,
  last_successful_import_at TEXT,
  last_error_kind TEXT,
  required_for_core_score INTEGER NOT NULL DEFAULT 0,
  used_for_context_only INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS healthkit_metric_registry (
  metric_key TEXT PRIMARY KEY,
  healthkit_identifier TEXT NOT NULL,
  normalized_metric_name TEXT NOT NULL,
  metric_family TEXT NOT NULL,
  availability TEXT NOT NULL DEFAULT 'unknown',
  permission_status TEXT NOT NULL DEFAULT 'unknown',
  last_successful_import_at TEXT,
  last_error_kind TEXT,
  required_for_core_score INTEGER NOT NULL DEFAULT 0,
  used_for_context_only INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS clinical_record_imports (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  record_type TEXT NOT NULL,
  source TEXT NOT NULL,
  effective_date TEXT,
  fhir_resource_type TEXT,
  fhir_id TEXT,
  extracted_json TEXT NOT NULL DEFAULT '{}',
  raw_resource_json TEXT,
  import_status TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS model_validation_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_key TEXT NOT NULL UNIQUE,
  started_at TEXT NOT NULL,
  completed_at TEXT,
  status TEXT NOT NULL,
  dataset_summary_json TEXT NOT NULL DEFAULT '{}',
  notes TEXT
);

CREATE TABLE IF NOT EXISTS model_validation_metrics (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_key TEXT NOT NULL,
  model_version TEXT NOT NULL,
  label_type TEXT NOT NULL,
  horizon_days INTEGER,
  metric_name TEXT NOT NULL,
  metric_value REAL,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  FOREIGN KEY (run_key) REFERENCES model_validation_runs(run_key)
    ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_context_windows_date_type
ON context_windows(date_local, context_type);

CREATE INDEX IF NOT EXISTS idx_context_windows_time
ON context_windows(start_time_utc, end_time_utc);

CREATE INDEX IF NOT EXISTS idx_intake_events_date_type
ON intake_events(date_local, event_type);

CREATE INDEX IF NOT EXISTS idx_clinical_record_imports_date
ON clinical_record_imports(effective_date, record_type);

CREATE INDEX IF NOT EXISTS idx_model_validation_metrics_run
ON model_validation_metrics(run_key, model_version);
