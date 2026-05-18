ALTER TABLE wearable_samples ADD COLUMN local_date TEXT NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_wearable_samples_local_date
ON wearable_samples(local_date);
