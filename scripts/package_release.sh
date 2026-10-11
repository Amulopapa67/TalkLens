#!/usr/bin/env bash
# Build build/TalkLens.app and package it for distribution:
#   dist/TalkLens.dmg      drag-to-Applications disk image
#   dist/TalkLens.zip      zipped app (used by scripts/install.sh)
#   dist/*.sha256          checksums
# Stable file names so https://github.com/<owner>/<repo>/releases/latest/download/TalkLens.zip always works.
#
# Signing for public builds: a "Developer ID Application" identity if one is in the keychain (then notarize
# separately), otherwise ad-hoc ("-"). "Apple Development" certificates are NOT used for releases: Gatekeeper
# rejects them on other Macs anyway, and the certificate name (an e-mail address) would be embedded in the app.
#
# Env: TALKLENS_SIGN_IDENTITY to force an identity; TALKLENS_SKIP_BUILD=1 to package an existing build;
#      TALKLENS_DMG_LAYOUT=0 to skip the Finder layout (AppleScript) step.
# Offline. Bash 3.2 compatible.

set -e
cd "$(dirname "$0")/.."

APP="build/TalkLens.app"
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
OUT_DIR="dist"

if [ -z "${TALKLENS_SIGN_IDENTITY:-}" ]; then
  DEVID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"Developer ID Application:' | head -1 | sed -E 's/^.*"(.*)"$/\1/')"
  export TALKLENS_SIGN_IDENTITY="${DEVID:--}"
fi

if [ "${TALKLENS_SKIP_BUILD:-0}" != "1" ]; then
  scripts/build_app.sh
fi
[ -d "$APP" ] || { echo "error: $APP not found" >&2; exit 1; }
codesign --verify --strict "$APP"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/TalkLens.zip" "$OUT_DIR/TalkLens.dmg" "$OUT_DIR"/*.sha256   # only our own previous artifacts

# Zip (ditto keeps the code signature and extended attributes intact).
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT_DIR/TalkLens.zip"

# DMG: background picture with a "drag to Applications" arrow, the app on the left, an /Applications shortcut
# on the right, and the TalkLens volume icon. The Finder window layout is written by asking Finder through
# AppleScript (packaging only — the app itself never uses AppleScript). Set TALKLENS_DMG_LAYOUT=0 to skip
# the layout step (plain DMG, same contents).
VOLNAME="TalkLens"
STAGE="$(mktemp -d -t talklens-dmg)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"
cp assets/dmg-background.tiff "$STAGE/.background/background.tiff"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"

RW="$(mktemp -u -t talklens-rw).dmg"
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
rm -rf "$STAGE"
MOUNT_DIR="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF; exit}')"
[ -d "$MOUNT_DIR" ] || { echo "error: could not mount $RW" >&2; exit 1; }

# Custom volume icon flag (SetFile ships with the Command Line Tools; skipped if missing).
if command -v SetFile >/dev/null 2>&1 && [ -f "$MOUNT_DIR/.VolumeIcon.icns" ]; then
  SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns" 2>/dev/null || true
  SetFile -a C "$MOUNT_DIR" 2>/dev/null || true
fi

if [ "${TALKLENS_DMG_LAYOUT:-1}" != "0" ]; then
  DISK_NAME="$(basename "$MOUNT_DIR")"
  osascript <<APPLESCRIPT || echo "warning: Finder layout step failed — the DMG keeps its contents but no custom layout" >&2
tell application "Finder"
  tell disk "$DISK_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 562}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "TalkLens.app" of container window to {180, 220}
    set position of item "Applications" of container window to {480, 220}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
  sync
fi
hdiutil detach -quiet "$MOUNT_DIR" || hdiutil detach -quiet -force "$MOUNT_DIR"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT_DIR/TalkLens.dmg"
rm -f "$RW"

( cd "$OUT_DIR" && for f in TalkLens.zip TalkLens.dmg; do shasum -a 256 "$f" > "$f.sha256"; done )

echo "signed with: $TALKLENS_SIGN_IDENTITY"
for f in TalkLens.dmg TalkLens.zip; do
  echo "packaged $OUT_DIR/$f ($(du -h "$OUT_DIR/$f" | cut -f1))  $(cut -d' ' -f1 "$OUT_DIR/$f.sha256")"
done
echo "version $VERSION"
