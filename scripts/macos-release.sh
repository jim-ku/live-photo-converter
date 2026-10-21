#!/usr/bin/env bash
# Build, Developer-ID-sign, notarize, staple, and DMG Live Photo Converter.
# Must run on macOS with a real Developer ID identity — will not fake signing.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "macos-release.sh must run on macOS (Darwin). Linux box cannot archive/sign/notarize."

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.1.0}"
SCHEME="${SCHEME:-LivePhotoConverter}"
TEAM_ID="${TEAM_ID:-}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT/build/LivePhotoConverter.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$ROOT/build/export}"
APP_NAME="LivePhotoConverter.app"
ZIP_PATH="$ROOT/build/LivePhotoConverter-${VERSION}.zip"

[[ -n "$TEAM_ID" ]] || die "set TEAM_ID (Apple Team ID)"
[[ -n "$SIGNING_IDENTITY" ]] || die "set SIGNING_IDENTITY (e.g. \"Developer ID Application: Name (TEAMID)\")"
[[ -n "$NOTARY_PROFILE" ]] || die "set NOTARY_PROFILE (xcrun notarytool store-credentials name)"

command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode"
command -v xcrun >/dev/null || die "xcrun not found"
security find-identity -v -p codesigning | grep -F "$SIGNING_IDENTITY" >/dev/null \
  || die "signing identity not in keychain: $SIGNING_IDENTITY
Run: security find-identity -v -p codesigning"

echo "==> Archive Release $VERSION"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
mkdir -p "$ROOT/build"

xcodebuild \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"

EXPORT_PLIST="$ROOT/build/exportOptions-DeveloperID.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
</dict>
</plist>
PLIST

echo "==> Export Developer ID"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST"

APP="$EXPORT_PATH/$APP_NAME"
[[ -d "$APP" ]] || die "export missing $APP"

echo "==> Verify signature"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP" || true

echo "==> Zip for notarytool"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP" "$ZIP_PATH"

echo "==> Notarize (wait)"
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Staple"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> DMG"
"$ROOT/scripts/make-dmg.sh" "$APP" "$VERSION"

echo
echo "OK: dist/LivePhotoConverter-${VERSION}.dmg"
echo "Next: smoke with docs/SMOKE.md, then:"
echo "  gh release create v${VERSION} dist/LivePhotoConverter-${VERSION}.dmg --title v${VERSION} --notes-file docs/release-notes-0.1.0.md"
