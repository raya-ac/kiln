#!/usr/bin/env bash
#
# One-time fetch of Monaco editor's `min/vs` runtime into
# Sources/App/Resources/monaco/vs/. The bundle is ~5 MB and is kept out of
# git — checked in only as .gitkeep so SPM's `resources:` path exists.
#
# Usage: scripts/fetch-monaco.sh [<version>]
#
#   version   monaco-editor npm tag (default: 0.52.2)
#
# Run once per clone (or `make monaco`). Offline after that — the editor
# host page loads everything via loadFileURL:.
set -euo pipefail

VERSION="${1:-0.52.2}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEST="Sources/App/Resources/monaco"
mkdir -p "$DEST"

if [ -d "$DEST/vs" ] && [ -f "$DEST/vs/loader.js" ]; then
  echo "monaco already present at $DEST/vs — delete to re-fetch"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TARBALL_URL="https://registry.npmjs.org/monaco-editor/-/monaco-editor-$VERSION.tgz"
echo "fetching $TARBALL_URL …"
curl -fsSL "$TARBALL_URL" -o "$TMP/monaco.tgz"

echo "extracting min/vs …"
tar -xzf "$TMP/monaco.tgz" -C "$TMP" package/min/vs
rm -rf "$DEST/vs"
mv "$TMP/package/min/vs" "$DEST/vs"

# Record the version so we can diff later without re-fetching.
echo "$VERSION" > "$DEST/VERSION"

SIZE="$(du -sh "$DEST/vs" | awk '{print $1}')"
echo "monaco $VERSION extracted to $DEST/vs ($SIZE)"
