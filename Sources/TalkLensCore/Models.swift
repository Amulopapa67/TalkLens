// SPDX-License-Identifier: MIT
// Shared value types used by every TalkLens module. Pure Foundation; no AppKit.
//
// CONTRACT FILE: other modules (KakaoAX, TalkLensTranslate, TalkLensApp, tlctl) compile against these
// declarations. Adding members is fine; renaming or removing them requires updating all modules.

import CoreGraphics
import Foundation

/// Rectangle in AX global coordinates (top-left origin of the primary screen, y grows downward).
/// A plain Hashable/Codable stand-in for CGRect.
public struct AXRect: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    public init(_ r: CGRect) {
        self.init(x: Double(r.origin.x), y: Double(r.origin.y), width: Double(r.size.width), height: Double(r.size.height))
    }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Stable identity of a message within one chat window (KakaoTalk exposes no message id).
/// See docs/architecture.md §4.2 for how it is derived.
public struct MessageID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Counts only — never the attachment contents or names.
public struct AttachmentSummary: Hashable, Sendable, Codable {
    public var images: Int
    public var links: Int
    public var files: Int
    public init(images: Int = 0, links: Int = 0, files: Int = 0) {
        self.images = images
        self.links = links
        self.files = files
    }
    public static let none = AttachmentSummary()
    public var isEmpty: Bool { images == 0 && links == 0 && files == 0 }
}

/// One message as parsed from the AX tree, before identity assignment.
public struct ParsedMessage: Hashable, Sendable, Codable {
    /// Display name of the sender; nil for "me" and for system rows.
    public var author: String?
    public var isMine: Bool
    /// Date dividers, join/leave notices, deleted-message notices, etc.
    public var isSystem: Bool
    /// Raw time label as shown, e.g. "오후 3:12".
    public var timeRaw: String?
    /// "YYYY-MM-DD", from the time label's AXHelp tooltip or the nearest date divider.
    public var date: String?
    public var body: String
    public var attachments: AttachmentSummary
    /// AX global coordinates (top-left origin), used for optional inline mode.
    public var frame: AXRect?
    /// Frame of the bubble background enclosing the body (AX global coordinates); falls back to `frame` when
    /// no bubble image was found. Geometry only: never part of the message identity or of replay output.
    public var bubbleFrame: AXRect?

    public init(author: String?, isMine: Bool, isSystem: Bool, timeRaw: String?, date: String?,
                body: String, attachments: AttachmentSummary = .none, frame: AXRect? = nil,
                bubbleFrame: AXRect? = nil) {
        self.author = author
        self.isMine = isMine
        self.isSystem = isSystem
        self.timeRaw = timeRaw
        self.date = date
        self.body = body
        self.attachments = attachments
        self.frame = frame
        self.bubbleFrame = bubbleFrame
    }
}

/// A parsed message with its identity.
public struct ChatMessage: Hashable, Sendable, Identifiable {
    public let id: MessageID
    public let author: String?
    public let isMine: Bool
    public let isSystem: Bool
    public let timeRaw: String?
    public let date: String?
    public let body: String
    public let attachments: AttachmentSummary
    public let frame: AXRect?
    /// See `ParsedMessage.bubbleFrame`.
    public let bubbleFrame: AXRect?

    public init(id: MessageID, parsed p: ParsedMessage) {
        self.id = id
        self.author = p.author
        self.isMine = p.isMine
        self.isSystem = p.isSystem
        self.timeRaw = p.timeRaw
        self.date = p.date
        self.body = p.body
        self.attachments = p.attachments
        self.frame = p.frame
        self.bubbleFrame = p.bubbleFrame
    }
}

/// All visible messages of one chat window at one moment, top to bottom.
public struct TranscriptSnapshot: Sendable {
    /// Hash of the window title (never the title itself in logs; see Redactor).
    public let chatKey: String
    public let messages: [ChatMessage]
    public let readAt: Date

    public init(chatKey: String, messages: [ChatMessage], readAt: Date = Date()) {
        self.chatKey = chatKey
        self.messages = messages
        self.readAt = readAt
    }
}

/// Preprocessing decision for one message (docs/architecture.md §4.4).
public enum MessageKind: String, Sendable, Codable, Hashable {
    case translate
    case system
    case emojiOnly
    case jamoOnly
    case urlOnly
    case numberOrTimeOnly
    case alreadyTarget
    case empty

    /// Whether the message text is sent to the MT engine.
    public var needsTranslation: Bool { self == .translate }
}

/// A glossary annotation shown under a translation, e.g. "랩미팅 = 组会".
public struct GlossaryChip: Hashable, Sendable, Codable {
    public let term: String
    public let gloss: String
    public let kind: String?
    public init(term: String, gloss: String, kind: String? = nil) {
        self.term = term
        self.gloss = gloss
        self.kind = kind
    }
}

/// A piece of a message as prepared for machine translation. URLs, @mentions and line breaks are kept
/// verbatim (`keep`); everything else is sent to the engine (`translate`). Long text is split into
/// several `translate` segments of ≤ ~1000 characters at line/sentence boundaries.
public enum MTSegment: Hashable, Sendable, Codable {
    case translate(String)
    case keep(String)
}

/// Output of ChatPreprocessor for one message.
public struct PreprocessedMessage: Hashable, Sendable {
    public let message: ChatMessage
    public let kind: MessageKind
    /// Normalized text to send to the MT engine (glossary `expand` applied).
    /// nil when `kind.needsTranslation == false`.
    public let textForMT: String?
    /// `textForMT` split into segments; empty when `kind.needsTranslation == false`.
    public let segments: [MTSegment]
    public let chips: [GlossaryChip]
    /// Short display note for messages that are not machine-translated (e.g. "哈哈（笑）" for ㅋㅋㅋ).
    public let note: String?

    public init(message: ChatMessage, kind: MessageKind, textForMT: String?, segments: [MTSegment],
                chips: [GlossaryChip], note: String?) {
        self.message = message
        self.kind = kind
        self.textForMT = textForMT
        self.segments = segments
        self.chips = chips
        self.note = note
    }
}

extension PreprocessedMessage {
    /// Texts of the `translate` segments, in order.
    public var translatableTexts: [String] {
        segments.compactMap { if case .translate(let t) = $0 { return t } else { return nil } }
    }

    /// Rebuild the full translation from per-segment results (same order as `translatableTexts`).
    /// Returns nil when the count does not match.
    public func assemble(translations: [String]) -> String? {
        guard translations.count == translatableTexts.count else { return nil }
        var out = ""
        var i = 0
        for seg in segments {
            switch seg {
            case .keep(let k): out += k
            case .translate:
                out += translations[i]
                i += 1
            }
        }
        return out
    }
}
