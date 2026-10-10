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
    /// Frame of the transcript container (the AXScrollArea): the on-screen viewport of the messages.
    public let transcriptFrame: CGRect?
    /// Frame of the transcript AXTable at read time. NSTableView's AX frame is its document bounds, which
    /// move up and down inside the viewport when the user scrolls, so comparing a later table frame with
    /// this one gives the scroll offset since the read (window moves aside).
    public let tableFrame: CGRect?
    /// Messages of `snapshot` whose row intersects the transcript viewport (what is on screen). The one-shot
    /// `read(windowNode:parser:)` only emits visible rows, so there it holds every snapshot id.
    public let visibleIDs: Set<MessageID>
    /// AXRow elements of the transcript table (all loaded rows, on screen or not).
    public let rowsTotal: Int
    /// Rows whose subtree was analysed by this call (0 when everything came from the row cache).
    public let rowsAnalyzed: Int
    /// Cached rows whose frame was re-read by this call to validate the cache (one IPC each).
    public let rowsVerified: Int
    /// Rows in the prefetch band still waiting for analysis because of the per-read budget; callers should
    /// schedule a follow-up read (after a short pause) while this is > 0.
    public let rowsPending: Int

    public init(title: String, windowFrame: CGRect?, inputFrame: CGRect?, snapshot: TranscriptSnapshot,
                elapsedMilliseconds: Double, transcriptFrame: CGRect? = nil, tableFrame: CGRect? = nil,
                visibleIDs: Set<MessageID>? = nil, rowsTotal: Int? = nil, rowsAnalyzed: Int? = nil,
                rowsVerified: Int = 0, rowsPending: Int = 0) {
        self.title = title
        self.windowFrame = windowFrame
        self.inputFrame = inputFrame
        self.snapshot = snapshot
        self.elapsedMilliseconds = elapsedMilliseconds
        self.transcriptFrame = transcriptFrame
        self.tableFrame = tableFrame
        self.visibleIDs = visibleIDs ?? Set(snapshot.messages.map(\.id))
        self.rowsTotal = rowsTotal ?? snapshot.messages.count
        self.rowsAnalyzed = rowsAnalyzed ?? self.rowsTotal
        self.rowsVerified = rowsVerified
        self.rowsPending = rowsPending
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
        // Verified on 26.8.0: the navigation buttons are direct children. Look one level deeper at most —
        // every node visited is a slow cross-process call (D-020).
        return AXTree.findFirst(in: window, maxNodes: 40) { node in
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
        currentChatWindow(app: app, isChat: { isChatWindow($0) })
    }

    /// Same, with the (expensive: a tree scan) chat-window test supplied by the caller, e.g. memoised per
    /// window element.
    public static func currentChatWindow(app: LiveAXNode, isChat: (LiveAXNode) -> Bool) -> LiveAXNode? {
        var tried: [LiveAXNode] = []
        func consider(_ w: LiveAXNode?) -> LiveAXNode? {
            guard let w, !tried.contains(where: { $0.isSameElement(as: w) }) else { return nil }
            tried.append(w)
            guard !w.isMinimized, isChat(w) else { return nil }
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
                              snapshot: snapshot, elapsedMilliseconds: watch.elapsedMilliseconds,
                              transcriptFrame: loc.transcriptRoot.frame,
                              tableFrame: firstTable(under: loc.transcriptRoot)?.frame)
    }

    /// Upper bound on nodes visited when looking for the AXTable under the transcript root.
    public static let tableSearchLimit = 64

    /// First AXTable at or below the transcript root (bounded BFS; on live nodes the parse has already
    /// cached these, so no extra IPC).
    public static func firstTable<Node: AXNodeLike>(under root: Node) -> Node? {
        var queue = [root]
        var index = 0
        while index < queue.count, index < tableSearchLimit {
            let node = queue[index]
            index += 1
            if node.role == AXRole.table { return node }
            queue.append(contentsOf: node.children)
        }
        return nil
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
