// SPDX-License-Identifier: MIT
// One followed KakaoTalk chat window: its AX observation (window-level notifications and the transcript
// table's AXRowCountChanged), geometry and drag tracking, read requests (executed one at a time across all
// sessions by SessionManager through the single AXReader actor), its own row model (SidebarViewModel, own
// translation channel) and its own inline overlay with its own occlusion mask.
//
// Read-only: never activates, raises, focuses, scrolls or otherwise touches KakaoTalk.

import AppKit
import ApplicationServices
import Foundation
import KakaoAX
import os
import TalkLensCore

private let logger = Logger.talkLens("session")

@MainActor
final class ChatSession: AXEventSink, InlineOverlayHost {
    enum State: Equatable {
        /// Not read successfully yet.
        case pending
        case tracking
        case transcriptNotFound
    }

    struct Geometry {
        /// Chat window frame in AX coordinates (top-left origin), nil when unknown.
        var windowAX: CGRect?
        /// Chat input box frame in AX coordinates, kept in sync with window moves/resizes.
        var inputAX: CGRect?
        var minimized: Bool
        /// Started when the triggering AX event arrived; nil for non-event updates.
        var stopwatch: Stopwatch?
    }

    // Notification names (literal strings: AX notification constants are plain CFSTR macros).
    static let windowNotifications = ["AXMoved", "AXResized", "AXUIElementDestroyed", "AXWindowMiniaturized",
                                      "AXWindowDeminiaturized", "AXTitleChanged"]
    static let contentNotifications = ["AXRowCountChanged", "AXCreated", "AXValueChanged", "AXLayoutChanged",
                                       "AXSelectedChildrenChanged"]
    /// Registered on the transcript AXTable once it is known: a new message posts it there (26.8.0).
    static let tableNotifications = ["AXRowCountChanged"]

    static let contentDebounce: Duration = .milliseconds(120)
    /// AXRowCountChanged on the followed transcript table (a new message): read sooner (D-027).
    static let rowCountDebounce: Duration = .milliseconds(40)
    /// A continuous stream of content events still triggers a read at least this often.
    static let contentMaxWait: Duration = .milliseconds(400)
    /// Rows still pending after a budgeted read are read after this pause (D-020).
    static let prefetchPause: Duration = .milliseconds(150)
    static let dragSampleInterval: Duration = .milliseconds(16)
    static let dragQuietPeriod: Duration = .milliseconds(300)
    /// A single transient "transcript not found" is retried after this delay before it is reported.
    static let notFoundRetryDelay: Duration = .milliseconds(400)
    static let notFoundGrace: Duration = .milliseconds(1500)

    let id: Int
    /// TranslationService channel of this window.
    let channel: String
    let window: AXElementRef
    let key: AXElementKey
    let model: SidebarViewModel
    private(set) var inline: InlineOverlayController!
    /// Occlusion of this chat window (windows above it, including other KakaoTalk chat windows).
    let occlusion = WindowOcclusion()
    private(set) var occlusionState: OcclusionSnapshot = .notOnScreen

    private(set) var state: State = .pending
    private(set) var geometry: Geometry
    /// Scroll anchor of the last successful read (set before the read is applied to the overlay).
    private(set) var scrollAnchor: ScrollAnchor?
    /// Whether this window's translations can currently be seen (set by AppController). While false nothing
    /// is read: requests only mark the content dirty, and one read happens when it becomes visible again.
    private(set) var contentWanted = false
    private(set) var ended = false
    /// Larger = focused more recently (SessionManager's focus counter).
    var focusSerial = 0

    private weak var manager: SessionManager?
    private let diagnostics: Diagnostics
    nonisolated let geometryReader: WindowGeometryReader
    private var routerToken = 0
    private var observation: AXObservation?
    /// Transcript AXTable of the last successful read (filters app-level AXRowCountChanged).
    private(set) var transcriptTable: AXElementRef?
    /// Input box position relative to the window's bottom-left corner (AX coordinates).
    private var inputInsets: (left: CGFloat, right: CGFloat, fromBottom: CGFloat, height: CGFloat)?

