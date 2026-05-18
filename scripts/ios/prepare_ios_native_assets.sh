#!/bin/sh
set -eu

ROOT_DIR="${PROJECT_DIR:-$(pwd)/ios}/.."

# ---------------------------------------------------------------------------
# Helper: stage a single native asset framework
#   $1 = hook shared build dir (contains the .dylib)
#   $2 = dylib filename to search for
#   $3 = output framework name (without .framework)
#   $4 = CFBundleIdentifier for the framework's Info.plist
# ---------------------------------------------------------------------------
stage_framework() {
  local HOOK_DIR="$1"
  local DYLIB_NAME="$2"
  local FW_NAME="$3"
  local BUNDLE_ID="$4"
  local FW_DIR="$ROOT_DIR/build/native_assets/ios/${FW_NAME}.framework"
  local SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
  local SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-YES}"

  if [ ! -f "${FW_DIR}/${FW_NAME}" ] || [ ! -f "${FW_DIR}/Info.plist" ]; then
    if [ ! -d "$HOOK_DIR" ]; then
      return 0
    fi

    local DYLIB_PATH
    DYLIB_PATH=$(find "$HOOK_DIR" -name "$DYLIB_NAME" -type f -print -quit 2>/dev/null || true)
    if [ -z "$DYLIB_PATH" ]; then
      return 0
    fi

    rm -rf "$FW_DIR"
    mkdir -p "$FW_DIR"
    cp "$DYLIB_PATH" "${FW_DIR}/${FW_NAME}"
    chmod 755 "${FW_DIR}/${FW_NAME}"

    cat > "${FW_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>${FW_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>${FW_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>MinimumOSVersion</key>
  <string>12.0</string>
</dict>
</plist>
PLIST
  fi

  if [ "$SIGNING_ALLOWED" != "NO" ] && [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "${FW_DIR}"
    /usr/bin/codesign --verify --deep --strict "${FW_DIR}"
  fi
}

stage_framework \
  "$ROOT_DIR/.dart_tool/hooks_runner/shared/objective_c/build" \
  "objective_c.dylib" \
  "objective_c" \
  "dev.dart.objective-c"

stage_framework \
  "$ROOT_DIR/.dart_tool/hooks_runner/shared/sqlite3/build" \
  "libsqlite3.dylib" \
  "sqlite3" \
  "dev.dart.sqlite3"