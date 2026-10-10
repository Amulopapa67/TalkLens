#!/usr/bin/env bash
# Print the development-environment facts TalkLens depends on. Read-only; changes nothing.
# Never prints chat titles or message text. Bash 3.2 compatible.
cd "$(dirname "$0")/.." || exit 1

echo "== macOS"
sw_vers 2>/dev/null || echo "sw_vers unavailable"
echo "arch: $(uname -m)"

echo "== Developer tools"
DEV="$(xcode-select -p 2>/dev/null)"
echo "xcode-select: ${DEV:-none}"
xcodebuild -version 2>/dev/null | head -2 || echo "xcodebuild: unavailable (Command Line Tools only?)"
swift --version 2>&1 | head -2
if [ -n "$DEV" ]; then
  for fw in XCTest Testing; do
    p=$(find "$DEV" -maxdepth 7 -type d -name "$fw.framework" 2>/dev/null | head -1)
    echo "$fw.framework: ${p:-not found under $DEV}"
  done
fi

echo "== KakaoTalk"
KAPP=$(mdfind "kMDItemCFBundleIdentifier == 'com.kakao.KakaoTalkMac'" 2>/dev/null | head -1)
[ -z "$KAPP" ] && [ -d /Applications/KakaoTalk.app ] && KAPP=/Applications/KakaoTalk.app
if [ -n "$KAPP" ]; then
  echo "app: $KAPP (version $(defaults read "$KAPP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?'))"
else
  echo "app: not found"
fi
PID=$(pgrep -x KakaoTalk 2>/dev/null | head -1)
[ -z "$PID" ] && PID=$(pgrep -f 'KakaoTalk.app/Contents/MacOS' 2>/dev/null | head -1)
if [ -n "$PID" ]; then echo "running: yes (pid $PID)"; else echo "running: no"; fi

echo "== Accessibility permission (inherited from this terminal app)"
swift tools/ax_trust_check.swift 2>&1 | tail -1

echo "== Apple Translation"
swift tools/translation_check.swift ko zh-Hans 2>&1 | tail -6

echo "== Dev config"
if [ -f .lens-dev.json ]; then
  echo ".lens-dev.json present (allowlisted titles not printed)"
else
  echo ".lens-dev.json missing — copy .lens-dev.example.json and add the self-chat (나와의 채팅) window title"
fi