    // Read bookkeeping (the queue itself lives in SessionManager).
    var readDirty = true
    private(set) var lastContentEventAt = ContinuousClock.now
    var lastFullReadAt: ContinuousClock.Instant?
    /// First content event not yet covered by a started read.
    private var pendingTriggerAt: ContinuousClock.Instant?
    /// Why the queued read was requested (content event / poll win over anything else).
    private var pendingTrigger: ReadTrigger?
    private var debounceTask: Task<Void, Never>?
    private var debounceFirstEventAt: ContinuousClock.Instant?
    private var debounceDeadline: ContinuousClock.Instant?
    /// The pending debounce includes an AXRowCountChanged of the followed table (short debounce).
    private var debounceFast = false
    /// True when at least one debounced event came from this window/table (→ full read); otherwise only a
    /// cheap probe.
    private var debounceNeedsRead = false
    private var probeInFlight = false
    private var retryTask: Task<Void, Never>?
    private var notFoundStreak = 0
    private var notFoundSince: ContinuousClock.Instant?

    // Geometry bookkeeping.
    private var dragTrackingTask: Task<Void, Never>?
    private var dragLastChange: ContinuousClock.Instant = .now
    private var geometryInFlight = false
    private var geometryPending = false
    private var geometryPendingStopwatch: Stopwatch?
    /// When the most recent fresh geometry read started; a full read requested before that must not
    /// overwrite the newer window frame.
    private var lastGeometryReadAt: ContinuousClock.Instant?

    init(id: Int, info: ChatWindowInfo, model: SidebarViewModel, manager: SessionManager,
         geometryReader: WindowGeometryReader, diagnostics: Diagnostics) {
        self.id = id
        channel = Self.channelName(id)
        window = info.window
        key = info.key
        self.model = model
        self.manager = manager
        self.geometryReader = geometryReader
        self.diagnostics = diagnostics
        geometry = Geometry(windowAX: info.frame, inputAX: nil, minimized: false, stopwatch: nil)
        inline = InlineOverlayController(model: model, diagnostics: diagnostics)
        inline.host = self
    }

    var windowAX: CGRect? { geometry.windowAX }

    // MARK: - Lifecycle

    /// Registers this window's observers (synchronous IPC; bounded by `deadline`) and reads the geometry.
    func start(pid: pid_t, deadline: ContinuousClock.Instant) {
        guard !ended, observation == nil else { return }
        routerToken = AXEventRouter.register(self)
        // Client-side IPC timeout for our own reads of this element (does not modify KakaoTalk).
        AXUIElementSetMessagingTimeout(window.element, 0.3)
        model.setTrackerStatus(.starting)
        let made = AXObservation.make(pid: pid, token: routerToken)
        var denied = false
        if let obs = made.observation {
            observation = obs
            let w = obs.add(Self.windowNotifications, to: window.element, deadline: deadline)
            let c = obs.add(Self.contentNotifications, to: window.element, deadline: deadline)
            logger.info("session \(self.id, privacy: .public) registered=\(w.registered + c.registered) unsupported=\(w.unsupported + c.unsupported) skipped=\(w.skipped + c.skipped)")
            denied = w.permissionDenied || c.permissionDenied
        } else {
            logger.error("session observer failed code=\(made.error.rawValue, privacy: .public)")
            denied = made.error == .apiDisabled
        }
        if denied {
            manager?.permissionLost()
            return
        }
        geometryChanged(stopwatch: nil)
    }

    static func channelName(_ id: Int) -> String { "window-\(id)" }

    /// Removes every observer registration and run-loop source, cancels every task and drops the chat content
    /// held by the model and the overlay.
    func end() {
        guard !ended else { return }
        ended = true
        for task in [debounceTask, retryTask, dragTrackingTask] { task?.cancel() }
        debounceTask = nil
        retryTask = nil
        dragTrackingTask = nil
        observation?.invalidate()
        observation = nil
        AXEventRouter.unregister(routerToken)
        inline.stop()
        inline.host = nil
        occlusion.reset()
        model.setTrackerStatus(.noChatWindow)
        transcriptTable = nil
        scrollAnchor = nil
    }

    // MARK: - AX events

