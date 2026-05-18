-- Migration 017: Notification preferences
CREATE TABLE IF NOT EXISTS notification_preferences (
  key TEXT PRIMARY KEY,
  value_json TEXT NOT NULL
);

INSERT OR IGNORE INTO notification_preferences (key, value_json) VALUES
  ('quiet_hours_start', '22'),
  ('quiet_hours_end', '8'),
  ('max_per_day', '2'),
  ('global_off', 'false'),
  ('snooze_until', 'null');
