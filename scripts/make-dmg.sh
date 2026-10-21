#!/usr/bin/env bash
# Build a simple read-only DMG from a signed .app
# Usage: make-dmg.sh "/path/to/Video to Live Photo.app" [VERSION]
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "make-dmg.sh must run on macOS"

APP="${1:-}"
VERSION="${2:-${VERSION:-0.1.0}}"
[[ -n "$APP" && -d "$APP" ]] || die "usage: $0 "/path/to/Video to Live Photo.app" [VERSION]"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$ROOT/build/dmg-stage"
DIST="$ROOT/dist"
VOL="Video to Live Photo"
DMG_RW="$ROOT/build/LivePhotoConverter-${VERSION}-rw.dmg"
DMG_OUT="$DIST/LivePhotoConverter-${VERSION}.dmg"

command -v hdiutil >/dev/null || die "hdiutil not found"

rm -rf "$STAGE"
mkdir -p "$STAGE" "$DIST"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG_RW" "$DMG_OUT"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW "$DMG_RW"
hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUT"
rm -f "$DMG_RW"
rm -rf "$STAGE"

echo "wrote $DMG_OUT"
ls -lh "$DMG_OUT"
