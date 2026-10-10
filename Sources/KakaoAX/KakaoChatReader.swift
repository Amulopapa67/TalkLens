// SPDX-License-Identifier: MIT
// One-shot read of a live chat window: locate transcript, parse, assign identities.
// STUB — core-dev: finish.

import CoreGraphics
import Foundation
import TalkLensCore

public enum KakaoReadError: Error, Sendable, Equatable, CustomStringConvertible {
    case notRunning
    case notTrusted
    case noChatWindow
    case transcriptNotFound

    public var description: String {
        switch self {
        case .notRunning: return "KakaoTalk is not running"
        case .notTrusted: return "Accessibility permission not granted"
        case .noChatWindow: return "no open chat window"
        case .transcriptNotFound: return "chat transcript area not found"
        }
    }
}

public struct ChatWindowRead: Sendable {
    /// Raw window title — keep in memory only; redact before logging.
    public let title: String
    public let windowFrame: CGRect?
    public let inputFrame: CGRect?
    public let snapshot: TranscriptSnapshot
    public let elapsedMilliseconds: Double

    public init(title: String, windowFrame: CGRect?, inputFrame: CGRect?, snapshot: TranscriptSnapshot,
                elapsedMilliseconds: Double) {
        self.title = title
        self.windowFrame = windowFrame
        self.inputFrame = inputFrame
        self.snapshot = snapshot
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public enum KakaoChatReader {
    /// Heuristic: a chat window (not the main friends/chat-list window).
    public static func isChatWindow<Node: AXNodeLike>(_ window: Node) -> Bool { false }

    /// Focused chat window if it is a chat window, else main window, else the first chat window.
    public static func currentChatWindow(app: LiveAXNode) -> LiveAXNode? { nil }

    public static func read(window: LiveAXNode, parser: TranscriptParser = TranscriptParser()) throws -> ChatWindowRead {
        throw KakaoReadError.transcriptNotFound
    }
}
