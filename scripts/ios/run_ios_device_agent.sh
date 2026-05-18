#!/usr/bin/env zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
device_id="${GEMMA_FLARES_IOS_DEVICE_ID:-00008140-00114DC82E07001C}"
suite="${GEMMA_FLARES_DEVICE_AGENT_SUITE:-persona_suite}"
persona_count="${GEMMA_FLARES_DEVICE_AGENT_PERSONAS:-8}"
rounds="${GEMMA_FLARES_DEVICE_AGENT_ROUNDS:-10}"
qa_run_id="${GEMMA_FLARES_QA_RUN_ID:-}"

cd "$repo_root"

cat <<EOF
Starting Gemma Flares physical iPhone autonomous agent.

- device: $device_id
- suite: $suite
- personas: $persona_count
- rounds/persona: $rounds
- qa_run_id: ${qa_run_id:-auto}
- watch on iPhone: visible iPhone Agent screen
- watch in terminal: GEMMA_FLARES_DEVICE_AGENT_EVENT and GEMMA_FLARES_DEVICE_AGENT_REPORT

EOF

exec flutter run --profile \
  --device-id "$device_id" \
  --dart-define=GEMMA_FLARES_DEVICE_AGENT=true \
  --dart-define=GEMMA_FLARES_DEVICE_AGENT_SUITE="$suite" \
  --dart-define=GEMMA_FLARES_DEVICE_AGENT_PERSONAS="$persona_count" \
  --dart-define=GEMMA_FLARES_DEVICE_AGENT_ROUNDS="$rounds" \
  --dart-define=GEMMA_FLARES_QA_RUN_ID="$qa_run_id"