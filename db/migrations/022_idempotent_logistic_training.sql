-- v22: Idempotent logistic training observations.
-- Recomputing the same risk date must not train the same model on the same
-- labeled sample repeatedly during app open/resume refreshes.

DELETE FROM logistic_training_history
WHERE id NOT IN (
  SELECT MIN(id)
  FROM logistic_training_history
  GROUP BY model_key, sample_date
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_lth_model_sample_unique
  ON logistic_training_history (model_key, sample_date);
