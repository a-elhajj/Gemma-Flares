-- Migration 012: Memory control infrastructure
-- Soft-delete tombstones (30-day grace before hard delete)
CREATE TABLE IF NOT EXISTS tombstones (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  target_table TEXT NOT NULL,
  target_row_id INTEGER NOT NULL,
  deleted_at TEXT NOT NULL,
  hard_delete_after TEXT NOT NULL,
  deletion_reason TEXT,
  initiator TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_tombstones_hard_delete
  ON tombstones(hard_delete_after);

-- Background job tracking (idempotent on retry)
CREATE TABLE IF NOT EXISTS bg_jobs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  job_type TEXT NOT NULL,
  scheduled_for TEXT NOT NULL,
  started_at TEXT,
  completed_at TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  error TEXT,
  retry_count INTEGER NOT NULL DEFAULT 0,
  idempotency_key TEXT NOT NULL UNIQUE
);

CREATE INDEX IF NOT EXISTS idx_bg_jobs_status
  ON bg_jobs(status, scheduled_for);

-- Pre-generated notification content
CREATE TABLE IF NOT EXISTS scheduled_notifications (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  scheduled_at TEXT NOT NULL,
  trigger_type TEXT NOT NULL,
  gemma_content TEXT NOT NULL,
  prompt_seed TEXT,
  fired INTEGER NOT NULL DEFAULT 0,
  dismissed INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);
