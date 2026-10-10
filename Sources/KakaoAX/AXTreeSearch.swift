// Derived from kmsg (https://github.com/channprj/kmsg) @54cbff7 — MIT License, Copyright (c) 2026 Park Hee Chan. Modifications: the breadth-first search helpers of UIElement.swift rewritten as free generic functions over AXNodeLike, with mandatory node budgets and an optional "do not descend" predicate.
// SPDX-License-Identifier: MIT

import Foundation

public enum AXTree {
    /// Descendants of `root` (root excluded) matching `predicate`, breadth-first, with early termination.
    /// `descend` decides whether the children of a visited node are explored.
    public static func findAll<Node: AXNodeLike>(
        in root: Node,
        limit: Int = .max,
        maxNodes: Int,
        descend: (Node) -> Bool = { _ in true },
        where predicate: (Node) -> Bool
    ) -> [Node] {
        var results: [Node] = []
        var queue = root.children
        var index = 0
        var visited = 0
        while index < queue.count, results.count < limit, visited < maxNodes {
            let current = queue[index]
            index += 1
            visited += 1
            if predicate(current) {
                results.append(current)
                if results.count >= limit { break }
            }
            if visited >= maxNodes { break }
            if descend(current) { queue.append(contentsOf: current.children) }
        }
        return results
    }

    /// First descendant matching `predicate` (breadth-first), or nil.
    public static func findFirst<Node: AXNodeLike>(
        in root: Node, maxNodes: Int, where predicate: (Node) -> Bool
    ) -> Node? {
        findAll(in: root, limit: 1, maxNodes: maxNodes, where: predicate).first
    }

    /// Elements matching any of `roles` in a single BFS pass, with per-role limits.
    public static func findAll<Node: AXNodeLike>(
        in root: Node,
        roles: Set<String>,
        roleLimits: [String: Int] = [:],
        maxNodes: Int,
        descend: (Node) -> Bool = { _ in true }
    ) -> [String: [Node]] {
        var results: [String: [Node]] = [:]
        for role in roles { results[role] = [] }
        var saturated = 0
        var queue = root.children
        var index = 0
        var visited = 0
        while index < queue.count, visited < maxNodes, saturated < roles.count {
            let current = queue[index]
            index += 1
            visited += 1
            if let role = current.role, roles.contains(role) {
                let limit = roleLimits[role] ?? .max
                if results[role, default: []].count < limit {
                    results[role, default: []].append(current)
                    if results[role, default: []].count >= limit { saturated += 1 }
                }
            }
            if saturated < roles.count, visited < maxNodes, descend(current) {
                queue.append(contentsOf: current.children)
            }
        }
        return results
    }
}