    func axEventReceived(_ name: String, element: AXElementRef) {
        guard !ended else { return }
        diagnostics.recordAXEvent()
        switch name {
        case "AXMoved", "AXResized":
            geometryChanged(stopwatch: Stopwatch())
            startDragTracking()
        case "AXWindowMiniaturized":
            geometry.minimized = true
            geometry.stopwatch = nil
            manager?.sessionGeometryChanged(self)
            manager?.scheduleEnumeration()
        case "AXWindowDeminiaturized":
            geometryChanged(stopwatch: Stopwatch())
            requestRead()
        case "AXUIElementDestroyed":
            if element.isSame(as: window) {
                manager?.sessionWindowDestroyed(self)
            } else {
                // Possibly the window under another element token: the enumeration settles it.
                contentEvent(needsRead: true)
                manager?.scheduleEnumeration()
            }
        case "AXTitleChanged":
            requestRead()
        case "AXRowCountChanged":
            transcriptRowsChanged(element: element)
        default:
            contentEvent(needsRead: true)
        }
    }

    /// AXRowCountChanged from this window (or routed here from the app-level registration). On the followed
    /// table it means a new message (or loaded history): read after the short debounce.
    func transcriptRowsChanged(element: AXElementRef) {
        let known = transcriptTable?.isSame(as: element)
        let ours = known ?? true
        contentEvent(needsRead: ours, fast: known == true)
        if ours { inline.transcriptRowsChanged() }
    }

    // MARK: - Visibility

    func setContentWanted(_ value: Bool) {
        guard contentWanted != value else { return }
        contentWanted = value
        guard value, !ended else { return }
        if readDirty {
            requestRead()
        } else {
            // Scrolling posts no notification; a cheap probe catches anything that changed while hidden.
            probeAndMaybeRead(trigger: .other)
            geometryChanged(stopwatch: nil)
        }
    }

    /// Recomputes which parts of this chat window other windows cover. `windows` = the on-screen window list
    /// (front to back), nil when the overlay cannot be shown at all.
    func refreshOcclusion(windows: [WindowListEntry]?, kakaoPID: pid_t?) {
        let next: OcclusionSnapshot
        if let windows, let pid = kakaoPID, let frame = geometry.windowAX, !geometry.minimized {
            next = occlusion.update(windows: windows, kakaoPID: pid, chatFrame: frame)
        } else {
            if occlusion.last != .notOnScreen { occlusion.reset() }
            next = .notOnScreen
        }
        guard next != occlusionState else { return }
        occlusionState = next
        inline.setOccluders(next.occluders)
    }

    /// Chat-window area not covered by other windows (approximate: overlapping occluders count twice).
    var visibleArea: CGFloat {
        guard let frame = geometry.windowAX else { return 0 }
        guard occlusionState.onScreen else { return frame.width * frame.height }
        if occlusionState.fullyCovered { return 0 }
        let covered = occlusionState.occluders.reduce(0) { $0 + $1.width * $1.height }
        return max(0, frame.width * frame.height - covered)
    }

    // MARK: - Reads

    /// Asks SessionManager for a full read of this window (serialized with every other session's reads).
    func requestRead() {
        requestRead(trigger: .other)
    }

    func requestRead(trigger: ReadTrigger) {
        guard !ended else { return }
        guard contentWanted else {
            readDirty = true
            // Whatever arrives while nothing is read is picked up by the read on return: not a latency sample.
            pendingTriggerAt = nil
            pendingTrigger = nil
            diagnostics.recordSkippedHiddenRead()
            return
        }
        readDirty = false
        if pendingTrigger?.canSample != true { pendingTrigger = trigger }
        manager?.enqueueRead(self, followUp: false)
    }

    /// Called by SessionManager when the read starts; returns the instant of the first content event behind it
    /// and why the read happens.
    func readStarting(at requestedAt: ContinuousClock.Instant, followUp: Bool) -> (ContinuousClock.Instant, ReadTrigger) {
        let triggeredAt = pendingTriggerAt ?? requestedAt
        let trigger = pendingTrigger ?? (followUp ? .followUp : .other)
        pendingTriggerAt = nil
        pendingTrigger = nil
        return (triggeredAt, trigger)
    }

    private func contentEvent(needsRead: Bool, fast: Bool = false) {
        lastContentEventAt = .now
        if needsRead, pendingTriggerAt == nil { pendingTriggerAt = lastContentEventAt }
        if needsRead { debounceNeedsRead = true }
        scheduleDebouncedRead(fast: fast && needsRead)
    }

