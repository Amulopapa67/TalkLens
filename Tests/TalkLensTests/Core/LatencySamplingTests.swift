// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TalkLensCore

@Suite("Core.LatencySampling")
struct LatencySamplingTests {
    static func ids(_ names: String...) -> [MessageID] { names.map { MessageID($0) } }

    @Test("a new message at the bottom of a content-event read is a sample")
    func newBottomRow() {
        let previous = Self.ids("a", "b", "c")
        let current = Self.ids("a", "b", "c", "d")
        let ids = LatencySampling.eligibleIDs(previous: previous, previousRowsTotal: 3, current: current,
                                              currentRowsTotal: 4, trigger: .contentEvent)
        #expect(ids == Self.ids("d"))
        // A poll that found the new row counts as well.
        #expect(LatencySampling.eligibleIDs(previous: previous, previousRowsTotal: 3, current: current,
                                            currentRowsTotal: 4, trigger: .poll) == Self.ids("d"))
    }

    @Test("the initial load is not a sample")
    func initialLoad() {
        let current = Self.ids("a", "b", "c")
        #expect(LatencySampling.eligibleIDs(previous: [], previousRowsTotal: nil, current: current,
                                            currentRowsTotal: 3, trigger: .contentEvent).isEmpty)
        #expect(LatencySampling.eligibleIDs(previous: [], previousRowsTotal: 0, current: current,
                                            currentRowsTotal: 3, trigger: .other).isEmpty)
    }

    @Test("rows added by a budgeted follow-up read are not samples, above or below the viewport")
    func followUpRows() {
        // The first (budgeted) read analysed the visible rows only; the follow-up adds the rest of the band.
        let previous = Self.ids("v1", "v2", "v3")
        let current = Self.ids("h1", "h2", "v1", "v2", "v3", "b1", "b2")
        #expect(LatencySampling.eligibleIDs(previous: previous, previousRowsTotal: 30, current: current,
                                            currentRowsTotal: 30, trigger: .followUp).isEmpty)
        // Same rows arriving in a content-event read: the table did not grow, so nothing is new.
        #expect(LatencySampling.eligibleIDs(previous: previous, previousRowsTotal: 30, current: current,
                                            currentRowsTotal: 30, trigger: .contentEvent).isEmpty)
    }

    @Test("prefetched rows above the viewport are not samples even when a new message arrives")
    func prefetchedAboveWithNewMessage() {
        let previous = Self.ids("v1", "v2")
        let current = Self.ids("h1", "h2", "h3", "v1", "v2", "new")
        let ids = LatencySampling.eligibleIDs(previous: previous, previousRowsTotal: 20, current: current,
                                              currentRowsTotal: 21, trigger: .contentEvent)
        #expect(ids == Self.ids("new"))
    }

    @Test("late-analysed rows below the old last row: only as many as the table grew by, newest last")
    func lateRowsBelowCapped() {
        let previous = Self.ids("a", "b")
        // "p1", "p2" were pending (over budget) at the previous read; "n" is the new message.
        let current = Self.ids("a", "b", "p1", "p2", "n")
        let ids = LatencySampling.eligibleIDs(previous: previous, previousRowsTotal: 10, current: current,
                                              currentRowsTotal: 11, trigger: .contentEvent)
        #expect(ids == Self.ids("n"))
    }

    @Test("lazily loaded history (table grew at the top) is not a sample")
    func historyLoaded() {
        let previous = Self.ids("a", "b", "c")
        let current = Self.ids("x", "y", "a", "b", "c")
        #expect(LatencySampling.eligibleIDs(previous: previous, previousRowsTotal: 3, current: current,
                                            currentRowsTotal: 5, trigger: .poll).isEmpty)
    }

    @Test("an edited message in the middle is not a sample; a chat switch (no overlap) is not either")
    func editsAndSwitches() {
        let previous = Self.ids("a", "b", "c")
        #expect(LatencySampling.eligibleIDs(previous: previous, previousRowsTotal: 3, current: Self.ids("a", "b2", "c"),
                                            currentRowsTotal: 3, trigger: .contentEvent).isEmpty)
        #expect(LatencySampling.eligibleIDs(previous: previous, previousRowsTotal: 3, current: Self.ids("x", "y", "z", "w"),
                                            currentRowsTotal: 4, trigger: .contentEvent).isEmpty)
    }

    @Test("breakdown splits the total into event→read, read, translate and display")
    func breakdown() {
        let t0 = ContinuousClock.now
        var trace = LatencyTrace(triggeredAt: t0, readStartedAt: t0 + .milliseconds(40),
                                 readEndedAt: t0 + .milliseconds(50))
        #expect(trace.breakdown(displayedAt: t0 + .milliseconds(60)) == nil)
        trace.submittedAt = t0 + .milliseconds(52)
        trace.outcomeAt = t0 + .milliseconds(352)
        let b = trace.breakdown(displayedAt: t0 + .milliseconds(355))
        #expect(b != nil)
        guard let b else { return }
        #expect(abs(b.total - 355) < 0.01)
        #expect(abs(b.eventToRead - 40) < 0.01)
        #expect(abs(b.read - 10) < 0.01)
        #expect(abs(b.translate - 300) < 0.01)
        #expect(abs(b.display - 3) < 0.01)
    }
}
