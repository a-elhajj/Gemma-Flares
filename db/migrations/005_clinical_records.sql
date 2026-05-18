-- Migration 005: Clinical records expansion
-- Adds endoscopy and procedure support plus clinical flare labeling.

CREATE TABLE IF NOT EXISTS endoscopy_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  procedure_date TEXT NOT NULL,
  procedure_type TEXT NOT NULL,
  mayo_endoscopic_score INTEGER,
  ses_cd_score INTEGER,
  rutgeerts_score TEXT,
  findings_text TEXT,
  biopsies_taken INTEGER NOT NULL DEFAULT 0,
  biopsy_result TEXT,
  provider TEXT,
  notes TEXT,
  created_at TEXT NOT NULL
);

ALTER TABLE flare_labels
ADD COLUMN clinical_flare INTEGER NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_endoscopy_date
ON endoscopy_records(procedure_date);