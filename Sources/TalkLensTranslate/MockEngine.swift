// SPDX-License-Identifier: MIT
// Deterministic engine for replay/golden and unit tests: "[mock→<target>] " + text.

import Foundation

public struct MockEngine: TranslationEngine {
    public let id = "mock"
    public init() {}

    public func status(source: Locale.Language, target: Locale.Language) async -> EngineStatus { .ready }

    public func translate(_ items: [TranslationItem], source: Locale.Language,
                          target: Locale.Language) async throws -> [TranslationResult] {
        let tag = MockEngine.tag(for: target)
        return items.map { TranslationResult(id: $0.id, text: "[mock→\(tag)] " + $0.text) }
    }

    /// Synchronous variant used by tlctl replay.
    public static func translateSync(_ text: String, target: String) -> String {
        "[mock→\(target)] " + text
    }

    static func tag(for target: Locale.Language) -> String {
        target.maximalIdentifier == Locale.Language(identifier: "zh-Hans").maximalIdentifier ? "zh-Hans" : target.minimalIdentifier
    }
}
