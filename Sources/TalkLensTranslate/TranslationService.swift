// SPDX-License-Identifier: MIT
// Scheduler: priority, in-flight dedupe, batching, cancellation, in-memory LRU cache (docs/architecture.md §5).
//
// Channels: every submission belongs to a channel (one per followed chat window). A new submission cancels
// only the previous submission on the same channel; the cache and the in-flight dedupe are shared by all
// channels, and engine calls are serialized across channels (one call at a time; the preferred channel's
// next batch goes first when several are waiting).
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
    /// Language pair used for this message (catalog ids), e.g. ja→zh-Hans for an auto-detected Japanese
    /// message. Lets the UI name the pair that needs a download.
    public let pair: LanguagePair?

    public init(id: MessageID, text: String?, error: TranslationEngineError?, fromCache: Bool,
                latencyMilliseconds: Double, pair: LanguagePair? = nil) {
        self.id = id
        self.text = text
        self.error = error
        self.fromCache = fromCache
        self.latencyMilliseconds = latencyMilliseconds
        self.pair = pair
    }
}

/// Cache key: (engine id, source, target, normalized segment text). `source` is the per-message source
/// (detected language when the source is auto), so the same text from two languages never collides.
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
    /// Warm-up engine calls (one fixed synthetic word, never user content).
    public var warmUps = 0
    public init() {}
}

