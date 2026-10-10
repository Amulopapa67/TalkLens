// SPDX-License-Identifier: MIT
// Test-only helpers for TalkLensTranslate: a configurable engine (delay, failure injection, call recording)
// and message builders. Synthetic text only.

import Foundation
@testable import TalkLensCore
@testable import TalkLensTranslate

actor CallRecorder {
    private(set) var calls: [[String]] = []
    func record(_ texts: [String]) { calls.append(texts) }
    var allTexts: [String] { calls.flatMap { $0 } }
    var count: Int { calls.count }
}

/// Deterministic engine for scheduler tests: "<target>" + text, optional delay, injectable failures.
struct ScriptedEngine: TranslationEngine {
    let id: String
    let recorder = CallRecorder()
    let delay: Duration
    let failingTexts: Set<String>

    init(id: String = "scripted", delay: Duration = .zero, failingTexts: Set<String> = []) {
        self.id = id
        self.delay = delay
        self.failingTexts = failingTexts
    }

    func status(source: Locale.Language, target: Locale.Language) async -> EngineStatus { .ready }

    func translate(_ items: [TranslationItem], source: Locale.Language,
                   target: Locale.Language) async throws -> [TranslationResult] {
        await recorder.record(items.map(\.text))
        if delay > .zero {
            // Ignore cancellation on purpose: mimics an engine call that runs to completion.
            let deadline = ContinuousClock.now + delay
            while ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        }
        if items.contains(where: { failingTexts.contains($0.text) }) {
            throw TranslationEngineError.failed("injected")
        }
        return items.map { TranslationResult(id: $0.id, text: Self.render($0.text, target: target)) }
    }

    static func render(_ text: String, target: Locale.Language) -> String {
        "<\(target.minimalIdentifier)>" + text
    }
}

enum Msg {
    static func chat(_ id: String, _ body: String) -> ChatMessage {
        ChatMessage(id: MessageID(id), parsed: ParsedMessage(author: "A", isMine: false, isSystem: false,
                                                             timeRaw: nil, date: nil, body: body))
    }

    /// A translatable message with a single segment.
    static func text(_ id: String, _ body: String) -> PreprocessedMessage {
        PreprocessedMessage(message: chat(id, body), kind: .translate, textForMT: body,
                            segments: [.translate(body)], chips: [], note: nil)
    }

    static func segments(_ id: String, _ segments: [MTSegment]) -> PreprocessedMessage {
        let body = segments.map { seg -> String in
            switch seg {
            case .translate(let t), .keep(let t): return t
            }
        }.joined()
        return PreprocessedMessage(message: chat(id, body), kind: .translate, textForMT: body,
                                   segments: segments, chips: [], note: nil)
    }

    static func skipped(_ id: String, _ body: String, kind: MessageKind) -> PreprocessedMessage {
        PreprocessedMessage(message: chat(id, body), kind: kind, textForMT: nil, segments: [], chips: [],
                            note: nil)
    }
}

func collect(_ stream: AsyncStream<TranslationOutcome>) async -> [TranslationOutcome] {
    var out: [TranslationOutcome] = []
    for await o in stream { out.append(o) }
    return out
}

/// Polls `condition` until true or the timeout elapses.
func waitUntil(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
