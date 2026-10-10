# Changelog

All notable changes to this project are documented here. Format: [Keep a Changelog](https://keepachangelog.com/), versions follow [SemVer](https://semver.org/).

## [Unreleased]

## [0.1.0] — 2026-10-10

### Added
- Menu bar app (`LSUIElement`) with enable/pause, show/hide sidebar, pin, settings, onboarding, about, quit.
- Read-only KakaoTalk chat window reader (vendored read-only subset of kmsg, generic over `AXNodeLike`).
- Non-activating sidebar panel docked to the chat window; follows move/resize/minimize/chat switch.
- Apple Translation engine (UI-less session on macOS 26+, SwiftUI-hosted session fallback on macOS 15–25), scheduler with priority, dedupe, batching, cancellation and in-memory LRU cache.
- Preprocessing: emoji/jamo/URL/number/already-target detection, URL and @mention protection, glossary chips and expansions.
- Settings: target language, show original, font size, opacity, dock side, width, glossary, launch at login.
- `tlctl` developer CLI: probe, watch, record, replay, bench, selftest.
- Synthetic AX fixtures, golden replay outputs, `scripts/verify.sh` acceptance gates.
