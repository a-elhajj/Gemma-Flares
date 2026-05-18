ALTER TABLE wearable_samples ADD COLUMN metric_family TEXT NOT NULL DEFAULT 'unknown';
ALTER TABLE wearable_samples ADD COLUMN aggregation_level TEXT NOT NULL DEFAULT 'sample';
ALTER TABLE wearable_samples ADD COLUMN is_estimated INTEGER NOT NULL DEFAULT 0;
ALTER TABLE wearable_samples ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0;
ALTER TABLE wearable_samples ADD COLUMN source_payload_json TEXT;
