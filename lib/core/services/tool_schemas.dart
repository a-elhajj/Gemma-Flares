/// Tool schema registry for Gemma Flares v2.
/// Provides strict JSON Schema definitions (additionalProperties: false)
/// for all 17 tools exposed to Gemma via the tool-calling interface.

// ignore_for_file: prefer_single_quotes

library;

const List<Map<String, Object?>> kAllToolSchemas = [
  _logCheckin,
  _logSymptom,
  _logUnrelatedSymptom,
  _logBm,
  _logMeal,
  _logMedEvent,
  _ingestLabPanel,
  _ingestProcedureRecord,
  _queryMemory,
  _updateMemoryFact,
  _deleteMemoryFact,
  _getFlareForecast,
  _explainRisk,
  _generateGiSummary,
  _scheduleProactiveCheckin,
  _setPreference,
  _escalateToHuman,
];

const _logCheckin = <String, Object?>{
  "name": "log_checkin",
  "description": "Log a structured IBD check-in using Harvey-Bradshaw Index items. "
      "Call after collecting all HBI fields through sequential conversation turns.",
  "parameters": {
    "type": "object",
    "additionalProperties": false,
    "required": [
      "wellbeing",
      "liquid_stool_count",
      "abdominal_pain",
      "abdominal_mass",
    ],
    "properties": {
      "wellbeing": {
        "type": "integer",
        "description":
            "General wellbeing (0=very well, 1=slightly below par, 2=poor, 3=very poor, 4=terrible)",
        "minimum": 0,
        "maximum": 4,
      },
      "liquid_stool_count": {
        "type": "integer",
        "description": "Number of liquid or very soft stools per day",
        "minimum": 0,
        "maximum": 30,
      },
      "abdominal_pain": {
        "type": "integer",
        "description":
            "Abdominal pain rating (0=none, 1=mild, 2=moderate, 3=severe)",
        "minimum": 0,
        "maximum": 3,
      },
      "abdominal_mass": {
        "type": "integer",
        "description":
            "Abdominal mass (0=none, 1=dubious, 2=definite, 3=tender)",
        "minimum": 0,
        "maximum": 3,
      },
      "complications": {
        "type": "array",
        "description": "IBD complications present",
        "items": {
          "type": "string",
          "enum": [
            "mouth_ulcers",
            "uveitis",
            "arthralgia",
            "erythema_nodosum",
            "pyoderma_gangrenosum",
            "fistula",
            "abscess",
            "other",
          ],
        },
      },
      "notes": {
        "type": "string",
        "description": "Any additional free-text notes",
      },
      "logged_at": {
        "type": "string",
        "description": "ISO 8601 timestamp. Omit to use current time.",
      },
    },
  },
};

const _logSymptom = <String, Object?>{
  "name": "log_symptom",
  "description": "Log an IBD-related symptom from the canonical symptom list.",
  "parameters": {
    "type": "object",
    "additionalProperties": false,
    "required": ["symptom_canonical_id", "severity"],
    "properties": {
      "symptom_canonical_id": {
        "type": "string",
        "description":
            "Canonical symptom ID from symptoms_v1.json (e.g. 'abdominal_pain', 'diarrhea')",
      },
      "severity": {
        "type": "number",
        "description":
            "Severity on the symptom's native scale (0–10 for pain; frequency count for diarrhea)",
        "minimum": 0,
        "maximum": 10,
      },
      "raw_text": {
        "type": "string",
        "description": "Verbatim text from the user describing the symptom",
      },
      "body_region": {"type": "string"},
      "logged_at": {"type": "string", "description": "ISO 8601 timestamp"},
    },
  },
};

const _logUnrelatedSymptom = <String, Object?>{
  "name": "log_unrelated_symptom",
  "description": "Log a symptom that does not match any IBD canonical symptom. "
      "Used for taxonomy expansion and completeness.",
  "parameters": {
    "type": "object",
    "additionalProperties": false,
    "required": ["raw_text"],
    "properties": {
      "raw_text": {
        "type": "string",
        "description": "Verbatim description of the symptom",
      },
      "candidate_category": {"type": "string"},
      "logged_at": {"type": "string"},
    },
  },
};

const _logBm = <String, Object?>{
  "name": "log_bm",
  "description": "Log a bowel movement event.",
  "parameters": {
    "type": "object",
    "additionalProperties": false,
    "required": ["count"],
    "properties": {
      "count": {
        "type": "integer",
        "description": "Number of bowel movements in this event (usually 1)",
        "minimum": 1,
      },
      "bristol_score": {
        "type": "integer",
        "description": "Bristol Stool Form Scale (1–7)",
        "minimum": 1,
        "maximum": 7,
      },
      "blood": {"type": "boolean"},
      "urgency": {"type": "boolean"},
      "notes": {"type": "string"},
      "logged_at": {"type": "string"},
    },
  },
};

