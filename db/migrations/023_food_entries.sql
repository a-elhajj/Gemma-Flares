-- v23: Structured food logging.
--
-- Food entries are saved locally before being indexed into RAG. The row id is
-- the stable source id used by the vector chunk id `food_tx_<id>`.

CREATE TABLE IF NOT EXISTS food_entries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  logged_at TEXT NOT NULL,
  date_local TEXT NOT NULL,
  food_name TEXT NOT NULL,
  description TEXT,
  meal_type TEXT,
  calories REAL,
  portion_grams REAL,
  portion_unit TEXT,
  is_gluten_free INTEGER,
  is_lactose_free INTEGER,
  is_dairy_free INTEGER,
  is_high_fiber INTEGER,
  is_high_fat INTEGER,
  is_spicy INTEGER,
  fiber_grams REAL,
  protein_grams REAL,
  fat_grams REAL,
  carb_grams REAL,
  sugar_grams REAL,
  sodium_mg REAL,
  allergens_json TEXT NOT NULL DEFAULT '[]',
  notes TEXT,
  trigger_suspected INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT 'manual',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_food_entries_logged_at
  ON food_entries(logged_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_food_entries_date_local
  ON food_entries(date_local, logged_at DESC);

CREATE INDEX IF NOT EXISTS idx_food_entries_trigger
  ON food_entries(trigger_suspected, logged_at DESC);
