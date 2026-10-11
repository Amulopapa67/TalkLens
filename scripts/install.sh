#!/usr/bin/env bash
# One-line installer for TalkLens (macOS 15+):
#
#   curl -fsSL https://raw.githubusercontent.com/Amulopapa67/TalkLens/main/scripts/install.sh | bash
#
# What it does — nothing else:
#   1. downloads TalkLens.zip and TalkLens.zip.sha256 from the latest GitHub release,
#   2. verifies the SHA-256 checksum,
#   3. installs TalkLens.app into /Applications (or ~/Applications if /Applications is not writable),
#   4. removes the download quarantine flag (the app is not notarized; see README "Gatekeeper"),
#   5. opens TalkLens. Grant Accessibility permission when asked.
#
# Env: TALKLENS_REPO (default Amulopapa67/TalkLens), TALKLENS_VERSION (a tag like v0.1.0; default latest).
# The installer itself is the only part of TalkLens that touches the network; the app never does.

set -euo pipefail

REPO="${TALKLENS_REPO:-Amulopapa67/TalkLens}"
if [ -n "${TALKLENS_VERSION:-}" ]; then
  BASE="https://github.com/$REPO/releases/download/$TALKLENS_VERSION"
else
  BASE="https://github.com/$REPO/releases/latest/download"
fi

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "TalkLens runs on macOS only."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 15 ] || die "TalkLens needs macOS 15 or later (this Mac: $(sw_vers -productVersion))."

TMP="$(mktemp -d -t talklens-install)"
trap 'rm -rf "$TMP"' EXIT

say "Downloading TalkLens from github.com/$REPO …"
curl -fL --progress-bar -o "$TMP/TalkLens.zip" "$BASE/TalkLens.zip"
curl -fsSL -o "$TMP/TalkLens.zip.sha256" "$BASE/TalkLens.zip.sha256"

say "Verifying checksum …"
( cd "$TMP" && shasum -a 256 -c TalkLens.zip.sha256 >/dev/null ) || die "checksum mismatch — download corrupted or tampered with."

ditto -x -k "$TMP/TalkLens.zip" "$TMP/unzipped"
[ -d "$TMP/unzipped/TalkLens.app" ] || die "TalkLens.app not found in the archive."

DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

if pgrep -x TalkLens >/dev/null 2>&1; then
  say "Quitting the running TalkLens …"
  pkill -x TalkLens 2>/dev/null || true   # only TalkLens itself
  sleep 1
fi

say "Installing to $DEST/TalkLens.app …"
rm -rf "$DEST/TalkLens.app"
ditto "$TMP/unzipped/TalkLens.app" "$DEST/TalkLens.app"
xattr -dr com.apple.quarantine "$DEST/TalkLens.app" 2>/dev/null || true

say "Opening TalkLens. Follow the onboarding window:"
echo "    • System Settings → Privacy & Security → Accessibility → enable TalkLens"
echo "    • download the translation languages if asked"
echo "    (After an update you may have to toggle the Accessibility switch off and on again.)"
open "$DEST/TalkLens.app"
