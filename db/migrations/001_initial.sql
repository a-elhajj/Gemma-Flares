PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS wearable_samples (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sample_key TEXT NOT NULL UNIQUE,
  vendor_sample_id TEXT,
  source_name TEXT NOT NULL,
  source_device TEXT NOT NULL,
  metric_name TEXT NOT NULL,
  value_numeric REAL NOT NULL,
  unit TEXT NOT NULL,
  start_time_utc TEXT NOT NULL,
  end_time_utc TEXT NOT NULL,
  timezone TEXT NOT NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  imported_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS daily_summaries (
  date_local TEXT PRIMARY KEY,
  summary_json TEXT NOT NULL,
  sync_quality_score REAL NOT NULL DEFAULT 0,
  recomputed_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS baseline_snapshots (
  snapshot_date_local TEXT PRIMARY KEY,
  readiness_state TEXT NOT NULL,
  baseline_json TEXT NOT NULL,
  valid_days INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS daily_features (
  feature_date_local TEXT PRIMARY KEY,
  feature_json TEXT NOT NULL,
  missingness_json TEXT NOT NULL,
  recomputed_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS flare_risk_scores (
  date_local TEXT PRIMARY KEY,
  risk_score REAL NOT NULL,
  risk_band TEXT NOT NULL,
  confidence_score REAL NOT NULL,
  contribution_json TEXT NOT NULL,
  feature_snapshot_json TEXT NOT NULL,
  model_version TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS symptoms (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  logged_at TEXT NOT NULL,
  symptom_type TEXT NOT NULL,
  severity INTEGER,
  duration_minutes INTEGER,
  meal_relation TEXT,
  notes TEXT,
  source_transcript TEXT,
  extraction_method TEXT NOT NULL,
  extraction_confidence REAL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS conversations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at TEXT NOT NULL,
  user_message TEXT NOT NULL,
  assistant_message TEXT NOT NULL,
  tool_trace_json TEXT NOT NULL,
  grounded_summary_json TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS timeline_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_type TEXT NOT NULL,
  event_time TEXT NOT NULL,
  date_local TEXT NOT NULL,
  title TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sync_state (
  source_name TEXT PRIMARY KEY,
  last_sync_at TEXT,
  last_backfill_start TEXT,
  last_backfill_end TEXT,
  sync_cursor_json TEXT,
  last_error TEXT,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS app_settings (
  key TEXT PRIMARY KEY,
  value_json TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_wearable_samples_metric_start
ON wearable_samples(metric_name, start_time_utc);

CREATE INDEX IF NOT EXISTS idx_wearable_samples_start
ON wearable_samples(start_time_utc);

CREATE INDEX IF NOT EXISTS idx_symptoms_logged_at
ON symptoms(logged_at);

CREATE INDEX IF NOT EXISTS idx_flare_risk_scores_date_local
ON flare_risk_scores(date_local);

CREATE INDEX IF NOT EXISTS idx_timeline_events_date_time
ON timeline_events(date_local, event_time DESC);
