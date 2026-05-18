#!/usr/bin/env zsh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
artifact_path="${1:-$repo_root/build/ios/iphoneos/Runner.app}"
mode="no-model"
max_no_model_bytes=$((1024 * 1024 * 1024))

usage() {
  cat <<EOF
Usage: scripts/verify_ios_release_artifact.sh [Runner.app|archive.xcarchive] [--mode=no-model|e2b|any]

Verifies the iOS app artifact model-bundling mode for Gemma Flares' LiteRT-LM runtime.
Normal internal TestFlight should use --mode=no-model: the app downloads LiteRT-LM
Gemma 4 E2B bundles during setup and stores them in the device sandbox.

Examples:
  scripts/validation/verify_ios_release_artifact.sh build/ios/iphoneos/Runner.app --mode=no-model
  scripts/validation/verify_ios_release_artifact.sh build/Runner.xcarchive --mode=e2b
EOF
}

for arg in "${@:2}"; do
  case "$arg" in
    --mode=*) mode="${arg#--mode=}" ;;
    --require-mlpackage|--allow-missing-mlpackage) ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

case "$mode" in
  no-model|e2b|any) ;;
  *) echo "Invalid mode: $mode" >&2; usage >&2; exit 2 ;;
esac

if [[ "$artifact_path" != /* ]]; then
  artifact_path="$repo_root/$artifact_path"
fi

if [[ "$artifact_path" == *.xcarchive ]]; then
  artifact_path="$artifact_path/Products/Applications/Runner.app"
fi

if [[ ! -d "$artifact_path" ]]; then
  echo "App bundle not found: $artifact_path" >&2
  exit 1
fi

# LiteRT-LM artifact paths (primary runtime since 2026-05-16)
litert_models_dir="$artifact_path/Models/litert-lm"
litert_e2b_dir="$litert_models_dir/gemma-4-E2B-it"

has_model_dir() {
  [[ -d "$1" ]] || return 1
  [[ -f "$1/model.litertlm" ]] || return 1
  local model_bytes
  model_bytes="$(stat -f '%z' "$1/model.litertlm" 2>/dev/null || echo 0)"
  [[ "$model_bytes" -ge 2500000000 ]] || return 1
}

# Check LiteRT-LM (primary) artifact presence
litert_e2b_present=false
if has_model_dir "$litert_e2b_dir"; then litert_e2b_present=true; fi

case "$mode" in
  no-model)
    if [[ "$litert_e2b_present" == true ]]; then
      echo "Expected no bundled LiteRT-LM models, but found bundled model folders under $litert_models_dir." >&2
      exit 1
    fi
    ;;
  e2b)
    if [[ "$litert_e2b_present" != true ]]; then
      echo "Expected bundled LiteRT-LM E2B but not found." >&2
      echo "  litert_e2b_present=$litert_e2b_present" >&2
      exit 1
    fi
    ;;
esac

if [[ "$mode" == "no-model" ]]; then
  app_size_kb="$(du -sk "$artifact_path" | awk '{print $1}')"
  app_size_bytes=$((app_size_kb * 1024))
  if (( app_size_bytes > max_no_model_bytes )); then
    echo "No-model artifact is unexpectedly large: ${app_size_bytes} bytes." >&2
    echo "Check for accidentally bundled model files or other oversized resources." >&2
    exit 1
  fi
fi

model_summary="no bundled model artifacts"
if [[ "$litert_e2b_present" == true ]]; then
  model_summary="bundled LiteRT-LM E2B only"
fi

cat <<EOF
Verified Gemma Flares iOS release artifact.

- app_bundle:              $artifact_path
- expected_mode:           $mode
- bundle_state:            $model_summary
- litert_e2b_present:      $litert_e2b_present

Normal internal TestFlight uses no bundled model artifacts. First-run setup downloads
approved LiteRT-LM artifacts via LiteRtLmDownloadService, verifies SHA-256, writes
install manifests, and reuses the device sandbox on relaunch.
EOF