const _logMeal = <String, Object?>{
  "name": "log_meal",
  "description": "Log a meal and any immediate GI response.",
  "parameters": {
    "type": "object",
    "additionalProperties": false,
    "required": ["description"],
    "properties": {
      "description": {
        "type": "string",
        "description": "Free-text meal description",
      },
      "immediate_gi_response": {
        "type": "string",
        "description": "Any immediate symptom triggered by this meal",
      },
      "logged_at": {"type": "string"},
    },
  },
};

const _logMedEvent = <String, Object?>{
  "name": "log_med_event",
  "description": "Log a medication taken or missed event.",
  "parameters": {
    "type": "object",
    "additionalProperties": false,
    "required": ["event_type"],
    "properties": {
      "event_type": {
        "type": "string",
        "enum": ["taken", "missed", "delayed", "side_effect"],
        "description": "Type of medication event",
      },
      "drug_name": {"type": "string"},
      "dose": {"type": "string"},
      "route": {
        "type": "string",
        "enum": ["oral", "injection", "infusion", "topical", "other"],
      },
      "notes": {"type": "string"},
      "logged_at": {"type": "string"},
    },
  },
};

const _ingestLabPanel = <String, Object?>{
  "name": "ingest_lab_panel",
  "description":
      "Ingest one or more lab results. Extract analyte, value, unit, and date "
          "from user-provided text or OCR output.",
  "parameters": {
    "type": "object",
    "additionalProperties": false,
    "required": ["results"],
    "properties": {
      "results": {
        "type": "array",
        "minItems": 1,
        "items": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "analyte_canonical_id",
            "value_numeric",
            "unit",
            "drawn_date",
          ],
          "properties": {
            "analyte_canonical_id": {"type": "string"},
            "value_numeric": {"type": "number"},
            "unit": {"type": "string"},
            "drawn_date": {"type": "string"},
            "reference_high": {"type": "number"},
            "reference_low": {"type": "number"},
            "abnormal_flag": {"type": "string"},
            "lab_name": {"type": "string"},
            "confidence": {"type": "number", "minimum": 0, "maximum": 1},
          },
        },
      },
      "source": {
        "type": "string",
        "enum": ["user_text", "photo_ocr", "hl7_fhir"],
        "description": "How the lab data was provided",
      },
    },
  },
};

const _ingestProcedureRecord = <String, Object?>{
  "name": "ingest_procedure_record",
  "description": "Ingest a procedure or clinical record summary.",
  "parameters": {
    "type": "object",
    "additionalProperties": false,
    "required": ["procedure_type", "procedure_date"],
    "properties": {
      "procedure_type": {
        "type": "string",
        "enum": [
          "colonoscopy",
          "sigmoidoscopy",
          "endoscopy",
          "mri_enterography",
          "ct_scan",
          "ultrasound",
          "biopsy",
          "infusion",
          "injection",
          "other",
        ],
      },
      "procedure_date": {"type": "string"},
      "findings_summary": {"type": "string"},
      "provider_name": {"type": "string"},
      "location": {"type": "string"},
      "notes": {"type": "string"},
    },
  },
};

const _queryMemory = <String, Object?>{
  "name": "query_memory",
  "description":
      "Retrieve past health events, symptoms, or context not present in the "
          "current grounded context block. Use for specific date ranges or event types.",
  "parameters": {
    "type": "object",
    "additionalProperties": false,
    "required": ["query"],
    "properties": {
      "query": {
        "type": "string",
        "description": "Natural language query for memory retrieval",
      },
      "date_from": {
        "type": "string",
        "description": "ISO 8601 start date (inclusive)",
      },
      "date_to": {
        "type": "string",
        "description": "ISO 8601 end date (inclusive)",
      },
      "event_types": {
        "type": "array",
        "items": {
          "type": "string",
          "enum": [
            "symptom",
            "checkin",
            "lab",
            "bm",
            "meal",
            "medication",
            "procedure",
            "risk_score",
          ],
        },
      },
      "max_results": {
        "type": "integer",
        "minimum": 1,
        "maximum": 20,
        "default": 10,
      },
    },
  },
};

