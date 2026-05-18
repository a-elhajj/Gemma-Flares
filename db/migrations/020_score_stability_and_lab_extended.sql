-- v20: score stability gate table + lab extended columns
-- BUG-078 + FEA-023: session-anchored display snapshots + lab normalization fields

-- Score stability: session-anchored display snapshots
CREATE TABLE IF NOT EXISTS displayed_score_snapshots (
  id                   INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id           TEXT    NOT NULL,
  date_local           TEXT    NOT NULL,
  model_version        TEXT    NOT NULL,
  risk_score           REAL    NOT NULL,
  risk_band            TEXT    NOT NULL,
  confidence_score     REAL    NOT NULL,
  trigger_reason       TEXT    NOT NULL,   -- 'session_start'|'user_action'|'threshold_exceeded'
  user_action_type     TEXT,               -- NULL|'lab_logged'|'symptom_logged'|'checkin_submitted'|'explicit_refresh'
  displayed_at         TEXT    NOT NULL,   -- ISO-8601 UTC
  superseded_at        TEXT                -- NULL while current
);

CREATE INDEX IF NOT EXISTS idx_dss_session_date
  ON displayed_score_snapshots (session_id, date_local, displayed_at DESC);

-- Lab extensions for normalization + contribution tracking
ALTER TABLE lab_values ADD COLUMN unit_normalized_value  REAL;
ALTER TABLE lab_values ADD COLUMN unit_normalized_unit   TEXT;
ALTER TABLE lab_values ADD COLUMN is_paper_biomarker     INTEGER NOT NULL DEFAULT 0;
ALTER TABLE lab_values ADD COLUMN lab_score_contribution REAL;
ALTER TABLE lab_values ADD COLUMN lab_score_decay_factor REAL;
ALTER TABLE lab_values ADD COLUMN conflict_resolution    TEXT;  -- 'used'|'discarded_duplicate'

-- flare_risk_scores: tag which scores were triggered by a user action
ALTER TABLE flare_risk_scores ADD COLUMN triggered_by_user_action TEXT;
