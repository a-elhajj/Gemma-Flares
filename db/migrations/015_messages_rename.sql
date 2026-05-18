-- Migration 015: Rename conversations → messages and add memory columns
ALTER TABLE conversations RENAME TO messages;
ALTER TABLE messages ADD COLUMN embedding BLOB;
ALTER TABLE messages ADD COLUMN embedding_model_version TEXT;
ALTER TABLE messages ADD COLUMN session_id TEXT;
ALTER TABLE messages ADD COLUMN turn_index INTEGER;
ALTER TABLE messages ADD COLUMN is_proactive_open INTEGER NOT NULL DEFAULT 0;
ALTER TABLE messages ADD COLUMN interrupted INTEGER NOT NULL DEFAULT 0;
ALTER TABLE messages ADD COLUMN interrupt_marker TEXT;

CREATE INDEX IF NOT EXISTS idx_messages_session_id
  ON messages(session_id);
CREATE INDEX IF NOT EXISTS idx_messages_created_at
  ON messages(created_at DESC);
