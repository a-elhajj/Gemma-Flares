-- Migration 018: Runtime events
-- Lightweight, structured event log for the on-device Gemma 4 / LiteRT-LM
-- runtime. Distinct from `diagnostic_logs` because it is high-frequency,
-- machine-shaped, and intended to drive the diagnostics UI + offline
-- post-mortems (memory headroom, KV window, ANE units, Stage A/B latency,
-- last memory warning, etc.). Local-only; never leaves the device.

CREATE TABLE IF NOT EXISTS runtime_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at TEXT NOT NULL,
  session_id TEXT NOT NULL,
  -- e.g. 'load.stage_a', 'load.stage_b', 'generate.start',
  -- 'generate.complete', 'memory_warning', 'thermal.serious',
  -- 'corpus.deferred', 'profile.downgrade', 'unload.background'
  event_kind TEXT NOT NULL,
  -- e2b | e4b | unknown
  model_role TEXT NOT NULL DEFAULT 'unknown',
  -- phone_safe | phone_balanced | phone_large | phone_extended | unknown
  profile TEXT NOT NULL DEFAULT 'unknown',
  -- per-process headroom in MB at event time, -1 if unknown
  available_mb INTEGER NOT NULL DEFAULT -1,
  -- resident-set in MB at event time, -1 if unknown
  resident_mb INTEGER NOT NULL DEFAULT -1,
  -- duration of the event in ms, 0 for instantaneous events
  duration_ms INTEGER NOT NULL DEFAULT 0,
  -- arbitrary structured detail (kv_window, ane_units, fallback_reason, ...)
  metadata_json TEXT NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_runtime_events_time
ON runtime_events(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_runtime_events_kind_time
ON runtime_events(event_kind, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_runtime_events_session_time
ON runtime_events(session_id, created_at DESC);
