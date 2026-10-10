// SPDX-License-Identifier: MIT
// Off-main AX reads on dedicated serial executors (one for snapshots, one for cheap geometry reads so that a
// window drag is never queued behind a transcript parse).
//
// Only `AXElementRef` values cross isolation domains. `LiveAXNode` graphs (which cache attributes and
// children) are created and dropped inside the actor that reads them, so a cached frame can never be reused
// by another actor or outlive the read that produced it.

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

enum ReadOutcome: Sendable {
    /// Full transcript read of the current chat window. `table` is the transcript AXTable when found.
    case read(ChatWindowRead, window: AXElementRef, table: AXElementRef?)
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

actor AXReader {
    private let queue = DispatchSerialQueue(label: "dev.lipper.TalkLens.ax-reader", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Elements used by the cheap poll, remembered from the last successful full read.
    private struct ProbeTarget {
        let window: AXElementRef
        let table: AXElementRef
        let rowsAttribute: String
    }

    /// Upper bound on nodes visited when looking for the AXTable under the transcript root.
    static let tableSearchLimit = 64

    private let parser: TranscriptParser
    private var lastStartedAt: ContinuousClock.Instant?
    private var lastOutcome: ReadOutcome?
    private var probeTarget: ProbeTarget?
    private var lastSignature: ContentSignature?
    private(set) var coalescedCount = 0

    init(parser: TranscriptParser = TranscriptParser()) {
        self.parser = parser
    }

    /// Reads the current chat window. Requests made before an already-started read began (i.e. queued
    /// behind it) are answered with that read's result instead of reading again.
    func read(requestedAt: ContinuousClock.Instant) -> ReadOutcome {
        if let started = lastStartedAt, started >= requestedAt, let cached = lastOutcome {
            coalescedCount += 1
            return cached
        }
        let started = ContinuousClock.now
        let outcome = performRead()
        lastStartedAt = started
        lastOutcome = outcome
        return outcome
    }

    /// Resolves the current chat window and its geometry without touching the transcript.
    func resolveWindow() -> ReadOutcome {
        guard KakaoProcess.isAccessibilityTrusted else { return .failure(.notTrusted, window: nil) }
        guard let app = KakaoProcess.applicationNode() else { return .failure(.notRunning, window: nil) }
        guard let window = KakaoChatReader.currentChatWindow(app: app) else {
            return .failure(.noChatWindow, window: nil)
        }
        let ref = AXElementRef(element: window.element)
        let geometry = AXQuickRead.windowGeometry(window.element) ?? WindowGeometry(frame: nil, minimized: false)
        return .windowOnly(ref, geometry)
    }

    /// Cheap change check (a handful of IPC round-trips, no tree walk) against the last full read.
    func probe() -> ProbeResult {
        guard let target = probeTarget, let previous = lastSignature,
              let now = Self.signature(target) else { return .unknown }
        return now == previous ? .unchanged : .changed
    }

    /// True when the chat window TalkLens should follow differs from `current` (used after app-level
    /// AXWindowCreated, which tooltips and popovers also emit). The focused-window check is one IPC.
    func chatWindowChanged(from current: AXElementRef?) -> Bool {
        guard KakaoProcess.isAccessibilityTrusted, let app = KakaoProcess.applicationNode() else { return true }
        if let current, let focused = app.focusedWindow, CFEqual(focused.element, current.element) { return false }
        guard let window = KakaoChatReader.currentChatWindow(app: app) else { return current != nil }
        guard let current else { return true }
        return !CFEqual(window.element, current.element)
    }

    /// Drops the cached outcome (it holds chat content in memory) and the probe state.
    func clear() {
        lastOutcome = nil
        lastStartedAt = nil
        probeTarget = nil
        lastSignature = nil
    }

    private func performRead() -> ReadOutcome {
        guard KakaoProcess.isAccessibilityTrusted else { return fail(.notTrusted, window: nil) }
        guard let app = KakaoProcess.applicationNode() else { return fail(.notRunning, window: nil) }
        guard let window = KakaoChatReader.currentChatWindow(app: app) else { return fail(.noChatWindow, window: nil) }
        let windowRef = AXElementRef(element: window.element)
        // Fingerprint taken *before* parsing: if the transcript changes during the parse, the next probe sees
        // a difference and triggers another read instead of silently missing it.
        let previousTarget = probeTarget.flatMap { $0.window.isSame(as: windowRef) ? $0 : nil }
        let preSignature = previousTarget.flatMap(Self.signature)
        do {
            let result = try KakaoChatReader.read(window: window, parser: parser)
            // Same (already cached) node graph: locating the table again costs no extra IPC.
            let table = TranscriptLocator.locate(inWindow: window).flatMap { Self.firstTable(under: $0.transcriptRoot) }
            updateProbeTarget(window: windowRef, table: table, previous: previousTarget, preSignature: preSignature)
            return .read(result, window: windowRef, table: table)
        } catch let error as KakaoReadError {
            return fail(error, window: windowRef)
        } catch {
            return fail(.transcriptNotFound, window: windowRef)
        }
    }

    private func fail(_ error: KakaoReadError, window: AXElementRef?) -> ReadOutcome {
        probeTarget = nil
        lastSignature = nil
        return .failure(error, window: window)
    }

    private func updateProbeTarget(window: AXElementRef, table: AXElementRef?, previous: ProbeTarget?,
                                   preSignature: ContentSignature?) {
        guard let table else {
            probeTarget = nil
            lastSignature = nil
            return
        }
        if let previous, previous.table.isSame(as: table), let preSignature {
            probeTarget = ProbeTarget(window: window, table: table, rowsAttribute: previous.rowsAttribute)
            lastSignature = preSignature
            return
        }
        guard let attribute = AXQuickRead.rowsAttribute(of: table.element) else {
            probeTarget = nil
            lastSignature = nil
            return
        }
        let target = ProbeTarget(window: window, table: table, rowsAttribute: attribute)
        probeTarget = target
        lastSignature = Self.signature(target)
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

    /// First AXTable at or below the transcript root (bounded BFS over already-cached nodes).
    private static func firstTable(under root: LiveAXNode) -> AXElementRef? {
        var queue = [root]
        var index = 0
        while index < queue.count, index < tableSearchLimit {
            let node = queue[index]
            index += 1
            if node.role == AXRole.table { return AXElementRef(element: node.element) }
            queue.append(contentsOf: node.children)
        }
        return nil
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
}
