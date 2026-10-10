// SPDX-License-Identifier: MIT
// Scheduler: priority, in-flight dedupe, batching, cancellation, in-memory LRU cache (docs/architecture.md §5).
//
// Privacy: the cache lives in memory only and is never persisted; logs carry counts and durations only.

import Foundation
import os
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

/// Cache key: (engine id, source, target, normalized segment text).
public struct TranslationCacheKey: Hashable, Sendable {
    public let engineID: String
    public let source: String
    public let target: String
    public let text: String
    public init(engineID: String, source: String, target: String, text: String) {
        self.engineID = engineID
        self.source = source
        self.target = target
        self.text = text
    }
}

/// Numbers only — safe to show in diagnostics or logs.
public struct TranslationServiceDiagnostics: Sendable, Equatable {
    /// Calls to `engine.translate`.
    public var engineCalls = 0
    /// Segment texts sent to the engine.
    public var itemsSent = 0
    /// Segment lookups answered by the cache at submit time.
    public var cacheHits = 0
    /// Segment lookups not in the cache at submit time.
    public var cacheMisses = 0
    /// Engine calls that threw or timed out.
    public var failedCalls = 0
    /// Engine calls abandoned after `engineTimeout` (also counted in `failedCalls`).
    public var timeouts = 0
    /// Outcomes yielded (success or error).
    public var outcomes = 0
    /// Current number of cached segments.
    public var cacheCount = 0
    public init() {}
}

