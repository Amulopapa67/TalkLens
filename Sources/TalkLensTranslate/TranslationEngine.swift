// SPDX-License-Identifier: MIT
// Translation engine abstraction (docs/architecture.md §5).
//
// CONTRACT FILE: see Sources/TalkLensCore/Models.swift.

import Foundation

public struct TranslationItem: Hashable, Sendable {
    /// Caller-chosen id (message id, or message id + chunk index). Echoed back in the result.
    public let id: String
    public let text: String
    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public struct TranslationResult: Hashable, Sendable {
    public let id: String
    public let text: String
    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public enum EngineStatus: Sendable, Equatable {
    case ready
    /// Language pair supported but models not downloaded; the user must install them.
    case needsDownload
    case unsupported(String)
}

public enum TranslationEngineError: Error, Sendable, Equatable {
    case notInstalled
    case unsupported(String)
    case cancelled
    case failed(String)
}

public protocol TranslationEngine: Sendable {
    /// Stable engine id ("apple", "mock"); part of the cache key.
    var id: String { get }
    func status(source: Locale.Language, target: Locale.Language) async -> EngineStatus
    /// Translate a batch. Results may come back in any order; match by `id`.
    func translate(_ items: [TranslationItem], source: Locale.Language,
                   target: Locale.Language) async throws -> [TranslationResult]
}
