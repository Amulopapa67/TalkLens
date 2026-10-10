// SPDX-License-Identifier: MIT
// AXNodeLike backed by a recorded .axjson fixture (docs/architecture.md §8).
// Frames are encoded as [x, y, w, h] in AX global coordinates. nil attributes and empty children are omitted.

import CoreGraphics
import Foundation

public struct RecordedAXNode: AXNodeLike, Codable, Sendable, Hashable {
    public var role: String?
    public var subrole: String?
    public var identifier: String?
    public var title: String?
    public var value: String?
    public var nodeDescription: String?
    public var help: String?
    public var rect: AXRectArray?
    public var enabled: Bool?
    public var children: [RecordedAXNode]

    public var frame: CGRect? { rect?.cgRect }
    public var isEnabled: Bool { enabled ?? true }

    enum CodingKeys: String, CodingKey {
        case role, subrole, identifier, title, value, help, children, enabled
        case nodeDescription = "description"
        case rect = "frame"
    }

    public init(role: String?, subrole: String? = nil, identifier: String? = nil, title: String? = nil,
                value: String? = nil, nodeDescription: String? = nil, help: String? = nil,
                frame: CGRect? = nil, enabled: Bool? = nil, children: [RecordedAXNode] = []) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.value = value
        self.nodeDescription = nodeDescription
        self.help = help
        self.rect = frame.map(AXRectArray.init)
        self.enabled = enabled
        self.children = children
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        subrole = try c.decodeIfPresent(String.self, forKey: .subrole)
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        nodeDescription = try c.decodeIfPresent(String.self, forKey: .nodeDescription)
        help = try c.decodeIfPresent(String.self, forKey: .help)
        rect = try c.decodeIfPresent(AXRectArray.self, forKey: .rect)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        children = try c.decodeIfPresent([RecordedAXNode].self, forKey: .children) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(role, forKey: .role)
        try c.encodeIfPresent(subrole, forKey: .subrole)
        try c.encodeIfPresent(identifier, forKey: .identifier)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(nodeDescription, forKey: .nodeDescription)
        try c.encodeIfPresent(help, forKey: .help)
        try c.encodeIfPresent(rect, forKey: .rect)
        try c.encodeIfPresent(enabled, forKey: .enabled)
        if !children.isEmpty { try c.encode(children, forKey: .children) }
    }

    /// Total number of nodes in this subtree (self included).
    public var nodeCount: Int { 1 + children.reduce(0) { $0 + $1.nodeCount } }
}

/// [x, y, w, h] JSON array.
public struct AXRectArray: Codable, Sendable, Hashable {
    public var x, y, w, h: Double
    public init(_ r: CGRect) {
        x = Double(r.minX); y = Double(r.minY); w = Double(r.width); h = Double(r.height)
    }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self); y = try c.decode(Double.self)
        w = try c.decode(Double.self); h = try c.decode(Double.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x); try c.encode(y); try c.encode(w); try c.encode(h)
    }
}

/// Whole .axjson file.
public struct AXSnapshotFile: Codable, Sendable {
    public struct Meta: Codable, Sendable, Hashable {
        /// "self-chat" (allowlisted 나와의 채팅), "synthetic" (hand-built), or "redacted-live"
        /// (a redacted live recording — must never be committed to fixtures/snapshots).
        public var source: String
        public var kakaoVersion: String?
        public var macOS: String?
        public var recordedAt: String?
        public var note: String?
        public init(source: String, kakaoVersion: String? = nil, macOS: String? = nil,
                    recordedAt: String? = nil, note: String? = nil) {
            self.source = source
            self.kakaoVersion = kakaoVersion
            self.macOS = macOS
            self.recordedAt = recordedAt
            self.note = note
        }
    }
    public struct Window: Codable, Sendable, Hashable {
        public var title: String
        public var frame: AXRectArray?
        public init(title: String, frame: AXRectArray?) {
            self.title = title
            self.frame = frame
        }
    }
    public var meta: Meta
    public var window: Window
    /// The chat window's AX subtree (role AXWindow), so the transcript locator also runs on fixtures.
    public var root: RecordedAXNode

    public init(meta: Meta, window: Window, root: RecordedAXNode) {
        self.meta = meta
        self.window = window
        self.root = root
    }

    public static func load(contentsOf url: URL) throws -> AXSnapshotFile {
        try JSONDecoder().decode(AXSnapshotFile.self, from: Data(contentsOf: url))
    }

    /// Sorted-key JSON with a trailing newline. `pretty: false` keeps large fixtures compact.
    public func encoded(pretty: Bool = true) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                                      : [.sortedKeys, .withoutEscapingSlashes]
        var data = try enc.encode(self)
        data.append(0x0A)
        return data
    }

    /// Year of `meta.recordedAt` ("2026-10-10T…"), used as the parser's reference year.
    public var recordedYear: Int? {
        guard let s = meta.recordedAt, s.count >= 4, let y = Int(s.prefix(4)), (1900...2999).contains(y) else { return nil }
        return y
    }
}
