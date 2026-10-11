// SPDX-License-Identifier: MIT
// Which messages of a transcript read count as "new message → translation displayed" latency samples (D-027).
//
// A sample is only meaningful for a message that really just arrived. Rows that a budgeted follow-up read
// (D-020) analyses later, rows loaded at launch, and lazily loaded history are not new messages, even when
// they appear below the last row the model knew about.

import Foundation

/// Why a transcript read happened (numbers-only diagnostics; decides latency-sample eligibility).
public enum ReadTrigger: String, Sendable, Equatable, CaseIterable {
    /// Debounced AX content notification (e.g. AXRowCountChanged on the followed table).
    case contentEvent
    /// Fallback poll (or a cheap probe) that found the transcript changed.
    case poll
    /// Budgeted follow-up read that analyses rows still pending from the previous read (D-020).
    case followUp
    /// First read of a session, a read after the window became visible again, a settings change, a retry.
    case other

    /// Only reads caused by a change in the chat can carry latency samples.
    public var canSample: Bool { self == .contentEvent || self == .poll }
}

public enum LatencySampling {
    /// Ids of `current` that are latency samples.
    ///
    /// - previous: message ids of the model's previous snapshot, top to bottom (empty = initial load).
    /// - previousRowsTotal / currentRowsTotal: loaded table rows at the previous / current read.
    /// - Returns: messages that (a) come after the last message of the previous snapshot in table order, and
    ///   (b) arrived through a content event or a poll; at most as many as the table grew by, newest last
    ///   (rows analysed late because of the read budget also land below the previous last message, but they
    ///   do not make the table grow).
    public static func eligibleIDs(previous: [MessageID], previousRowsTotal: Int?, current: [MessageID],
                                   currentRowsTotal: Int, trigger: ReadTrigger) -> [MessageID] {
        guard trigger.canSample, !previous.isEmpty, let previousRowsTotal else { return [] }
        let grown = currentRowsTotal - previousRowsTotal
        guard grown > 0 else { return [] }
        let tail = tailAfterLastCommon(old: previous, new: current)
        guard !tail.isEmpty else { return [] }
        return Array(tail.suffix(grown))
    }

    /// Ids of `new` below the last id that also exists in `old` (empty when there is no overlap).
    public static func tailAfterLastCommon(old: [MessageID], new: [MessageID]) -> [MessageID] {
        let oldSet = Set(old)
        guard let last = new.lastIndex(where: { oldSet.contains($0) }) else { return [] }
        return Array(new[(last + 1)...])
    }
}

/// Timestamps of one latency sample (monotonic clock). Durations are derived in milliseconds.
public struct LatencyTrace: Sendable, Equatable {
    /// First content event (or poll) behind the read.
    public var triggeredAt: ContinuousClock.Instant
    /// The read started (after debounce and queue wait).
    public var readStartedAt: ContinuousClock.Instant
    /// The read result reached the main actor.
    public var readEndedAt: ContinuousClock.Instant
    /// The message was handed to the translation service (or looked up in its cache).
    public var submittedAt: ContinuousClock.Instant?
    /// Its translation outcome was applied to the row model.
    public var outcomeAt: ContinuousClock.Instant?

    public init(triggeredAt: ContinuousClock.Instant, readStartedAt: ContinuousClock.Instant,
                readEndedAt: ContinuousClock.Instant) {
        self.triggeredAt = triggeredAt
        self.readStartedAt = readStartedAt
        self.readEndedAt = readEndedAt
    }

    public struct Breakdown: Sendable, Equatable {
        public let total: Double
        public let eventToRead: Double
        public let read: Double
        public let translate: Double
        public let display: Double
    }

    /// Durations (ms) once the translation is displayed at `displayedAt`; nil before submit / outcome.
    public func breakdown(displayedAt: ContinuousClock.Instant) -> Breakdown? {
        guard let submittedAt, let outcomeAt else { return nil }
        return Breakdown(total: Self.ms(displayedAt - triggeredAt),
                         eventToRead: Self.ms(readStartedAt - triggeredAt),
                         read: Self.ms(readEndedAt - readStartedAt),
                         translate: Self.ms(outcomeAt - submittedAt),
                         display: Self.ms(displayedAt - outcomeAt))
    }

    public static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}
