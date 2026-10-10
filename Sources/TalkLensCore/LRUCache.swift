// SPDX-License-Identifier: MIT
// Fixed-capacity in-memory LRU cache. Never persisted (CLAUDE.md privacy rules).

import Foundation

public struct LRUCache<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        var prev: Node?
        var next: Node?
        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    public let capacity: Int
    private var map: [Key: Node] = [:]
    private var head: Node?   // most recently used
    private var tail: Node?   // least recently used

    public init(capacity: Int) {
        precondition(capacity > 0, "LRUCache capacity must be > 0")
        self.capacity = capacity
    }

    public var count: Int { map.count }

    /// Returns the value and marks it most recently used.
    public mutating func get(_ key: Key) -> Value? {
        guard let node = map[key] else { return nil }
        moveToFront(node)
        return node.value
    }

    /// Returns the value without touching recency.
    public func peek(_ key: Key) -> Value? { map[key]?.value }

    public mutating func set(_ key: Key, _ value: Value) {
        if let node = map[key] {
            node.value = value
            moveToFront(node)
            return
        }
        let node = Node(key: key, value: value)
        map[key] = node
        insertFront(node)
        if map.count > capacity, let lru = tail {
            unlink(lru)
            map[lru.key] = nil
        }
    }

    @discardableResult
    public mutating func remove(_ key: Key) -> Value? {
        guard let node = map[key] else { return nil }
        unlink(node)
        map[key] = nil
        return node.value
    }

    public mutating func removeAll() {
        // Break links so nodes are freed promptly.
        var cursor = head
        while let n = cursor {
            cursor = n.next
            n.prev = nil
            n.next = nil
        }
        map.removeAll()
        head = nil
        tail = nil
    }

    /// Keys from most to least recently used (for tests / diagnostics).
    public var keysByRecency: [Key] {
        var out: [Key] = []
        var cursor = head
        while let n = cursor {
            out.append(n.key)
            cursor = n.next
        }
        return out
    }

    private mutating func insertFront(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private mutating func unlink(_ node: Node) {
        if let p = node.prev { p.next = node.next } else { head = node.next }
        if let n = node.next { n.prev = node.prev } else { tail = node.prev }
        node.prev = nil
        node.next = nil
    }

    private mutating func moveToFront(_ node: Node) {
        guard head !== node else { return }
        unlink(node)
        insertFront(node)
    }
}
