#!/usr/bin/env zsh

set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/opt/homebrew/share/flutter/bin:$PATH"

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

cd "$repo_root"

set +e
clean_output="$(flutter clean 2>&1)"
clean_status=$?
set -e

if [[ $clean_status -ne 0 ]]; then
  print -r -- "$clean_output"
  exit $clean_status
fi

# Xcode can recreate XCBuildData/PIFCache while Flutter is deleting build/.
# That leaves build/ non-empty and causes Flutter's non-fatal
# "Directory not empty" warning. Remove only generated build artifacts here.
rm -rf "$repo_root/build/ios/XCBuildData" \
  "$repo_root/build/ios/.DS_Store" \
  "$repo_root/build/.DS_Store" \
  "$HOME/Library/Developer/Xcode/DerivedData"/Runner-* \
  "$repo_root/ios/Flutter/ephemeral"
rmdir "$repo_root/build/ios" "$repo_root/build" 2>/dev/null || true

print -r -- "$clean_output" | sed \
  -e "/^Failed to remove build: FileSystemException: Deletion failed, path = 'build'/d"
