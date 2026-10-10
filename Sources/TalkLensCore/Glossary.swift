// SPDX-License-Identifier: MIT
// Glossary loading and longest-match lookup (fixtures/glossary.ko-zh.json format).
// STUB — core-dev: implement and test.

import Foundation

public struct GlossaryEntry: Sendable, Hashable, Codable {
    public var ko: String
    public var zh: String
    public var kind: String?
    /// NSRegularExpression pattern; when nil, `ko` is matched literally.
    public var pattern: String?
    /// Apply only when the whole message is this token.
    public var standaloneOnly: Bool?
    /// Replacement applied before machine translation.
    public var expand: String?

    enum CodingKeys: String, CodingKey {
        case ko, zh, kind, pattern, expand
        case standaloneOnly = "standalone_only"
    }

    public init(ko: String, zh: String, kind: String? = nil, pattern: String? = nil,
                standaloneOnly: Bool? = nil, expand: String? = nil) {
        self.ko = ko
        self.zh = zh
        self.kind = kind
        self.pattern = pattern
        self.standaloneOnly = standaloneOnly
        self.expand = expand
    }
}

public struct Glossary: Sendable {
    public let entries: [GlossaryEntry]

    public init(entries: [GlossaryEntry]) {
        self.entries = entries
    }

    public static let empty = Glossary(entries: [])

    public static func load(from data: Data) throws -> Glossary {
        struct File: Decodable { let entries: [GlossaryEntry] }
        return Glossary(entries: try JSONDecoder().decode(File.self, from: data).entries)
    }

    public static func load(contentsOf url: URL) throws -> Glossary {
        try load(from: Data(contentsOf: url))
    }

    /// Entries of `other` override entries with the same `ko`.
    public func merged(with other: Glossary) -> Glossary {
        var byKey: [String: GlossaryEntry] = [:]
        var order: [String] = []
        for e in entries + other.entries {
            if byKey[e.ko] == nil { order.append(e.ko) }
            byKey[e.ko] = e
        }
        return Glossary(entries: order.compactMap { byKey[$0] })
    }

    /// Chips for all non-overlapping longest matches in `text`, in order of appearance.
    public func chips(in text: String) -> [GlossaryChip] { [] }

    /// `text` with `expand` replacements applied.
    public func expand(_ text: String) -> String { text }

    /// Gloss for a message that consists of a single standalone token (e.g. "ㅇㅇ"), if any.
    public func standaloneNote(for text: String) -> String? { nil }
}
