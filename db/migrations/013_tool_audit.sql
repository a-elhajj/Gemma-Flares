-- Migration 013: Tool call audit trail
CREATE TABLE IF NOT EXISTS tool_audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  turn_id INTEGER,
  tool_name TEXT NOT NULL,
  args_json TEXT NOT NULL,
  result_json TEXT,
  error TEXT,
  latency_ms INTEGER,
  called_at TEXT NOT NULL,
  model_role TEXT,
  prompt_version TEXT,
  validated INTEGER NOT NULL DEFAULT 0,
  retry_count INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_tool_audit_called_at
  ON tool_audit(called_at DESC);
CREATE INDEX IF NOT EXISTS idx_tool_audit_turn_id
  ON tool_audit(turn_id);
