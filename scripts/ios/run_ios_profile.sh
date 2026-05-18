#!/usr/bin/env zsh

set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/opt/homebrew/share/flutter/bin:$PATH"

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
staged_app_dirs=(
  "$repo_root/build/ios/iphoneos/Runner.app"
  "$repo_root/build/ios/Profile-iphoneos/Runner.app"
)
derived_data_dir="$HOME/Library/Developer/Xcode/DerivedData"
min_free_gb=30
min_no_model_free_gb="${GUTGUARD_MIN_NO_MODEL_IOS_PROFILE_FREE_GB:-8}"
max_active_model_gb="${GUTGUARD_MAX_ACTIVE_MODEL_GB:-8}"
retry_devicectl="${GUTGUARD_RETRY_DEVICECTL:-1}"
dry_run=false
reset_setup=false
model_mode="${GEMMA_FLARES_IOS_PROFILE_MODEL_MODE:-none}"
flutter_args=()

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      dry_run=true
      ;;
    --fast-ui)
      model_mode="none"
      ;;
    --model-mode=*)
      model_mode="${arg#--model-mode=}"
      ;;
    --reset-setup)
      reset_setup=true
      ;;
    *)
      flutter_args+=("$arg")
      ;;
  esac
done

# Inject GEMMA_FLARES_DEV_RESET=true when --reset-setup is passed.
# This clears setup state and profile at boot so the setup wizard runs.
if [[ "$reset_setup" == "true" ]]; then
  flutter_args+=("--dart-define=GEMMA_FLARES_DEV_RESET=true")
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<EOF
Usage: scripts/run_ios_profile.sh [--dry-run] [--fast-ui] [--reset-setup] [--model-mode=e2b|none|keep] [flutter-run-args...]

Removes Flutter's staged iOS app bundle before running flutter run --profile.
This avoids intermittent rsync staging failures with the large bundled
Gemma model archives.

The script also checks available disk space before starting. Profile builds with
bundled models copy multi-GB assets into Xcode/Flutter staging folders. No-model
profile builds use a smaller free-space floor because the app bundle stays small.

By default it builds a fast no-model app bundle. First-run setup downloads the
E2B model into the app sandbox, and later --fast-ui/no-model installs can reuse
that sandbox model without copying multi-GB assets through Xcode.

Model mode defaults to none, which excludes all bundled model artifacts. Gemma
loads after setup downloads LiteRT-LM model bundles into the app sandbox. Use
--model-mode=e2b only when you intentionally want to seed a bundled model.

Examples:
  scripts/ios/run_ios_profile.sh -d <device-id>
  scripts/ios/run_ios_profile.sh --fast-ui -d <device-id>
  scripts/ios/run_ios_profile.sh --model-mode=e2b -d <device-id>
  scripts/ios/run_ios_profile.sh --dry-run -d <device-id>
EOF
  exit 0
fi

case "$model_mode" in
  e2b|none|keep)
    ;;
  *)
    echo "Invalid model mode: $model_mode" >&2
    echo "Expected one of: e2b, none, keep" >&2
    exit 2
    ;;
esac

if [[ "$model_mode" != "keep" ]]; then
  if [[ "$dry_run" == true ]]; then
    echo "Dry run only. Would select LiteRT-LM bundled model mode: $model_mode"
  else
    echo "Selecting LiteRT-LM bundled model mode: $model_mode"
    litert_models_dir="$repo_root/ios/Runner/Models/litert-lm"
    litert_cache_dir="${GUTGUARD_MODEL_CACHE:-$HOME/Library/Application Support/GutGuard/ModelArtifacts/litert-lm}"
    case "$model_mode" in
      none)
        mkdir -p "$litert_cache_dir"
        if [[ -d "$litert_models_dir" ]]; then
          while IFS= read -r -d '' model_dir; do
            model_name="$(basename "$model_dir")"
            rm -rf "$litert_cache_dir/$model_name"
            mv "$model_dir" "$litert_cache_dir/$model_name"
          done < <(find "$litert_models_dir" -mindepth 1 -maxdepth 1 -type d -print0)
        fi
        ;;
      e2b)
        mkdir -p "$litert_models_dir"
        if [[ -d "$litert_cache_dir/gemma-4-E2B-it" ]]; then
          rm -rf "$litert_models_dir/gemma-4-E2B-it"
          mv "$litert_cache_dir/gemma-4-E2B-it" "$litert_models_dir/gemma-4-E2B-it"
        elif [[ ! -d "$litert_models_dir/gemma-4-E2B-it" ]]; then
          cat >&2 <<EOF
