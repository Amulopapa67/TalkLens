---
name: talklens-installer
description: Install, update, check or uninstall TalkLens — the free, open-source, read-only translation overlay for KakaoTalk on macOS (on-device Apple Translation). Use when the user wants KakaoTalk messages translated on their Mac, asks to set up / fix / remove TalkLens, or says things like "安装 TalkLens", "KakaoTalk 翻译", "카카오톡 번역", "translate KakaoTalk on Mac".
---

# TalkLens installer

TalkLens (https://github.com/Amulopapa67/TalkLens, MIT) paints translations over KakaoTalk for Mac message bubbles. It is read-only, makes no network requests, and translates on device with Apple Translation. It is an unofficial tool, not affiliated with Kakao Corp.

You are helping the user install it on **their own Mac**. Talk to the user in the language they use (中文 / 한국어 / English …). Keep each step short and tell them what you are doing.

## Ground rules (always)

- **Ask before changing anything.** Before installing, updating or uninstalling, show the user the plan (what will be downloaded from where, where it goes, what will be removed) and wait for a clear yes.
- **No sudo, no password prompts.** Install into `/Applications` if it is writable, otherwise `~/Applications`.
- **Only download from the official GitHub releases** of `Amulopapa67/TalkLens`, and verify the SHA-256 checksum before installing. Stop if the checksum does not match.
- **Never toggle system permissions yourself** and never try to bypass the Accessibility prompt. Open the right settings page and ask the user to switch TalkLens on.
- **Never read, scrape, automate or send anything in KakaoTalk**, and never open KakaoTalk's data folders. TalkLens itself does the (read-only) reading after the user grants permission.
- If a command fails, show the user the error in plain words and suggest the next step; do not retry destructive actions.

## 1. Check the Mac

Run and summarize:

```bash
sw_vers -productVersion
uname -m
ls -d /Applications/KakaoTalk.app 2>/dev/null || echo "KakaoTalk not found"
ls -d /Applications/TalkLens.app ~/Applications/TalkLens.app 2>/dev/null || echo "TalkLens not installed"
```

- macOS must be **15 or later**. If it is older, explain that TalkLens needs macOS 15+ and stop.
- If KakaoTalk is missing, tell the user TalkLens works with KakaoTalk for Mac (they can install it from the Mac App Store or kakaocorp.com) — they can still install TalkLens now.
- If TalkLens is already installed, offer **update** (section 5) instead.

## 2. Download and verify (after the user agrees)

```bash
TMP="$(mktemp -d -t talklens)"
curl -fL -o "$TMP/TalkLens.zip" https://github.com/Amulopapa67/TalkLens/releases/latest/download/TalkLens.zip
curl -fsSL -o "$TMP/TalkLens.zip.sha256" https://github.com/Amulopapa67/TalkLens/releases/latest/download/TalkLens.zip.sha256
cd "$TMP" && shasum -a 256 -c TalkLens.zip.sha256
```

Continue only if the last line says `TalkLens.zip: OK`.

## 3. Install

```bash
DEST=/Applications; [ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
pkill -x TalkLens 2>/dev/null || true          # only if an older TalkLens is running
ditto -x -k "$TMP/TalkLens.zip" "$TMP/unzipped"
rm -rf "$DEST/TalkLens.app"
ditto "$TMP/unzipped/TalkLens.app" "$DEST/TalkLens.app"
xattr -dr com.apple.quarantine "$DEST/TalkLens.app"   # release builds are open source but not notarized
rm -rf "$TMP"
open "$DEST/TalkLens.app"
echo "installed to $DEST/TalkLens.app"
```

Explain the `xattr` line to the user: the app is ad-hoc signed (no paid Apple Developer ID), so macOS would otherwise block the first launch; removing the download quarantine flag is the same as choosing "Open" in Finder.

The equivalent one-liner (useful if the user prefers to run it themselves) is:
`curl -fsSL https://raw.githubusercontent.com/Amulopapa67/TalkLens/main/scripts/install.sh | bash`

## 4. Guide the first run

1. **Accessibility permission** — open the page, then ask the user to switch on **TalkLens** (they may need Touch ID / password; that is their action, not yours):
   ```bash
   open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
   ```
   TalkLens picks the permission up automatically; no restart needed.
2. **Translation languages** — TalkLens' onboarding window offers to download them. If the user prefers: System Settings → General → Language & Region → Translation Languages → download **Korean** and the target language (e.g. Chinese Simplified).
3. **Try it** — open any KakaoTalk chat window. Translations appear over the bubbles. Tips to pass on:
   - Hover a bubble to see the original + glossary notes; hold **⌥ Option** to show all originals.
   - The menu bar icon (speech bubble with a lens) has pause, display mode (immersive / sidebar), source & target language and app language.
   - Default source language is Korean; "auto-detect" is available.

Ask the user whether translations appear. If not, go to section 7.

## 5. Update

Same as sections 2–3 (the latest release replaces the app). Afterwards tell the user: because builds are ad-hoc signed, macOS may treat the new version as a new app — if translations stop, switch TalkLens **off and on again** in Accessibility settings.

## 6. Uninstall (after the user agrees)

```bash
pkill -x TalkLens 2>/dev/null || true
rm -rf /Applications/TalkLens.app ~/Applications/TalkLens.app
defaults delete dev.lipper.TalkLens 2>/dev/null || true          # preferences (no message content)
rm -rf "$HOME/Library/Application Support/TalkLens"              # only the user's own glossary file
```

Then ask the user to remove TalkLens from System Settings → Privacy & Security → Accessibility (select it, click "−"). TalkLens never stores chat messages, so there is nothing else to clean up.

## 7. Troubleshooting

| Symptom | What to do |
|---|---|
| "TalkLens can't be opened / developer cannot be verified" | Run the `xattr -dr com.apple.quarantine …` line from section 3, or right-click the app → Open. |
| Nothing is translated | Check the Accessibility switch is on (toggle off → on after updates); make sure a KakaoTalk **chat window** (not only the main window) is open and not minimized. |
| Banner "translation languages not installed" | Download the language pair (section 4.2) or click "Download…" in TalkLens. |
| Older messages not translated | TalkLens only sees messages KakaoTalk has loaded — scroll up in KakaoTalk once. |
| Translation in the wrong language | Menu bar icon → source / target language (source "auto-detect" helps for mixed chats). |
| KakaoTalk feels slow | Quit TalkLens, restart KakaoTalk, then reopen TalkLens; report it at https://github.com/Amulopapa67/TalkLens/issues. |

For anything else, point the user to the README: https://github.com/Amulopapa67/TalkLens#readme
