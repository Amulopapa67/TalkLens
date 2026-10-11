// SPDX-License-Identifier: MIT
// Off-main AX reads on dedicated serial executors (one for snapshots, one for cheap geometry reads so that a
// window drag is never queued behind a transcript parse).
//
// Only `AXElementRef` values cross isolation domains. `LiveAXNode` graphs (which cache attributes and
// children) are created and dropped inside the actor that reads them, so a cached frame can never be reused
// by another actor or outlive the read that produced it. The per-window `TranscriptRowCache`s (row analyses,
// in memory only) are owned and used exclusively by `AXReader`; they never leave the actor.

import ApplicationServices
import CoreGraphics
import Dispatch
import Foundation
import KakaoAX
import TalkLensCore

/// A bare accessibility element handed between actors.
///
/// `@unchecked Sendable` justification: an `AXUIElement` is an immutable CF reference (process id + opaque
/// element token) with no client-side cached state, and the AX client API may be called from any thread.
/// Every read through it is a fresh IPC round-trip, so sharing the reference cannot leak stale data.
struct AXElementRef: @unchecked Sendable {
    let element: AXUIElement

    func isSame(as other: AXElementRef) -> Bool { CFEqual(element, other.element) }
}

struct WindowGeometry: Sendable, Equatable {
    var frame: CGRect?
    var minimized: Bool
}

/// Cheap fingerprint of the transcript used by the 1 s fallback poll: if none of these changed, the
/// visible transcript has not changed either (scrolling moves the last row; new rows change the count).
struct ContentSignature: Sendable, Equatable {
    var rowCount: Int
    /// Frame of the last row relative to the window origin (so a pure window move is not a content change).
    var lastRow: CGRect?
    var windowSize: CGSize?
}

enum ProbeResult: Sendable, Equatable {
    case unchanged
    case changed
    /// No previous successful read to compare with, or an element went away.
    case unknown
}

/// Element whose AX frame follows the transcript's scroll position, with its frame at read time. Normally the
/// transcript AXTable (NSTableView reports its document bounds, which move when the user scrolls); when the
/// table frame does not look like document bounds, the last row (rows also move with the content).
struct ScrollAnchor: Sendable {
    let element: AXElementRef
    let frameAtRead: CGRect
    let isTable: Bool
}

enum ReadOutcome: Sendable {
    /// Full transcript read of the current chat window. `table` is the transcript AXTable when found.
    case read(ChatWindowRead, window: AXElementRef, table: AXElementRef?, anchor: ScrollAnchor?)
    /// Window resolved without reading the transcript (used while paused).
    case windowOnly(AXElementRef, WindowGeometry)
    case failure(KakaoReadError, window: AXElementRef?)
}

/// Uncached single-purpose AX reads (each is one or two IPC round-trips). Read-only.
enum AXQuickRead {
    static func windowGeometry(_ element: AXUIElement) -> WindowGeometry? {
        guard let values = copyMultiple(element, ["AXPosition", "AXSize", "AXMinimized"]) else { return nil }
        let frame: CGRect?
        if let p = point(values[0]), let s = size(values[1]) {
            frame = CGRect(origin: p, size: s)
        } else {
            frame = nil
        }
        return WindowGeometry(frame: frame, minimized: bool(values[2]) ?? false)
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let values = copyMultiple(element, ["AXPosition", "AXSize"]),
              let p = point(values[0]), let s = size(values[1]) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Picks the attribute that lists the table's rows ("AXRows", else "AXChildren").
    static func rowsAttribute(of table: AXUIElement) -> String? {
        for name in ["AXRows", "AXChildren"] {
            var count: CFIndex = 0
            if AXUIElementGetAttributeValueCount(table, name as CFString, &count) == .success { return name }
        }
        return nil
    }

    static func count(_ element: AXUIElement, _ attribute: String) -> Int? {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, attribute as CFString, &count) == .success else { return nil }
        return count
    }

