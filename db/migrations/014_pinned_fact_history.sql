-- Migration 014: Pinned fact mutation history
CREATE TABLE IF NOT EXISTS pinned_fact_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_json TEXT NOT NULL,
  changed_at TEXT NOT NULL,
  changed_by TEXT NOT NULL,
  field_path TEXT,
  old_value TEXT,
  new_value TEXT,
  conflict_detected INTEGER NOT NULL DEFAULT 0,
  user_confirmed INTEGER
);

CREATE INDEX IF NOT EXISTS idx_pfh_changed_at
  ON pinned_fact_history(changed_at DESC);
