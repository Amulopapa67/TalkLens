#!/usr/bin/env bash
# Assemble build/TalkLens.app from the SwiftPM release binary and code-sign it.
#
# Signing identity, in order of preference:
#   1. $TALKLENS_SIGN_IDENTITY
#   2. the first "Developer ID Application" or "Apple Development" identity in the keychain
#   3. ad-hoc ("-")
# macOS ties the Accessibility (TCC) grant to the code signature. A stable identity (1 or 2) keeps the
# grant across rebuilds; with ad-hoc signing you may have to re-grant after every rebuild.
#
# Env overrides: TALKLENS_BUNDLE_ID (default dev.lipper.TalkLens), TALKLENS_SIGN_IDENTITY.
# Bash 3.2 compatible.

set -e
cd "$(dirname "$0")/.."

APP_NAME="TalkLens"
PRODUCT="TalkLensApp"                       # SwiftPM executable product name
BUNDLE_ID="${TALKLENS_BUNDLE_ID:-dev.lipper.TalkLens}"
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
MIN_MACOS="15.0"
OUT="build/$APP_NAME.app"

swift build -c release --product "$PRODUCT"
BIN="$(swift build -c release --show-bin-path)/$PRODUCT"
[ -x "$BIN" ] || { echo "error: $BIN not found" >&2; exit 1; }

rm -rf "$OUT"                               # only our own build output
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$APP_NAME"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>MIT License. Not affiliated with Kakao Corp.</string>
</dict>
</plist>
PLIST
plutil -lint "$OUT/Contents/Info.plist" >/dev/null

IDENTITY="${TALKLENS_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"(Developer ID Application|Apple Development):' | head -1 | sed -E 's/^.*"(.*)"$/\1/')"
fi
[ -z "$IDENTITY" ] && IDENTITY="-"

# Hardened runtime; no sandbox (Accessibility clients cannot be sandboxed); no entitlements needed for MVP.
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$OUT"
codesign --verify --strict "$OUT"

if [ "$IDENTITY" = "-" ]; then
  echo "note: ad-hoc signed — Accessibility permission may need re-granting after each rebuild."
fi
echo "built $OUT ($BUNDLE_ID $VERSION/$BUILD_NUMBER, identity: $IDENTITY)"
