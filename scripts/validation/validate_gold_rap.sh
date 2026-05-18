#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

# Modes:
# - Local dev (default outside CI): faster test subset, skips non-critical UI/widget and gemma eval.
# - Full/CI: include broader test surfaces.
if [[ "${CI:-}" == "true" || "${CI:-}" == "1" ]]; then
  default_local_dev=0
else
  default_local_dev=1
fi
local_dev_mode="${GOLD_RAP_LOCAL_DEV:-$default_local_dev}"
skip_ui_widget="${GOLD_RAP_SKIP_UI_WIDGET:-$local_dev_mode}"
skip_gemma_eval="${GOLD_RAP_SKIP_GEMMA_EVAL:-$local_dev_mode}"
schema_safety_only="${GOLD_RAP_SCHEMA_SAFETY_ONLY:-0}"
skip_tests="${GOLD_RAP_SKIP_TESTS:-0}"

# Local pre-push should stay fast while preserving broad signal.
# By default we exclude heavyweight suites tagged `extended` and `slow`
# in local-dev mode. CI/full mode runs without exclusions unless explicitly set.
if [[ "$local_dev_mode" == "1" ]]; then
  default_exclude_tags="extended,slow"
else
  default_exclude_tags=""
fi
test_exclude_tags="${GOLD_RAP_TEST_EXCLUDE_TAGS:-$default_exclude_tags}"

echo "Gold RAP mode: local_dev=$local_dev_mode skip_ui_widget=$skip_ui_widget skip_gemma_eval=$skip_gemma_eval skip_tests=$skip_tests schema_safety_only=$schema_safety_only"

if [[ "$schema_safety_only" == "1" ]]; then
  echo "Gold RAP running schema/safety checks only."
else
  echo "== Gold RAP gate: dependencies =="
  flutter pub get

  echo "== Gold RAP gate: formatting =="
  dart format --set-exit-if-changed lib test

  echo "== Gold RAP gate: static analysis =="
  flutter analyze --no-pub

  echo "== Gold RAP gate: tests =="
  if [[ "$skip_tests" == "1" ]]; then
    echo "Gold RAP tests skipped because GOLD_RAP_SKIP_TESTS=1."
  else
    test_targets=(
      test/core
      # test/adversarial
      # Disabled per request: do not run adversarial suites in Gold RAP.
    )

    if [[ "$skip_ui_widget" != "1" ]]; then
      test_targets+=(
        test/app
        test/features
        test/widget_test.dart
      )
    fi

    echo "Gold RAP test targets: ${test_targets[*]}"

    test_cmd=(flutter test --no-pub)
    if [[ -n "$test_exclude_tags" ]]; then
      echo "Gold RAP exclude tags: $test_exclude_tags"
      test_cmd+=(--exclude-tags="$test_exclude_tags")
    fi
    test_cmd+=("${test_targets[@]}")
    "${test_cmd[@]}"
  fi
fi

# Persona/Gemma eval disabled per request: do not run in Gold RAP.
# if [[ "$skip_gemma_eval" != "1" ]]; then
#   flutter test --no-pub test/gemma_eval/local_agent_eval_runner_test.dart
# fi

echo "== Gold RAP gate: schema drift =="
# v10: Gemma structured tasks (original gate checks)
test -f db/migrations/010_gemma_structured_tasks.sql
grep -q "currentSchemaVersion" lib/core/database/database_contracts.dart
grep -q "Gemma structured tasks" lib/core/database/database_contracts.dart
grep -q "10: 'db/migrations/010_gemma_structured_tasks.sql'" \
  lib/core/database/database_contracts.dart
grep -q "CREATE TABLE IF NOT EXISTS gemma_task_runs" \
  db/migrations/010_gemma_structured_tasks.sql
grep -q "CREATE TABLE IF NOT EXISTS gemma_extraction_reviews" \
  db/migrations/010_gemma_structured_tasks.sql
grep -q "CREATE TABLE IF NOT EXISTS doctor_summaries" \
  db/migrations/010_gemma_structured_tasks.sql
# v11-v19: memory, controls, tool audit, pinned facts, RAG transactions
test -f db/migrations/011_memory_layer_core.sql
test -f db/migrations/012_memory_controls.sql
test -f db/migrations/013_tool_audit.sql
test -f db/migrations/014_pinned_fact_history.sql
test -f db/migrations/015_messages_rename.sql
test -f db/migrations/016_unrelated_symptoms.sql
test -f db/migrations/017_notification_preferences.sql
test -f db/migrations/018_runtime_events.sql
test -f db/migrations/019_rag_memory_transactions.sql
grep -q "19: 'db/migrations/019_rag_memory_transactions.sql'" \
  lib/core/database/database_contracts.dart
grep -q "rag_memory_transactions" db/migrations/019_rag_memory_transactions.sql

echo "== Gold RAP gate: safety copy =="
grep -R -q "not a diagnosis" lib/core lib/features

echo "Gold RAP gate passed."