LiteRT-LM E2B is not installed for bundling.

Install the approved artifact first:
  scripts/install_litert_lm_models.sh e2b

Or run without bundled models:
  scripts/run_ios_profile.sh --fast-ui ${flutter_args[*]}
EOF
          exit 1
        fi
        ;;
    esac
  fi
fi

staged_app_kb=0
for staged_app_dir in "${staged_app_dirs[@]}"; do
  if [[ -d "$staged_app_dir" ]]; then
    staged_app_kb=$((staged_app_kb + $(du -sk "$staged_app_dir" 2>/dev/null | awk '{print $1}')))
    display_path="${staged_app_dir#$repo_root/}"
    if [[ "$dry_run" == true ]]; then
      echo "Dry run only. Would remove stale staged app bundle at $display_path"
    else
      echo "Removing stale staged app bundle at $display_path"
      rm -rf "$staged_app_dir"
    fi
  fi
done

free_kb="$(df -Pk "$repo_root" | awk 'NR == 2 {print $4}')"
effective_free_kb="$free_kb"
if [[ "$dry_run" == true && "$staged_app_kb" != "0" ]]; then
  effective_free_kb=$((free_kb + staged_app_kb))
fi
free_gb=$((effective_free_kb / 1024 / 1024))
required_free_gb="$min_free_gb"
if [[ "$model_mode" == "none" ]]; then
  required_free_gb="$min_no_model_free_gb"
fi
if (( free_gb < required_free_gb )); then
  if [[ "$model_mode" == "none" ]]; then
    cat >&2 <<EOF
Refusing to start no-model profile build: only ${free_gb}GB free.

The current app bundle has no bundled model assets, but Flutter/Xcode still need room
for build products, DerivedData, logs, and device-install staging. Free at least
${required_free_gb}GB, or override GEMMA_FLARES_MIN_NO_MODEL_IOS_PROFILE_FREE_GB for
a one-off run if you accept the risk of an Xcode disk-space failure.

Safe generated cleanup:
  rm -rf build .dart_tool ios/Pods ios/.symlinks ios/Flutter/ephemeral
  rm -rf ~/Library/Developer/Xcode/DerivedData/Runner-*
EOF
  else
    cat >&2 <<EOF
Refusing to start profile build: only ${free_gb}GB free.

This app bundles multi-GB local model assets, and Xcode needs enough room to
copy them into DerivedData and build/ staging. Free at least ${required_free_gb}GB,
or remove one inactive model from ios/Runner/Models/ before building.

Safe generated cleanup:
  rm -rf build .dart_tool ios/Pods ios/.symlinks ios/Flutter/ephemeral
  rm -rf ~/Library/Developer/Xcode/DerivedData/Runner-*
EOF
  fi
  exit 1
fi

if [[ -d "$derived_data_dir" ]]; then
  find "$derived_data_dir" -maxdepth 1 -type d -name 'Runner-*' -size -1M -mtime +0 -exec rm -rf {} + 2>/dev/null || true
  if [[ "${GEMMA_FLARES_CLEAN_DERIVED_DATA:-0}" == "1" ]]; then
    if [[ "$dry_run" == true ]]; then
      echo "Dry run only. Would remove Runner DerivedData under $derived_data_dir"
    else
      echo "Removing Runner DerivedData under $derived_data_dir"
      find "$derived_data_dir" -maxdepth 1 -type d -name 'Runner-*' -exec rm -rf {} + 2>/dev/null || true
    fi
  fi
fi

active_models_dir="$repo_root/ios/Runner/Models/litert-lm"
skip_active_model_size_guard=false
if [[ "$dry_run" == true && "$model_mode" == "none" ]]; then
  skip_active_model_size_guard=true