const _updateMemoryFact = <String, Object?>{
  "name": "update_memory_fact",
  "description":
      "Update or add a persistent fact in the user's pinned fact card "
          "(Tier 1 memory). Always confirm with the user before calling.",
  "parameters": {
    "type": "object",
    "additionalProperties": false,
    "required": ["field", "value"],
    "properties": {
      "field": {
        "type": "string",
        "description":
            "Fact field key. Valid keys: name, age, diagnosis, diagnosis_year, "
                "current_medications, allergies, surgeon, last_colonoscopy, "
                "baseline_crp, baseline_calprotectin, typical_flare_triggers, goals",
      },
      "value": {
        "description": "New value for the field. Pass null to clear it.",
      },
      "reason": {
        "type": "string",
        "description": "Why this fact is being updated",
      },
      "user_confirmed": {
        "type": "boolean",
        "description":
            "Must be true. Do not call without explicit user confirmation.",
      },
    },
  },
};

const _deleteMemoryFact = <String, Object?>{
  "name": "delete_memory_fact",
  "description": "Remove a specific fact from the pinned fact card. "
      "Requires explicit user confirmation.",
  "parameters": {
    "type": "object",
    "additionalProperties": false,
    "required": ["field", "user_confirmed"],
    "properties": {
      "field": {"type": "string"},
      "user_confirmed": {"type": "boolean"},
    },
  },
};

const _getFlareForecast = <String, Object?>{
  "name": "get_flare_forecast",
  "description":
      "Retrieve the current flare-risk score, probability estimates for 7/14/21 "
          "days, and a plain-language explanation.",
  "parameters": {
    "type": "object",
    "additionalProperties": false,
    "properties": {
      "include_feature_weights": {
        "type": "boolean",
        "description": "Include per-feature attribution in the response",
        "default": false,
      },
    },
  },
};

const _explainRisk = <String, Object?>{
  "name": "explain_risk",
  "description":
      "Generate a detailed explanation of what's driving the current flare-risk "
          "score. Returns structured attribution + narrative.",
  "parameters": {
    "type": "object",
    "additionalProperties": false,
    "properties": {
      "depth": {
        "type": "string",
        "enum": ["brief", "detailed"],
        "default": "brief",
      },
    },
  },
};

const _generateGiSummary = <String, Object?>{
  "name": "generate_gi_summary",
  "description":
      "Generate a structured GI appointment summary covering the specified "
          "date range. Ask user for date range first.",
  "parameters": {
    "type": "object",
    "additionalProperties": false,
    "required": ["date_from", "date_to"],
    "properties": {
      "date_from": {"type": "string", "description": "ISO 8601 start date"},
      "date_to": {"type": "string", "description": "ISO 8601 end date"},
      "include_labs": {"type": "boolean", "default": true},
      "include_medications": {"type": "boolean", "default": true},
      "include_wearable_trends": {"type": "boolean", "default": true},
      "format": {
        "type": "string",
        "enum": ["structured", "narrative"],
        "default": "structured",
      },
    },
  },
};

const _scheduleProactiveCheckin = <String, Object?>{
  "name": "schedule_proactive_checkin",
  "description":
      "Pre-generate a proactive check-in prompt to be delivered as a "
          "local notification. Only call when risk is elevated and the user "
          "hasn't checked in for >48 hours.",
  "parameters": {
    "type": "object",
    "additionalProperties": false,
    "required": ["schedule_at"],
    "properties": {
      "schedule_at": {
        "type": "string",
        "description": "ISO 8601 datetime for delivery",
      },
      "trigger_reason": {
        "type": "string",
        "description": "Why this check-in was scheduled",
      },
      "draft_message": {
        "type": "string",
        "description":
            "Pre-drafted notification message. Keep under 140 chars.",
      },
    },
  },
};

const _setPreference = <String, Object?>{
  "name": "set_preference",
  "description": "Persist a user communication or app preference.",
  "parameters": {
    "type": "object",
    "additionalProperties": false,
    "required": ["key", "value"],
    "properties": {
      "key": {
        "type": "string",
        "description":
            "Preference key. Valid keys: response_length, use_medical_terms, "
                "units_weight, units_temperature, quiet_hours_start, quiet_hours_end, "
                "notifications_enabled",
      },
      "value": {"description": "New preference value"},
      "reason": {"type": "string"},
    },
  },
};

const _escalateToHuman = <String, Object?>{
  "name": "escalate_to_human",
  "description":
      "Flag that the user should contact their care team or seek urgent care. "
          "Always call this when the user describes alarming symptoms.",
  "parameters": {
    "type": "object",
    "additionalProperties": false,
    "required": ["reason", "urgency"],
    "properties": {
      "reason": {
        "type": "string",
        "description": "Brief reason for escalation",
      },
      "urgency": {
        "type": "string",
        "enum": ["routine", "soon", "urgent"],
        "description":
            "routine = next appointment; soon = within days; urgent = seek care now",
      },
      "suggested_action": {
        "type": "string",
        "description": "What the user should do (e.g. 'Call your GI doctor')",
      },
    },
  },
};
