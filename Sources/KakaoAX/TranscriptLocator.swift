// Derived from kmsg (https://github.com/channprj/kmsg) @54cbff7 — MIT License, Copyright (c) 2026 Park Hee Chan. Modifications: background-safe subset of MessageContextResolver.swift, generic over AXNodeLike: one budgeted BFS over the chat window finds input candidates and transcript containers; kept the input scoring and the two-phase spatial + child-bonus transcript scoring; the chosen input element is returned with its frame; removed kakao.activate(), focusWithVerification, focused-element lineage, the AXPathCache (memory and disk) and the pane-root/ancestor walk (AXNodeLike has no parent).
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

public struct TranscriptLocation<Node: AXNodeLike> {
    public let transcriptRoot: Node
    public let inputFrame: CGRect?
    public let windowFrame: CGRect?
    /// The message input element whose frame is `inputFrame` (kept so incremental reads can re-validate it).
    public let input: Node?
    public init(transcriptRoot: Node, inputFrame: CGRect?, windowFrame: CGRect?, input: Node? = nil) {
        self.transcriptRoot = transcriptRoot
        self.inputFrame = inputFrame
        self.windowFrame = windowFrame
        self.input = input
    }
}

/// Finds the message input and the transcript container inside a chat window.
/// Read-only: it only inspects attributes and children; it never focuses, scrolls or clicks.
public enum TranscriptLocator {
    /// Upper bound on nodes visited while scanning a window.
    public static let maxVisitedNodes = 3_000

    /// Roles whose subtrees are not scanned for the input field (message rows contain enabled text areas).
    static let transcriptInteriorRoles: Set<String> = [AXRole.row, AXRole.cell, AXRole.table, AXRole.outline, AXRole.list]

    static let containerRoleLimits: [String: Int] = [
        AXRole.scrollArea: 12, AXRole.table: 8, AXRole.outline: 8, AXRole.list: 8, AXRole.group: 10,
    ]

    public static func locate<Node: AXNodeLike>(inWindow window: Node) -> TranscriptLocation<Node>? {
        let scan = scanWindow(window)
        guard let input = pickInput(scan.inputCandidates, windowFrame: window.frame),
              let inputFrame = input.frame,
              let root = pickTranscript(scan.containers, windowFrame: window.frame, inputFrame: inputFrame)
        else { return nil }
        return TranscriptLocation(transcriptRoot: root, inputFrame: inputFrame, windowFrame: window.frame, input: input)
    }

    // MARK: - Scan

    struct Scan<Node: AXNodeLike> {
        var inputCandidates: [Node] = []
        var containers: [Node] = []
        var visited = 0
    }

    static func scanWindow<Node: AXNodeLike>(_ window: Node) -> Scan<Node> {
        var scan = Scan<Node>()
        var containerCounts: [String: Int] = [:]
        var queue = window.children
        var index = 0
        while index < queue.count, scan.visited < maxVisitedNodes {
            let node = queue[index]
            index += 1
            scan.visited += 1
            let role = node.role ?? ""
            if role == AXRole.textArea || role == AXRole.textField {
                if node.isEnabled { scan.inputCandidates.append(node) }
                continue // text views have no interesting descendants
            }
            if let limit = containerRoleLimits[role], containerCounts[role, default: 0] < limit {
                containerCounts[role, default: 0] += 1
                scan.containers.append(node)
            }
            if transcriptInteriorRoles.contains(role) { continue }
            queue.append(contentsOf: node.children)
        }
        return scan
    }

    // MARK: - Input

    static func pickInput<Node: AXNodeLike>(_ candidates: [Node], windowFrame: CGRect?) -> Node? {
        var best: (node: Node, score: Double)?
        for c in candidates {
            guard let s = inputScore(c, windowFrame: windowFrame) else { continue }
            if best == nil || s > best!.score { best = (c, s) }
        }
        return best?.node
    }

