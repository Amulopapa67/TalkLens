#!/usr/bin/env bash
# TalkLens read-only / offline guard.
#
# Fails when forbidden APIs appear in Sources/ (pure comment lines are ignored).
# Usage:
#   scripts/guard_readonly.sh            # report; exit 0 (clean) or 1 (violations)
#   scripts/guard_readonly.sh --hook     # Claude Code PostToolUse mode: silent on success,
#                                        # exit 2 with the report on stderr when violations exist
#   scripts/guard_readonly.sh --privacy  # heuristic list of logging calls that may print message text
#                                        # (never fails; last line "PRIVACY-HEURISTIC: n hit(s)")
#
# Do not weaken this file to make a build pass (see README "What it never does"). Bash 3.2 compatible (macOS /bin/bash).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Sources"
MODE="${1:-}"

if [ ! -d "$SRC" ]; then
  if [ "$MODE" != "--hook" ]; then echo "guard_readonly: Sources/ not found yet (OK before M1)"; fi
  if [ "$MODE" = "--privacy" ]; then echo "PRIVACY-HEURISTIC: 0 hit(s)"; fi
  exit 0
fi

# Drop pure comment lines ("//", "///", "/*", " *") that follow the "file:line:" prefix.
strip_comments() {
  grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|/\*|\*)'
}

if [ "$MODE" = "--privacy" ]; then
  # Logging / printing calls that mention message-text-like identifiers. Heuristic only.
  # tlctl is excluded: it prints synthetic selftest output and redacted probe output by design.
  hits=$(grep -rnE --include='*.swift' \
    '(print|NSLog|os_log|debugPrint|dump|logger\.[a-z]+|log\.[a-z]+)\(.*(body|text|original|translation|translated|message\.)' \
    "$SRC" 2>/dev/null | grep -v '/Sources/tlctl/' | strip_comments | grep -viE 'redact')
  n=0
  if [ -n "$hits" ]; then n=$(printf '%s\n' "$hits" | wc -l | tr -d ' '); printf '%s\n' "$hits"; fi
  echo "PRIVACY-HEURISTIC: $n hit(s)"
  exit 0
fi

report=""
count=0

# Format: name @@ forbidden-regex @@ exclude-regex (exclude may be empty)
while IFS= read -r rule; do
  [ -z "$rule" ] && continue
  name="${rule%% @@ *}"
  rest="${rule#* @@ }"
  regex="${rest%% @@ *}"
  exclude="${rest#* @@ }"
  [ "$exclude" = "$rest" ] && exclude=""
  matches=$(grep -rnE --include='*.swift' "$regex" "$SRC" 2>/dev/null | strip_comments)
  if [ -n "$exclude" ] && [ -n "$matches" ]; then
    matches=$(printf '%s\n' "$matches" | grep -vE "$exclude")
  fi
  if [ -n "$matches" ]; then
    n=$(printf '%s\n' "$matches" | wc -l | tr -d ' ')
    count=$((count + n))
    report="$report
[$name] $n hit(s)
$matches"
  fi
done <<'RULES'
AX actions (press/click/etc.) @@ AXUIElementPerformAction|kAX(Press|Raise|Pick|Confirm|Cancel|Increment|Decrement|ShowMenu|ShowAlternateUI|ShowDefaultUI)Action
AX attribute writes @@ AXUIElementSetAttributeValue
Synthetic keyboard/mouse events @@ CGEvent(Post|PostToPid|PostToPSN|CreateKeyboardEvent|CreateMouseEvent|CreateScrollWheelEvent)|\.post\(tap:|\.postToPid\(
Pasteboard writes (only user-initiated "copy translation" in TalkLensApp is allowed) @@ NSPasteboard|\.(setString|writeObjects|clearContents)\( @@ /Sources/TalkLensApp/
AppleScript / osascript @@ NSAppleScript|OSAScript|osascript
Activating other apps @@ \.activate\( @@ NSApp\.activate|NSApplication\.shared\.activate
Launching apps @@ openApplication\(|launchApplication|NSWorkspace\.shared\.launch
Terminating apps @@ \.terminate\(|forceTerminate|(^|[^A-Za-z_])kill\( @@ NSApp\.terminate|NSApplication\.shared\.terminate
Injection / private frameworks @@ dlopen\(|DYLD_INSERT|task_for_pid|mach_inject|PrivateFrameworks
KakaoTalk data directories @@ Containers/com\.kakao|Application Support/com\.kakao|Group Containers/[^"]*kakao
Network APIs (MVP is offline) @@ URLSession|URLRequest|NWConnection|NWPathMonitor|NWListener|import Network|WKWebView|CFSocket|CFStream
Screen capture @@ CGWindowListCreateImage|CGDisplayCreateImage|SCScreenshotManager|SCStream|ScreenCaptureKit|screencapture
RULES

if [ "$count" -eq 0 ]; then
  if [ "$MODE" != "--hook" ]; then echo "guard_readonly: clean (0 forbidden API uses in Sources/)"; fi
  exit 0
fi

msg="guard_readonly: $count forbidden API use(s) in Sources/ — TalkLens must stay read-only and offline (see README "What it never does").$report"
if [ "$MODE" = "--hook" ]; then
  printf '%s\n' "$msg" >&2
  exit 2
fi
printf '%s\n' "$msg"
exit 1
