-- Migration 006: Expanded lab panel metadata
-- Adds source metadata for manual lab entry without changing flare logic.

ALTER TABLE lab_values
ADD COLUMN lab_name TEXT;

ALTER TABLE lab_values
ADD COLUMN ordering_provider TEXT;