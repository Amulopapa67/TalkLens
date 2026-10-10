#!/usr/bin/env bash
# TalkLens acceptance gate (GOAL.md §6). One line per gate, then a summary, then exactly one of:
#   VERIFY: PASS
#   VERIFY: FAIL (G2,G7,...)
# WARN / SKIP do not fail the run but must be explained in docs/STATUS.md.
#
# Do not weaken this script to make it pass (CLAUDE.md). MIN_TESTS may only be raised.
# Any change to this file must be recorded in docs/decisions.md.
# Bash 3.2 compatible (macOS /bin/bash). Full logs: .build/verify-logs/

cd "$(dirname "$0")/.." || exit 1
MIN_TESTS=40
APP_NAME="TalkLens"
APP_PATH="build/$APP_NAME.app"
CLI=".build/release/tlctl"
LOGS=".build/verify-logs"
mkdir -p "$LOGS"

SUMMARY=""
FAILED=""
WARNED=""
BUILD_OK=0

gate() { # id status detail
  printf '[%s] %-4s %s\n' "$1" "$2" "$3"
  SUMMARY="$SUMMARY
$1 $2  $3"
  case "$2" in
    FAIL) FAILED="${FAILED:+$FAILED,}$1" ;;
    WARN|SKIP) WARNED="${WARNED:+$WARNED,}$1" ;;
  esac
}

# Run a command with a timeout in seconds (macOS has no coreutils `timeout`). Exit 142 = timed out.
with_timeout() {
  secs="$1"; shift
  perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!\n"' "$secs" "$@"
}

last_line() { grep -v '^[[:space:]]*$' "$1" | tail -1 | cut -c1-220; }

echo "== TalkLens verify @ $(date '+%Y-%m-%d %H:%M:%S')"

# G1 — environment (informational)
OSV=$(sw_vers -productVersion 2>/dev/null || echo "?")
SWV=$(swift --version 2>&1 | head -1 | cut -c1-120)
gate G1 INFO "macOS $OSV · $(uname -m) · $SWV"

# G2 — release build
if [ ! -f Package.swift ]; then
  gate G2 FAIL "Package.swift missing (M1 not started)"
else
  swift build -c release >"$LOGS/build.log" 2>&1; rc=$?
  if [ $rc -eq 0 ] && [ -x "$CLI" ]; then
    BUILD_OK=1; gate G2 PASS "swift build -c release"
  elif [ $rc -eq 0 ]; then
    gate G2 FAIL "build succeeded but $CLI not found (product must be named tlctl)"
  else
    gate G2 FAIL "swift build -c release exit $rc — $(tail -3 "$LOGS/build.log" | tr '\n' ' ' | cut -c1-200)"
  fi
fi

# G3 — tests (XCTest and/or Swift Testing), count >= MIN_TESTS
if [ ! -f Package.swift ]; then
  gate G3 FAIL "no Package.swift"
else
  swift test >"$LOGS/test.log" 2>&1; rc=$?
  xc=$(grep -Eo 'Executed [0-9]+ tests?' "$LOGS/test.log" | grep -Eo '[0-9]+' | sort -n | tail -1)
  st=$(grep -Eo 'Test run with [0-9]+ tests?' "$LOGS/test.log" | grep -Eo '[0-9]+' | sort -n | tail -1)
  total=$(( ${xc:-0} + ${st:-0} ))
  if [ $rc -eq 0 ] && [ "$total" -ge "$MIN_TESTS" ]; then
    gate G3 PASS "swift test: $total tests (XCTest ${xc:-0} + Swift Testing ${st:-0}; min $MIN_TESTS)"
  elif [ $rc -ne 0 ]; then
    gate G3 FAIL "swift test exit $rc ($total tests counted) — see $LOGS/test.log"
  else
    gate G3 FAIL "only $total tests (< MIN_TESTS=$MIN_TESTS)"
  fi
fi

# G4 — read-only / offline guard
scripts/guard_readonly.sh >"$LOGS/guard.log" 2>&1; rc=$?
if [ $rc -eq 0 ]; then gate G4 PASS "$(last_line "$LOGS/guard.log")"
else gate G4 FAIL "$(head -1 "$LOGS/guard.log" | cut -c1-200)"; fi

# G5 — privacy heuristic (warn only; reviewer must confirm hits do not log message text)
scripts/guard_readonly.sh --privacy >"$LOGS/privacy.log" 2>&1
ph=$(grep -Eo 'PRIVACY-HEURISTIC: [0-9]+' "$LOGS/privacy.log" | grep -Eo '[0-9]+' | tail -1)
if [ "${ph:-0}" -eq 0 ]; then gate G5 PASS "no logging call mentions message text"
else gate G5 WARN "$ph heuristic hit(s) — confirm none logs message text (see $LOGS/privacy.log)"; fi

# G6 — license & attribution
probs=""
grep -q "MIT License" LICENSE 2>/dev/null || probs="$probs LICENSE-not-MIT;"
grep -q "Park Hee Chan" THIRD_PARTY_NOTICES.md 2>/dev/null && grep -q "Permission is hereby granted" THIRD_PARTY_NOTICES.md 2>/dev/null \
  || probs="$probs THIRD_PARTY_NOTICES-missing-kmsg-MIT;"
if [ -d Sources/KakaoAX ]; then
  nbad=0
  for f in $(find Sources/KakaoAX -name '*.swift' | tr ' ' '?'); do
    head -5 "$f" | grep -qE 'Derived from kmsg|SPDX-License-Identifier: MIT' || { nbad=$((nbad + 1)); probs="$probs no-header:$f;"; }
  done
else
  probs="$probs Sources/KakaoAX-missing;"
