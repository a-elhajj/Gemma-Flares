-- Migration 016: Unrelated symptoms pool for taxonomy expansion
CREATE TABLE IF NOT EXISTS unrelated_symptoms (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  logged_at TEXT NOT NULL,
  raw_text TEXT NOT NULL,
  source TEXT NOT NULL,
  embedding BLOB,
  embedding_model_version TEXT,
  candidate_canonical_id TEXT,
  candidate_confidence REAL,
  resolved INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_unrelated_symptoms_resolved
  ON unrelated_symptoms(resolved);