    /// nil = not a plausible message input.
    static func inputScore<Node: AXNodeLike>(_ node: Node, windowFrame: CGRect?) -> Double? {
        guard node.isEnabled, let frame = node.frame else { return nil }
        let role = node.role ?? ""
        let roleScore: Double
        switch role {
        case AXRole.textArea: roleScore = 12_000
        case AXRole.textField:
            if isLikelySearchField(node, windowFrame: windowFrame) { return nil }
            roleScore = 9_000
        default: return nil
        }
        var location = 0.0
        if let w = windowFrame {
            if isInsideWindow(frame, w) {
                let relY = (frame.midY - w.minY) / max(w.height, 1)
                location = relY > 0.55 ? 1_500 : 0
            } else {
                location = -6_000
            }
        }
        return roleScore + Double(frame.minY) + Double(frame.height) + location
    }

    static func isLikelySearchField<Node: AXNodeLike>(_ node: Node, windowFrame: CGRect?) -> Bool {
        guard node.role == AXRole.textField else { return false }
        let joined = [node.identifier ?? "", node.title ?? "", node.nodeDescription ?? ""].joined(separator: " ").lowercased()
        if joined.contains("search") || joined.contains("검색") { return true }
        guard let w = windowFrame, let f = node.frame, w.height > 0 else { return false }
        if !isInsideWindow(f, w) { return true }
        return (f.midY - w.minY) / w.height < 0.5
    }

    static func isInsideWindow(_ frame: CGRect, _ window: CGRect) -> Bool {
        window.insetBy(dx: -24, dy: -24).intersects(frame)
    }

    // MARK: - Transcript container

    static func pickTranscript<Node: AXNodeLike>(_ containers: [Node], windowFrame: CGRect?, inputFrame: CGRect) -> Node? {
        guard let windowFrame else { return nil }
        var phase1 = containers.map { (node: $0, score: spatialScore($0, windowFrame: windowFrame, inputFrame: inputFrame)) }
        // Stable sort: ties keep BFS order (outermost first).
        phase1 = phase1.enumerated().sorted { a, b in
            a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset
        }.map(\.element)
        for i in 0..<min(3, phase1.count) where phase1[i].score > 0 {
            phase1[i].score += childBonus(phase1[i].node)
        }
        let scored = phase1.enumerated().sorted { a, b in
            a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset
        }.map(\.element)
        return scored.first(where: { $0.score > 0 })?.node
    }

    /// Phase 1: role and geometry relative to the window and the input box.
    static func spatialScore<Node: AXNodeLike>(_ node: Node, windowFrame: CGRect, inputFrame: CGRect) -> Double {
        guard let f = node.frame else { return -Double.greatestFiniteMagnitude }
        if f.width / max(windowFrame.width, 1) < 0.35 { return -8_000 }
        let overlap = max(0, min(f.maxX, inputFrame.maxX) - max(f.minX, inputFrame.minX))
        let overlapRatio = overlap / max(min(f.width, inputFrame.width), 1)
        if overlapRatio < 0.15 { return -7_000 }

        var score = 0.0
        switch node.role ?? "" {
        case AXRole.scrollArea: score += 4_400
        case AXRole.table: score += 3_600
        case AXRole.list, AXRole.outline: score += 3_000
        case AXRole.group: score += 1_500
        default: break
        }
        score += f.maxY <= inputFrame.minY + 24 ? 1_300 : -2_800
        score += overlapRatio * 2_200
        if (f.midX - windowFrame.minX) / max(windowFrame.width, 1) < 0.35 { score -= 1_600 }
        if f.minY >= inputFrame.minY { score -= 3_000 }
        if f.height > inputFrame.height * 2.2 { score += 320 }
        return score
    }

    /// Phase 2: rows and static texts inside the candidate.
    static func childBonus<Node: AXNodeLike>(_ node: Node) -> Double {
        let found = AXTree.findAll(in: node, roles: [AXRole.row, AXRole.staticText],
                                   roleLimits: [AXRole.row: 20, AXRole.staticText: 20], maxNodes: 240)
        return Double((found[AXRole.row]?.count ?? 0) * 150) + Double((found[AXRole.staticText]?.count ?? 0) * 25)
    }
}