    /// Events are coalesced for `contentDebounce` (each event postpones the read, up to `contentMaxWait`); an
    /// AXRowCountChanged of the followed table shortens the wait to `rowCountDebounce` and is never postponed.
    private func scheduleDebouncedRead(fast: Bool) {
        let now = ContinuousClock.now
        if debounceTask != nil, let first = debounceFirstEventAt, now - first >= Self.contentMaxWait {
            return // Let the pending task fire; do not postpone it further.
        }
        var deadline = now + (fast ? Self.rowCountDebounce : Self.contentDebounce)
        if debounceTask != nil, let current = debounceDeadline, debounceFast || fast {
            deadline = min(current, deadline)
        }
        if debounceTask == nil { debounceFirstEventAt = now }
        debounceFast = debounceFast || fast
        debounceDeadline = deadline
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(until: deadline, tolerance: .milliseconds(5), clock: .continuous)
            guard !Task.isCancelled, let self, !self.ended else { return }
            self.debounceTask = nil
            self.debounceFirstEventAt = nil
            self.debounceDeadline = nil
            self.debounceFast = false
            let needsRead = self.debounceNeedsRead
            self.debounceNeedsRead = false
            if needsRead { self.requestRead(trigger: .contentEvent) } else { self.probeAndMaybeRead(trigger: .contentEvent) }
        }
    }

    /// Cheap probe (row count + last row frame + window size); a full read only when something changed or
    /// there is nothing to compare with.
    func probeAndMaybeRead(trigger: ReadTrigger = .poll) {
        guard !ended, contentWanted, let manager, !manager.paused, !probeInFlight,
              !manager.isReading(self) else { return }
        probeInFlight = true
        let reader = manager.reader
        let window = self.window
        Task {
            let result = await reader.probe(window: window)
            probeInFlight = false
            guard !ended else { return }
            diagnostics.recordCheapPollCheck()
            if result != .unchanged { requestRead(trigger: trigger) }
        }
    }

    /// Applies a read result (called by SessionManager on the main actor).
    func handle(_ outcome: ReadOutcome, requestedAt: ContinuousClock.Instant, triggeredAt: ContinuousClock.Instant,
                trigger: ReadTrigger) {
        guard !ended else { return }
        switch outcome {
        case .read(let result, _, let table, let anchor):
            diagnostics.markStartup(.firstRead)
            let timing = ReadTiming(trigger: trigger, triggeredAt: triggeredAt, readStartedAt: requestedAt,
                                    readEndedAt: .now, rowsTotal: result.rowsTotal)
            diagnostics.recordRead(result.elapsedMilliseconds, rowsAnalyzed: result.rowsAnalyzed,
                                   rowsTotal: result.rowsTotal)
            lastFullReadAt = .now
            resetNotFound()
            bindTable(table)
            scrollAnchor = anchor
            if let frame = result.windowFrame {
                rememberInput(result.inputFrame, window: frame)
                // A fresh geometry read that started after this read was requested is newer: keep its frame.
                let newerGeometry = lastGeometryReadAt.map { $0 > requestedAt } ?? false
                if !newerGeometry || geometry.windowAX == nil {
                    geometry.windowAX = frame
                    geometry.inputAX = result.inputFrame
                } else if let current = geometry.windowAX {
                    geometry.inputAX = inputFrame(for: current)
                }
                geometry.stopwatch = nil
                manager?.sessionGeometryChanged(self)
            }
            setState(.tracking)
            model.ingest(result, timing: timing)
            inline.ingest(result, anchor: anchor)
            if result.rowsPending > 0, contentWanted {
                manager?.enqueueRead(self, followUp: true)
            }
        case .windowOnly(_, let g):
            resetNotFound()
            applyGeometry(g, stopwatch: nil)
            setState(.tracking)
        case .failure(let error, _):
            diagnostics.recordRead(nil)
            logger.debug("session read failed reason=\(String(describing: error), privacy: .public)")
            switch error {
            case .notTrusted: manager?.permissionLost()
            case .notRunning: manager?.kakaoTerminated()
            case .noChatWindow: manager?.sessionWindowDestroyed(self)
            case .transcriptNotFound: transcriptNotFound()
            }
        }
    }

    private func bindTable(_ table: AXElementRef?) {
        if let current = transcriptTable, let table, current.isSame(as: table) {
            transcriptTable = table
            return
        }
        if let current = transcriptTable { observation?.removeAll(for: current.element) }
        transcriptTable = table
        guard let table, let obs = observation else { return }
        let r = obs.add(Self.tableNotifications, to: table.element, deadline: .now + .milliseconds(300))
        if r.permissionDenied { manager?.permissionLost() }
    }

    /// One transient miss (e.g. mid-relayout) is retried; the state changes only after two consecutive misses
    /// or a miss streak longer than `notFoundGrace`.
    private func transcriptNotFound() {
        let now = ContinuousClock.now
        notFoundStreak += 1
        let since = notFoundSince ?? now
        notFoundSince = since
        if notFoundStreak >= 2 || now - since >= Self.notFoundGrace {
            setState(.transcriptNotFound)
            return
        }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: ChatSession.notFoundRetryDelay)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.requestRead()
        }
    }

    private func resetNotFound() {
        notFoundStreak = 0
        notFoundSince = nil
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        model.setTrackerStatus(Self.modelStatus(new))
        manager?.sessionStateChanged(self)
    }

    static func modelStatus(_ state: State) -> SidebarViewModel.Status {
        switch state {
        case .pending: return .starting
        case .tracking: return .active
        case .transcriptNotFound: return .transcriptNotFound
        }
    }

    // MARK: - Geometry (move/resize drive the overlay / panel directly)

    /// At most one fresh geometry read is in flight; bursts (AXResized arrives at ~60 Hz) collapse into one
    /// follow-up read whose result is the latest frame.
    func geometryChanged(stopwatch: Stopwatch?) {
        guard !ended else { return }
        if geometryInFlight {
            geometryPending = true
            if geometryPendingStopwatch == nil { geometryPendingStopwatch = stopwatch }
            return
        }
        geometryInFlight = true
        lastGeometryReadAt = .now
        let window = self.window
        Task {
            let g = await geometryReader.geometry(of: window)
            geometryInFlight = false
            guard !ended else { return }
            if let g { applyGeometry(g, stopwatch: stopwatch) }
            if geometryPending {
                geometryPending = false
                let pendingStopwatch = geometryPendingStopwatch
                geometryPendingStopwatch = nil
                geometryChanged(stopwatch: pendingStopwatch)
            }
        }
    }

    /// KakaoTalk posts AXMoved only about every 100 ms while a window is dragged. After any move/resize
    /// event, sample the frame at display rate (one cheap position/size read per tick, coalesced by
    /// `geometryChanged`) until it has been still for a moment.
    private func startDragTracking() {
        dragLastChange = .now
        guard dragTrackingTask == nil else { return }
        dragTrackingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ChatSession.dragSampleInterval, tolerance: .milliseconds(4))
                guard let self, !Task.isCancelled, !self.ended else { return }
                if ContinuousClock.now - self.dragLastChange > ChatSession.dragQuietPeriod { break }
                self.geometryChanged(stopwatch: nil)
            }
            self?.dragTrackingTask = nil
        }
    }

    private func applyGeometry(_ g: WindowGeometry, stopwatch: Stopwatch?) {
        var next = geometry
        next.minimized = g.minimized
        if let frame = g.frame {
            next.windowAX = frame
            next.inputAX = inputFrame(for: frame)
        }
        next.stopwatch = stopwatch
        // Poll-driven refreshes that found nothing new do not touch the panel.
        if stopwatch == nil, next.windowAX == geometry.windowAX, next.inputAX == geometry.inputAX,
           next.minimized == geometry.minimized {
            return
        }
        if next.windowAX != geometry.windowAX { dragLastChange = .now }
        geometry = next
        manager?.sessionGeometryChanged(self)
    }

    private func rememberInput(_ input: CGRect?, window: CGRect?) {
        guard let input, let window else {
            inputInsets = nil
            return
        }
        inputInsets = (left: input.minX - window.minX, right: window.maxX - input.maxX,
                       fromBottom: window.maxY - input.minY, height: input.height)
    }

    private func inputFrame(for window: CGRect) -> CGRect? {
        guard let i = inputInsets else { return nil }
        let width = max(0, window.width - i.left - i.right)
        return CGRect(x: window.minX + i.left, y: window.maxY - i.fromBottom, width: width, height: i.height)
    }
}
