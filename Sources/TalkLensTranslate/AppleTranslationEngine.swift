// SPDX-License-Identifier: MIT
// Apple Translation engine (on-device). See docs/architecture.md §5.
// STUB — translate-dev owns this file.

import Foundation

public struct AppleTranslationEngine: TranslationEngine {
    public let id = "apple"
    public init() {}

    public func status(source: Locale.Language, target: Locale.Language) async -> EngineStatus {
        .unsupported("not implemented")
    }

    public func translate(_ items: [TranslationItem], source: Locale.Language,
                          target: Locale.Language) async throws -> [TranslationResult] {
        throw TranslationEngineError.unsupported("not implemented")
    }
}
