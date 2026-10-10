// SPDX-License-Identifier: MIT
// Pure helpers behind the tlctl developer CLI (kept here so they are unit-testable): argument parsing,
// replay rendering (snapshot → parse → identity → preprocess → mock translation → JSON), golden diffs and
// run-scoped correlation tags.

import CryptoKit
import Foundation
import TalkLensCore

// MARK: - Correlation tags

/// Short correlation tags for live CLI output (`tlctl probe`): HMAC-SHA256 under a random key that lives only
/// for this process, truncated to 6 hex chars. Equal inputs get equal tags within one run, but a tag cannot be
/// reversed by hashing a dictionary of likely names (unlike a plain SHA-256 prefix) and does not correlate
/// across runs. The key is never printed or stored.
public struct RunScopedTagger: Sendable {
    private let key: SymmetricKey

    /// Fresh random 256-bit key.
    public init() {
        key = SymmetricKey(size: .bits256)
    }

    /// Fixed key (tests only).
    init(key: Data) {
        self.key = SymmetricKey(data: key)
    }

    public func tag(_ text: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)
        return mac.prefix(3).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Arguments

public struct CLIArguments: Equatable, Sendable {
    public var positionals: [String] = []
    public var options: [String: String] = [:]
    public var flags: Set<String> = []

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknownOption(String)
        case missingValue(String)

        public var description: String {
            switch self {
            case .unknownOption(let o): return "unknown option \(o)"
            case .missingValue(let o): return "option \(o) needs a value"
            }
        }
    }

    public init() {}

    /// `valueOptions` take one value (`--out F` or `--out=F`); `flags` take none. Names include the dashes.
    public static func parse(_ args: [String], valueOptions: Set<String>, flags: Set<String>) throws -> CLIArguments {
        var out = CLIArguments()
        var i = 0
        while i < args.count {
            let a = args[i]
            i += 1
            guard a.hasPrefix("--"), a.count > 2 else {
                out.positionals.append(a)
                continue
            }
            if let eq = a.firstIndex(of: "=") {
                let name = String(a[..<eq])
                guard valueOptions.contains(name) else { throw ParseError.unknownOption(name) }
                out.options[name] = String(a[a.index(after: eq)...])
            } else if valueOptions.contains(a) {
                guard i < args.count, !args[i].hasPrefix("--") else { throw ParseError.missingValue(a) }
                out.options[a] = args[i]
                i += 1
            } else if flags.contains(a) {
                out.flags.insert(a)
            } else {
                throw ParseError.unknownOption(a)
            }
        }
        return out
    }

    public func int(_ name: String) -> Int? { options[name].flatMap { Int($0) } }
    public func has(_ flag: String) -> Bool { flags.contains(flag) }
}

// MARK: - Replay

public enum ReplayError: Error, Equatable, CustomStringConvertible {
    case transcriptNotFound
    public var description: String { "transcript not found" }
}

public struct ReplayOutput: Encodable {
    public struct Attachments: Encodable, Equatable {
        public let images: Int
        public let links: Int
        public let files: Int
    }
    public struct Chip: Encodable, Equatable {
        public let term: String
        public let gloss: String
    }
    public struct Message: Encodable {
        public let id: String
        public let author: String?
        public let isMine: Bool
        public let isSystem: Bool
        public let timeRaw: String?
        public let date: String?
        public let body: String
        public let attachments: Attachments
        public let kind: String
        public let chips: [Chip]
        public let note: String?
        public let translation: String?

        enum CodingKeys: String, CodingKey {
            case id, author, isMine, isSystem, timeRaw, date, body, attachments, kind, chips, note, translation
        }

        // Explicit nulls keep every message object the same shape in golden files.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(author, forKey: .author)
            try c.encode(isMine, forKey: .isMine)
            try c.encode(isSystem, forKey: .isSystem)
            try c.encode(timeRaw, forKey: .timeRaw)
            try c.encode(date, forKey: .date)
            try c.encode(body, forKey: .body)
            try c.encode(attachments, forKey: .attachments)
            try c.encode(kind, forKey: .kind)
            try c.encode(chips, forKey: .chips)
            try c.encode(note, forKey: .note)
            try c.encode(translation, forKey: .translation)
        }
    }

    public let snapshot: String
    public let source: String
    public let messages: [Message]
}

public enum ReplayRenderer {
    /// Parses one recorded snapshot and renders the replay output.
    /// `translate` maps one MT segment to its translation (MockEngine in tlctl).
    public static func render(name: String, file: AXSnapshotFile, glossary: Glossary, targetLanguage: String = "zh-Hans",
                              parser: TranscriptParser? = nil, translate: (String) -> String) throws -> ReplayOutput {
        let p = parser ?? TranscriptParser(referenceYear: file.recordedYear ?? 2026)
        guard let parsed = p.parse(window: file.root) else { throw ReplayError.transcriptNotFound }
        let messages = MessageIdentity.assign(parsed, chatKey: MessageIdentity.chatKey(forTitle: file.window.title))
        let pre = ChatPreprocessor(glossary: glossary, targetLanguage: targetLanguage)
        let out: [ReplayOutput.Message] = messages.map { m in
            let pm = pre.process(m)
            let translation: String? = pm.kind == .translate
                ? pm.assemble(translations: pm.translatableTexts.map(translate)) : nil
            return ReplayOutput.Message(
                id: m.id.rawValue, author: m.author, isMine: m.isMine, isSystem: m.isSystem, timeRaw: m.timeRaw,
                date: m.date, body: m.body,
                attachments: .init(images: m.attachments.images, links: m.attachments.links, files: m.attachments.files),
                kind: pm.kind.rawValue, chips: pm.chips.map { .init(term: $0.term, gloss: $0.gloss) },
                note: pm.note, translation: translation)
        }
        return ReplayOutput(snapshot: name, source: file.meta.source, messages: out)
    }

    /// Pretty-printed, sorted-key JSON with a trailing newline.
    public static func encode(_ output: ReplayOutput) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try enc.encode(output)
        data.append(0x0A)
        return data
    }
}

// MARK: - Golden diff

public enum GoldenDiff {
    /// A short unified-style excerpt around the first differing line; empty when equal.
    public static func firstDifferences(expected: String, actual: String, context: Int = 2, maxLines: Int = 14) -> [String] {
        guard expected != actual else { return [] }
        let e = expected.components(separatedBy: "\n")
        let a = actual.components(separatedBy: "\n")
        var first = 0
        while first < e.count, first < a.count, e[first] == a[first] { first += 1 }
        // Common suffix (to bound the changed region).
        var ee = e.count - 1, aa = a.count - 1
        while ee >= first, aa >= first, e[ee] == a[aa] { ee -= 1; aa -= 1 }
        var out = ["@@ line \(first + 1) @@"]
        for i in max(0, first - context)..<first { out.append("  " + e[i]) }
        if ee >= first { for i in first...ee { out.append("- " + e[i]) } }
        if aa >= first { for i in first...aa { out.append("+ " + a[i]) } }
        if out.count > maxLines { out = Array(out.prefix(maxLines)) + ["… (\(out.count - maxLines) more line(s))"] }
        return out
    }
}