fi
grep -qi "not affiliated with Kakao" README.md 2>/dev/null || probs="$probs README-missing-'not affiliated with Kakao';"
if [ -z "$probs" ]; then gate G6 PASS "LICENSE, THIRD_PARTY_NOTICES, KakaoAX headers, README disclaimer"
else gate G6 FAIL "$(printf '%s' "$probs" | cut -c1-220)"; fi

# G7 — offline replay against golden outputs
nsnap=$(ls fixtures/snapshots/*.axjson 2>/dev/null | wc -l | tr -d ' ')
nself=$(grep -lE '"source"[[:space:]]*:[[:space:]]*"self-chat"' fixtures/snapshots/*.axjson 2>/dev/null | wc -l | tr -d ' ')
if [ $BUILD_OK -ne 1 ]; then
  gate G7 FAIL "build failed"
elif [ "$nself" -lt 3 ]; then
  gate G7 FAIL "need ≥3 self-chat recordings in fixtures/snapshots (have $nself of $nsnap) — ask Lipper (启动说明 §0)"
else
  with_timeout 300 "$CLI" replay fixtures/snapshots --engine mock --golden fixtures/golden >"$LOGS/replay.log" 2>&1; rc=$?
  if [ $rc -eq 0 ]; then gate G7 PASS "replay $nsnap snapshot(s) ($nself self-chat) == golden"
  else gate G7 FAIL "replay exit $rc — $(last_line "$LOGS/replay.log")"; fi
fi

# G8 — parse/diff performance budget (enforced by tlctl bench's exit code)
if [ $BUILD_OK -ne 1 ]; then
  gate G8 FAIL "build failed"
elif [ "$nsnap" -lt 1 ]; then
  gate G8 FAIL "no fixtures to benchmark"
else
  with_timeout 300 "$CLI" bench fixtures/snapshots >"$LOGS/bench.log" 2>&1; rc=$?
  if [ $rc -eq 0 ]; then gate G8 PASS "$(last_line "$LOGS/bench.log")"
  else gate G8 FAIL "bench exit $rc — $(last_line "$LOGS/bench.log")"; fi
fi

# G9 — Apple Translation self-test (OK, or SKIP with a reason)
if [ $BUILD_OK -ne 1 ]; then
  gate G9 FAIL "build failed"
else
  with_timeout 240 "$CLI" selftest --engine apple --source ko --target zh-Hans --input fixtures/test_messages_ko.txt \
    >"$LOGS/selftest.log" 2>&1; rc=$?
  case $rc in
    0) gate G9 PASS "$(last_line "$LOGS/selftest.log")" ;;
    3) gate G9 SKIP "$(last_line "$LOGS/selftest.log")" ;;
    142) gate G9 FAIL "selftest timed out (240 s)" ;;
    *) gate G9 FAIL "selftest exit $rc — $(last_line "$LOGS/selftest.log")" ;;
  esac
fi

# G10 — app bundle + code signature
if [ ! -x scripts/build_app.sh ]; then
  gate G10 FAIL "scripts/build_app.sh missing or not executable"
else
  scripts/build_app.sh >"$LOGS/bundle.log" 2>&1; rc=$?
  plist="$APP_PATH/Contents/Info.plist"
  if [ $rc -ne 0 ] || [ ! -d "$APP_PATH" ]; then
    gate G10 FAIL "build_app.sh exit $rc — $(last_line "$LOGS/bundle.log")"
  elif ! codesign --verify --strict "$APP_PATH" >>"$LOGS/bundle.log" 2>&1; then
    gate G10 FAIL "codesign --verify failed for $APP_PATH"
  else
    ui=$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$plist" 2>/dev/null)
    minv=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null | cut -d. -f1)
    bid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)
    if [ "$ui" = "true" ] && [ "${minv:-0}" -ge 15 ] && [ -n "$bid" ]; then
      gate G10 PASS "$APP_PATH signed ($(codesign -dv "$APP_PATH" 2>&1 | grep -E '^Authority=|^Signature=' | head -1)), $bid, LSUIElement, min macOS $minv"
    else
      gate G10 FAIL "Info.plist check: LSUIElement=$ui LSMinimumSystemVersion=$minv CFBundleIdentifier=$bid"
    fi
  fi
fi

# G11 — live probe against the running KakaoTalk (OK, or SKIP with a reason)
if [ $BUILD_OK -ne 1 ]; then
  gate G11 FAIL "build failed"
else
  with_timeout 60 "$CLI" probe --summary >"$LOGS/probe.log" 2>&1; rc=$?
  case $rc in
    0) gate G11 PASS "$(last_line "$LOGS/probe.log")" ;;
    3) gate G11 SKIP "$(last_line "$LOGS/probe.log")" ;;
    142) gate G11 FAIL "probe timed out (60 s)" ;;
    *) gate G11 FAIL "probe exit $rc — $(last_line "$LOGS/probe.log")" ;;
  esac
fi

# G12 — documentation present
missing=""
for f in README.md PRIVACY.md THIRD_PARTY_NOTICES.md docs/STATUS.md docs/PERF.md docs/LIVE_CHECKLIST.md docs/ax-map.md; do
  [ -s "$f" ] || missing="$missing $f"
done
if [ -z "$missing" ]; then gate G12 PASS "README, PRIVACY, NOTICES, STATUS, PERF, LIVE_CHECKLIST, ax-map present"
else gate G12 FAIL "missing/empty:$missing"; fi

echo
echo "== Summary"
printf '%s\n' "$SUMMARY" | sed '/^$/d'
echo "logs: $LOGS/"
if [ -n "$WARNED" ]; then echo "note: WARN/SKIP in $WARNED — explain in docs/STATUS.md"; fi
if [ -z "$FAILED" ]; then
  echo "VERIFY: PASS"
  exit 0
fi
echo "VERIFY: FAIL ($FAILED)"
exit 1
