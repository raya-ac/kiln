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
# SPM generates a per-target resource bundle (Kiln_Kiln.bundle) at build
# time that holds everything declared under `resources:` in Package.swift
# — the Monaco editor tree, editor/index.html, ClaudeMark.png, etc.
# Bundle.module at runtime locates it next to the executable, so drop it
# alongside the binary. Without this copy the .app ships with no editor
# runtime, and Bundle.module falls back to whatever stale bundle lives
# under .build/ (or nothing at all on a fresh machine).
SPM_RES_BUNDLE="$BIN_PATH/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$SPM_RES_BUNDLE" ]; then
  # Resource bundle goes into Contents/Resources/ — anywhere else either
  # fails codesign ("unsealed contents present in the bundle root" at
  # .app root, or "bundle format unrecognized" in Contents/MacOS). The
  # generated Bundle.module accessor looks at
  # `Bundle.main.bundleURL/Kiln_Kiln.bundle` which isn't right for a
  # .app, so CodeEditorView has a fallback that checks
  # Bundle.main.resourceURL — that resolves to Contents/Resources and
  # finds this copy.
  DEST_BUNDLE="$APP/Contents/Resources/${APP_NAME}_${APP_NAME}.bundle"
  # SPM emits a flat resource directory — no Info.plist, no Contents/
  # wrapper — which codesign refuses to treat as a bundle (the outer
  # --deep pass choked with "bundle format unrecognized"). Copy the
  # resources into a properly-formed deep bundle instead: Contents/
  # Info.plist plus Contents/Resources/<files>. Bundle.module / Bundle
  # (url:) both handle deep-style bundles transparently.
  mkdir -p "$DEST_BUNDLE/Contents/Resources"
  # Use `.` + `cp -R` so dotfiles come along; we want the children of
  # SPM_RES_BUNDLE (editor/, monaco/, ClaudeMark.png) mirrored directly
  # under Contents/Resources/.
  (cd "$SPM_RES_BUNDLE" && tar cf - .) | (cd "$DEST_BUNDLE/Contents/Resources" && tar xf -)
  cat > "$DEST_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.resources</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${APP_NAME}_${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
</dict>
</plist>
EOF
fi
# Bundle CHANGELOG so the "What's New" popup has something to read.
if [ -f "$ROOT/CHANGELOG.md" ]; then
  cp "$ROOT/CHANGELOG.md" "$APP/Contents/Resources/CHANGELOG.md"
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

# 6. Codesign. A Developer ID identity is preferred (enables notarization +
# Gatekeeper approval for downloaded builds), but we ALWAYS fall back to an
# ad-hoc seal (`-s -`). Without any codesign pass the linker-signed Mach-O
# is left with a malformed resource seal — macOS then refuses to launch it
# with "code has no resources but signature indicates they must be present".
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  IDENTITY="$CODESIGN_IDENTITY"
  EXTRA_OPTS=(--options runtime --timestamp)
  ENTITLEMENTS_OPT=(--entitlements "$ROOT/scripts/Kiln.entitlements")
  echo "signing with: $IDENTITY"
else
  IDENTITY="-"
  EXTRA_OPTS=()
  ENTITLEMENTS_OPT=()
  echo "signing ad-hoc (no CODESIGN_IDENTITY set)"
fi

# `set -u` + empty arrays is a bash landmine: `"${EXTRA_OPTS[@]}"` on an
# empty array triggers "unbound variable". The `+"…"` guard expands to
# nothing when the array is unset/empty, and to the quoted elements otherwise.
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  find "$APP/Contents/Frameworks/Sparkle.framework" \( -name '*.app' -o -name '*.xpc' \) \
    | while read -r helper; do
      codesign --force ${EXTRA_OPTS[@]+"${EXTRA_OPTS[@]}"} --sign "$IDENTITY" "$helper"
    done
  codesign --force ${EXTRA_OPTS[@]+"${EXTRA_OPTS[@]}"} --sign "$IDENTITY" \
    "$APP/Contents/Frameworks/Sparkle.framework"
fi
codesign --force --deep \
  ${EXTRA_OPTS[@]+"${EXTRA_OPTS[@]}"} \
  ${ENTITLEMENTS_OPT[@]+"${ENTITLEMENTS_OPT[@]}"} \
  --sign "$IDENTITY" "$APP"

# Sanity check: the bundle should be fully sealed now.
if ! codesign --verify --verbose=2 "$APP" 2>&1 | tail -5; then
  echo "error: codesign verification failed for $APP" >&2
  exit 1
fi

# 7. Zip the bundle. Filename carries the arch so Sparkle's generate_appcast
# can differentiate items on the feed.
ZIP="$DIST/$APP_NAME-$VERSION-$ARCH.zip"
rm -f "$ZIP"
( cd "$WORK" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "$APP_NAME.app" "$ZIP" )

echo "built: $APP"
echo "zip:   $ZIP"