    static func element(_ parent: AXUIElement, _ attribute: String, at index: Int) -> AXUIElement? {
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(parent, attribute as CFString, index, 1, &values) == .success,
              let array = values as? [AXUIElement] else { return nil }
        return array.first
    }

    private static func copyMultiple(_ element: AXUIElement, _ names: [String]) -> [AnyObject]? {
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(element, names as CFArray,
                                                         AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard err == .success, let array = values as? [AnyObject], array.count == names.count else { return nil }
        return array
    }

    private static func point(_ v: AnyObject) -> CGPoint? {
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let ax = v as! AXValue
        var p = CGPoint.zero
        return AXValueGetType(ax) == .cgPoint && AXValueGetValue(ax, .cgPoint, &p) ? p : nil
    }

    private static func size(_ v: AnyObject) -> CGSize? {
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let ax = v as! AXValue
        var s = CGSize.zero
        return AXValueGetType(ax) == .cgSize && AXValueGetValue(ax, .cgSize, &s) ? s : nil
    }

    private static func bool(_ v: AnyObject) -> Bool? {
        guard CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((v as! CFBoolean))
    }
}

/// One KakaoTalk chat window found by `AXReader.enumerateChatWindows()`.
struct ChatWindowInfo: Sendable {
    let window: AXElementRef
    let key: AXElementKey
    /// Frame in AX coordinates at enumeration time.
    let frame: CGRect?
}

/// Open chat windows of KakaoTalk (not minimized), in the application's window order.
struct ChatWindowEnumeration: Sendable {
    var chatWindows: [ChatWindowInfo]
    /// KakaoTalk's focused window when it is one of `chatWindows`.
    var focused: AXElementKey?
    /// Windows whose chat-window test was negative but may change (e.g. still loading): worth re-checking.
    var unresolved: Int
    /// Only the focused window was tested (launch fast path); a full enumeration should follow.
    var partial = false
}

enum EnumerationOutcome: Sendable {
    case windows(ChatWindowEnumeration)
    case failure(KakaoReadError)
}

actor AXReader {
    private let queue = DispatchSerialQueue(label: "dev.lipper.TalkLens.ax-reader", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Elements used by the cheap probe of one window, remembered from its last successful full read.
    private struct ProbeTarget {
        let window: AXElementRef
        let table: AXElementRef
        let rowsAttribute: String
    }

    private struct WindowState {
        var lastStartedAt: ContinuousClock.Instant?
        var lastOutcome: ReadOutcome?
        var probeTarget: ProbeTarget?
        var lastSignature: ContentSignature?
    }

    private let parser: TranscriptParser
    /// Kept for API compatibility: every read now covers all loaded rows (incremental), so the inline
    /// overlay's margin no longer changes what is read.
    private var inlineMargin = false
    /// Row caches of recently read chat windows, most recently used last (one per followed window, plus a few
    /// for windows that were followed recently, e.g. before a Space switch).
    private var rowCaches: [(window: AXElementKey, cache: TranscriptRowCache<LiveAXNode>)] = []
    static let maxRowCaches = 8
    /// Memoised chat-window test per window element (`isChatWindow` scans the window's tree). Stable answers
    /// are kept: "chat window", "main window", "not a window". Other negatives (a chat window that is still
    /// loading looks like a non-chat window) are re-tested with exponential backoff, so a window that is not a
    /// chat window (profile, image viewer, settings) is not scanned again and again.
    private var windowKinds: [AXElementKey: Bool] = [:]
    private var transientNegatives: [AXElementKey: (retryAt: ContinuousClock.Instant, misses: Int)] = [:]
    static let negativeRetryInterval: Duration = .seconds(2)
    static let maxNegativeRetryInterval: Duration = .seconds(60)
    /// Windows smaller than this are popovers / tooltips, never chat windows (no tree scan).
    static let minChatWindowSide: CGFloat = 200
    private var windowStates: [AXElementKey: WindowState] = [:]
    private(set) var coalescedCount = 0

    init(parser: TranscriptParser = TranscriptParser()) {
        self.parser = parser
    }

    // MARK: - Enumeration

    /// Every open (not minimized) chat window. IPC: the window list, the focused window, one batched
    /// geometry read per window, and a (memoised, bounded) chat-window test for windows not seen before.
    ///
    /// - focusedOnly: launch fast path: when KakaoTalk's focused window is a chat window, return just that one
    ///   (`partial`) so it can be read before the other windows are tested; otherwise enumerate everything.
    func enumerateChatWindows(focusedOnly: Bool = false) -> EnumerationOutcome {
        guard KakaoProcess.isAccessibilityTrusted else { return .failure(.notTrusted) }
        guard let app = KakaoProcess.applicationNode() else { return .failure(.notRunning) }
        // A failed window-list read (busy KakaoTalk, IPC timeout) must not look like "every window closed".
        guard AXQuickRead.count(app.element, "AXWindows") != nil else { return .failure(.noChatWindow) }
        let now = ContinuousClock.now
        if focusedOnly, let window = app.focusedWindow {
            let key = window.elementIdentity
            let g = window.currentGeometry()
            if !g.isMinimized, chatKind(window, key: key, frame: g.frame, now: now) == .chat {
                let info = ChatWindowInfo(window: AXElementRef(element: window.element), key: key, frame: g.frame)
                return .windows(ChatWindowEnumeration(chatWindows: [info], focused: key, unresolved: 0, partial: true))
            }
        }
        var result = ChatWindowEnumeration(chatWindows: [], focused: nil, unresolved: 0)
        var present = Set<AXElementKey>()
        for window in app.windows {
            let key = window.elementIdentity
            present.insert(key)
            let g = window.currentGeometry()
            if g.isMinimized { continue }
            switch chatKind(window, key: key, frame: g.frame, now: now) {
            case .chat:
                result.chatWindows.append(ChatWindowInfo(window: AXElementRef(element: window.element), key: key,
                                                         frame: g.frame))
            case .notChat:
                break
            case .unknown:
                result.unresolved += 1
            }
        }
        if let focused = app.focusedWindow?.elementIdentity,
           result.chatWindows.contains(where: { $0.key == focused }) {
            result.focused = focused
        }
        // Forget windows that no longer exist (closed): memo entries, and the row caches / last outcomes that
        // hold their chat content in memory.
        windowKinds = windowKinds.filter { present.contains($0.key) }
        transientNegatives = transientNegatives.filter { present.contains($0.key) }
        windowStates = windowStates.filter { present.contains($0.key) }
        rowCaches.removeAll { !present.contains($0.window) }
        return .windows(result)
    }

    private enum ChatKind { case chat, notChat, unknown }

    private func chatKind(_ window: LiveAXNode, key: AXElementKey, frame: CGRect?,
                          now: ContinuousClock.Instant) -> ChatKind {
        if let known = windowKinds[key] { return known ? .chat : .notChat }
        if let negative = transientNegatives[key], now < negative.retryAt { return .unknown }
        if let role = window.role, role != AXRole.window {
            windowKinds[key] = false
            return .notChat
        }
        if let frame, frame.width < Self.minChatWindowSide || frame.height < Self.minChatWindowSide {
            noteNegative(key, now: now)
            return .unknown
        }
        if KakaoChatReader.isMainWindow(window) {
            windowKinds[key] = false
            return .notChat
        }
        if KakaoChatReader.isChatWindow(window) {
            if windowKinds.count > 64 { windowKinds.removeAll() }
            windowKinds[key] = true
            transientNegatives[key] = nil
            return .chat
        }
        noteNegative(key, now: now)
        return .unknown
    }

    private func noteNegative(_ key: AXElementKey, now: ContinuousClock.Instant) {
        let misses = (transientNegatives[key]?.misses ?? 0) + 1
        let delay = min(Self.negativeRetryInterval * (1 << min(misses - 1, 5)), Self.maxNegativeRetryInterval)
        transientNegatives[key] = (now + delay, misses)
    }

    // MARK: - Reads

    /// Reads one chat window. Requests made before an already-started read of the same window began (i.e.
    /// queued behind it) are answered with that read's result instead of reading again.
    func read(window: AXElementRef, requestedAt: ContinuousClock.Instant) -> ReadOutcome {
        let key = AXElementKey(window.element)
        if let state = windowStates[key], let started = state.lastStartedAt, started >= requestedAt,
           let cached = state.lastOutcome {
            coalescedCount += 1
            return cached
        }
        let started = ContinuousClock.now
        let outcome = performRead(window: window, key: key)
        windowStates[key, default: WindowState()].lastStartedAt = started
        windowStates[key, default: WindowState()].lastOutcome = outcome
        return outcome
    }

    /// Geometry of one window without touching the transcript (used while paused).
    func resolveWindow(_ window: AXElementRef) -> ReadOutcome {
        guard KakaoProcess.isAccessibilityTrusted else { return .failure(.notTrusted, window: nil) }
        guard KakaoProcess.applicationNode() != nil else { return .failure(.notRunning, window: nil) }
        guard let geometry = AXQuickRead.windowGeometry(window.element) else {
            return .failure(.noChatWindow, window: window)
        }
        return .windowOnly(window, geometry)
    }

    /// Cheap change check of one window (a handful of IPC round-trips, no tree walk) against its last read.
    func probe(window: AXElementRef) -> ProbeResult {
        let key = AXElementKey(window.element)
        guard let state = windowStates[key], let target = state.probeTarget, let previous = state.lastSignature,
              let now = Self.signature(target) else { return .unknown }
        return now == previous ? .unchanged : .changed
    }

    /// No effect on what is read any more (all loaded rows are read incrementally); kept for callers.
    func setInlineMargin(_ enabled: Bool) {
        inlineMargin = enabled
    }

    /// Forgets everything about one window (it was closed): row cache (chat content), probe and memo state.
    func dropWindow(_ key: AXElementKey) {
        rowCaches.removeAll { $0.window == key }
        windowStates[key] = nil
        windowKinds[key] = nil
        transientNegatives[key] = nil
    }

    /// Drops the cached outcomes and the row caches (they hold chat content in memory) and the probe state.
    func clear() {
        windowStates.removeAll()
        rowCaches.removeAll()
        windowKinds.removeAll()
        transientNegatives.removeAll()
    }

    /// Row cache for `window` (created on first use; least recently used caches are dropped).
    private func rowCache(for window: AXElementKey) -> TranscriptRowCache<LiveAXNode> {
        if let i = rowCaches.firstIndex(where: { $0.window == window }) {
            let entry = rowCaches.remove(at: i)
            rowCaches.append(entry)
            return entry.cache
        }
        let cache = TranscriptRowCache<LiveAXNode>()
        rowCaches.append((window, cache))
        if rowCaches.count > Self.maxRowCaches { rowCaches.removeFirst(rowCaches.count - Self.maxRowCaches) }
        return cache
    }

    private func performRead(window windowRef: AXElementRef, key: AXElementKey) -> ReadOutcome {
        guard KakaoProcess.isAccessibilityTrusted else { return fail(.notTrusted, window: nil, key: key) }
        guard KakaoProcess.applicationNode() != nil else { return fail(.notRunning, window: nil, key: key) }
        let window = LiveAXNode(windowRef.element)
        // Fingerprint taken *before* parsing: if the transcript changes during the parse, the next probe sees
        // a difference and triggers another read instead of silently missing it.
        let previousTarget = windowStates[key]?.probeTarget
        let preSignature = previousTarget.flatMap(Self.signature)
        let cache = rowCache(for: key)
        do {
            // Incremental: only rows not analysed before (or lazily loaded / resized) cost a subtree walk.
            let result = try KakaoChatReader.read(window: window, cache: cache, parser: parser)
            // The table node of this read (its frame and children are already fetched).
            let tableNode = cache.lastTable ?? TranscriptLocator.locate(inWindow: window)
                .flatMap { KakaoChatReader.firstTable(under: $0.transcriptRoot) }
            let table = tableNode.map { AXElementRef(element: $0.element) }
            updateProbeTarget(key: key, window: windowRef, table: table, previous: previousTarget,
                              preSignature: preSignature)
            let anchor = tableNode.flatMap { Self.scrollAnchor(table: $0, read: result) }
            return .read(result, window: windowRef, table: table, anchor: anchor)
        } catch {
            // A window that no longer answers a geometry read is gone (closed meanwhile).
            if AXQuickRead.windowGeometry(windowRef.element)?.frame == nil {
                return fail(.noChatWindow, window: windowRef, key: key)
            }
            let readError = (error as? KakaoReadError) ?? .transcriptNotFound
            return fail(readError, window: windowRef, key: key)
        }
    }

    private func fail(_ error: KakaoReadError, window: AXElementRef?, key: AXElementKey) -> ReadOutcome {
        windowStates[key]?.probeTarget = nil
        windowStates[key]?.lastSignature = nil
        return .failure(error, window: window)
    }

    private func updateProbeTarget(key: AXElementKey, window: AXElementRef, table: AXElementRef?,
                                   previous: ProbeTarget?, preSignature: ContentSignature?) {
        var state = windowStates[key] ?? WindowState()
        defer { windowStates[key] = state }
        guard let table else {
            state.probeTarget = nil
            state.lastSignature = nil
            return
        }
        if let previous, previous.table.isSame(as: table), let preSignature {
            state.probeTarget = ProbeTarget(window: window, table: table, rowsAttribute: previous.rowsAttribute)
            state.lastSignature = preSignature
            return
        }
        guard let attribute = AXQuickRead.rowsAttribute(of: table.element) else {
            state.probeTarget = nil
            state.lastSignature = nil
            return
        }
        let target = ProbeTarget(window: window, table: table, rowsAttribute: attribute)
        state.probeTarget = target
        state.lastSignature = Self.signature(target)
    }

    private static func signature(_ target: ProbeTarget) -> ContentSignature? {
        guard let count = AXQuickRead.count(target.table.element, target.rowsAttribute),
              let windowFrame = AXQuickRead.frame(target.window.element) else { return nil }
        var lastRow: CGRect?
        if count > 0, let row = AXQuickRead.element(target.table.element, target.rowsAttribute, at: count - 1),
           let frame = AXQuickRead.frame(row) {
            lastRow = frame.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
        }
        return ContentSignature(rowCount: count, lastRow: lastRow, windowSize: windowFrame.size)
    }

    /// The table when its frame tracks scrolling, else the last row; frames come from the read's cached
    /// node graph, so they are consistent with the message frames of the same read (no extra IPC).
    private static func scrollAnchor(table: LiveAXNode, read: ChatWindowRead) -> ScrollAnchor? {
        if let tableFrame = read.tableFrame, let viewport = read.transcriptFrame,
           InlineLayout.usesTableAnchor(tableFrame: tableFrame, viewport: viewport) {
            return ScrollAnchor(element: AXElementRef(element: table.element), frameAtRead: tableFrame, isTable: true)
        }
        guard let row = table.children.last(where: { $0.role == AXRole.row && $0.frame != nil }),
              let frame = row.frame else {
            return read.tableFrame.map { ScrollAnchor(element: AXElementRef(element: table.element), frameAtRead: $0,
                                                      isTable: true) }
        }
        return ScrollAnchor(element: AXElementRef(element: row.element), frameAtRead: frame, isTable: false)
    }
}

actor WindowGeometryReader {
    private let queue = DispatchSerialQueue(label: "dev.lipper.TalkLens.ax-geometry", qos: .userInteractive)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init() {}

    /// Fresh (uncached) position/size/minimized read: one IPC round-trip. Nil when the element is gone.
    func geometry(of window: AXElementRef) -> WindowGeometry? {
        AXQuickRead.windowGeometry(window.element)
    }

    /// Fresh position/size of any element (the inline overlay's scroll anchor): one IPC round-trip.
    func frame(of element: AXElementRef) -> CGRect? {
        AXQuickRead.frame(element.element)
    }
}
