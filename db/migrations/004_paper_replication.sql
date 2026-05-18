-- Migration 004: Mount Sinai Paper Replication Tables
-- Hirten et al., Gastroenterology 2025 (168:939-951)
--
-- Adds ground-truth label infrastructure (lab values, PRO-2 surveys, flare labels),
-- Cosinor circadian feature storage, and logistic model state persistence.
-- All statements use IF NOT EXISTS — safe for fresh installs and upgrades from v3.

-- ─────────────────────────────────────────────────────────────────────────────
-- Lab biomarker values (CRP, ESR, FC) entered by user from clinic results.
-- Used ONLY as ground-truth labels for inflammatory flare detection.
-- NOT used as wearable predictors.
-- Paper thresholds (Hirten et al. 2025):
--   CRP >5 mg/dL  |  ESR >30 mm/h  |  FC >150 μg/g
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS lab_values (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  drawn_date      TEXT    NOT NULL,   -- YYYY-MM-DD (local date of blood draw / stool test)
  lab_type        TEXT    NOT NULL,   -- 'crp' | 'esr' | 'fc'
  value_numeric   REAL    NOT NULL,
  unit            TEXT    NOT NULL,   -- 'mg/dL' | 'mm/h' | 'ug/g'
  reference_high  REAL,               -- paper threshold stored for display (5 / 30 / 150)
  notes           TEXT,
  created_at      TEXT    NOT NULL,
  updated_at      TEXT    NOT NULL
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Daily PRO-2 check-in survey responses.
-- Ground-truth labels for symptomatic flare detection.
--
-- CD PRO-2 formula (Hirten et al., Supplementary):
--   score = (abdominal_pain * 7) + stool_frequency
--   remission = score < 8
--
-- UC PRO-2 formula:
--   score = rectal_bleeding + stool_frequency
--   remission = score <= 1 AND rectal_bleeding = 0 AND stool_frequency <= 1
--
-- Symptomatic flare definition used in paper:
--   >= 4 surveys answered in 7-day window AND >= 2 surveys meeting flare threshold
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS pro2_surveys (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  survey_date         TEXT    NOT NULL,   -- YYYY-MM-DD
  disease_type        TEXT    NOT NULL,   -- 'CD' | 'UC'
  -- CD-specific fields (null for UC)
  cd_abdominal_pain   INTEGER,            -- 0=None | 1=Mild | 2=Moderate | 3=Severe
  cd_stool_frequency  INTEGER,            -- 0 | 1 | 2 | 3 | 4 (4+ per day)
  -- UC-specific fields (null for CD)
  uc_rectal_bleeding  INTEGER,            -- 0=None | 1=Streaks | 2=Obvious | 3=Mostly blood
  uc_stool_frequency  INTEGER,            -- 0=Normal | 1=1-2 more | 2=3-4 more | 3=5+ more
  pro2_score          REAL    NOT NULL,
  is_flare            INTEGER NOT NULL DEFAULT 0,  -- 1 if score meets flare threshold
  notes               TEXT,
  created_at          TEXT    NOT NULL
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Computed ground-truth flare labels (one row per calendar date).
-- Rebuilt deterministically from lab_values + pro2_surveys on every recompute.
-- Primary key is label_date so upsert via INSERT OR REPLACE is safe.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS flare_labels (
  label_date          TEXT    PRIMARY KEY,
  inflammatory_flare  INTEGER NOT NULL DEFAULT 0,  -- 1 if CRP>5 OR ESR>30 OR FC>150 within ±7d
  symptomatic_flare   INTEGER NOT NULL DEFAULT 0,  -- 1 if ≥2/4 surveys meet PRO-2 threshold in 7d window
  combined_flare      INTEGER NOT NULL DEFAULT 0,  -- 1 if BOTH inflammatory AND symptomatic
  label_source        TEXT    NOT NULL,            -- 'lab' | 'pro2' | 'combined' | 'none'
  confidence          TEXT    NOT NULL,            -- 'high' | 'medium' | 'low'
  recomputed_at       TEXT    NOT NULL
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Daily Cosinor circadian features extracted from intraday HRV SDNN samples.
--
-- OLS model (Hirten et al. Supplementary Eq. 1, simplified for single user):
--   y(t) = M + A*cos(2πt/24) + B*sin(2πt/24) + ε
--
-- Derived parameters:
--   MESOR        = M  (midline-estimating statistic of rhythm)
--   Amplitude    = sqrt(A² + B²)
--   Acrophase    = atan2(−B, A)  [radians, chronobiological convention]
--   PeakTime     = −Acrophase × 24 / (2π)  [hours, 0–24]
--
-- fit_valid = 1 iff sample_count >= 6 AND time_span_hours >= 8.0 AND r_squared >= 0.10
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cosinor_features (
  feature_date      TEXT    PRIMARY KEY,
  mesor             REAL,               -- ms (mean SDNN level)
  amplitude         REAL,               -- ms (half the circadian swing)
  acrophase_rad     REAL,               -- radians
  peak_time_hours   REAL,               -- 0.0–24.0
  r_squared         REAL,               -- goodness-of-fit (0–1)
  sample_count      INTEGER,
  time_span_hours   REAL,
  fit_valid         INTEGER NOT NULL DEFAULT 0,
  recomputed_at     TEXT    NOT NULL
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Logistic regression model state (online SGD, one row per horizon × flare type).
-- model_key format: 'logistic_v1_{flare_type}_{horizon}d'
-- e.g. 'logistic_v1_inflammatory_7d', 'logistic_v1_symptomatic_49d'
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS logistic_model_state (
  model_key         TEXT    PRIMARY KEY,
  horizon_days      INTEGER NOT NULL,
  flare_type        TEXT    NOT NULL,           -- 'inflammatory' | 'symptomatic'
  coefficients_json TEXT    NOT NULL,           -- JSON: {"feature_name": weight, ...}
  intercept         REAL    NOT NULL DEFAULT 0.0,
  training_samples  INTEGER NOT NULL DEFAULT 0,
  last_auc          REAL,
  last_f1           REAL,
  updated_at        TEXT    NOT NULL
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Indexes
-- ─────────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_lab_values_drawn
  ON lab_values(drawn_date);
CREATE INDEX IF NOT EXISTS idx_lab_values_type_drawn
  ON lab_values(lab_type, drawn_date);
CREATE INDEX IF NOT EXISTS idx_pro2_date
  ON pro2_surveys(survey_date);
CREATE INDEX IF NOT EXISTS idx_flare_labels_date
  ON flare_labels(label_date);
CREATE INDEX IF NOT EXISTS idx_cosinor_date
  ON cosinor_features(feature_date);
