// SPDX-License-Identifier: MIT
// Prefetch band and per-read analysis budget of TranscriptRowCache (D-020): reads must never analyse many
// off-screen rows at once, and rows far from the viewport are never touched.

import CoreGraphics
import Foundation
import Testing
@testable import KakaoAX
import TalkLensCore

@Suite("KakaoAX.IncrementalReadBudget")
struct IncrementalReadBudgetTests {
    let parser = TranscriptParser(referenceYear: 2026)
    let t0 = ContinuousClock.now

    @Test("a read analyses at most maxAnalysesPerRead rows and reports the rest as pending")
    func budgetIsRespected() throws {
        let file = try Fixture.load("synthetic_200rows")
        let world = FakeWorld()
        let root = FakeAXNode.load(file.root, into: world)
        let cache = TranscriptRowCache<FakeAXNode>(maxAnalysesPerRead: 5, prefetchViewports: 1_000_000)
        let first = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0)
        #expect(first.rowsAnalyzed == 5)
        #expect(first.rowsPending == first.rowsTotal - 5)
    }

    @Test("on-screen rows are analysed before off-screen rows")
    func visibleFirst() throws {
        let file = try Fixture.load("synthetic_200rows")
        let world = FakeWorld()
        let root = FakeAXNode.load(file.root, into: world)
        let cache = TranscriptRowCache<FakeAXNode>(maxAnalysesPerRead: 8, prefetchViewports: 1_000_000)
        let first = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0)
        #expect(!first.visibleIDs.isEmpty)
        // Every emitted message after one budgeted read is on screen (the budget went to visible rows).
        for m in first.snapshot.messages { #expect(first.visibleIDs.contains(m.id)) }
    }

    @Test("follow-up reads drain the pending rows")
    func followUpsDrain() throws {
        let file = try Fixture.load("synthetic_200rows")
        let world = FakeWorld()
        let root = FakeAXNode.load(file.root, into: world)
        let cache = TranscriptRowCache<FakeAXNode>(maxAnalysesPerRead: 40, prefetchViewports: 1_000_000)
        var read = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0)
        var rounds = 1
        while read.rowsPending > 0 && rounds < 50 {
            read = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser,
                                            now: t0 + .milliseconds(10 * rounds))
            rounds += 1
        }
        #expect(read.rowsPending == 0)
        #expect(rounds > 1)
        #expect(read.rowsAnalyzed == 0 || rounds < 50)
    }

    @Test("rows outside the prefetch band are never analysed")
    func bandLimitsAnalysis() throws {
        let file = try Fixture.load("synthetic_200rows")
        let world = FakeWorld()
        let root = FakeAXNode.load(file.root, into: world)
        let cache = TranscriptRowCache<FakeAXNode>(maxAnalysesPerRead: Int.max, prefetchViewports: 1)
        var read = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0)
        while read.rowsPending > 0 {
            read = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0)
        }
        #expect(read.rowsTotal > 100)
        #expect(cache.cachedRowCount < read.rowsTotal / 2)
        // Everything on screen is there.
        #expect(!read.visibleIDs.isEmpty)
        #expect(read.visibleIDs.isSubset(of: Set(read.snapshot.messages.map(\.id))))
    }

    @Test("deferred rows are not re-queried on the next read")
    func deferredRowsAreNotRequeried() throws {
        let file = try Fixture.load("synthetic_200rows")
        let world = FakeWorld()
        let root = FakeAXNode.load(file.root, into: world)
        let cache = TranscriptRowCache<FakeAXNode>(maxAnalysesPerRead: Int.max, prefetchViewports: 1)
        _ = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0)
        world.resetCounters()
        let second = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser,
                                              now: t0 + .milliseconds(100))
        #expect(second.rowsAnalyzed == 0)
        #expect(world.childrenReads.filter { $0.key.hasPrefix("w/0/0/") }.values.reduce(0, +) == 0)
    }
}
