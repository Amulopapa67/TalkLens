// SPDX-License-Identifier: MIT
// Normalization, classification, segmentation and glossary annotation (docs/architecture.md §4.4).

import Foundation
import NaturalLanguage

public struct ChatPreprocessor: Sendable {
    public let glossary: Glossary
    /// BCP-47 target language, e.g. "zh-Hans", "en", "ja".
    public let targetLanguage: String
    public let glossaryEnabled: Bool
    /// Max characters per `translate` segment.
    public let maxSegmentLength: Int

    /// Minimum share of letter-bearing words that contain Hangul syllables for a message to count as Korean
    /// without asking NLLanguageRecognizer.
    public static let hangulShareThreshold = 0.3

    public init(glossary: Glossary, targetLanguage: String = "zh-Hans", glossaryEnabled: Bool = true,
                maxSegmentLength: Int = 1000) {
        self.glossary = glossary
        self.targetLanguage = targetLanguage
        self.glossaryEnabled = glossaryEnabled
        self.maxSegmentLength = max(1, maxSegmentLength)
    }

    // MARK: - Public API

    public func process(_ message: ChatMessage) -> PreprocessedMessage {
        if message.isSystem {
            return result(message, .system)
        }
        let normalized = Self.normalize(message.body)
        let kind = classify(normalized: normalized)
        let chips: [GlossaryChip]
        switch kind {
        case .system, .empty, .urlOnly:
            chips = []
        default:
            chips = glossaryEnabled ? glossary.chips(in: normalized) : []
        }
        switch kind {
        case .translate:
            let segments = makeSegments(normalized)
            let textForMT = segments.map { seg -> String in
                switch seg {
                case .keep(let s), .translate(let s): return s
                }
            }.joined()
            return PreprocessedMessage(message: message, kind: .translate, textForMT: textForMT,
                                       segments: segments, chips: chips, note: nil)
        case .jamoOnly:
            let note = chips.isEmpty ? nil : chips.map(\.gloss).joined(separator: " · ")
            return result(message, .jamoOnly, chips: chips, note: note)
        default:
            return result(message, kind, chips: chips)
        }
    }

