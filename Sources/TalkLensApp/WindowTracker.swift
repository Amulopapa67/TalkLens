// SPDX-License-Identifier: MIT
// Follows KakaoTalk's current chat window: frontmost/running state via NSWorkspace, window geometry and
// content changes via AXObserver, fallback polling only while KakaoTalk is frontmost.
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
    /// Also registered on the application element, which receives them for descendant elements (a window
    /// registration may only see its own element). AXValueChanged is left out here so typing in the input box
    /// does not trigger reads. Debounce + max-wait bound the read rate either way.
    static let appContentNotifications = ["AXRowCountChanged", "AXCreated"]

    static let contentDebounce: Duration = .milliseconds(120)
    /// A continuous stream of content events still triggers a read at least this often.
    static let contentMaxWait: Duration = .milliseconds(400)
    static let pollInterval: Duration = .seconds(1)
    static let pollQuietPeriod: Duration = .seconds(5)

    var onStateChange: ((State) -> Void)?
    /// The instant is when the first content event (or poll) behind this read happened.
    var onRead: ((ChatWindowRead, ContinuousClock.Instant) -> Void)?
    var onGeometry: ((Geometry) -> Void)?
    var onFrontmostChange: ((Bool) -> Void)?

    private(set) var state: State = .idle
    private(set) var kakaoFrontmost = false
    private(set) var kakaoRunning = false
    private(set) var paused = false
    private(set) var geometry = Geometry(windowAX: nil, inputAX: nil, minimized: false, stopwatch: nil)

    private let reader: AXReader
    private let geometryReader = WindowGeometryReader()
    private let diagnostics: Diagnostics

    private var started = false
    private var routerToken = 0
    private var observation: AXObservation?
    private var observedWindow: LiveAXNode?
    /// Input box position relative to the window's bottom-left corner (AX coordinates).
    private var inputInsets: (left: CGFloat, right: CGFloat, fromBottom: CGFloat, height: CGFloat)?

    private var workspaceTokens: [NSObjectProtocol] = []
    private var debounceTask: Task<Void, Never>?
    private var debounceFirstEventAt: ContinuousClock.Instant?
    private var pollTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var delayedRefreshTask: Task<Void, Never>?

    private var readInFlight = false
    private var readPending = false
    private var geometryInFlight = false
    private var geometryPending = false
    private var geometryPendingStopwatch: Stopwatch?
    private var lastContentEventAt = ContinuousClock.now
    /// First content event not yet covered by a started read.
    private var pendingTriggerAt: ContinuousClock.Instant?

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
        debounceTask?.cancel()
        pollTask?.cancel()
        permissionTask?.cancel()
        delayedRefreshTask?.cancel()
        debounceTask = nil
        pollTask = nil
        permissionTask = nil
        delayedRefreshTask = nil
        detach()
        AXEventRouter.unregister(routerToken)
    }

    func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        updatePolling()
        requestRead()
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
        observation = obs
        guard let appNode = KakaoProcess.applicationNode() else { return }
        let result = obs.add(Self.appNotifications + Self.appContentNotifications, to: appNode.element)
        logger.info("attached app observer registered=\(result.registered) unsupported=\(result.unsupported) errors=\(result.otherErrors)")
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
        observation?.invalidate()
        observation = nil
        observedWindow = nil
        inputInsets = nil
        geometryPending = false
        geometryPendingStopwatch = nil
    }

    private func bindWindow(_ window: LiveAXNode) {
        if let current = observedWindow, CFEqual(current.element, window.element) { return }
        if let current = observedWindow { observation?.removeAll(for: current.element) }
        observedWindow = window
        inputInsets = nil
        // Client-side IPC timeout for our own reads of this element (does not modify KakaoTalk).
        AXUIElementSetMessagingTimeout(window.element, 0.3)
        if let obs = observation {
            let w = obs.add(Self.windowNotifications, to: window.element)
            let c = obs.add(Self.contentNotifications, to: window.element)
            logger.info("bound window registered=\(w.registered + c.registered) unsupported=\(w.unsupported + c.unsupported)")
            if w.permissionDenied || c.permissionDenied { handlePermissionLoss() }
        }
        geometryChanged(stopwatch: nil)
    }

    private func unbindWindow() {
        if let current = observedWindow { observation?.removeAll(for: current.element) }
        observedWindow = nil
        inputInsets = nil
        geometry = Geometry(windowAX: nil, inputAX: nil, minimized: false, stopwatch: nil)
        onGeometry?(geometry)
    }

    func axEventReceived(_ name: String) {
        diagnostics.recordAXEvent()
        switch name {
        case "AXMoved", "AXResized":
            geometryChanged(stopwatch: Stopwatch())
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
        case "AXTitleChanged", "AXFocusedWindowChanged", "AXMainWindowChanged", "AXWindowCreated":
            requestRead()
        default:
            lastContentEventAt = .now
            if pendingTriggerAt == nil { pendingTriggerAt = lastContentEventAt }
            scheduleDebouncedRead()
        }
    }

    // MARK: - Geometry (move/resize drive the panel directly)

    private func geometryChanged(stopwatch: Stopwatch?) {
        guard let window = observedWindow else { return }
        if geometryInFlight {
            geometryPending = true
            if geometryPendingStopwatch == nil { geometryPendingStopwatch = stopwatch }
            return
        }
        geometryInFlight = true
        Task {
            let g = await geometryReader.geometry(of: window)
            geometryInFlight = false
            // Ignore results for a window we no longer follow.
            if let current = observedWindow, CFEqual(current.element, window.element) {
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

    private func applyGeometry(_ g: WindowGeometry, stopwatch: Stopwatch?) {
        geometry.minimized = g.minimized
        if let frame = g.frame {
            geometry.windowAX = frame
            geometry.inputAX = inputFrame(for: frame)
        }
        geometry.stopwatch = stopwatch
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
            self.requestRead()
        }
    }

    func requestRead() {
        guard started, kakaoRunning, state != .noPermission || AccessibilityAccess.isGranted else { return }
        if readInFlight {
            readPending = true
            return
        }
        readInFlight = true
        let requestedAt = ContinuousClock.now
        let triggeredAt = pendingTriggerAt ?? requestedAt
        pendingTriggerAt = nil
        let resolveOnly = paused
        Task {
            let outcome = resolveOnly ? await reader.resolveWindow() : await reader.read(requestedAt: requestedAt)
            readInFlight = false
            handle(outcome, triggeredAt: triggeredAt)
            if readPending {
                readPending = false
                requestRead()
            }
        }
    }

    private func handle(_ outcome: ReadOutcome, triggeredAt: ContinuousClock.Instant) {
        guard started else { return }
        switch outcome {
        case .read(let result, let window):
            diagnostics.recordRead(result.elapsedMilliseconds)
            bindWindow(window)
            if let frame = result.windowFrame {
                geometry.windowAX = frame
                rememberInput(result.inputFrame, window: frame)
                geometry.inputAX = result.inputFrame
                geometry.stopwatch = nil
                onGeometry?(geometry)
            }
            setState(.tracking)
            onRead?(result, triggeredAt)
        case .windowOnly(let window, let g):
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
                unbindWindow()
                setState(.noChatWindow)
            } else {
                if let window { bindWindow(window) }
                setState(.transcriptNotFound)
            }
        }
    }

    // MARK: - Polling

    private func updatePolling() {
        let shouldPoll = started && kakaoFrontmost && kakaoRunning && !paused && state != .noPermission
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
        guard ContinuousClock.now - lastContentEventAt >= Self.pollQuietPeriod else { return }
        diagnostics.recordPollRead()
        requestRead()
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
        onFrontmostChange?(isKakao)
        if isKakao {
            if observation == nil { refreshAttachment() } else { requestRead() }
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
