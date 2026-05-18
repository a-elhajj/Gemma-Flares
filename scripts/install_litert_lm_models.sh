#!/usr/bin/env zsh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
downloads_dir="${LITERT_LM_MODEL_DOWNLOADS_DIR:-/private/tmp/litert-lm-model-downloads}"
models_dir="$repo_root/ios/Runner/Models/litert-lm"
model_mode="${1:-e2b}"

# SHA-256 for the approved LiteRT-LM Gemma 4 E2B model file.
# Update this value whenever the hosted artifact changes.
e2b_source_file="gemma-4-E2B-it.litertlm"
e2b_model="$downloads_dir/$e2b_source_file"
e2b_sha="${LITERT_LM_E2B_SHA:-181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

usage() {
  cat <<EOF
Usage: scripts/install_litert_lm_models.sh [e2b]

Downloads the approved LiteRT-LM Gemma 4 E2B model file, verifies SHA-256, and
installs it into ios/Runner/Models/litert-lm. Only E2B is supported for the
initial release track.

Environment variables:
  LITERT_LM_MODEL_DOWNLOADS_DIR   Override download staging directory
                                  (default: /private/tmp/litert-lm-model-downloads)
  LITERT_LM_E2B_SHA               Override expected SHA-256 (useful in CI when
                                  the artifact is pre-staged and verified upstream)
EOF
}

case "$model_mode" in
  e2b) ;;
  --help|-h) usage; exit 0 ;;
  *) echo "Invalid model mode: $model_mode (only 'e2b' is supported)" >&2; usage >&2; exit 2 ;;
esac

verify_sha() {
  local file="$1"
  local expected="$2"
  local actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "Checksum mismatch for $file" >&2
    echo "expected: $expected" >&2
    echo "actual  : $actual" >&2
    rm -f "$file"
    exit 1
  fi
}

require_cmd hf
require_cmd shasum

mkdir -p "$downloads_dir" "$models_dir"

hf download litert-community/gemma-4-E2B-it-litert-lm \
  "$e2b_source_file" \
  --local-dir "$downloads_dir" \
  --max-workers 4

verify_sha "$e2b_model" "$e2b_sha"
rm -rf "$models_dir/gemma-4-E2B-it"
mkdir -p "$models_dir/gemma-4-E2B-it"
cp "$e2b_model" "$models_dir/gemma-4-E2B-it/model.litertlm"

model_bytes="$(stat -f '%z' "$models_dir/gemma-4-E2B-it/model.litertlm" 2>/dev/null || echo 0)"
if (( model_bytes < 2500000000 )); then
  echo "Invalid LiteRT-LM artifact: model.litertlm is too small (${model_bytes} bytes)." >&2
  exit 1
fi

cat <<EOF
Installed LiteRT-LM Gemma 4 E2B model folder.
- root:   $models_dir
- sha256: $e2b_sha
EOF
