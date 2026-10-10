// SPDX-License-Identifier: MIT
// Glossary loading and leftmost-longest lookup (fixtures/glossary.ko-zh.json format).

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

    public var isStandaloneOnly: Bool { standaloneOnly ?? false }
}

/// Precompiled matchers for a list of entries. Immutable after init, hence safe to share.
final class GlossaryMatcher: @unchecked Sendable {
    struct Compiled {
        let entry: GlossaryEntry
        let index: Int
        /// nil → literal match on `entry.ko` (also the fallback for an invalid pattern).
        let regex: CompiledRegex?
    }

    struct Match {
        let range: NSRange
        let compiled: Compiled
    }

    let inline: [Compiled]       // matched anywhere in the text
    let standalone: [Compiled]   // matched only against the whole (trimmed) message

    init(entries: [GlossaryEntry]) {
        var inline: [Compiled] = []
        var standalone: [Compiled] = []
        for (i, e) in entries.enumerated() where !e.ko.isEmpty || !(e.pattern ?? "").isEmpty {
            let regex = e.pattern.flatMap { $0.isEmpty ? nil : CompiledRegex.compile($0) }
            let c = Compiled(entry: e, index: i, regex: regex)
            if e.isStandaloneOnly { standalone.append(c) } else { inline.append(c) }
        }
        self.inline = inline
        self.standalone = standalone
    }

    /// Characters trimmed from a message before standalone comparison: whitespace plus light trailing
    /// punctuation ("ㅇㅇ~", "ㅂㅂ!").
    private static let standaloneTrim = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "~!.?…"))

    static func standaloneCore(_ text: String) -> String {
        text.trimmingCharacters(in: standaloneTrim)
    }

    /// First standalone entry that covers the whole trimmed message.
    func standaloneMatch(_ text: String) -> Compiled? {
        guard !standalone.isEmpty else { return nil }
        let core = Self.standaloneCore(text)
        guard !core.isEmpty else { return nil }
        for c in standalone {
            if let r = c.regex {
                if r.matchesWhole(core) { return c }
            } else if core == c.entry.ko {
                return c
            }
        }
        return nil
    }

    /// Non-overlapping inline matches, chosen leftmost-longest (ties → earlier entry), in text order.
    func inlineMatches(_ text: String) -> [Match] {
        guard !inline.isEmpty, !text.isEmpty else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        // Cheap prefilter for literal entries: skip those whose first UTF-16 unit is absent from the text.
        var units = Set<UInt16>(minimumCapacity: min(ns.length, 256))
        for u in text.utf16 { units.insert(u) }
        var candidates: [Match] = []
        for c in inline {
            if c.regex == nil, let first = c.entry.ko.utf16.first, !units.contains(first) { continue }
            if let r = c.regex {
                for m in r.regex.matches(in: text, range: full) where m.range.length > 0 {
                    candidates.append(Match(range: m.range, compiled: c))
                }
            } else {
                var search = full
                while search.length > 0 {
                    let found = ns.range(of: c.entry.ko, options: [.literal], range: search)
                    if found.location == NSNotFound || found.length == 0 { break }
                    candidates.append(Match(range: found, compiled: c))
                    let next = found.location + found.length
                    search = NSRange(location: next, length: full.length - next)
                }
            }
        }
        guard !candidates.isEmpty else { return [] }
        candidates.sort { a, b in
            if a.range.location != b.range.location { return a.range.location < b.range.location }
            if a.range.length != b.range.length { return a.range.length > b.range.length }
            return a.compiled.index < b.compiled.index
        }
        var out: [Match] = []
        var cursor = 0
        for m in candidates where m.range.location >= cursor {
            out.append(m)
            cursor = m.range.location + m.range.length
        }
        return out
    }
}

public struct Glossary: Sendable {
    public let entries: [GlossaryEntry]
    private let matcher: GlossaryMatcher

    public init(entries: [GlossaryEntry]) {
        self.entries = entries
        self.matcher = GlossaryMatcher(entries: entries)
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

    /// Chips for all non-overlapping leftmost-longest matches in `text`, in order of appearance,
    /// de-duplicated by term (`ko`). A `standalone_only` entry yields a chip only when the whole trimmed
    /// message is that token (and then it is the only chip).
    public func chips(in text: String) -> [GlossaryChip] {
        if let s = matcher.standaloneMatch(text) {
            return [chip(s.entry)]
        }
        var seen = Set<String>()
        var out: [GlossaryChip] = []
        for m in matcher.inlineMatches(text) where seen.insert(m.compiled.entry.ko).inserted {
            out.append(chip(m.compiled.entry))
        }
        return out
    }

    /// `text` with `expand` replacements applied (standalone entries only when they cover the whole text).
    public func expand(_ text: String) -> String {
        if let s = matcher.standaloneMatch(text) {
            return s.entry.expand ?? text
        }
        return expandInline(text)
    }

    /// Inline-only expansion, for pieces of a larger message (standalone entries never apply).
    func expandInline(_ text: String) -> String {
        let matches = matcher.inlineMatches(text).filter { $0.compiled.entry.expand != nil }
        guard !matches.isEmpty else { return text }
        let out = NSMutableString(string: text)
        for m in matches.reversed() {
            out.replaceCharacters(in: m.range, with: m.compiled.entry.expand ?? "")
        }
        return out as String
    }

    /// Gloss for a message that consists of a single standalone token (e.g. "ㅇㅇ"), if any.
    public func standaloneNote(for text: String) -> String? {
        matcher.standaloneMatch(text)?.entry.zh
    }

    private func chip(_ e: GlossaryEntry) -> GlossaryChip {
        GlossaryChip(term: e.ko, gloss: e.zh, kind: e.kind)
    }
}
