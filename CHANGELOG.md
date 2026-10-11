# Changelog

All notable changes to this project are documented here. Format: [Keep a Changelog](https://keepachangelog.com/), versions follow [SemVer](https://semver.org/).

## [Unreleased]

## [0.1.0] — 2026-10-11

### Added
- Immersive overlay mode (default): translations painted over each message bubble in a click-through overlay; follows scrolling (scroll-wheel triggered fast tracking), window moves and new messages; hover a bubble or hold ⌥ to reveal the original.
- Every open chat window is translated at once (one session per window), with occlusion masking so nothing is drawn over windows that cover a chat.
- Read-only chats without an input box (business / channel accounts) are supported.
- Selectable source language (auto-detect or fixed) and target language.
- Incremental AX reads with a per-row cache, a prefetch band around the viewport and a per-read budget so KakaoTalk is never overloaded.
- One-line installer (`scripts/install.sh`), DMG/zip packaging (`scripts/package_release.sh`) and a tag-triggered GitHub release workflow.
- Menu bar app (`LSUIElement`) with enable/pause, show/hide sidebar, pin, settings, onboarding, about, quit.
- Read-only KakaoTalk chat window reader (vendored read-only subset of kmsg, generic over `AXNodeLike`).
- Non-activating sidebar panel docked to the chat window; follows move/resize/minimize/chat switch.
- Apple Translation engine (UI-less session on macOS 26+, SwiftUI-hosted session fallback on macOS 15–25), scheduler with priority, dedupe, batching, cancellation and in-memory LRU cache.
- Preprocessing: emoji/jamo/URL/number/already-target detection, URL and @mention protection, glossary chips and expansions.
- Settings: target language, show original, font size, opacity, dock side, width, glossary, launch at login.
- `tlctl` developer CLI: probe, watch, record, replay, bench, selftest.
- Synthetic AX fixtures, golden replay outputs, `scripts/verify.sh` acceptance gates.
