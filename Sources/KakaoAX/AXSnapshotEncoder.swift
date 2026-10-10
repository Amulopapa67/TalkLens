// SPDX-License-Identifier: MIT
// Turns any AXNodeLike subtree into a RecordedAXNode (for `tlctl record`), applying a text transform to every
// string attribute (including AXIdentifier) and bounding depth and node count. The transform is how redaction
// is enforced.

import CoreGraphics
import Foundation
import TalkLensCore

/// String attributes that can carry user-visible text. `identifier` is usually a developer id ("_NS:29"),
/// but nothing guarantees that, so it goes through the same transform.
public enum AXTextAttribute: String, Sendable, CaseIterable {
    case title, value, description, help, identifier
}

public struct AXSnapshotEncoder {
    public var maxDepth: Int
    public var maxNodes: Int
    /// Applied to every non-nil text attribute; return nil to drop the attribute.
    public var transform: (AXTextAttribute, String) -> String?

    public init(maxDepth: Int = 40, maxNodes: Int = 8_000,
                transform: @escaping (AXTextAttribute, String) -> String?) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.transform = transform
    }

    public struct Result {
        public let root: RecordedAXNode
        public let nodeCount: Int
        /// True when depth or node limits cut the tree.
        public let truncated: Bool
    }

    public func encode<Node: AXNodeLike>(_ root: Node) -> Result {
        var count = 0
        var truncated = false
        let rec = encodeNode(root, depth: 0, count: &count, truncated: &truncated)
        return Result(root: rec, nodeCount: count, truncated: truncated)
    }

    private func encodeNode<Node: AXNodeLike>(_ node: Node, depth: Int, count: inout Int, truncated: inout Bool) -> RecordedAXNode {
        count += 1
        var kids: [RecordedAXNode] = []
        if depth < maxDepth {
            for child in node.children {
                if count >= maxNodes { truncated = true; break }
                kids.append(encodeNode(child, depth: depth + 1, count: &count, truncated: &truncated))
            }
        } else if !node.children.isEmpty {
            truncated = true
        }
        return RecordedAXNode(
            role: node.role,
            subrole: node.subrole,
            identifier: node.identifier.flatMap { transform(.identifier, $0) },
            title: node.title.flatMap { transform(.title, $0) },
            value: node.value.flatMap { transform(.value, $0) },
            nodeDescription: node.nodeDescription.flatMap { transform(.description, $0) },
            help: node.help.flatMap { transform(.help, $0) },
            frame: node.frame,
            enabled: node.isEnabled ? nil : false,
            children: kids)
    }
}

/// What `tlctl record` may store for a given window (pure; unit-tested).
public enum RecordPolicy: Equatable, Sendable {
    /// Allowlisted self-chat: raw text kept, but the real window title is never stored.
    case selfChat(title: String)
    /// Everything else: every text attribute goes through Redactor.
    case redacted

    public static let selfChatPlaceholder = "<self-chat>"

    public static func decide(config: DevConfig, windowTitle: String, requestedTitle: String?) -> RecordPolicy {
        config.allowsText(windowTitle: windowTitle, requested: requestedTitle) ? .selfChat(title: windowTitle) : .redacted
    }

    public var source: String {
        switch self {
        case .selfChat: return "self-chat"
        case .redacted: return "redacted-live"
        }
    }

    public var storesRawText: Bool {
        if case .selfChat = self { return true }
        return false
    }

    /// Title written to `window.title`.
    public func storedWindowTitle(_ title: String) -> String {
        switch self {
        case .selfChat: return RecordPolicy.selfChatPlaceholder
        case .redacted: return Redactor.redactTitle(title)
        }
    }

    /// Text transform for AXSnapshotEncoder.
    public func transform(_ attribute: AXTextAttribute, _ text: String) -> String? {
        switch self {
        case .selfChat(let title):
            // The self-chat's title (the owner's nickname) is replaced wherever it appears verbatim.
            return text == title ? RecordPolicy.selfChatPlaceholder : text
        case .redacted:
            if attribute == .identifier, RecordPolicy.isStructuralIdentifier(text) { return text }
            return Redactor.redact(text)
        }
    }

    /// Developer identifiers that carry no user content and that the locator / chat-window heuristics rely on:
    /// AppKit's "_NS:<n>", table column ids, KakaoTalk's "Count Label", main-window navigation ids.
    public static func isStructuralIdentifier(_ id: String) -> Bool {
        if structuralIdentifiers.contains(id) { return true }
        for prefix in ["_NS:", "AutomaticTableColumnIdentifier."] where id.hasPrefix(prefix) {
            let rest = id.dropFirst(prefix.count)
            return !rest.isEmpty && rest.allSatisfy { $0.isASCII && $0.isNumber }
        }
        return false
    }

    static let structuralIdentifiers: Set<String> =
        KakaoChatReader.mainWindowNavigationIdentifiers.union(["Main Window", "Count Label"])
}
