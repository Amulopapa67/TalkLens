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
# Env: TALKLENS_SIGN_IDENTITY to force an identity; TALKLENS_SKIP_BUILD=1 to package an existing build.
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

# DMG with an /Applications shortcut for drag-and-drop installs.
STAGE="$(mktemp -d -t talklens-dmg)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "TalkLens $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT_DIR/TalkLens.dmg"
rm -rf "$STAGE"

( cd "$OUT_DIR" && for f in TalkLens.zip TalkLens.dmg; do shasum -a 256 "$f" > "$f.sha256"; done )

echo "signed with: $TALKLENS_SIGN_IDENTITY"
for f in TalkLens.dmg TalkLens.zip; do
  echo "packaged $OUT_DIR/$f ($(du -h "$OUT_DIR/$f" | cut -f1))  $(cut -d' ' -f1 "$OUT_DIR/$f.sha256")"
done
echo "version $VERSION"
