-- Migration 007: Production hardening
-- Adds multi-model score persistence, versioned PRO-2 scoring metadata,
-- and local-only A/B experiment instrumentation.

CREATE TABLE flare_risk_scores_v7 (
  date_local TEXT NOT NULL,
  risk_score REAL NOT NULL,
  risk_band TEXT NOT NULL,
  confidence_score REAL NOT NULL,
  contribution_json TEXT NOT NULL,
  feature_snapshot_json TEXT NOT NULL,
  model_version TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (date_local, model_version)
);

INSERT OR REPLACE INTO flare_risk_scores_v7 (
  date_local,
  risk_score,
  risk_band,
  confidence_score,
  contribution_json,
  feature_snapshot_json,
  model_version,
  created_at
)
SELECT
  date_local,
  risk_score,
  risk_band,
  confidence_score,
  contribution_json,
  feature_snapshot_json,
  model_version,
  created_at
FROM flare_risk_scores;

DROP TABLE flare_risk_scores;

ALTER TABLE flare_risk_scores_v7
RENAME TO flare_risk_scores;

ALTER TABLE pro2_surveys
ADD COLUMN score_version TEXT NOT NULL DEFAULT 'cd_pro2_v1_pain7_stool1';

UPDATE pro2_surveys
SET score_version = 'uc_pro2_v1_bleeding_stool'
WHERE disease_type = 'UC';

CREATE TABLE IF NOT EXISTS experiment_assignments (
  experiment_key TEXT PRIMARY KEY,
  variant TEXT NOT NULL,
  assigned_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS experiment_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_name TEXT NOT NULL,
  experiment_key TEXT NOT NULL,
  variant TEXT NOT NULL,
  session_id TEXT,
  metadata_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_flare_risk_scores_date_local
ON flare_risk_scores(date_local);

CREATE INDEX IF NOT EXISTS idx_flare_risk_scores_model_date
ON flare_risk_scores(model_version, date_local);

CREATE INDEX IF NOT EXISTS idx_experiment_events_key_time
ON experiment_events(experiment_key, created_at);
