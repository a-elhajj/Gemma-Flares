-- Migration 011: Memory layer core tables
-- Tier 1: Pinned fact card
CREATE TABLE IF NOT EXISTS pinned_facts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  schema_version INTEGER NOT NULL DEFAULT 1,
  content_json TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  updated_by TEXT NOT NULL,
  prompt_version TEXT,
  model_version TEXT,
  change_summary TEXT
);

-- Tier 2: Hierarchical summaries
CREATE TABLE IF NOT EXISTS summaries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  level TEXT NOT NULL,
  date_range_start TEXT NOT NULL,
  date_range_end TEXT NOT NULL,
  source_event_ids TEXT NOT NULL,
  content TEXT NOT NULL,
  embedding BLOB,
  embedding_model_version TEXT,
  prompt_version TEXT,
  model_version TEXT,
  generated_at TEXT NOT NULL,
  needs_regeneration INTEGER NOT NULL DEFAULT 0,
  UNIQUE (level, date_range_start)
);

CREATE INDEX IF NOT EXISTS idx_summaries_level_date
  ON summaries(level, date_range_start);
CREATE INDEX IF NOT EXISTS idx_summaries_needs_regen
  ON summaries(needs_regeneration) WHERE needs_regeneration = 1;

-- Tier 3: Vector index row metadata
CREATE TABLE IF NOT EXISTS vector_index_meta (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  collection TEXT NOT NULL,
  row_id INTEGER NOT NULL,
  table_name TEXT NOT NULL,
  embedding_model_version TEXT NOT NULL,
  indexed_at TEXT NOT NULL,
  UNIQUE (collection, row_id, embedding_model_version)
);

CREATE INDEX IF NOT EXISTS idx_vim_collection
  ON vector_index_meta(collection);
