// SPDX-License-Identifier: MIT
// Follows KakaoTalk's current chat window: frontmost/running state via NSWorkspace, window geometry and
// content changes via AXObserver, a cheap fallback poll only while KakaoTalk is frontmost and the panel is
// visible.
//
// Read-only: never activates, raises, focuses, scrolls or otherwise touches KakaoTalk.

import AppKit
import ApplicationServices
import Foundation
import KakaoAX
import os
import TalkLensCore

private let logger = Logger.talkLens("tracker")

@MainActor
final class WindowTracker: AXEventSink {
    enum State: Equatable {
        case idle
        case noPermission
        case kakaoNotRunning
        case noChatWindow
        case transcriptNotFound
        case tracking
    }

    struct Geometry {
        /// Chat window frame in AX coordinates (top-left origin), nil when there is no chat window.
        var windowAX: CGRect?
        /// Chat input box frame in AX coordinates, kept in sync with window moves/resizes.
        var inputAX: CGRect?
        var minimized: Bool
        /// Started when the triggering AX event arrived; nil for non-event updates.
        var stopwatch: Stopwatch?
    }

    // Notification names (literal strings: AX notification constants are plain CFSTR macros).
    static let appNotifications = ["AXFocusedWindowChanged", "AXMainWindowChanged", "AXWindowCreated"]
    static let windowNotifications = ["AXMoved", "AXResized", "AXUIElementDestroyed", "AXWindowMiniaturized",
                                      "AXWindowDeminiaturized", "AXTitleChanged"]
    static let contentNotifications = ["AXRowCountChanged", "AXCreated", "AXValueChanged", "AXLayoutChanged",
                                       "AXSelectedChildrenChanged"]
    /// Also registered on the application element, which receives it for descendant elements (a window
    /// registration may only see its own element). A new message posts AXRowCountChanged on the transcript
    /// AXTable (verified on KakaoTalk 26.8.0); events from any other table (other chat windows) only trigger
    /// the cheap probe. App-level AXCreated is not registered: tooltips and popovers post it constantly.
    static let appContentNotifications = ["AXRowCountChanged"]

    static let contentDebounce: Duration = .milliseconds(120)
    /// A continuous stream of content events still triggers a read at least this often.
    static let contentMaxWait: Duration = .milliseconds(400)
    static let pollInterval: Duration = .seconds(1)
    static let pollQuietPeriod: Duration = .seconds(5)
    /// The fallback poll does a full read at least this often even when the cheap probe sees no change.
    static let fullReadSafetyInterval: Duration = .seconds(10)
    /// Poll read cadence while there is no tracked transcript (state != .tracking).
    static let untrackedPollInterval: Duration = .seconds(3)
    /// App-level AXWindowCreated (also posted for tooltips/popovers) is coalesced this long.
    static let windowCreatedDebounce: Duration = .milliseconds(300)
    /// A single transient "transcript not found" is retried after this delay before it is reported.
    static let notFoundRetryDelay: Duration = .milliseconds(400)
    static let notFoundGrace: Duration = .milliseconds(1500)
    /// Upper bound on the main-thread time spent registering observers in one attach/bind.
    static let registrationBudget: Duration = .seconds(1)

    var onStateChange: ((State) -> Void)?
    /// The instant is when the first content event (or poll) behind this read happened.
    var onRead: ((ChatWindowRead, ContinuousClock.Instant) -> Void)?
    var onGeometry: ((Geometry) -> Void)?
    var onFrontmostChange: ((Bool) -> Void)?
    /// AXRowCountChanged on the followed transcript table (a new message; KakaoTalk may auto-scroll).
    var onTranscriptRowsChanged: (() -> Void)?

    private(set) var state: State = .idle
    private(set) var kakaoFrontmost = false
    private(set) var kakaoRunning = false
    private(set) var paused = false
    /// Whether the panel can currently be seen (set by AppController). While false nothing is read: requests
    /// only mark the content dirty, and one read happens when the panel becomes visible again.
    private(set) var contentWanted = false
    private(set) var geometry = Geometry(windowAX: nil, inputAX: nil, minimized: false, stopwatch: nil)
    /// Scroll anchor of the last successful read (set before `onRead` is called).
    private(set) var scrollAnchor: ScrollAnchor?

    private let reader: AXReader
    /// Cheap single-element reads (window geometry; the inline overlay's scroll anchor).
    let geometryReader = WindowGeometryReader()
    private let diagnostics: Diagnostics

