#!/usr/bin/env bash
# Build build/TalkLens.app (scripts/build_app.sh) and package it as dist/TalkLens-<version>.zip
# with a matching .sha256 file. Offline; no notarization (optional, see README).
# Env: TALKLENS_SKIP_BUILD=1 to package an existing build/TalkLens.app.
# Bash 3.2 compatible.

set -e
cd "$(dirname "$0")/.."

APP="build/TalkLens.app"
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
OUT_DIR="dist"
ZIP="$OUT_DIR/TalkLens-$VERSION.zip"

if [ "${TALKLENS_SKIP_BUILD:-0}" != "1" ]; then
  scripts/build_app.sh
fi
[ -d "$APP" ] || { echo "error: $APP not found" >&2; exit 1; }
codesign --verify --strict "$APP"

mkdir -p "$OUT_DIR"
rm -f "$ZIP" "$ZIP.sha256"                 # only our own previous artifacts
# ditto keeps extended attributes / code signature intact.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
( cd "$OUT_DIR" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )

echo "packaged $ZIP ($(du -h "$ZIP" | cut -f1))"
cat "$ZIP.sha256"
