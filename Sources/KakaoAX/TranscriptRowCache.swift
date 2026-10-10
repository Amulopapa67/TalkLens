// SPDX-License-Identifier: MIT
// Incremental transcript reads: per chat window, each AXRow is analysed once and cached by element identity.
//
// KakaoTalk keeps every loaded row in the AX tree and AX IPC is slow (~150 ms to analyse ~56 rows even with
// batched attribute reads), so re-walking every row on each scroll or new message makes the app lag. The
// AXTable's frame is its document bounds and moves with scrolling, and every row moves by the same delta, so a
// cached analysis stays valid up to a translation: absolute frame = cached frame + (table origin now − table
// origin at analysis). Only new rows, lazily loaded rows near the viewport and (after a width change, which
// re-wraps bubbles) all rows are analysed again.
//
// Read-only: only attribute and children reads; nothing is focused, scrolled or clicked.

import CoreGraphics
import Foundation
import TalkLensCore

/// An AXNodeLike whose underlying element has a stable identity and can be re-read without cached state.
/// This is the seam that lets `TranscriptRowCache` run on live elements, recordings and test fakes.
public protocol IncrementalAXNode: AXNodeLike {
    associatedtype Identity: Hashable
    /// Identity of the underlying element (CFEqual / CFHash for live AXUIElements).
    var elementIdentity: Identity { get }
    /// The same element with nothing cached: the next attribute / children access reads the source again.
    func refreshed() -> Self
}

extension RecordedAXNode: IncrementalAXNode {
    /// A recording has no element identity; the value itself stands in for it. Re-reading an unchanged
    /// recording therefore hits the cache, while any change (including a frame) makes it a new element.
    public var elementIdentity: RecordedAXNode { self }
    public func refreshed() -> RecordedAXNode { self }
}

/// Per-chat-window cache of row analyses and of the located transcript elements.
///
/// Concurrency contract (`@unchecked Sendable`): the cache holds mutable state without a lock. It may be
/// created in one isolation domain and handed to another, but it must only be *used* (read or mutated) by one
/// domain at a time — in the app, exclusively by the `AXReader` actor that owns it; in tlctl and tests, by a
/// single task. Nothing in it is shared with other caches.
public final class TranscriptRowCache<Node: IncrementalAXNode>: @unchecked Sendable {
    struct Entry {
        /// nil = the row showed nothing displayable when analysed (spacer, divider without text, or content
        /// not loaded yet).
        var analysis: TranscriptParser.RowAnalysis?
        /// Row frame when analysed (or last verified); same reference as `analysis`' frames.
        var rowFrame: CGRect?
        /// Table origin at that moment.
        var tableOrigin: CGPoint
        var analyzedAt: ContinuousClock.Instant

        func offset(to origin: CGPoint) -> CGVector {
            CGVector(dx: origin.x - tableOrigin.x, dy: origin.y - tableOrigin.y)
        }

        /// Moves the stored frames by `d` (same table-origin reference).
        mutating func translate(by d: CGVector) {
            analysis = analysis?.offsetBy(dx: d.dx, dy: d.dy)
            rowFrame = rowFrame?.offsetBy(dx: d.dx, dy: d.dy)
        }
    }

    /// Empty rows near the viewport (lazily loaded content) are re-analysed at most this often.
    public var lazyRetryInterval: Duration
    /// Rows on screen are re-analysed when their analysis is older than this (edited / deleted messages keep
    /// their element and frame, so nothing else would notice).
    public var visibleRefreshInterval: Duration

    var windowIdentity: Node.Identity?
    var root: Node?
    var rootRole: String?
    var table: Node?
    var input: Node?
    /// Transcript viewport width the cached analyses were made with.
    var analysisWidth: CGFloat?
    var entries: [Node.Identity: Entry] = [:]
    /// Table children that are not rows (AXColumn).
    var nonRows: Set<Node.Identity> = []
    /// Row identities of the last read, in table order.
    var order: [Node.Identity] = []

    /// The transcript AXTable as (freshly) read by the last successful incremental read.
    public private(set) var lastTable: Node?

    public init(lazyRetryInterval: Duration = .seconds(2), visibleRefreshInterval: Duration = .seconds(15)) {
        self.lazyRetryInterval = lazyRetryInterval
        self.visibleRefreshInterval = visibleRefreshInterval
    }

    /// Number of rows with a cached analysis (empty rows included).
    public var cachedRowCount: Int { entries.count }

    /// Forgets everything, including the window binding and the located elements.
    public func reset() {
        windowIdentity = nil
        clearLocation()
        clearRows()
    }

    func clearLocation() {
        root = nil
        rootRole = nil
        table = nil
        input = nil
        lastTable = nil
    }