public actor TranslationService {
    public let engine: any TranslationEngine
    public private(set) var source: Locale.Language
    public private(set) var target: Locale.Language
    public let batchSize: Int
    public let batchWindowMilliseconds: Int
    /// Upper bound for one engine call. On timeout its keys leave the in-flight set, the affected messages get
    /// `.failed("timeout")` and scheduling continues; the abandoned call is cancelled and its result ignored.
    public nonisolated let engineTimeout: Duration

    private var cache: LRUCache<TranslationCacheKey, String>
    /// Keys currently being translated by some engine call (possibly from a cancelled submission).
    private var inFlight: Set<TranslationCacheKey> = []
    private var generation: UInt64 = 0
    private var current: Submission?
    private var counters = TranslationServiceDiagnostics()
    private let logger = Logger(subsystem: TranslateLog.subsystem, category: "translate")

    private struct PendingMessage {
        let message: PreprocessedMessage
        let keys: [TranslationCacheKey]
    }

    private struct Submission {
        let generation: UInt64
        let continuation: AsyncStream<TranslationOutcome>.Continuation
        let stopwatch: Stopwatch
        let source: Locale.Language
        let target: Locale.Language
        /// Messages still waiting, in priority order.
        var pending: [PendingMessage]
        /// Segment translations known to this submission (from cache or completed batches).
        var resolved: [TranslationCacheKey: String]
        var needed: Set<TranslationCacheKey>
        var driver: Task<Void, Never>?
    }

    public init(engine: any TranslationEngine,
                source: Locale.Language = Locale.Language(identifier: "ko"),
                target: Locale.Language = Locale.Language(identifier: "zh-Hans"),
                cacheCapacity: Int = 2000, batchSize: Int = 16, batchWindowMilliseconds: Int = 50,
                engineTimeout: Duration = .seconds(10)) {
        self.engine = engine
        self.source = source
        self.target = target
        self.cache = LRUCache(capacity: max(1, cacheCapacity))
        self.batchSize = max(1, batchSize)
        self.batchWindowMilliseconds = max(0, batchWindowMilliseconds)
        self.engineTimeout = engineTimeout > .zero ? engineTimeout : .seconds(10)
    }

    /// Changing the target cancels pending work. The cache key includes the target, so no flush is needed.
    public func setTarget(_ target: Locale.Language) {
        guard target != self.target else { return }
        cancelCurrent()
        self.target = target
    }

    /// Changing the source cancels pending work (the source is part of the cache key).
    public func setSource(_ source: Locale.Language) {
        guard source != self.source else { return }
        cancelCurrent()
        self.source = source
    }

    public func status() async -> EngineStatus {
        await engine.status(source: source, target: target)
    }

    public var diagnostics: TranslationServiceDiagnostics {
        var d = counters
        d.cacheCount = cache.count
        return d
    }

    /// Cached full translation for a message, if every segment is cached.
    public func cachedTranslation(for message: PreprocessedMessage) -> String? {
        guard message.kind.needsTranslation else { return nil }
        let texts = message.translatableTexts
        guard !texts.isEmpty else { return nil }
        var values: [String] = []
        values.reserveCapacity(texts.count)
        for t in texts {
            guard let v = cache.peek(key(for: t)) else { return nil }
            values.append(v)
        }
        return message.assemble(translations: values)
    }

    /// Submit the current visible set, highest priority first (callers pass newest-first).
    /// Messages with `kind.needsTranslation == false` are ignored. Work from earlier submissions that is not
    /// part of this set is cancelled. Outcomes stream as they complete; the stream finishes when all are done.
    public func submit(_ messages: [PreprocessedMessage]) -> AsyncStream<TranslationOutcome> {
        cancelCurrent()
        let gen = generation
        let stopwatch = Stopwatch()
        let (stream, continuation) = AsyncStream.makeStream(of: TranslationOutcome.self)

        var pending: [PendingMessage] = []
        var resolved: [TranslationCacheKey: String] = [:]
        var queue: [TranslationCacheKey] = []
        var queued: Set<TranslationCacheKey> = []
        var itemIDs: [TranslationCacheKey: String] = [:]
        var seenMessages: Set<MessageID> = []
        var cachedCount = 0

        for m in messages {
            guard m.kind.needsTranslation, seenMessages.insert(m.message.id).inserted else { continue }
            let texts = m.translatableTexts
            guard !texts.isEmpty else { continue }
            let keys = texts.map { key(for: $0) }
            var complete = true
            for k in keys where resolved[k] == nil {
                if let v = cache.get(k) {
                    resolved[k] = v
                    counters.cacheHits += 1
                } else {
                    complete = false
                    counters.cacheMisses += 1
                }
            }
            if complete {
                cachedCount += 1
                yield(outcome(for: m, keys: keys, resolved: resolved, fromCache: true, stopwatch: stopwatch),
                      to: continuation)
                continue
            }
            pending.append(PendingMessage(message: m, keys: keys))
            for (i, k) in keys.enumerated()
            where resolved[k] == nil && !inFlight.contains(k) && queued.insert(k).inserted {
                queue.append(k)
                // Unique per batch: texts are deduplicated, and (message id, segment index) is unique.
                itemIDs[k] = "\(m.message.id.rawValue)#\(i)"
            }
        }
        logger.debug("submit pending=\(pending.count, privacy: .public) cached=\(cachedCount, privacy: .public) queued=\(queue.count, privacy: .public)")

        guard !pending.isEmpty else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { _ in
            Task { await self.streamTerminated(generation: gen) }
        }
        var submission = Submission(generation: gen, continuation: continuation, stopwatch: stopwatch,
                                    source: source, target: target, pending: pending, resolved: resolved,
                                    needed: Set(pending.flatMap(\.keys)), driver: nil)
        if !queue.isEmpty {
            submission.driver = Task { await self.drive(generation: gen, queue: queue, itemIDs: itemIDs) }
        }
        current = submission
        return stream
    }

    /// Cancels the current submission: its stream finishes and not-yet-started batches are dropped.
    /// Engine calls already running may complete and still fill the cache.
    public func cancelAll() {
        cancelCurrent()
    }

    public func clearCache() {
        cache.removeAll()
    }

    // MARK: - Internals

    private func key(for text: String) -> TranslationCacheKey {
        TranslationCacheKey(engineID: engine.id, source: source.maximalIdentifier,
                            target: target.maximalIdentifier, text: text)
    }

    private func cancelCurrent() {
        generation &+= 1
        guard let sub = current else { return }
        current = nil
        sub.driver?.cancel()
        sub.continuation.finish()
    }

    private func finishCurrent() {
        guard let sub = current else { return }
        current = nil
        sub.driver?.cancel()
        sub.continuation.finish()
    }

    private func streamTerminated(generation gen: UInt64) {
        // The consumer went away (or we finished it ourselves, in which case `current` is already gone).
        guard let sub = current, sub.generation == gen else { return }
        cancelCurrent()
    }

    private func drive(generation gen: UInt64, queue: [TranslationCacheKey],
                       itemIDs: [TranslationCacheKey: String]) async {
        if batchWindowMilliseconds > 0 {
            // Collect window: a resubmit during this time cancels us before anything is sent.
            try? await Task.sleep(for: .milliseconds(batchWindowMilliseconds))
        }
        var index = 0
        while index < queue.count {
            guard gen == generation, !Task.isCancelled, let sub = current, sub.generation == gen else { return }
            var batch: [TranslationCacheKey] = []
            while index < queue.count, batch.count < batchSize {
                let k = queue[index]
                index += 1
                if sub.resolved[k] != nil || inFlight.contains(k) || !sub.needed.contains(k) { continue }
                batch.append(k)
            }
            if batch.isEmpty { continue }
            await runBatch(batch, itemIDs: itemIDs, source: sub.source, target: sub.target)
        }
    }

    private func runBatch(_ keys: [TranslationCacheKey], itemIDs: [TranslationCacheKey: String],
                          source: Locale.Language, target: Locale.Language) async {
        for k in keys { inFlight.insert(k) }
        let items = keys.map { TranslationItem(id: itemIDs[$0] ?? UUID().uuidString, text: $0.text) }
        counters.engineCalls += 1
        counters.itemsSent += items.count
        let engine = self.engine
        let stopwatch = Stopwatch()
        // Unstructured on purpose: cancelling the driver must not abort an engine call already started.
        let call = Task { try await engine.translate(items, source: source, target: target) }
        let result = await Self.result(of: call, timeout: engineTimeout)
        for k in keys { inFlight.remove(k) }

        var successes: [TranslationCacheKey: String] = [:]
        var failed: Set<TranslationCacheKey> = []
        var failure: TranslationEngineError = .failed("missing result")
        switch result {
        case .success(let results):
            var byID: [String: String] = [:]
            for r in results { byID[r.id] = r.text }
            for (k, item) in zip(keys, items) {
                if let t = byID[item.id] {
                    cache.set(k, t)
                    successes[k] = t
                } else {
                    failed.insert(k)
                }
            }
        case .failure(let error):
            counters.failedCalls += 1
            failure = Self.engineError(error)
            if failure == Self.timeoutError { counters.timeouts += 1 }
            failed = Set(keys)
        }
        logger.debug("batch items=\(items.count, privacy: .public) failed=\(failed.count, privacy: .public) ms=\(stopwatch.elapsedMilliseconds, privacy: .public)")
        deliver(successes: successes, failed: failed, error: failure)
    }

    /// Applies batch results to the current submission and yields every message that became complete.
    private func deliver(successes: [TranslationCacheKey: String], failed: Set<TranslationCacheKey>,
                         error: TranslationEngineError) {
        guard var sub = current else { return }
        var touched = false
        for (k, v) in successes where sub.needed.contains(k) {
            sub.resolved[k] = v
            touched = true
        }
        if !touched && failed.isDisjoint(with: sub.needed) { return }

        var remaining: [PendingMessage] = []
        for p in sub.pending {
            if p.keys.contains(where: failed.contains) {
                yield(TranslationOutcome(id: p.message.message.id, text: nil, error: error, fromCache: false,
                                         latencyMilliseconds: sub.stopwatch.elapsedMilliseconds),
                      to: sub.continuation)
            } else if p.keys.allSatisfy({ sub.resolved[$0] != nil }) {
                yield(outcome(for: p.message, keys: p.keys, resolved: sub.resolved, fromCache: false,
                              stopwatch: sub.stopwatch), to: sub.continuation)
            } else {
                remaining.append(p)
            }
        }
        sub.pending = remaining
        sub.needed = Set(remaining.flatMap(\.keys))
        current = sub
        if remaining.isEmpty { finishCurrent() }
    }

    private func outcome(for m: PreprocessedMessage, keys: [TranslationCacheKey],
                         resolved: [TranslationCacheKey: String], fromCache: Bool,
                         stopwatch: Stopwatch) -> TranslationOutcome {
        let values = keys.compactMap { resolved[$0] }
        let text = values.count == keys.count ? m.assemble(translations: values) : nil
        return TranslationOutcome(id: m.message.id, text: text, error: text == nil ? .failed("assembly") : nil,
                                  fromCache: fromCache, latencyMilliseconds: stopwatch.elapsedMilliseconds)
    }

    private func yield(_ outcome: TranslationOutcome, to continuation: AsyncStream<TranslationOutcome>.Continuation) {
        counters.outcomes += 1
        continuation.yield(outcome)
    }

    static let timeoutError = TranslationEngineError.failed("timeout")

    /// Waits for `call` at most `timeout`. On timeout the call is cancelled (cooperatively) and abandoned:
    /// its eventual result is dropped and `.failure(timeoutError)` is returned right away.
    static func result<T: Sendable>(of call: Task<T, any Error>, timeout: Duration) async -> Result<T, any Error> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, any Error>, Never>) in
            let once = ResumeOnce(continuation)
            let timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                if once.resume(.failure(timeoutError)) { call.cancel() }
            }
            Task {
                let r = await call.result
                if once.resume(r) { timer.cancel() }
            }
        }
    }

    static func engineError(_ error: any Error) -> TranslationEngineError {
        if let e = error as? TranslationEngineError { return e }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        return .failed("\(ns.domain)#\(ns.code)")
    }
}

/// Resumes a continuation exactly once, from whichever racer gets there first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    /// True when this call resumed the continuation; false when someone else already had.
    @discardableResult
    func resume(_ value: T) -> Bool {
        let c: CheckedContinuation<T, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
        return c != nil
    }
}

/// os.Logger subsystem shared with TalkLensApp.
enum TranslateLog {
    static let subsystem = "dev.lipper.TalkLens"
}
