// SPDX-License-Identifier: MIT

import Testing
@testable import TalkLensCore

@Suite struct LRUCacheTests {
    @Test func evictsLeastRecentlyUsed() {
        var c = LRUCache<String, Int>(capacity: 2)
        c.set("a", 1)
        c.set("b", 2)
        #expect(c.get("a") == 1)       // a becomes most recent
        c.set("c", 3)                  // evicts b
        #expect(c.peek("b") == nil)
        #expect(c.keysByRecency == ["c", "a"])
        #expect(c.count == 2)
    }

    @Test func updateRefreshesRecencyWithoutGrowing() {
        var c = LRUCache<String, Int>(capacity: 3)
        c.set("a", 1); c.set("b", 2); c.set("c", 3)
        c.set("a", 10)
        #expect(c.count == 3)
        #expect(c.keysByRecency == ["a", "c", "b"])
        c.set("d", 4)                  // evicts b, the LRU
        #expect(c.peek("b") == nil)
        #expect(c.peek("a") == 10)
    }

    @Test func peekDoesNotTouchRecency() {
        var c = LRUCache<String, Int>(capacity: 2)
        c.set("a", 1); c.set("b", 2)
        #expect(c.peek("a") == 1)
        c.set("c", 3)                  // a is still LRU
        #expect(c.peek("a") == nil)
    }

    @Test func removeAndRemoveAll() {
        var c = LRUCache<Int, String>(capacity: 4)
        for i in 0..<4 { c.set(i, "v\(i)") }
        #expect(c.remove(2) == "v2")
        #expect(c.remove(2) == nil)
        #expect(c.keysByRecency == [3, 1, 0])
        #expect(c.remove(3) == "v3")   // head
        #expect(c.remove(0) == "v0")   // tail
        #expect(c.keysByRecency == [1])
        c.removeAll()
        #expect(c.count == 0)
        #expect(c.keysByRecency.isEmpty)
        c.set(9, "x")
        #expect(c.get(9) == "x")
    }

    @Test func capacityOneAndMissingKeys() {
        var c = LRUCache<String, Int>(capacity: 1)
        #expect(c.get("nope") == nil)
        c.set("a", 1); c.set("b", 2)
        #expect(c.keysByRecency == ["b"])
        #expect(c.capacity == 1)
    }
}

@Suite struct LatencyStatsTests {
    @Test func nearestRankPercentiles() {
        let s = LatencyStats((1...100).map(Double.init))
        #expect(s.count == 100)
        #expect(s.p50 == 50)
        #expect(s.p95 == 95)
        #expect(s.max == 100)
        #expect(s.mean == 50.5)
    }

    @Test func emptyAndUnsortedInput() {
        let e = LatencyStats([])
        #expect(e.count == 0 && e.p50 == 0 && e.p95 == 0 && e.max == 0 && e.mean == 0)
        let s = LatencyStats([5, 1, 3])
        #expect(s.p50 == 3)
        #expect(s.p95 == 5)
        #expect(LatencyStats.percentile([1, 2], 0) == 1)
    }

    @Test func summaryFormatsMilliseconds() {
        #expect(LatencyStats([1, 2]).summary == "n=2 p50=1.00ms p95=2.00ms max=2.00ms")
    }

    @Test func stopwatchIsMonotonic() {
        let sw = Stopwatch()
        let a = sw.elapsedMilliseconds
        let b = sw.elapsedMilliseconds
        #expect(a >= 0 && b >= a)
    }
}