    private var started = false
    private var routerToken = 0
    private var observation: AXObservation?
    private var observedWindow: AXElementRef?
    /// Transcript AXTable of the last successful read (filters app-level AXRowCountChanged).
    private var transcriptTable: AXElementRef?
    /// Input box position relative to the window's bottom-left corner (AX coordinates).
    private var inputInsets: (left: CGFloat, right: CGFloat, fromBottom: CGFloat, height: CGFloat)?

    private var workspaceTokens: [NSObjectProtocol] = []
    private var debounceTask: Task<Void, Never>?
    private var debounceFirstEventAt: ContinuousClock.Instant?
    /// True when at least one debounced event came from the followed window/table (→ full read); otherwise
    /// the debounced work is only a cheap probe.
    private var debounceNeedsRead = false
    private var pollTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var delayedRefreshTask: Task<Void, Never>?
    private var windowCheckTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    private var readInFlight = false
    private var readPending = false
    private var readDirty = false
    private var probeInFlight = false
    private var dragTrackingTask: Task<Void, Never>?
    private var dragLastChange: ContinuousClock.Instant = .now
    static let dragSampleInterval: Duration = .milliseconds(16)
    static let dragQuietPeriod: Duration = .milliseconds(300)
    private var geometryInFlight = false
    private var geometryPending = false
    private var geometryPendingStopwatch: Stopwatch?
    /// When the most recent fresh geometry read started; a full read requested before that must not
    /// overwrite the newer window frame.
    private var lastGeometryReadAt: ContinuousClock.Instant?
    private var lastContentEventAt = ContinuousClock.now
    private var lastFullReadAt: ContinuousClock.Instant?
    /// First content event not yet covered by a started read.
    private var pendingTriggerAt: ContinuousClock.Instant?
    private var notFoundStreak = 0
    private var notFoundSince: ContinuousClock.Instant?

    init(reader: AXReader, diagnostics: Diagnostics) {
        self.reader = reader
        self.diagnostics = diagnostics
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        routerToken = AXEventRouter.register(self)
        subscribeWorkspace()
        kakaoFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == KakaoProcess.bundleIdentifier
        refreshAttachment()
    }

    /// Removes every observer, run-loop source, notification token and task.
    func stop() {
        guard started else { return }
        started = false
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens { center.removeObserver(token) }
        workspaceTokens.removeAll()
        for task in [debounceTask, pollTask, permissionTask, delayedRefreshTask, windowCheckTask, retryTask,
                     dragTrackingTask] {
            task?.cancel()
        }
        debounceTask = nil
        pollTask = nil
        permissionTask = nil
        delayedRefreshTask = nil
        windowCheckTask = nil
        retryTask = nil
        detach()
        AXEventRouter.unregister(routerToken)
    }

