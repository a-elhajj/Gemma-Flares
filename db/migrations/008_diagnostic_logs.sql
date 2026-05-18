-- Migration 008: Local diagnostics and audit trail
-- Structured local-only logging for production support and friend-test audits.

CREATE TABLE IF NOT EXISTS diagnostic_logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at TEXT NOT NULL,
  session_id TEXT NOT NULL,
  level TEXT NOT NULL,
  category TEXT NOT NULL,
  event_name TEXT NOT NULL,
  message TEXT NOT NULL,
  metadata_json TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'app'
);

CREATE INDEX IF NOT EXISTS idx_diagnostic_logs_time
ON diagnostic_logs(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_diagnostic_logs_category_time
ON diagnostic_logs(category, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_diagnostic_logs_level_time
ON diagnostic_logs(level, created_at DESC);