    func clearRows() {
        analysisWidth = nil
        entries = [:]
        nonRows = []
        order = []
    }

    func setLastTable(_ node: Node?) { lastTable = node }
}

extension KakaoChatReader {
    /// A cached row list shrinking below this fraction of its size means another chat is shown: start over.
    static let cacheShrinkResetRatio = 0.5

    /// Incremental read of a chat window (see `TranscriptRowCache`).
    ///
    /// IPC per call: window title/frame, the cached transcript root / table / input re-read once each (located
    /// again only when one of them is gone), the table's children list, one frame read per cached row on
    /// screen (validation), and full analysis only for rows not cached yet, empty rows that came within one
    /// viewport of the visible area (at most every `lazyRetryInterval`), stale rows on screen, rows whose size
    /// changed, or every row after a transcript width change.
    ///
    /// `snapshot.messages` holds every loaded message top-to-bottom (the newest `parser.maxRows`), with frames
    /// for the current scroll position; `visibleIDs` marks the ones on screen.
    public static func read<Node: IncrementalAXNode>(window: Node, cache: TranscriptRowCache<Node>,
                                                     parser: TranscriptParser = TranscriptParser(),
                                                     readAt: Date = Date(),
                                                     now: ContinuousClock.Instant = .now) throws -> ChatWindowRead {
        let watch = Stopwatch()
        let windowID = window.elementIdentity
        if cache.windowIdentity != windowID {
            cache.reset()
            cache.windowIdentity = windowID
        }
        let title = window.title ?? ""
        let windowFrame = window.frame

        // 1. Transcript root, table and input: re-validate the cached elements, locate only when needed.
        var rootNow: Node
        var tableNow: Node
        var inputFrame: CGRect?
        if let root = cache.root?.refreshed(), let role = root.role, role == cache.rootRole,
           let table = cache.table?.refreshed(), table.role == AXRole.table,
           let inputNode = cache.input?.refreshed(), let inputNodeFrame = inputNode.frame {
            rootNow = root
            tableNow = table
            inputFrame = inputNodeFrame
        } else {
            cache.clearLocation()
            guard let loc = TranscriptLocator.locate(inWindow: window) else { throw KakaoReadError.transcriptNotFound }
            guard let table = firstTable(under: loc.transcriptRoot) else {
                // No AXTable (never observed on 26.8.0): fall back to the one-shot read, nothing cached.
                cache.clearRows()
                return try read(windowNode: window, parser: parser, readAt: readAt)
            }
            rootNow = loc.transcriptRoot
            tableNow = table
            inputFrame = loc.inputFrame
            cache.root = loc.transcriptRoot
            cache.rootRole = loc.transcriptRoot.role
            cache.table = table
            cache.input = loc.input
        }
        let viewport = rootNow.frame
        let tableFrame = tableNow.frame
        let tableOrigin = tableFrame?.origin ?? .zero

        // 2. Rows, in table order (one children read; known rows need no further IPC to be recognised).
        var rows: [(id: Node.Identity, node: Node)] = []
        for child in tableNow.children {
            let id = child.elementIdentity
            if cache.nonRows.contains(id) { continue }
            if cache.entries[id] != nil || child.role == AXRole.row {
                rows.append((id, child))
            } else {
                cache.nonRows.insert(id)
            }
        }
        if cache.entries.count >= 8, Double(rows.count) < Double(cache.entries.count) * cacheShrinkResetRatio {
            cache.clearRows()
        }
        let width = viewport?.width ?? 0
        let widthChanged = cache.analysisWidth.map { abs($0 - width) > 0.5 } ?? false
        cache.analysisWidth = width

        func expectedFrame(_ e: TranscriptRowCache<Node>.Entry) -> CGRect? {
            let d = e.offset(to: tableOrigin)
            return e.rowFrame?.offsetBy(dx: d.dx, dy: d.dy)
        }
        func onScreen(_ f: CGRect?) -> Bool {
            guard viewport != nil else { return true }
            return TranscriptParser.isOnScreen(f, viewport: viewport, inputFrame: inputFrame)
        }
        let nearBand = viewport.map { $0.insetBy(dx: 0, dy: -$0.height) }

        // 3. Decide what to analyse and which cached frames to validate.
        var analyse = Set<Int>()
        var verify: [Int] = []
        for (i, row) in rows.enumerated() {
            guard let e = cache.entries[row.id] else { analyse.insert(i); continue }
            if widthChanged { analyse.insert(i); continue }
            let f = expectedFrame(e)
            let age = now - e.analyzedAt
            if e.analysis == nil {
                if let band = nearBand, let f, band.intersects(f), age >= cache.lazyRetryInterval { analyse.insert(i) }
                else if onScreen(f), viewport != nil { verify.append(i) }
                continue
            }
            if viewport != nil, onScreen(f) {
                if age >= cache.visibleRefreshInterval { analyse.insert(i) } else { verify.append(i) }
            }
        }
        // Rows after an insertion / removal in the middle of the table moved relative to the table origin.
        let previous = cache.order
        var structuralFrom: Int?
        if !previous.isEmpty {
            let common = zip(previous, rows.map(\.id)).prefix { $0 == $1 }.count
            if common < previous.count { structuralFrom = common }
        }
        var verified = 0
        var refreshAll = false
        func refresh(_ i: Int) -> Bool {
            // true = frame matches (after correcting a pure translation); false = size changed (re-analyse).
            guard var e = cache.entries[rows[i].id] else { return false }
            verified += 1
            guard let actual = rows[i].node.frame, let expected = expectedFrame(e) else { return true }
            if abs(actual.width - expected.width) > 0.5 || abs(actual.height - expected.height) > 0.5 { return false }
            let dx = actual.minX - expected.minX, dy = actual.minY - expected.minY
            if abs(dx) > 0.5 || abs(dy) > 0.5 {
                e.translate(by: CGVector(dx: dx, dy: dy))
                cache.entries[rows[i].id] = e
                refreshAll = true
            }
            return true
        }
        var checked = Set<Int>()
        for i in verify {
            checked.insert(i)
            if !refresh(i) { analyse.insert(i); refreshAll = true }
        }
        func refreshFrames(from start: Int) {
            guard start < rows.count else { return }
            for i in start..<rows.count where !analyse.contains(i) && checked.insert(i).inserted {
                if !refresh(i) { analyse.insert(i) }
            }
        }
        if refreshAll { refreshFrames(from: 0) } else if let s = structuralFrom { refreshFrames(from: s) }

        // 4. Analyse (visible rows first is irrelevant here: the call is synchronous).
        var heightChangedAt: Int?
        for i in analyse.sorted() {
            let node = rows[i].node
            let rowFrame = node.frame
            let a = parser.analyzeRow(node, rowFrame: rowFrame, transcriptFrame: viewport)
            if let old = cache.entries[rows[i].id], let of = old.rowFrame, let nf = rowFrame,
               abs(of.height - nf.height) > 0.5, heightChangedAt == nil {
                heightChangedAt = i
            }
            cache.entries[rows[i].id] = .init(analysis: a, rowFrame: rowFrame, tableOrigin: tableOrigin, analyzedAt: now)
        }
        // A row that grew or shrank pushes the rows below it within the table.
        if let h = heightChangedAt { refreshFrames(from: h + 1) }

        // 5. Prune rows that left the table; remember the order.
        let present = Set(rows.map(\.id))
        if present.count != cache.entries.count {
            cache.entries = cache.entries.filter { present.contains($0.key) }
        }
        cache.order = rows.map(\.id)
        cache.setLastTable(tableNow)

        // 6. Assemble every loaded row (in memory), top to bottom.
        var items: [(analysis: TranscriptParser.RowAnalysis, frame: CGRect?, order: Int)] = []
        items.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() {
            guard let e = cache.entries[row.id], let a = e.analysis else { continue }
            let d = e.offset(to: tableOrigin)
            let shifted = a.offsetBy(dx: d.dx, dy: d.dy)
            items.append((shifted, shifted.rowFrame, i))
        }
        items.sort { a, b in
            let ay = a.frame?.minY ?? .greatestFiniteMagnitude, by = b.frame?.minY ?? .greatestFiniteMagnitude
            if ay != by { return ay < by }
            let ax = a.frame?.minX ?? .greatestFiniteMagnitude, bx = b.frame?.minX ?? .greatestFiniteMagnitude
            if ax != bx { return ax < bx }
            return a.order < b.order
        }
        let assembled = parser.assemble(items.map(\.analysis))
        let key = MessageIdentity.chatKey(forTitle: title)
        let all = MessageIdentity.assign(assembled, chatKey: key)
        let keep = max(0, min(all.count, parser.maxRows))
        let start = all.count - keep
        var visible = Set<MessageID>()
        for i in start..<all.count where onScreen(items[i].frame) { visible.insert(all[i].id) }
        let snapshot = TranscriptSnapshot(chatKey: key, messages: Array(all[start...]), readAt: readAt)
        return ChatWindowRead(title: title, windowFrame: windowFrame, inputFrame: inputFrame, snapshot: snapshot,
                              elapsedMilliseconds: watch.elapsedMilliseconds, transcriptFrame: viewport,
                              tableFrame: tableFrame, visibleIDs: visible, rowsTotal: rows.count,
                              rowsAnalyzed: analyse.count, rowsVerified: verified)
    }
}
