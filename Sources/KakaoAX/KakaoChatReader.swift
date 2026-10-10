// SPDX-License-Identifier: MIT
// One-shot read of a live chat window: locate transcript, parse, assign identities.
// Read-only: windows are only inspected; nothing is opened, focused, scrolled or clicked.

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
    /// Identifiers of KakaoTalk's main-window navigation (friends / chat list / more).
    public static let mainWindowNavigationIdentifiers: Set<String> = ["friends", "chatrooms", "more"]

    /// True for KakaoTalk's main (friends / chat list) window.
    public static func isMainWindow<Node: AXNodeLike>(_ window: Node) -> Bool {
        if window.identifier == "Main Window" { return true }
        if window.children.contains(where: { $0.identifier.map(mainWindowNavigationIdentifiers.contains) ?? false }) {
            return true
        }
        return AXTree.findFirst(in: window, maxNodes: 400) { node in
            node.identifier.map(mainWindowNavigationIdentifiers.contains) ?? false
        } != nil
    }

    /// Heuristic: a chat window (not the main friends/chat-list window) with an input box and a transcript.
    public static func isChatWindow<Node: AXNodeLike>(_ window: Node) -> Bool {
        if let role = window.role, role != AXRole.window { return false }
        if isMainWindow(window) { return false }
        return TranscriptLocator.locate(inWindow: window) != nil
    }

    /// Focused chat window if it is a chat window, else main window, else the first chat window.
    /// Minimized windows are skipped.
    public static func currentChatWindow(app: LiveAXNode) -> LiveAXNode? {
        var tried: [LiveAXNode] = []
        func consider(_ w: LiveAXNode?) -> LiveAXNode? {
            guard let w, !tried.contains(where: { $0.isSameElement(as: w) }) else { return nil }
            tried.append(w)
            guard !w.isMinimized, isChatWindow(w) else { return nil }
            return w
        }
        if let w = consider(app.focusedWindow) { return w }
        if let w = consider(app.mainWindow) { return w }
        for w in app.windows {
            if let found = consider(w) { return found }
        }
        return nil
    }

    /// Generic read used by the live path and by tests on recorded windows.
    public static func read<Node: AXNodeLike>(windowNode window: Node, parser: TranscriptParser = TranscriptParser(),
                                              readAt: Date = Date()) throws -> ChatWindowRead {
        let watch = Stopwatch()
        guard let loc = TranscriptLocator.locate(inWindow: window) else { throw KakaoReadError.transcriptNotFound }
        let parsed = parser.parse(transcriptRoot: loc.transcriptRoot, inputFrame: loc.inputFrame)
        let title = window.title ?? ""
        let key = MessageIdentity.chatKey(forTitle: title)
        let snapshot = TranscriptSnapshot(chatKey: key, messages: MessageIdentity.assign(parsed, chatKey: key), readAt: readAt)
        return ChatWindowRead(title: title, windowFrame: loc.windowFrame, inputFrame: loc.inputFrame,
                              snapshot: snapshot, elapsedMilliseconds: watch.elapsedMilliseconds)
    }

    public static func read(window: LiveAXNode, parser: TranscriptParser = TranscriptParser()) throws -> ChatWindowRead {
        try read(windowNode: window, parser: parser)
    }

    /// Full live read: process → permission → current chat window → read.
    public static func readCurrentChat(parser: TranscriptParser = TranscriptParser()) throws -> ChatWindowRead {
        guard KakaoProcess.isRunning else { throw KakaoReadError.notRunning }
        guard KakaoProcess.isAccessibilityTrusted else { throw KakaoReadError.notTrusted }
        guard let app = KakaoProcess.applicationNode() else { throw KakaoReadError.notRunning }
        guard let window = currentChatWindow(app: app) else { throw KakaoReadError.noChatWindow }
        return try read(window: window, parser: parser)
    }
}
