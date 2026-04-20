#!/usr/bin/env bash
#
# Wrap the SPM-built Kiln executable in a proper Kiln.app bundle with
# Sparkle.framework, Info.plist, and an icon. Builds ONE architecture per
# invocation so CI can run it twice (arm64 + x86_64) and Sparkle can serve
# the right one at update time via sparkle:machineArchitectures.
#
# Usage:
#   scripts/make-app-bundle.sh <version> <arch> [<build-number>]
#
#     version       e.g. 0.1.0 (CFBundleShortVersionString)
#     arch          arm64 | x86_64
#     build-number  defaults to `<version>`; use a monotonic int for Sparkle
#
# Output:
#   dist/<arch>/Kiln.app         — the bundle
#   dist/Kiln-<version>-<arch>.zip  — zipped + ready for Sparkle/GH Release
#
# Env vars (all optional):
#   CODESIGN_IDENTITY   "Developer ID Application: …" — signs the bundle
#   SUFEED_URL          overrides the default appcast URL embedded in Info.plist
#   SUPUBLIC_ED_KEY     EdDSA public key for Sparkle update verification
set -euo pipefail

VERSION="${1:?missing version (e.g. 0.1.0)}"
ARCH="${2:?missing arch (arm64|x86_64)}"
BUILD="${3:-$VERSION}"

case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "error: arch must be 'arm64' or 'x86_64'" >&2; exit 1 ;;
esac

BUNDLE_ID="li.raya.kiln"
APP_NAME="Kiln"
DEFAULT_FEED="https://raw.githubusercontent.com/raya-ac/kiln/main/appcast.xml"
FEED_URL="${SUFEED_URL:-$DEFAULT_FEED}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 1. Build release binary for the requested arch.
swift build -c release --arch "$ARCH"

BIN_PATH="$(swift build -c release --arch "$ARCH" --show-bin-path)"
EXECUTABLE="$BIN_PATH/$APP_NAME"

if [ ! -x "$EXECUTABLE" ]; then
  echo "error: $EXECUTABLE not found" >&2
  exit 1
fi

# 2. Per-arch workspace. `dist/` itself is shared so both arches' zips can
# coexist for appcast generation.
DIST="$ROOT/dist"
WORK="$DIST/$ARCH"
APP="$WORK/$APP_NAME.app"
mkdir -p "$DIST"
rm -rf "$WORK"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$EXECUTABLE" "$APP/Contents/MacOS/$APP_NAME"

# SPM builds only stamp `@loader_path` into LC_RPATH. Once the binary lives
# in Contents/MacOS/, that resolves to MacOS/ — but Sparkle.framework lives
# one level up in Contents/Frameworks/, so dyld can't find it and the app
# dies at launch with "Library not loaded: @rpath/Sparkle.framework/…".
# Add the Frameworks search path explicitly. `|| true` keeps reruns idempotent.
install_name_tool -add_rpath '@executable_path/../Frameworks' \
  "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# 3. Bundle Sparkle.framework. Pull the matching arch slice out of the
# xcframework if available; otherwise fall back to whatever's there.
SPARKLE_FW=""
# SPM drops the xcframework under .build/artifacts, with per-arch folders.
case "$ARCH" in
  arm64)
    SPARKLE_FW="$(find .build -type d -name 'Sparkle.framework' -path '*macos-arm64*' 2>/dev/null | head -1)"
    ;;
  x86_64)
    SPARKLE_FW="$(find .build -type d -name 'Sparkle.framework' -path '*macos-x86_64*' 2>/dev/null | head -1)"
    ;;
esac
# Sparkle's xcframework usually ships a single universal slice
# (macos-arm64_x86_64). Use it when the arch-specific one isn't present.
if [ -z "$SPARKLE_FW" ]; then
  SPARKLE_FW="$(find .build -type d -name 'Sparkle.framework' 2>/dev/null | head -1)"
fi
if [ -n "$SPARKLE_FW" ]; then
  cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
  chmod -R u+rwX,go+rX "$APP/Contents/Frameworks/Sparkle.framework"
else
  echo "warning: Sparkle.framework not found under .build — auto-updates will not work" >&2
fi

# 4. Resources.
if [ -d "$ROOT/Sources/Resources" ]; then
  cp -R "$ROOT/Sources/Resources/"* "$APP/Contents/Resources/" 2>/dev/null || true
fi
if [ -f "$ROOT/Sources/App/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Sources/App/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# 5. Info.plist. LSMinimumSystemVersion stays 14.0 — both arches support
# the same floor; Sparkle uses sparkle:machineArchitectures to pick.
PUB_KEY_LINE=""
if [ -n "${SUPUBLIC_ED_KEY:-}" ]; then
  PUB_KEY_LINE="<key>SUPublicEDKey</key><string>$SUPUBLIC_ED_KEY</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>$BUNDLE_ID.scheme</string>
      <key>CFBundleURLSchemes</key><array><string>kiln</string></array>
    </dict>
  </array>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  $PUB_KEY_LINE
</dict>
</plist>
PLIST

# 6. Optional codesign.
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    find "$APP/Contents/Frameworks/Sparkle.framework" -name '*.app' -o -name '*.xpc' \
      | while read -r helper; do
        codesign --force --options runtime --timestamp \
          --sign "$CODESIGN_IDENTITY" "$helper"
      done
    codesign --force --options runtime --timestamp \
      --sign "$CODESIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
  fi
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$ROOT/scripts/Kiln.entitlements" \
    --sign "$CODESIGN_IDENTITY" "$APP"
  echo "signed with: $CODESIGN_IDENTITY"
else
  echo "skipping codesign (CODESIGN_IDENTITY not set)"
fi

# 7. Zip the bundle. Filename carries the arch so Sparkle's generate_appcast
# can differentiate items on the feed.
ZIP="$DIST/$APP_NAME-$VERSION-$ARCH.zip"
rm -f "$ZIP"
( cd "$WORK" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "$APP_NAME.app" "$ZIP" )

echo "built: $APP"
echo "zip:   $ZIP"
