-- RAG memory transaction ledger.
--
-- A row is created for every user-confirmed item that Gemma Flares attempts to
-- write into the LiteRT-LM memory corpus. UI may only claim "saved to memory"
-- after the
-- transaction reaches verified status.

CREATE TABLE IF NOT EXISTS rag_memory_transactions (
  transaction_id TEXT PRIMARY KEY,
  source_type TEXT NOT NULL,
  source_id TEXT NOT NULL,
  chunk_id TEXT NOT NULL,
  status TEXT NOT NULL,
  text_hash TEXT NOT NULL,
  created_at TEXT NOT NULL,
  indexed_at TEXT,
  verified_at TEXT,
  retry_count INTEGER NOT NULL DEFAULT 0,
  last_error TEXT
);

CREATE INDEX IF NOT EXISTS idx_rag_memory_transactions_status
  ON rag_memory_transactions(status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_rag_memory_transactions_source
  ON rag_memory_transactions(source_type, source_id);
