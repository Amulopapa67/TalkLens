// SPDX-License-Identifier: MIT
// Fixed-capacity in-memory LRU cache. Never persisted (see PRIVACY.md).

import Foundation

/// Doubly linked recency list stored in a dense array with integer links: no class nodes, so no reference
/// cycles (dropping the cache frees every entry without `removeAll()`), and true value semantics (copies are
/// independent, copy-on-write via Array/Dictionary).
public struct LRUCache<Key: Hashable, Value> {
    private struct Entry {
        let key: Key
        var value: Value
        var prev: Int
        var next: Int
    }

    private static var none: Int { -1 }

    public let capacity: Int
    private var map: [Key: Int] = [:]
    private var entries: [Entry] = []
    private var head = LRUCache.none   // most recently used
    private var tail = LRUCache.none   // least recently used

    public init(capacity: Int) {
        precondition(capacity > 0, "LRUCache capacity must be > 0")
        self.capacity = capacity
    }

    public var count: Int { map.count }

    /// Returns the value and marks it most recently used.
    public mutating func get(_ key: Key) -> Value? {
        guard let i = map[key] else { return nil }
        moveToFront(i)
        return entries[i].value
    }

    /// Returns the value without touching recency.
    public func peek(_ key: Key) -> Value? { map[key].map { entries[$0].value } }

    public mutating func set(_ key: Key, _ value: Value) {
        if let i = map[key] {
            entries[i].value = value
            moveToFront(i)
            return
        }
        let i = entries.count
        entries.append(Entry(key: key, value: value, prev: Self.none, next: Self.none))
        map[key] = i
        insertFront(i)
        if map.count > capacity, tail != Self.none {
            removeEntry(at: tail)
        }
    }

    @discardableResult
    public mutating func remove(_ key: Key) -> Value? {
        guard let i = map[key] else { return nil }
        let value = entries[i].value
        removeEntry(at: i)
        return value
    }

    public mutating func removeAll() {
        map.removeAll()
        entries.removeAll()
        head = Self.none
        tail = Self.none
    }

    /// Keys from most to least recently used (for tests / diagnostics).
    public var keysByRecency: [Key] {
        var out: [Key] = []
        out.reserveCapacity(entries.count)
        var cursor = head
        while cursor != Self.none {
            out.append(entries[cursor].key)
            cursor = entries[cursor].next
        }
        return out
    }

    // MARK: - List maintenance

    private mutating func insertFront(_ i: Int) {
        entries[i].prev = Self.none
        entries[i].next = head
        if head != Self.none { entries[head].prev = i }
        head = i
        if tail == Self.none { tail = i }
    }

    private mutating func unlink(_ i: Int) {
        let p = entries[i].prev, n = entries[i].next
        if p != Self.none { entries[p].next = n } else { head = n }
        if n != Self.none { entries[n].prev = p } else { tail = p }
        entries[i].prev = Self.none
        entries[i].next = Self.none
    }

    private mutating func moveToFront(_ i: Int) {
        guard head != i else { return }
        unlink(i)
        insertFront(i)
    }

    /// Unlinks entry `i`, then fills its slot with the last entry (fixing that entry's neighbours and map
    /// index) so the array stays dense and the removed value is released immediately.
    private mutating func removeEntry(at i: Int) {
        unlink(i)
        map[entries[i].key] = nil
        let last = entries.count - 1
        if i != last {
            let moved = entries[last]
            entries[i] = moved
            map[moved.key] = i
            if moved.prev != Self.none { entries[moved.prev].next = i } else { head = i }
            if moved.next != Self.none { entries[moved.next].prev = i } else { tail = i }
        }
        entries.removeLast()
    }
}