-- Migration 010: Gemma structured task audit and doctor summaries
-- Adds local-only audit tables for Gemma 4 structured extraction, tool routing,
-- and doctor-ready summaries. Raw prompts are intentionally not stored.

CREATE TABLE IF NOT EXISTS gemma_task_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_type TEXT NOT NULL,
  prompt_version TEXT NOT NULL,
  schema_version TEXT NOT NULL,
  model_id TEXT NOT NULL,
  runtime_name TEXT NOT NULL,
  status TEXT NOT NULL,
  used_model_output INTEGER NOT NULL DEFAULT 0,
  validation_status TEXT NOT NULL,
  validation_errors_json TEXT NOT NULL DEFAULT '[]',
  input_summary_json TEXT NOT NULL DEFAULT '{}',
  output_summary_json TEXT NOT NULL DEFAULT '{}',
  output_hash TEXT,
  latency_ms INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS gemma_extraction_reviews (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_run_id INTEGER,
  review_type TEXT NOT NULL,
  source_kind TEXT NOT NULL,
  source_hash TEXT,
  extracted_json TEXT NOT NULL DEFAULT '{}',
  user_confirmed_json TEXT NOT NULL DEFAULT '{}',
  review_status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  confirmed_at TEXT,
  FOREIGN KEY (task_run_id) REFERENCES gemma_task_runs(id)
    ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS doctor_summaries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_run_id INTEGER,
  summary_range_days INTEGER NOT NULL,
  summary_text TEXT NOT NULL,
  context_summary_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  FOREIGN KEY (task_run_id) REFERENCES gemma_task_runs(id)
    ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_gemma_task_runs_type_time
ON gemma_task_runs(task_type, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_gemma_extraction_reviews_type_time
ON gemma_extraction_reviews(review_type, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_doctor_summaries_created
ON doctor_summaries(created_at DESC);
