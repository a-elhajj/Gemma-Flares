#!/usr/bin/env zsh
#
# verify_entitlements.sh
#
# Asserts that a built Runner.app is signed with the three entitlements
# Gemma Flares requires to load Gemma 4 on physical iPhones:
#
#   - com.apple.developer.healthkit
#   - com.apple.developer.kernel.increased-memory-limit
#   - com.apple.developer.kernel.extended-virtual-addressing
#
# Without increased-memory-limit + extended-virtual-addressing iOS will jetsam
# the process at ~3.3 GB and the 6+ GB Gemma model cannot be loaded. This
# script is intentionally chatty so failures show up clearly in CI logs.
#
# Usage:
#   scripts/validation/verify_entitlements.sh                    # auto-detect Runner.app
#   scripts/validation/verify_entitlements.sh path/to/Runner.app

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

candidate="${1:-}"
if [[ -z "$candidate" ]]; then
  for guess in \
    "$repo_root/build/ios/iphoneos/Runner.app" \
    "$repo_root/build/ios/Profile-iphoneos/Runner.app" \
    "$repo_root/build/ios/Release-iphoneos/Runner.app" \
    "$repo_root/build/ios/Debug-iphoneos/Runner.app"; do
    if [[ -d "$guess" ]]; then
      candidate="$guess"
      break
    fi
  done
fi

if [[ -z "$candidate" || ! -d "$candidate" ]]; then
  echo "verify_entitlements: could not locate a Runner.app to inspect" >&2
  echo "  pass an explicit path: scripts/validation/verify_entitlements.sh path/to/Runner.app" >&2
  exit 2
fi

echo "verify_entitlements: inspecting $candidate"
entitlements_xml="$(codesign -d --entitlements :- "$candidate" 2>/dev/null || true)"
if [[ -z "$entitlements_xml" ]]; then
  echo "verify_entitlements: codesign returned no entitlements (unsigned bundle?)" >&2
  exit 1
fi

required_keys=(
  "com.apple.developer.healthkit"
  "com.apple.developer.kernel.increased-memory-limit"
  "com.apple.developer.kernel.extended-virtual-addressing"
)

missing=()
for key in "${required_keys[@]}"; do
  # Match the key followed (anywhere on the next bit of XML) by <true/>.
  if ! grep -q -E "<key>${key}</key>[[:space:]]*<true/>" <<<"$entitlements_xml"; then
    missing+=("$key")
  fi
done

if (( ${#missing[@]} > 0 )); then
  echo "verify_entitlements: FAIL — missing entitlements:" >&2
  for key in "${missing[@]}"; do
    echo "  - $key" >&2
  done
  echo >&2
  echo "Fix:" >&2
  echo "  - In Xcode > Runner > Signing & Capabilities, ensure the team is a paid" >&2
  echo "    Apple Developer account (Personal Team cannot provision these)." >&2
  echo "  - Confirm Runner.entitlements (not Runner.DevProfile.entitlements) is" >&2
  echo "    selected for Debug, Profile, and Release configs." >&2
  echo "  - Re-archive: flutter build ios --profile" >&2
  exit 1
fi

echo "verify_entitlements: OK — all 3 required entitlements present"