public actor TranslationService {
    public let engine: any TranslationEngine
    /// Fallback source for messages without `PreprocessedMessage.sourceLanguage` (and for `status()`).
    public private(set) var source: Locale.Language
    public private(set) var target: Locale.Language
    public let batchSize: Int
    public let batchWindowMilliseconds: Int
    /// Upper bound for one engine call. On timeout its keys leave the in-flight set, the affected messages get
    /// `.failed("timeout")` and scheduling continues; the abandoned call is cancelled and its result ignored.
    public nonisolated let engineTimeout: Duration

    /// Channel used by callers that do not pass one.
    public static let defaultChannel = "default"

    private var cache: LRUCache<TranslationCacheKey, String>
    /// Keys currently being translated by some engine call (possibly from a cancelled submission).
    private var inFlight: Set<TranslationCacheKey> = []
    /// Last submission id handed out (ids are unique across channels).
    private var generation: UInt64 = 0
    /// Live submission per channel.
    private var submissions: [String: Submission] = [:]
    /// Engine lane: at most one engine call runs at a time, whichever channel it serves.
    private var laneBusy = false
    private var laneWaiters: [(channel: String, continuation: CheckedContinuation<Void, Never>)] = []
    /// Channel whose waiting batch gets the engine lane first (the focused chat window).
    private var preferredChannel: String?
    private var counters = TranslationServiceDiagnostics()
    /// Engine status per (source, target) maximal identifiers: `.ready` is kept until invalidated, anything
    /// else is re-checked after `languageStatusRetry`.
    private var languageStatuses: [String: (status: EngineStatus, at: ContinuousClock.Instant)] = [:]
    static let languageStatusRetry: Duration = .seconds(5)
    private let logger = Logger(subsystem: TranslateLog.subsystem, category: "translate")

    private struct PendingMessage {
        let message: PreprocessedMessage
        let keys: [TranslationCacheKey]
        let pair: LanguagePair
    }

    private struct Submission {
        let channel: String
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

    /// Changing the target cancels pending work on every channel. The cache key includes the target, so no
    /// flush is needed.
    public func setTarget(_ target: Locale.Language) {
        guard target != self.target else { return }
        cancelAllChannels()
        self.target = target
    }

    /// Changing the source cancels pending work on every channel (the source is part of the cache key).
    public func setSource(_ source: Locale.Language) {
        guard source != self.source else { return }
        cancelAllChannels()
        self.source = source
    }

    /// The channel whose batches go first when several channels wait for the engine (nil = arrival order).
    public func setPreferredChannel(_ channel: String?) {
        preferredChannel = channel
    }

    /// Number of channels with a live submission (numbers only, for diagnostics).
    public var activeChannelCount: Int { submissions.count }

    /// Status of the fallback pair (service source → target).
    public func status() async -> EngineStatus {
        await status(source: source, target: target)
    }

    /// Status of one pair, checked now (the result also refreshes the per-pair cache used before engine calls).
    public func status(source: Locale.Language, target: Locale.Language) async -> EngineStatus {
        let s = await engine.status(source: source, target: target)
        languageStatuses[Self.pairKey(source, target)] = (s, .now)
        return s
    }

    /// Forget cached per-pair statuses (call after languages were downloaded).
    public func invalidateLanguageStatus() {
        languageStatuses.removeAll()
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
        let src = sourceLanguage(for: message)
        var values: [String] = []
        values.reserveCapacity(texts.count)
        for t in texts {
            guard let v = cache.peek(key(for: t, source: src)) else { return nil }
            values.append(v)
        }
        return message.assemble(translations: values)
    }

    /// Submit the current visible set of one channel, highest priority first (callers pass newest-first).
    /// Messages with `kind.needsTranslation == false` are ignored. The previous submission on the same channel
    /// is cancelled (work it started keeps filling the cache); other channels are not affected. Texts already
    /// in flight for any channel are awaited, not sent again. Outcomes stream as they complete; the stream
    /// finishes when all are done.
    ///
    /// - immediate: skip the batch collect window (the submission holds a message that just arrived, or the
    ///   first visible messages of a chat): nothing is waiting to be coalesced with it.
    public func submit(_ messages: [PreprocessedMessage],
                       channel: String = TranslationService.defaultChannel,
                       immediate: Bool = false) -> AsyncStream<TranslationOutcome> {
        cancel(channel: channel)
        generation &+= 1
        let gen = generation
        let stopwatch = Stopwatch()
        let (stream, continuation) = AsyncStream.makeStream(of: TranslationOutcome.self)

        var pending: [PendingMessage] = []
        var resolved: [TranslationCacheKey: String] = [:]
        var queue: [TranslationCacheKey] = []
        var queued: Set<TranslationCacheKey> = []
        var itemIDs: [TranslationCacheKey: String] = [:]
        var languages: [String: Locale.Language] = [:]
        var seenMessages: Set<MessageID> = []
        var cachedCount = 0

        for m in messages {
            guard m.kind.needsTranslation, seenMessages.insert(m.message.id).inserted else { continue }
            let texts = m.translatableTexts
            guard !texts.isEmpty else { continue }
            let src = sourceLanguage(for: m)
            languages[src.maximalIdentifier] = src
            let pair = LanguagePair(source: LanguageCatalog.pairID(src), target: LanguageCatalog.pairID(target))
            let keys = texts.map { key(for: $0, source: src) }
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
                yield(outcome(for: m, keys: keys, resolved: resolved, fromCache: true, stopwatch: stopwatch, pair: pair),
                      to: continuation)
                continue
            }
            pending.append(PendingMessage(message: m, keys: keys, pair: pair))
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
            Task { await self.streamTerminated(channel: channel, generation: gen) }
        }
        var submission = Submission(channel: channel, generation: gen, continuation: continuation,
                                    stopwatch: stopwatch,
                                    source: source, target: target, pending: pending, resolved: resolved,
                                    needed: Set(pending.flatMap(\.keys)), driver: nil)
        if !queue.isEmpty {
            let window = immediate ? 0 : batchWindowMilliseconds
            submission.driver = Task {
                await self.drive(channel: channel, generation: gen, queue: queue, itemIDs: itemIDs,
                                 languages: languages, windowMilliseconds: window)
            }
        }
        submissions[channel] = submission
        return stream
    }

    /// Fixed synthetic warm-up word per source language family (never user content).
    public static func warmUpText(for source: Locale.Language) -> String {
        switch source.languageCode?.identifier ?? "" {
        case "ko": return "안녕하세요"
        case "ja": return "こんにちは"
        case "zh": return "你好"
        case "es": return "Hola"
        case "fr": return "Bonjour"
        case "de": return "Hallo"
        case "ru": return "Привет"
        case "vi": return "Xin chào"
        case "th": return "สวัสดี"
        case "id": return "Halo"
        default: return "hello"
        }
    }

    /// Pre-warms the engine for `source → target` (default: the fallback pair) by translating one fixed
    /// synthetic word, so that the first real batch does not pay for session creation / model loading. Runs
    /// through the engine lane (never in parallel with a real call) and the engine's own session store, so
    /// the warmed session is the one reused later. Skipped (returns false) when the pair is not installed.
    /// The result is discarded and not cached.
    @discardableResult
    public func warmUp(source: Locale.Language? = nil, target: Locale.Language? = nil) async -> Bool {
        let source = source ?? self.source
        let target = target ?? self.target
        guard await cachedLanguageStatus(source: source, target: target) == .ready else { return false }
        await acquireLane(channel: "warm-up")
        defer { releaseLane() }
        counters.warmUps += 1
        let engine = self.engine
        let item = TranslationItem(id: "warm-up", text: Self.warmUpText(for: source))
        let stopwatch = Stopwatch()
        let call = Task { try await engine.translate([item], source: source, target: target) }
        let result = await Self.result(of: call, timeout: engineTimeout)
        let ok: Bool
        if case .success = result { ok = true } else { ok = false }
        logger.info("warm-up ok=\(ok, privacy: .public) ms=\(Int(stopwatch.elapsedMilliseconds), privacy: .public)")
        return ok
    }

    /// Cancels the submissions of every channel: their streams finish and not-yet-started batches are dropped.
    /// Engine calls already running may complete and still fill the cache.
    public func cancelAll() {
        cancelAllChannels()
    }

    /// Cancels the submission of one channel only.
    public func cancel(channel: String) {
        guard let sub = submissions.removeValue(forKey: channel) else { return }
        sub.driver?.cancel()
        sub.continuation.finish()
    }

    public func clearCache() {
        cache.removeAll()
    }

    // MARK: - Internals

    private func key(for text: String, source: Locale.Language) -> TranslationCacheKey {
        TranslationCacheKey(engineID: engine.id, source: source.maximalIdentifier,
                            target: target.maximalIdentifier, text: text)
    }

    /// The message's own source (auto-detected or fixed in the preprocessor), else the service source.
    private func sourceLanguage(for message: PreprocessedMessage) -> Locale.Language {
        message.sourceLanguage.map { Locale.Language(identifier: $0) } ?? source
    }

    private static func pairKey(_ source: Locale.Language, _ target: Locale.Language) -> String {
        source.maximalIdentifier + "|" + target.maximalIdentifier
    }

    /// Cached engine status for a pair (re-checked when stale or not ready for a while).
    private func cachedLanguageStatus(source: Locale.Language, target: Locale.Language) async -> EngineStatus {
        let k = Self.pairKey(source, target)
        if let entry = languageStatuses[k],
           entry.status == .ready || ContinuousClock.now - entry.at < Self.languageStatusRetry {
            return entry.status
        }
        return await status(source: source, target: target)
    }

    private func cancelAllChannels() {
        for channel in Array(submissions.keys) { cancel(channel: channel) }
    }

    private func isCurrent(channel: String, generation gen: UInt64) -> Bool {
        submissions[channel]?.generation == gen
    }

    private func streamTerminated(channel: String, generation gen: UInt64) {
        // The consumer went away (or we finished it ourselves, in which case the submission is already gone).
        guard isCurrent(channel: channel, generation: gen) else { return }
        cancel(channel: channel)
    }

    /// Sends the queue in batches. Every batch has a single source language (texts of several sources — auto
    /// detect — are grouped by source; within a source the priority order is kept, and the source of the
    /// highest-priority waiting text goes first). A pair that is not installed fails its messages without an
    /// engine call.
    private func drive(channel: String, generation gen: UInt64, queue: [TranslationCacheKey],
                       itemIDs: [TranslationCacheKey: String], languages: [String: Locale.Language],
                       windowMilliseconds: Int) async {
        if windowMilliseconds > 0 {
            // Collect window: a resubmit during this time cancels us before anything is sent.
            try? await Task.sleep(for: .milliseconds(windowMilliseconds))
        }
        var remaining = queue
        while !remaining.isEmpty {
            guard !Task.isCancelled, let sub = submissions[channel], sub.generation == gen else { return }
            var batch: [TranslationCacheKey] = []
            var rest: [TranslationCacheKey] = []
            var batchSource: String?
            for k in remaining {
                if sub.resolved[k] != nil || inFlight.contains(k) || !sub.needed.contains(k) { continue }
                if batch.count < batchSize, batchSource == nil || batchSource == k.source {
                    batchSource = k.source
                    batch.append(k)
                } else {
                    rest.append(k)
                }
            }
            remaining = rest
            guard let batchSource, !batch.isEmpty else { continue }
            let source = languages[batchSource] ?? Locale.Language(identifier: batchSource)
            let target = sub.target

            let pairStatus = await cachedLanguageStatus(source: source, target: target)
            guard !Task.isCancelled, let checked = submissions[channel], checked.generation == gen else { return }
            if pairStatus != .ready {
                let error: TranslationEngineError
                switch pairStatus {
                case .unsupported(let reason): error = .unsupported(reason)
                default: error = .notInstalled
                }
                logger.debug("batch skipped items=\(batch.count, privacy: .public) pair not ready")
                deliver(successes: [:], failed: Set(batch), error: error)
                continue
            }

            await acquireLane(channel: channel)
            // Another channel's call may have resolved (or started) some of these texts while we waited.
            guard !Task.isCancelled, let fresh = submissions[channel], fresh.generation == gen else {
                releaseLane()
                return
            }
            batch.removeAll { fresh.resolved[$0] != nil || inFlight.contains($0) || !fresh.needed.contains($0) }
            if batch.isEmpty {
                releaseLane()
                continue
            }
            await runBatch(batch, itemIDs: itemIDs, source: source, target: fresh.target)
            releaseLane()
        }
    }

    // MARK: - Engine lane

    private func acquireLane(channel: String) async {
        guard laneBusy else {
            laneBusy = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            laneWaiters.append((channel, continuation))
        }
        // Ownership was handed over by `releaseLane` (laneBusy stayed true).
    }

    private func releaseLane() {
        guard !laneWaiters.isEmpty else {
            laneBusy = false
            return
        }
        let index = preferredChannel.flatMap { p in laneWaiters.firstIndex { $0.channel == p } } ?? 0
        let next = laneWaiters.remove(at: index)
        next.continuation.resume()
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
            if failure == .notInstalled {
                // Re-check this pair before the next call instead of trusting a cached `.ready`.
                languageStatuses[Self.pairKey(source, target)] = (.needsDownload, .now)
            }
            failed = Set(keys)
        }
        logger.debug("batch items=\(items.count, privacy: .public) failed=\(failed.count, privacy: .public) ms=\(stopwatch.elapsedMilliseconds, privacy: .public)")
        deliver(successes: successes, failed: failed, error: failure)
    }

    /// Applies batch results to every live submission (any channel) that needs them and yields every message
    /// that became complete.
    private func deliver(successes: [TranslationCacheKey: String], failed: Set<TranslationCacheKey>,
                         error: TranslationEngineError) {
        var finished: [String] = []
        for channel in Array(submissions.keys) {
            guard var sub = submissions[channel] else { continue }
            var touched = false
            for (k, v) in successes where sub.needed.contains(k) {
                sub.resolved[k] = v
                touched = true
            }
            if !touched && failed.isDisjoint(with: sub.needed) { continue }

            var remaining: [PendingMessage] = []
            for p in sub.pending {
                if p.keys.contains(where: failed.contains) {
                    yield(TranslationOutcome(id: p.message.message.id, text: nil, error: error, fromCache: false,
                                             latencyMilliseconds: sub.stopwatch.elapsedMilliseconds, pair: p.pair),
                          to: sub.continuation)
                } else if p.keys.allSatisfy({ sub.resolved[$0] != nil }) {
                    yield(outcome(for: p.message, keys: p.keys, resolved: sub.resolved, fromCache: false,
                                  stopwatch: sub.stopwatch, pair: p.pair), to: sub.continuation)
                } else {
                    remaining.append(p)
                }
            }
            sub.pending = remaining
            sub.needed = Set(remaining.flatMap(\.keys))
            submissions[channel] = sub
            if remaining.isEmpty { finished.append(channel) }
        }
        for channel in finished { finish(channel: channel) }
    }

    private func finish(channel: String) {
        guard let sub = submissions.removeValue(forKey: channel) else { return }
        sub.driver?.cancel()
        sub.continuation.finish()
    }

    private func outcome(for m: PreprocessedMessage, keys: [TranslationCacheKey],
                         resolved: [TranslationCacheKey: String], fromCache: Bool,
                         stopwatch: Stopwatch, pair: LanguagePair) -> TranslationOutcome {
        let values = keys.compactMap { resolved[$0] }
        let text = values.count == keys.count ? m.assemble(translations: values) : nil
        return TranslationOutcome(id: m.message.id, text: text, error: text == nil ? .failed("assembly") : nil,
                                  fromCache: fromCache, latencyMilliseconds: stopwatch.elapsedMilliseconds,
                                  pair: pair)
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
