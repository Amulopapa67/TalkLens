// SPDX-License-Identifier: MIT
// Scheduler: priority, in-flight dedupe, batching, cancellation, in-memory LRU cache (docs/architecture.md §5).
// STUB — translate-dev: implement and test.

import Foundation
import TalkLensCore

public struct TranslationOutcome: Sendable, Equatable {
    public let id: MessageID
    /// Full assembled translation; nil on failure.
    public let text: String?
    public let error: TranslationEngineError?
    public let fromCache: Bool
    /// Time from submit to result, milliseconds.
    public let latencyMilliseconds: Double

    public init(id: MessageID, text: String?, error: TranslationEngineError?, fromCache: Bool,
                latencyMilliseconds: Double) {
        self.id = id
        self.text = text
        self.error = error
        self.fromCache = fromCache
        self.latencyMilliseconds = latencyMilliseconds
    }
}

public actor TranslationService {
    public let engine: any TranslationEngine
    public private(set) var source: Locale.Language
    public private(set) var target: Locale.Language

    public init(engine: any TranslationEngine,
                source: Locale.Language = Locale.Language(identifier: "ko"),
                target: Locale.Language = Locale.Language(identifier: "zh-Hans"),
                cacheCapacity: Int = 2000, batchSize: Int = 16, batchWindowMilliseconds: Int = 50) {
        self.engine = engine
        self.source = source
        self.target = target
    }

    /// Changing the target cancels pending work. The cache key includes the target, so no flush is needed.
    public func setTarget(_ target: Locale.Language) {
        self.target = target
    }

    public func status() async -> EngineStatus {
        await engine.status(source: source, target: target)
    }

    /// Cached full translation for a message, if every segment is cached.
    public func cachedTranslation(for message: PreprocessedMessage) -> String? { nil }

    /// Submit the current visible set, highest priority first (callers pass newest-first).
    /// Messages with `kind.needsTranslation == false` are ignored. Work from earlier submissions that is not
    /// part of this set is cancelled. Outcomes stream as they complete; the stream finishes when all are done.
    public func submit(_ messages: [PreprocessedMessage]) -> AsyncStream<TranslationOutcome> {
        AsyncStream { $0.finish() }
    }

    public func cancelAll() {}

    public func clearCache() {}
}