    /// Zero-width characters removed, runs of spaces/tabs collapsed, each line trimmed, line breaks kept
    /// (CR/CRLF → LF), runs of blank lines collapsed to one, leading/trailing blank lines dropped.
    public static func normalize(_ text: String) -> String {
        var lines: [String] = []
        var line = String.UnicodeScalarView()
        var pendingSpace = false
        var prevWasCR = false

        func flushLine() {
            lines.append(String(line))
            line = String.UnicodeScalarView()
            pendingSpace = false
        }

        for s in text.unicodeScalars {
            switch s.value {
            case 0x200B, 0x200C, 0x200D, 0xFEFF, 0x2060:
                prevWasCR = false
                continue
            case 0x0D:  // CR
                flushLine()
                prevWasCR = true
                continue
            case 0x0A, 0x2028, 0x2029:  // LF, line/paragraph separators
                if prevWasCR && s.value == 0x0A { prevWasCR = false; continue }
                flushLine()
            case 0x20, 0x09, 0xA0, 0x3000, 0x0B, 0x0C:
                if !line.isEmpty { pendingSpace = true }
            default:
                if pendingSpace {
                    line.append(" ")
                    pendingSpace = false
                }
                line.append(s)
            }
            prevWasCR = false
        }
        flushLine()

        // Collapse blank-line runs and drop leading/trailing blank lines.
        var out: [String] = []
        var blankRun = 0
        for l in lines {
            if l.isEmpty {
                blankRun += 1
                continue
            }
            if !out.isEmpty && blankRun > 0 { out.append("") }
            blankRun = 0
            out.append(l)
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Classification

    /// Decision for a normalized, non-system message.
    func classify(normalized text: String) -> MessageKind {
        if text.isEmpty { return .empty }

        // URLs and @mentions never decide the language; classify what is left.
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let urlMatches = Self.urlRegex.regex.matches(in: text, range: full)
        var rest = text
        if !urlMatches.isEmpty || text.contains("@") {
            rest = Self.protectedRegex.regex.stringByReplacingMatches(in: text, range: full, withTemplate: " ")
        }
        let restTrimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if restTrimmed.isEmpty {
            // Only URLs and/or mentions.
            return urlMatches.isEmpty ? .alreadyTarget : .urlOnly
        }

        if Self.isEmojiOnly(restTrimmed) { return .emojiOnly }
        if Self.isJamoOnly(restTrimmed) { return .jamoOnly }
        if Self.isNumberOrTimeOnly(restTrimmed) { return .numberOrTimeOnly }

        // No Hangul syllables → nothing for a ko→X engine to do.
        guard TextScan.containsHangulSyllable(restTrimmed) else { return .alreadyTarget }
        if targetLanguage.lowercased().hasPrefix("ko") { return .alreadyTarget }

        if Self.hangulWordShare(restTrimmed) >= Self.hangulShareThreshold { return .translate }
        // Mostly non-Korean with a few Korean words: ask the language recognizer.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(restTrimmed)
        return recognizer.dominantLanguage == .korean ? .translate : .alreadyTarget
    }

    /// Share of whitespace-separated words containing a letter that contain at least one Hangul syllable.
    /// Word-based so that mixed text like "Deadline은 Friday까지예요" counts as Korean.
    static func hangulWordShare(_ text: String) -> Double {
        var words = 0
        var hangulWords = 0
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            var hasLetter = false
            var hasHangul = false
            for s in word.unicodeScalars {
                if TextScan.isHangulSyllable(s) { hasHangul = true; hasLetter = true; break }
                if s.properties.isAlphabetic { hasLetter = true }
            }
            if hasLetter { words += 1 }
            if hasHangul { hangulWords += 1 }
        }
        return words == 0 ? 0 : Double(hangulWords) / Double(words)
    }

    /// Emoji (incl. ZWJ sequences, skin tones, flags, keycaps, variation selectors) and whitespace only.
    static func isEmojiOnly(_ text: String) -> Bool {
        var sawEmoji = false
        for ch in text {
            if ch.isWhitespace { continue }
            guard let first = ch.unicodeScalars.first else { continue }
            let p = first.properties
            let multi = ch.unicodeScalars.count > 1
            if p.isEmojiPresentation || (p.isEmoji && (multi || first.value > 0x238C)) {
                sawEmoji = true
                continue
            }
            // Stray joiners / selectors on their own.
            if ch.unicodeScalars.allSatisfy({ $0.value == 0x200D || (0xFE00...0xFE0F).contains($0.value) }) {
                continue
            }
            return false
        }
        return sawEmoji
    }

    /// Hangul compatibility jamo (ㅋㅋ, ㅇㅋ, ㅠㅠ …) plus whitespace, punctuation, symbols or emoji;
    /// at least one jamo.
    static func isJamoOnly(_ text: String) -> Bool {
        var sawJamo = false
        for s in text.unicodeScalars {
            if TextScan.isCompatibilityJamo(s) { sawJamo = true; continue }
            if s.properties.isWhitespace { continue }
            switch s.properties.generalCategory {
            case .otherPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .connectorPunctuation,
                 .mathSymbol, .modifierSymbol, .otherSymbol, .currencySymbol,
                 .nonspacingMark, .enclosingMark, .format:
                continue
            default:
                if s.properties.isEmoji && s.value > 0x238C { continue }
                return false
            }
        }
        return sawJamo
    }

    /// Digits with separators (: / . - , ~ ( ) + % # and spaces) and optional 오전/오후/上午/下午/AM/PM.
    static func isNumberOrTimeOnly(_ text: String) -> Bool {
        var t = text
        for marker in ["오전", "오후", "上午", "下午", "AM", "PM", "am", "pm"] {
            t = t.replacingOccurrences(of: marker, with: " ")
        }
        var sawDigit = false
        for s in t.unicodeScalars {
            if s.properties.numericType == .decimal { sawDigit = true; continue }
            if s.properties.isWhitespace { continue }
            switch s {
            case ":", "/", ".", "-", ",", "~", "(", ")", "+", "%", "#", "–", "—", "·": continue
            default: return false
            }
        }
        return sawDigit
    }

    // MARK: - Segmentation

    /// URLs (http/https/www).
    static let urlRegex = CompiledRegex(#"(?:https?://|www\.)[^\s]+"#, options: [.caseInsensitive])
    /// URLs or @mentions (an "@" not preceded by a word char or "@", followed by a run of non-space,
    /// non-punctuation characters). Emails ("kim@example.com") are not mentions.
    static let protectedRegex = CompiledRegex(
        #"(?:https?://|www\.)[^\s]+|(?<![\w@])@[^\s,.!?:;()\[\]{}"'<>]+"#, options: [.caseInsensitive])

    /// Splits `text` into keep (URLs, mentions, line breaks, surrounding whitespace) and translate pieces,
    /// applies glossary `expand` to translate pieces, and splits long pieces at sentence boundaries.
    func makeSegments(_ text: String) -> [MTSegment] {
        var out: [MTSegment] = []
        let lines = text.components(separatedBy: "\n")
        for (li, line) in lines.enumerated() {
            if li > 0 { out.append(.keep("\n")) }
            let ns = line as NSString
            let matches = Self.protectedRegex.regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            var cursor = 0
            for m in matches {
                if m.range.location > cursor {
                    appendTranslatable(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)),
                                       to: &out)
                }
                out.append(.keep(ns.substring(with: m.range)))
                cursor = m.range.location + m.range.length
            }
            if cursor < ns.length {
                appendTranslatable(ns.substring(from: cursor), to: &out)
            }
        }
        return out
    }

    /// Adds a translatable run: leading/trailing whitespace become keep segments; the core is expanded
    /// and split to ≤ maxSegmentLength characters.
    private func appendTranslatable(_ piece: String, to out: inout [MTSegment]) {
        guard !piece.isEmpty else { return }
        let core = piece.trimmingCharacters(in: .whitespaces)
        if core.isEmpty {
            out.append(.keep(piece))
            return
        }
        let leading = piece.prefix { $0.isWhitespace }
        let trailing = String(piece.reversed().prefix { $0.isWhitespace }.reversed())
        if !leading.isEmpty { out.append(.keep(String(leading))) }
        let expanded = glossaryEnabled ? glossary.expandInline(core) : core
        out.append(contentsOf: splitLong(expanded))
        if !trailing.isEmpty { out.append(.keep(trailing)) }
    }

    /// Splits text longer than `maxSegmentLength` into translate chunks at sentence boundaries
    /// (. ! ? 。 ！ ？ … followed by whitespace), packing sentences greedily; a single over-long sentence is
    /// hard-split (preferring the last space). Whitespace between chunks becomes a keep segment.
    func splitLong(_ text: String) -> [MTSegment] {
        let limit = maxSegmentLength
        if text.count <= limit { return [.translate(text)] }

        // Sentences, each including its trailing whitespace.
        var sentences: [String] = []
        var current = ""
        var afterTerminator = false
        for ch in text {
            if afterTerminator && !ch.isWhitespace {
                sentences.append(current)
                current = ""
                afterTerminator = false
            }
            current.append(ch)
            if Self.sentenceTerminators.contains(ch) {
                afterTerminator = true
            } else if !ch.isWhitespace {
                afterTerminator = false
            }
        }
        if !current.isEmpty { sentences.append(current) }

        // Pack sentences into chunks (by trimmed length).
        var chunks: [String] = []
        var chunk = ""
        for s in sentences {
            let candidate = chunk + s
            if candidate.trimmingCharacters(in: .whitespaces).count <= limit {
                chunk = candidate
                continue
            }
            if !chunk.isEmpty { chunks.append(chunk) }
            if s.trimmingCharacters(in: .whitespaces).count <= limit {
                chunk = s
            } else {
                let parts = Self.hardSplit(s, limit: limit)
                chunks.append(contentsOf: parts.dropLast())
                chunk = parts.last ?? ""
            }
        }
        if !chunk.isEmpty { chunks.append(chunk) }

        var out: [MTSegment] = []
        for c in chunks {
            let core = c.trimmingCharacters(in: .whitespaces)
            let leading = c.prefix { $0.isWhitespace }
            let trailing = String(c.reversed().prefix { $0.isWhitespace }.reversed())
            if core.isEmpty {
                out.append(.keep(c))
                continue
            }
            if !leading.isEmpty { out.append(.keep(String(leading))) }
            out.append(.translate(core))
            if !trailing.isEmpty { out.append(.keep(trailing)) }
        }
        return out
    }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]

    /// Cuts `text` into pieces whose trimmed length is ≤ limit, preferring to cut after a space.
    static func hardSplit(_ text: String, limit: Int) -> [String] {
        var parts: [String] = []
        var rest = Substring(text)
        while rest.trimmingCharacters(in: .whitespaces).count > limit {
            // Skip leading whitespace into the previous part (or keep it at the front if none).
            let lead = rest.prefix { $0.isWhitespace }
            let body = rest.dropFirst(lead.count)
            var cut = body.index(body.startIndex, offsetBy: limit)
            if let space = body[body.startIndex..<cut].lastIndex(where: { $0.isWhitespace }),
               space > body.startIndex {
                cut = body.index(after: space)
            }
            parts.append(String(lead) + String(body[body.startIndex..<cut]))
            rest = body[cut...]
        }
        if !rest.isEmpty { parts.append(String(rest)) }
        return parts
    }

    // MARK: - Helpers

    private func result(_ m: ChatMessage, _ kind: MessageKind, chips: [GlossaryChip] = [],
                        note: String? = nil) -> PreprocessedMessage {
        PreprocessedMessage(message: m, kind: kind, textForMT: nil, segments: [], chips: chips, note: note)
    }
}
