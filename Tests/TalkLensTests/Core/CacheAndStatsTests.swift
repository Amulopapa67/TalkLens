// SPDX-License-Identifier: MIT

import Foundation
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

    // MARK: memory

    @Test func droppedCacheReleasesAllValues() {
        let counter = DeinitCounter()
        let n = 500
        do {
            var c = LRUCache<Int, Tracked>(capacity: n)
            for i in 0..<n { c.set(i, Tracked(counter)) }
            // Shuffle recency so the list order differs from insertion order.
            for i in stride(from: 0, to: n, by: 3) { _ = c.get(i) }
            #expect(c.remove(7) != nil)
            #expect(c.count == n - 1)
        } // dropped without removeAll()
        #expect(counter.count == n)
    }

    @Test func evictedRemovedAndReplacedValuesAreReleasedImmediately() {
        let counter = DeinitCounter()
        var c = LRUCache<Int, Tracked>(capacity: 2)
        c.set(1, Tracked(counter)); c.set(2, Tracked(counter)); c.set(3, Tracked(counter))
        #expect(counter.count == 1)          // 1 was evicted
        _ = c.remove(2)
        #expect(counter.count == 2)
        c.set(3, Tracked(counter))           // replacing a value releases the old one
        #expect(counter.count == 3)
        #expect(c.keysByRecency == [3])
    }

    @Test func copiesAreIndependent() {
        var a = LRUCache<String, Int>(capacity: 3)
        a.set("x", 1); a.set("y", 2)
        var b = a
        b.set("z", 3)
        _ = b.get("x")
        #expect(a.keysByRecency == ["y", "x"])
        #expect(b.keysByRecency == ["x", "z", "y"])
        #expect(a.peek("z") == nil)
    }

    @Test func randomizedOperationsMatchReferenceModel() {
        var c = LRUCache<Int, Int>(capacity: 8)
        var model: [(key: Int, value: Int)] = [] // most recent first
        var mismatches = 0
        for step in 0..<2_000 {
            let k = Int.random(in: 0..<20)
            switch Int.random(in: 0..<4) {
            case 0, 1:
                c.set(k, step)
                model.removeAll { $0.key == k }
                model.insert((k, step), at: 0)
                if model.count > 8 { model.removeLast() }
            case 2:
                let v = c.get(k)
                if let i = model.firstIndex(where: { $0.key == k }) {
                    let e = model.remove(at: i)
                    model.insert(e, at: 0)
                    if v != e.value { mismatches += 1 }
                } else if v != nil {
                    mismatches += 1
                }
            default:
                let v = c.remove(k)
                let i = model.firstIndex { $0.key == k }
                if v != i.map({ model[$0].value }) { mismatches += 1 }
                if let i { model.remove(at: i) }
            }
            if c.keysByRecency != model.map(\.key) || c.count != model.count { mismatches += 1 }
        }
        #expect(mismatches == 0)
    }
}

/// Counts deinits of `Tracked` values (leak tests).
final class DeinitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

final class Tracked {
    let counter: DeinitCounter
    init(_ counter: DeinitCounter) { self.counter = counter }
    deinit { counter.increment() }
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