    func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        updatePolling()
        requestRead()
    }

    /// Called by AppController whenever panel visibility is recomputed.
    func setContentWanted(_ value: Bool) {
        guard contentWanted != value else { return }
        contentWanted = value
        updatePolling()
        guard value, started else { return }
        if readDirty {
            requestRead()
        } else {
            // Scrolling posts no notification; a cheap probe catches anything that changed while hidden.
            probeAndMaybeRead()
            geometryChanged(stopwatch: nil)
        }
    }

    /// Re-checks permission and process, (re)attaches observers and reads once. Safe to call any time.
    func refreshAttachment() {
        guard started else { return }
        guard AccessibilityAccess.isGranted else {
            handlePermissionLoss()
            return
        }
        permissionTask?.cancel()
        permissionTask = nil
        guard let app = KakaoProcess.runningApplication else {
            detach()
            kakaoRunning = false
            setState(.kakaoNotRunning)
            updatePolling()
            return
        }
        kakaoRunning = true
        if observation?.pid != app.processIdentifier || observation?.isValid != true {
            detach()
            attach(pid: app.processIdentifier)
        }
        updatePolling()
        requestRead()
    }

    // MARK: - Observers

    private func attach(pid: pid_t) {
        let made = AXObservation.make(pid: pid, token: routerToken)
        guard let obs = made.observation else {
            logger.error("attach failed code=\(made.error.rawValue, privacy: .public)")
            if made.error == .apiDisabled { handlePermissionLoss() }
            return
        }
        guard let appNode = KakaoProcess.applicationNode() else {
            // KakaoTalk quit (or is quitting) between the process check and here: retry shortly.
            obs.invalidate()
            scheduleRefresh(after: .seconds(2))
            return
        }
        observation = obs
        let deadline = ContinuousClock.now + Self.registrationBudget
        let result = obs.add(Self.appNotifications + Self.appContentNotifications, to: appNode.element,
                             deadline: deadline)
        logger.info("attached app observer registered=\(result.registered) unsupported=\(result.unsupported) errors=\(result.otherErrors) skipped=\(result.skipped)")
        if result.permissionDenied {
            handlePermissionLoss()
        } else if result.registered == 0 {
            // KakaoTalk just launched or is busy: AX not ready yet. Retry shortly.
            obs.invalidate()
            observation = nil
            scheduleRefresh(after: .seconds(2))
        }
    }

    private func detach() {
        debounceTask?.cancel()
        debounceTask = nil
        debounceNeedsRead = false
        windowCheckTask?.cancel()
        windowCheckTask = nil
        retryTask?.cancel()
        retryTask = nil
        observation?.invalidate()
        observation = nil
        stopDragTracking()
        observedWindow = nil
        transcriptTable = nil
        scrollAnchor = nil
        inputInsets = nil
        geometryPending = false
        geometryPendingStopwatch = nil
        resetNotFound()
    }

    /// Follows `window`. Always stores the latest reference; observers are only (re)registered when the
    /// underlying element changes.
    private func bindWindow(_ window: AXElementRef) {
        if let current = observedWindow, current.isSame(as: window) {
            observedWindow = window
            return
        }
        if let current = observedWindow { observation?.removeAll(for: current.element) }
        observedWindow = window
        transcriptTable = nil
        inputInsets = nil
        // Client-side IPC timeout for our own reads of this element (does not modify KakaoTalk).
        AXUIElementSetMessagingTimeout(window.element, 0.3)
        if let obs = observation {
            let deadline = ContinuousClock.now + Self.registrationBudget
            let w = obs.add(Self.windowNotifications, to: window.element, deadline: deadline)
            let c = obs.add(Self.contentNotifications, to: window.element, deadline: deadline)
            logger.info("bound window registered=\(w.registered + c.registered) unsupported=\(w.unsupported + c.unsupported) skipped=\(w.skipped + c.skipped)")
            if w.permissionDenied || c.permissionDenied { handlePermissionLoss() }
        }
        geometryChanged(stopwatch: nil)
    }

    private func unbindWindow() {
        if let current = observedWindow { observation?.removeAll(for: current.element) }
        observedWindow = nil
        transcriptTable = nil
        scrollAnchor = nil
        inputInsets = nil
        geometry = Geometry(windowAX: nil, inputAX: nil, minimized: false, stopwatch: nil)
        onGeometry?(geometry)
    }

    func axEventReceived(_ name: String, element: AXElementRef) {
        diagnostics.recordAXEvent()
        switch name {
        case "AXMoved", "AXResized":
            geometryChanged(stopwatch: Stopwatch())
            startDragTracking()
        case "AXWindowMiniaturized":
            geometry.minimized = true
            geometry.stopwatch = nil
            onGeometry?(geometry)
        case "AXWindowDeminiaturized":
            geometryChanged(stopwatch: Stopwatch())
            requestRead()
        case "AXUIElementDestroyed":
            unbindWindow()
            requestRead()
        case "AXWindowCreated":
            // Tooltips and popovers post this too; only re-evaluate which chat window to follow.
            scheduleWindowReevaluation()
        case "AXTitleChanged", "AXFocusedWindowChanged", "AXMainWindowChanged":
            requestRead()
        case "AXRowCountChanged":
            // Row-count changes of other tables (e.g. another open chat window) only warrant a cheap probe.
            let ours = transcriptTable.map { $0.isSame(as: element) } ?? true
            contentEvent(needsRead: ours)
            if ours { onTranscriptRowsChanged?() }
        default:
            contentEvent(needsRead: true)
        }
    }

    // MARK: - Geometry (move/resize drive the panel directly)

    /// At most one fresh geometry read is in flight; bursts (AXResized arrives at ~60 Hz) collapse into one
    /// follow-up read whose result is the latest frame.
    private func geometryChanged(stopwatch: Stopwatch?) {
        guard let window = observedWindow else { return }
        if geometryInFlight {
            geometryPending = true
            if geometryPendingStopwatch == nil { geometryPendingStopwatch = stopwatch }
            return
        }
        geometryInFlight = true
        lastGeometryReadAt = .now
        Task {
            let g = await geometryReader.geometry(of: window)
            geometryInFlight = false
            // Ignore results for a window we no longer follow.
            if let g, let current = observedWindow, current.isSame(as: window) {
                applyGeometry(g, stopwatch: stopwatch)
            }
            if geometryPending {
                geometryPending = false
                let pendingStopwatch = geometryPendingStopwatch
                geometryPendingStopwatch = nil
                geometryChanged(stopwatch: pendingStopwatch)
            }
        }
    }

    // MARK: - Drag tracking

    /// KakaoTalk posts AXMoved only about every 100 ms while a window is dragged, which makes the panel move
    /// in visible steps. After any move/resize event, sample the frame at display rate (one cheap
    /// position/size read per tick, coalesced by `geometryChanged`) until it has been still for a moment.
    private func startDragTracking() {
        dragLastChange = .now
        guard dragTrackingTask == nil else { return }
        dragTrackingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.dragSampleInterval, tolerance: .milliseconds(4))
                guard let self, !Task.isCancelled else { return }
                if ContinuousClock.now - self.dragLastChange > Self.dragQuietPeriod { break }
                self.geometryChanged(stopwatch: nil)
            }
            self?.dragTrackingTask = nil
        }
    }

    private func stopDragTracking() {
        dragTrackingTask?.cancel()
        dragTrackingTask = nil
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
        onGeometry?(geometry)
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

    // MARK: - Reads

    private func contentEvent(needsRead: Bool) {
        lastContentEventAt = .now
        if needsRead, pendingTriggerAt == nil { pendingTriggerAt = lastContentEventAt }
        if needsRead { debounceNeedsRead = true }
        scheduleDebouncedRead()
    }

    private func scheduleDebouncedRead() {
        let now = ContinuousClock.now
        if debounceTask != nil, let first = debounceFirstEventAt, now - first >= Self.contentMaxWait {
            return // Let the pending task fire; do not postpone it further.
        }
        if debounceTask == nil { debounceFirstEventAt = now }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: WindowTracker.contentDebounce)
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            self.debounceFirstEventAt = nil
            let needsRead = self.debounceNeedsRead
            self.debounceNeedsRead = false
            if needsRead { self.requestRead() } else { self.probeAndMaybeRead() }
        }
    }

    private func scheduleWindowReevaluation() {
        windowCheckTask?.cancel()
        windowCheckTask = Task { [weak self] in
            try? await Task.sleep(for: WindowTracker.windowCreatedDebounce)
            guard !Task.isCancelled, let self else { return }
            self.windowCheckTask = nil
            guard self.started, self.kakaoRunning else { return }
            guard self.contentWanted else {
                self.markSkippedHidden()
                return
            }
            let current = self.observedWindow
            if await self.reader.chatWindowChanged(from: current) { self.requestRead() }
        }
    }

    func requestRead() {
        guard started, kakaoRunning, state != .noPermission || AccessibilityAccess.isGranted else { return }
        guard contentWanted else {
            markSkippedHidden()
            return
        }
        if readInFlight {
            readPending = true
            return
        }
        readInFlight = true
        readDirty = false
        let requestedAt = ContinuousClock.now
        let triggeredAt = pendingTriggerAt ?? requestedAt
        pendingTriggerAt = nil
        let resolveOnly = paused
        Task {
            let outcome = resolveOnly ? await reader.resolveWindow() : await reader.read(requestedAt: requestedAt)
            readInFlight = false
            if !resolveOnly { lastFullReadAt = .now }
            handle(outcome, requestedAt: requestedAt, triggeredAt: triggeredAt)
            if readPending {
                readPending = false
                requestRead()
            }
        }
    }

    private func markSkippedHidden() {
        readDirty = true
        diagnostics.recordSkippedHiddenRead()
    }

    /// Cheap probe (row count + last row frame + window size); a full read only when something changed or
    /// there is nothing to compare with.
    private func probeAndMaybeRead() {
        guard started, kakaoRunning, contentWanted, !paused, !probeInFlight, !readInFlight else { return }
        probeInFlight = true
        Task {
            let result = await reader.probe()
            probeInFlight = false
            diagnostics.recordCheapPollCheck()
            if result != .unchanged { requestRead() }
        }
    }

    private func handle(_ outcome: ReadOutcome, requestedAt: ContinuousClock.Instant,
                        triggeredAt: ContinuousClock.Instant) {
        guard started else { return }
        switch outcome {
        case .read(let result, let window, let table, let anchor):
            diagnostics.recordRead(result.elapsedMilliseconds)
            resetNotFound()
            bindWindow(window)
            transcriptTable = table
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
                onGeometry?(geometry)
            }
            setState(.tracking)
            onRead?(result, triggeredAt)
        case .windowOnly(let window, let g):
            resetNotFound()
            bindWindow(window)
            applyGeometry(g, stopwatch: nil)
            setState(.tracking)
        case .failure(let error, let window):
            diagnostics.recordRead(nil)
            logger.debug("read failed reason=\(String(describing: error), privacy: .public)")
            if error == .notTrusted {
                handlePermissionLoss()
            } else if error == .notRunning {
                detach()
                kakaoRunning = false
                setState(.kakaoNotRunning)
                updatePolling()
            } else if error == .noChatWindow {
                resetNotFound()
                unbindWindow()
                setState(.noChatWindow)
            } else {
                if let window { bindWindow(window) }
                transcriptNotFound()
            }
        }
    }

    /// One transient miss (e.g. mid-relayout) is retried; the state (which clears the sidebar) changes only
    /// after two consecutive misses or a miss streak longer than `notFoundGrace`.
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
            try? await Task.sleep(for: WindowTracker.notFoundRetryDelay)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.requestRead()
        }
    }

    private func resetNotFound() {
        notFoundStreak = 0
        notFoundSince = nil
    }

    // MARK: - Polling

    private func updatePolling() {
        let shouldPoll = started && kakaoFrontmost && kakaoRunning && contentWanted && state != .noPermission
        if shouldPoll {
            guard pollTask == nil else { return }
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: WindowTracker.pollInterval, tolerance: .milliseconds(200))
                    guard !Task.isCancelled, let self else { return }
                    self.pollTick()
                }
            }
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func pollTick() {
        // Geometry fallback (one IPC): the panel follows within ~1 s even if a move/resize event is missed.
        geometryChanged(stopwatch: nil)
        guard !paused, ContinuousClock.now - lastContentEventAt >= Self.pollQuietPeriod else { return }
        let sinceFull = lastFullReadAt.map { ContinuousClock.now - $0 }
        if state != .tracking {
            // Nothing to probe (no chat window / no transcript): window events drive discovery, the poll only
            // retries at a slow cadence.
            if sinceFull.map({ $0 >= Self.untrackedPollInterval }) ?? true {
                diagnostics.recordPollRead()
                requestRead()
            }
            return
        }
        if let sinceFull, sinceFull >= Self.fullReadSafetyInterval {
            diagnostics.recordPollRead()
            requestRead()
            return
        }
        probeAndMaybeRead()
    }

    private func handlePermissionLoss() {
        detach()
        // Process state does not need AX; it decides whether the "permission needed" panel is shown.
        kakaoRunning = KakaoProcess.isRunning
        setState(.noPermission)
        updatePolling()
        guard permissionTask == nil, started else { return }
        // Pick up a grant without restarting the app.
        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1500), tolerance: .milliseconds(300))
                guard !Task.isCancelled, let self else { return }
                if AccessibilityAccess.isGranted {
                    self.permissionTask = nil
                    logger.info("accessibility granted; attaching")
                    self.refreshAttachment()
                    return
                }
            }
        }
    }

    // MARK: - NSWorkspace

    private func subscribeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let kakaoID = KakaoProcess.bundleIdentifier
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (WindowTracker, Bool) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let isKakao = app?.bundleIdentifier == kakaoID
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self, isKakao)
                }
            }
            workspaceTokens.append(token)
        }
        observe(NSWorkspace.didActivateApplicationNotification) { tracker, isKakao in
            tracker.frontmostChanged(isKakao)
        }
        observe(NSWorkspace.didLaunchApplicationNotification) { tracker, isKakao in
            guard isKakao else { return }
            // AX is not ready immediately after launch.
            tracker.scheduleRefresh(after: .seconds(1))
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { tracker, isKakao in
            guard isKakao else { return }
            tracker.kakaoTerminated()
        }
        observe(NSWorkspace.didWakeNotification) { tracker, _ in
            tracker.scheduleRefresh(after: .seconds(1))
        }
    }

    private func frontmostChanged(_ isKakao: Bool) {
        guard kakaoFrontmost != isKakao else { return }
        kakaoFrontmost = isKakao
        // AppController recomputes visibility here (→ setContentWanted, which reads if dirty).
        onFrontmostChange?(isKakao)
        if isKakao {
            if observation == nil { refreshAttachment() } else if readDirty { requestRead() } else { probeAndMaybeRead() }
        }
        updatePolling()
    }

    private func kakaoTerminated() {
        detach()
        kakaoRunning = false
        kakaoFrontmost = false
        geometry = Geometry(windowAX: nil, inputAX: nil, minimized: false, stopwatch: nil)
        onGeometry?(geometry)
        setState(.kakaoNotRunning)
        onFrontmostChange?(false)
        updatePolling()
        Task { await reader.clear() }
    }

    private func scheduleRefresh(after delay: Duration) {
        delayedRefreshTask?.cancel()
        delayedRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.delayedRefreshTask = nil
            self.refreshAttachment()
        }
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        logger.info("state=\(String(describing: new), privacy: .public)")
        onStateChange?(new)
    }
}