fi
if [[ -d "$active_models_dir" && "${ALLOW_LARGE_IOS_MODEL_BUNDLE:-0}" != "1" && "$skip_active_model_size_guard" != true ]]; then
  active_models_kb="$(du -sk "$active_models_dir" 2>/dev/null | awk '{print $1}')"
  active_models_gb=$((active_models_kb / 1024 / 1024))
  if (( active_models_gb > max_active_model_gb )); then
    cat >&2 <<EOF
Refusing to start profile build: active bundled LiteRT-LM models are ${active_models_gb}GB.

Xcode copies every folder under ios/Runner/Models/litert-lm into Runner.app. A
large bundled model inflates the app bundle and device install can take long
enough that Flutter reports "Dart VM Service was not discovered".

Recommended fix for normal profiling:
  scripts/run_ios_profile.sh --model-mode=e2b ${flutter_args[*]}

Fastest UI-only profiling:
  scripts/run_ios_profile.sh --fast-ui ${flutter_args[*]}

Fast app bundle — stage the model once in the app sandbox, then run without
bundled models:
  scripts/run_ios_profile.sh --fast-ui ${flutter_args[*]}

Override only when intentionally testing a large seeded bundle:
  ALLOW_LARGE_IOS_MODEL_BUNDLE=1 scripts/run_ios_profile.sh --model-mode=e2b ${flutter_args[*]}
EOF
    exit 1
  fi
fi

if [[ -d "$active_models_dir" ]]; then
  for model_dir in "$active_models_dir"/*(/N); do
    missing=()
    litert_file="$model_dir/model.litertlm"
    if [[ ! -f "$litert_file" ]]; then
      missing+=("model.litertlm missing")
    else
      file_bytes="$(stat -f '%z' "$litert_file" 2>/dev/null || echo 0)"
      if (( file_bytes < 2500000000 )); then
        missing+=("model.litertlm truncated (${file_bytes} bytes)")
      fi
    fi
    total_bytes="$(( $(du -sk "$model_dir" 2>/dev/null | awk '{print $1}') * 1024 ))"
    if (( total_bytes < 2500000000 )); then
      missing+=("extracted model too small (${total_bytes} bytes)")
    fi
    if (( ${#missing[@]} > 0 )); then
      cat >&2 <<EOF
Refusing to start profile build: invalid LiteRT-LM model bundle at ${model_dir#$repo_root/}.

${(F)missing}

Reinstall the active model before building:
  scripts/install_litert_lm_models.sh e2b
EOF
      exit 1
    fi
  done
fi

cd "$repo_root"

if [[ "$dry_run" == true ]]; then
  echo "Dry run only. Would execute: flutter run --profile ${flutter_args[*]}"
  exit 0
fi

run_log="$(mktemp -t gemma_flares_flutter_run.XXXXXX.log)"
set +e
flutter run --profile "${flutter_args[@]}" 2>&1 | tee "$run_log"
run_status="${pipestatus[1]}"
set -e

if (( run_status != 0 )) && grep -E "CoreDeviceError|No provider was found|devicectl" "$run_log" >/dev/null 2>&1; then
  cat >&2 <<EOF

Flutter/device launch failed in Apple's devicectl layer, not in Gemma Flares code.

Fast recovery:
  1. Keep the iPhone unlocked and trusted.
  2. Unplug/replug the cable, or toggle Developer Mode if Xcode cannot see services.
  3. Retry with this wrapper so stale Runner.app staging is cleaned first:
    scripts/ios/run_ios_profile.sh ${flutter_args[*]}

Deep cleanup if it repeats:
  xcrun devicectl list devices
  rm -rf ~/Library/Developer/Xcode/DerivedData/Runner-*
  flutter clean
  flutter pub get

Log captured at: $run_log
EOF
  if [[ "$retry_devicectl" == "1" ]]; then
    echo "Retrying flutter run once after devicectl failure..." >&2
    xcrun devicectl list devices >/dev/null 2>&1 || true
    set +e
    flutter run --profile "${flutter_args[@]}" 2>&1 | tee -a "$run_log"
    retry_status="${pipestatus[1]}"
    set -e
    exit "$retry_status"
  fi
fi

exit "$run_status"
