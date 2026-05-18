-- v21: Circular-buffer training history for per-model AUC computation.
-- Stores the last 200 (predicted_prob, actual_label) pairs per logistic model.
-- Append-only from the app's perspective; pruned by the logistic risk service
-- whenever records exceed 200 per model_key.

CREATE TABLE IF NOT EXISTS logistic_training_history (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  model_key      TEXT    NOT NULL,         -- e.g. 'logistic_v1_inflammatory_7d'
  sample_date    TEXT    NOT NULL,         -- YYYY-MM-DD of the training observation
  predicted_prob REAL    NOT NULL,         -- probability produced BEFORE the SGD update
  actual_label   INTEGER NOT NULL,         -- 0 (no flare) or 1 (flare)
  training_n     INTEGER NOT NULL,         -- trainingSamples at time of observation
  recorded_at    TEXT    NOT NULL          -- ISO-8601 UTC timestamp
);

CREATE INDEX IF NOT EXISTS idx_lth_model_key ON logistic_training_history (model_key);
CREATE INDEX IF NOT EXISTS idx_lth_model_date ON logistic_training_history (model_key, sample_date);
