// SPDX-License-Identifier: MIT
// Follows every open KakaoTalk chat window at once: one ChatSession per chat window that is open, not
// minimized and on the current Space (at most `maxSessions`; the least recently focused windows get none).
//
// - App-level AXObserver (focused/main window changes, window creation, (de)miniaturize) and NSWorkspace
//   launch/terminate/activate/wake/Space changes trigger a debounced re-enumeration of KakaoTalk's windows
//   (chat-window test memoised per element in AXReader) that creates and ends sessions.
// - Every transcript read of every session goes through the single AXReader actor, one at a time (never
//   parallel AX bursts against KakaoTalk, D-020): event-driven reads first (focused session, then the largest
//   unoccluded area), budgeted follow-up reads round-robin with a pause between them.
// - Fallback polling only while KakaoTalk is frontmost, only for sessions that are at least partly visible,
//   one session per tick so that poll reads stay at or below 2/s in total.
//
// Read-only: never activates, raises, focuses, scrolls or otherwise touches KakaoTalk.

import AppKit
import ApplicationServices
import Foundation
import KakaoAX
import os
import TalkLensCore

private let logger = Logger.talkLens("sessions")

@MainActor
final class SessionManager: AXEventSink {
    enum State: Equatable {
        case idle
        case noPermission
        case kakaoNotRunning
        case noChatWindow
        case tracking
    }

    // Notification names (literal strings: AX notification constants are plain CFSTR macros).
    static let appNotifications = ["AXFocusedWindowChanged", "AXMainWindowChanged", "AXWindowCreated",
                                   "AXWindowMiniaturized", "AXWindowDeminiaturized"]
    /// Registered on the application element, which receives it for descendant elements (a window
    /// registration may only see its own element); routed to the session whose transcript table posted it.
    /// App-level AXCreated is not registered: tooltips and popovers post it constantly.
    static let appContentNotifications = ["AXRowCountChanged"]

    static let maxSessions = 6
    static let enumerationDebounce: Duration = .milliseconds(300)
    /// Windows whose chat-window test was inconclusive (still loading) are re-checked this much later, a few
    /// times after each triggering event.
    static let unresolvedRetryDelay: Duration = .milliseconds(2500)
    static let maxUnresolvedRetries = 4
    /// Poll timer period; each tick polls at most one session (≤ 2 poll reads/s in total).
    static let pollTick: Duration = .milliseconds(500)
    /// A session is poll-read at most this often.
    static let pollInterval: Duration = .seconds(1)
    static let pollQuietPeriod: Duration = .seconds(5)
    /// Poll read cadence of a session whose transcript was not found.
    static let untrackedPollInterval: Duration = .seconds(3)
    /// Pause between consecutive budgeted follow-up reads (any session) and after a session's own read.
    static let prefetchPause: Duration = ChatSession.prefetchPause
    /// Upper bound on the main-thread time spent registering observers in one attach / enumeration.
    static let registrationBudget: Duration = .seconds(1)

    var onStateChange: ((State) -> Void)?
    /// Sessions were created or ended, or the focused session changed.
    var onSessionsChanged: (() -> Void)?
    var onSessionGeometry: ((ChatSession) -> Void)?
    var onSessionStateChange: ((ChatSession) -> Void)?
    var onFrontmostChange: ((Bool) -> Void)?
    /// Creates the row model of a new session for the given translation channel.
    var makeModel: ((String) -> SidebarViewModel?)?

    private(set) var state: State = .idle
    private(set) var kakaoFrontmost = false
    private(set) var kakaoRunning = false
    private(set) var paused = false
    private(set) var sessions: [ChatSession] = []
    /// KakaoTalk's focused window when it is a followed chat window, else the most recently focused session.
    private(set) var focusedSession: ChatSession?

    let reader: AXReader
    /// Cheap single-element reads (window geometry; the inline overlays' scroll anchors).
    let geometryReader = WindowGeometryReader()
    private let diagnostics: Diagnostics

    private var started = false
    private var routerToken = 0
    private var observation: AXObservation?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var permissionTask: Task<Void, Never>?
    private var delayedRefreshTask: Task<Void, Never>?
    private var enumerationTask: Task<Void, Never>?
    private var unresolvedTask: Task<Void, Never>?
    private var unresolvedRetries = 0
    private var enumerationInFlight = false
    private var enumerationPending = false
    /// The first enumeration after attaching tests only the focused window (read it first, D-027).
    private var quickPassPending = true
    private var pollTask: Task<Void, Never>?
    private var pollCursor = 0

    private var nextSessionID = 1
    private var focusCounter = 0
    /// Focus recency of chat windows (also those without a session), larger = more recent.
    private var focusHistory: [AXElementKey: Int] = [:]

    // Read queue (one read at a time across all sessions).
    private var reading: ChatSession?
    private var urgentReads: Set<ObjectIdentifier> = []
    private var followUpDue: [ObjectIdentifier: ContinuousClock.Instant] = [:]
    private var lastReadEndedAt: ContinuousClock.Instant?
    private var pumpTask: Task<Void, Never>?

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

    /// Ends every session and removes every observer, run-loop source, notification token and task.
    func stop() {
        guard started else { return }
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens { center.removeObserver(token) }
        workspaceTokens.removeAll()
        for task in [permissionTask, delayedRefreshTask, pollTask] { task?.cancel() }
        permissionTask = nil
        delayedRefreshTask = nil
        pollTask = nil
        detach()
        started = false
        AXEventRouter.unregister(routerToken)
    }

    func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        updatePolling()
        for session in sessions { session.requestRead() }
    }

    /// Called by AppController after it changed the sessions' `contentWanted` flags.
    func contentWantedChanged() {
        updatePolling()
    }

    /// Asks every session for a fresh read (e.g. after a display-mode change).
    func requestReadAll() {
        for session in sessions { session.requestRead() }
    }

    /// Re-checks permission and process, (re)attaches observers and enumerates windows. Safe to call any time.
    func refreshAttachment() {
        guard started else { return }
        guard AccessibilityAccess.isGranted else {
            permissionLost()
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
        if observation != nil { scheduleEnumeration(after: .zero) }
    }

    // MARK: - App-level observer

    private func attach(pid: pid_t) {
        let made = AXObservation.make(pid: pid, token: routerToken)
        guard let obs = made.observation else {
            logger.error("attach failed code=\(made.error.rawValue, privacy: .public)")
            if made.error == .apiDisabled { permissionLost() }
            return
        }
        guard let appNode = KakaoProcess.applicationNode() else {
            // KakaoTalk quit (or is quitting) between the process check and here: retry shortly.
            obs.invalidate()
            scheduleRefresh(after: .seconds(2))
            return
        }
        observation = obs
        quickPassPending = true
        let deadline = ContinuousClock.now + Self.registrationBudget
        let result = obs.add(Self.appNotifications + Self.appContentNotifications, to: appNode.element,
                             deadline: deadline)
        logger.info("attached app observer registered=\(result.registered) unsupported=\(result.unsupported) errors=\(result.otherErrors) skipped=\(result.skipped)")
        if result.permissionDenied {
            permissionLost()
        } else if result.registered == 0 {
            // KakaoTalk just launched or is busy: AX not ready yet. Retry shortly.
            obs.invalidate()
            observation = nil
            scheduleRefresh(after: .seconds(2))
        }
    }

    /// Ends all sessions and drops the app-level observer.
    private func detach() {
        enumerationTask?.cancel()
        enumerationTask = nil
        unresolvedTask?.cancel()
        unresolvedTask = nil
        enumerationPending = false
        pumpTask?.cancel()
        pumpTask = nil
        urgentReads.removeAll()
        followUpDue.removeAll()
        observation?.invalidate()
        observation = nil
        let ended = sessions
        sessions.removeAll()
        focusedSession = nil
        for session in ended { session.end() }
        diagnostics.setSessionCount(0)
        if !ended.isEmpty { onSessionsChanged?() }
    }

    func axEventReceived(_ name: String, element: AXElementRef) {
        diagnostics.recordAXEvent()
        switch name {
        case "AXFocusedWindowChanged", "AXMainWindowChanged":
            // The element is the newly focused / main window: switch at once when it is followed already.
            let key = AXElementKey(element.element)
            if let session = session(for: key) {
                noteFocus(key)
                if focusedSession !== session {
                    focusedSession = session
                    onSessionsChanged?()
                }
            }
            scheduleEnumeration()
        case "AXWindowCreated", "AXWindowMiniaturized", "AXWindowDeminiaturized":
            // Tooltips and popovers post AXWindowCreated too; the enumeration's memoised test sorts them out.
            scheduleEnumeration()
        case "AXRowCountChanged":
            // Only the followed transcript tables matter (a new message in a followed window).
            for session in sessions where session.transcriptTable?.isSame(as: element) == true {
                session.transcriptRowsChanged(element: element)
            }
        default:
            break
        }
    }

    // MARK: - Enumeration

    /// Debounced re-enumeration of KakaoTalk's windows.
    func scheduleEnumeration(after delay: Duration = SessionManager.enumerationDebounce) {
        guard started, kakaoRunning, observation != nil else { return }
        unresolvedRetries = 0
        enumerationTask?.cancel()
        enumerationTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.enumerationTask = nil
            self.runEnumeration()
        }
    }

    private func runEnumeration() {
        guard started, kakaoRunning else { return }
        if enumerationInFlight {
            enumerationPending = true
            return
        }
        enumerationInFlight = true
        let quick = quickPassPending && sessions.isEmpty
        quickPassPending = false
        diagnostics.activity.set("enumerate", busy: true)
        Task {
            let outcome = await reader.enumerateChatWindows(focusedOnly: quick)
            enumerationInFlight = false
            diagnostics.activity.set("enumerate", busy: false)
            apply(outcome)
            if enumerationPending {
                enumerationPending = false
                runEnumeration()
            }
        }
    }

    private func apply(_ outcome: EnumerationOutcome) {
        guard started, kakaoRunning else { return }
        switch outcome {
        case .failure(.notTrusted):
            permissionLost()
            return
        case .failure(.notRunning):
            if KakaoProcess.isRunning { scheduleRefresh(after: .seconds(2)) } else { kakaoTerminated() }
            return
        case .failure:
            // The window list could not be read (busy KakaoTalk): keep the sessions, try again later.
            scheduleEnumeration(after: .seconds(2))
            return
        case .windows(let found):
            diagnostics.markStartup(.firstEnumeration)
            applyWindows(found)
            // Launch fast path: the focused chat window's read is queued; now test the other windows.
            if found.partial { scheduleEnumeration(after: .zero) }
        }
    }

    private func applyWindows(_ found: ChatWindowEnumeration) {
        guard let pid = observation?.pid ?? KakaoProcess.processIdentifier else { return }
        if let focused = found.focused { noteFocus(focused) }
        // On the current Space = present in the window server's on-screen list (covered windows included).
        let onScreen = WindowOcclusion.onScreenWindows()
        let ownPID = getpid()
        var candidates: [(info: ChatWindowInfo, order: Int)] = []
        for (order, info) in found.chatWindows.enumerated() {
            let visible: Bool
            if let existing = session(for: info.key) {
                let frame = info.frame ?? existing.geometry.windowAX
                visible = frame.map {
                    existing.occlusion.update(windows: onScreen, kakaoPID: pid, chatFrame: $0).onScreen
                } ?? false
            } else if let frame = info.frame {
                visible = WindowOcclusion.evaluate(windows: onScreen, kakaoPID: pid, chatFrame: frame,
                                                   ownPID: ownPID, cachedWindow: nil).snapshot.onScreen
            } else {
                visible = false
            }
            if visible { candidates.append((info, order)) }
        }
        // Most recently focused first; never-focused windows in KakaoTalk's window order.
        candidates.sort { a, b in
            let fa = focusHistory[a.info.key] ?? 0, fb = focusHistory[b.info.key] ?? 0
            return fa != fb ? fa > fb : a.order < b.order
        }
        let kept = candidates.prefix(Self.maxSessions).map(\.info)
        let keptKeys = Set(kept.map(\.key))
        var changed = false
        for session in sessions where !found.partial && !keptKeys.contains(session.key) {
            removeSession(session, notify: false)
            changed = true
        }
        let deadline = ContinuousClock.now + Self.registrationBudget
        for info in kept where session(for: info.key) == nil {
            let id = nextSessionID
            guard let model = makeModel?(ChatSession.channelName(id)) else { break }
            nextSessionID += 1
            let session = ChatSession(id: id, info: info, model: model,
                                      manager: self, geometryReader: geometryReader, diagnostics: diagnostics)
            session.focusSerial = focusHistory[info.key] ?? 0
            sessions.append(session)
            diagnostics.markStartup(.firstSession)
            session.start(pid: pid, deadline: deadline)
            // Permission lost while registering: everything was torn down.
            guard observation != nil, !session.ended else { return }
            changed = true
        }
        if candidates.count > kept.count {
            logger.info("session cap reached windows=\(candidates.count, privacy: .public) sessions=\(kept.count, privacy: .public)")
        }
        let focusChanged = updateFocused(preferred: found.focused)
        diagnostics.setSessionCount(sessions.count)
        setState(sessions.isEmpty ? .noChatWindow : .tracking)
        if changed || focusChanged { onSessionsChanged?() }
        updatePolling()
        if !found.partial, found.unresolved > 0, unresolvedRetries < Self.maxUnresolvedRetries {
            unresolvedRetries += 1
            unresolvedTask?.cancel()
            unresolvedTask = Task { [weak self] in
                try? await Task.sleep(for: SessionManager.unresolvedRetryDelay)
                guard !Task.isCancelled, let self else { return }
                self.unresolvedTask = nil
                self.runEnumeration()
            }
        }
    }

    private func session(for key: AXElementKey) -> ChatSession? {
        sessions.first { $0.key == key }
    }

    private func noteFocus(_ key: AXElementKey) {
        focusCounter += 1
        focusHistory[key] = focusCounter
        session(for: key)?.focusSerial = focusCounter
        if focusHistory.count > 64 {
            // Keep the 32 most recent entries.
            let recent = focusHistory.sorted { $0.value > $1.value }.prefix(32)
            focusHistory = Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0.value) })
        }
    }

    /// Returns true when the focused session changed.
    @discardableResult
    private func updateFocused(preferred: AXElementKey?) -> Bool {
        var next = preferred.flatMap(session(for:))
        if next == nil, let current = focusedSession, sessions.contains(where: { $0 === current }) { next = current }
        if next == nil { next = sessions.max { $0.focusSerial < $1.focusSerial } }
        guard next !== focusedSession else { return false }
        focusedSession = next
        return true
    }

    private func removeSession(_ session: ChatSession, notify: Bool) {
        let id = ObjectIdentifier(session)
        urgentReads.remove(id)
        followUpDue[id] = nil
        sessions.removeAll { $0 === session }
        session.end()
        if focusedSession === session {
            focusedSession = nil
            updateFocused(preferred: nil)
        }
        diagnostics.setSessionCount(sessions.count)
        guard notify else { return }
        if sessions.isEmpty, state == .tracking { setState(.noChatWindow) }
        onSessionsChanged?()
        updatePolling()
    }

    // MARK: - Session callbacks

    func sessionWindowDestroyed(_ session: ChatSession) {
        guard sessions.contains(where: { $0 === session }) else { return }
        let key = session.key
        removeSession(session, notify: true)
        Task { [reader] in await reader.dropWindow(key) }
        scheduleEnumeration()
    }

    func sessionGeometryChanged(_ session: ChatSession) {
        onSessionGeometry?(session)
    }

    func sessionStateChanged(_ session: ChatSession) {
        onSessionStateChange?(session)
    }

    // MARK: - Read queue

    /// Queues a read of `session`. Event-driven reads run before budgeted follow-ups (`followUp`), which wait
    /// `prefetchPause` after the previous read.
    func enqueueRead(_ session: ChatSession, followUp: Bool) {
        guard started, !session.ended, sessions.contains(where: { $0 === session }) else { return }
        let id = ObjectIdentifier(session)
        if followUp {
            if !urgentReads.contains(id), followUpDue[id] == nil {
                followUpDue[id] = .now + Self.prefetchPause
            }
        } else {
            urgentReads.insert(id)
            followUpDue[id] = nil
        }
        pump()
    }

    func isReading(_ session: ChatSession) -> Bool { reading === session }

    /// Starts the next read when none is running.
    private func pump() {
        guard started, kakaoRunning, reading == nil else { return }
        // 1. Event-driven reads: focused session first, then the largest unoccluded area.
        let urgent = sessions.filter { urgentReads.contains(ObjectIdentifier($0)) }
        if !urgent.isEmpty {
            let focused = focusedSession
            let next = urgent.max { a, b in
                let fa = a === focused, fb = b === focused
                if fa != fb { return fb }
                return a.visibleArea < b.visibleArea
            }!
            urgentReads.remove(ObjectIdentifier(next))
            run(next, followUp: false)
            return
        }
        // 2. Budgeted follow-ups, round-robin (least recently read first), never back to back.
        guard !followUpDue.isEmpty else { return }
        let now = ContinuousClock.now
        let gapEnd = lastReadEndedAt.map { $0 + Self.prefetchPause } ?? now
        let waiting = sessions.compactMap { s in followUpDue[ObjectIdentifier(s)].map { (session: s, due: $0) } }
        guard !waiting.isEmpty else {
            followUpDue.removeAll()
            return
        }
        let ready = waiting.filter { $0.due <= now }
        if gapEnd <= now, !ready.isEmpty {
            let next = ready.min { a, b in
                switch (a.session.lastFullReadAt, b.session.lastFullReadAt) {
                case (nil, nil): return false
                case (nil, _): return true
                case (_, nil): return false
                case let (x?, y?): return x < y
                }
            }!.session
            followUpDue[ObjectIdentifier(next)] = nil
            run(next, followUp: true)
            return
        }
        let earliest = waiting.map(\.due).min()!
        schedulePump(at: max(earliest, gapEnd))
    }

    private func schedulePump(at instant: ContinuousClock.Instant) {
        pumpTask?.cancel()
        pumpTask = Task { [weak self] in
            try? await Task.sleep(until: instant, tolerance: .milliseconds(20), clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.pumpTask = nil
            self.pump()
        }
    }

    private func run(_ session: ChatSession, followUp: Bool) {
        guard session.contentWanted else {
            // Hidden meanwhile: read once it can be seen again.
            session.readDirty = true
            pump()
            return
        }
        reading = session
        let requestedAt = ContinuousClock.now
        let (triggeredAt, trigger) = session.readStarting(at: requestedAt, followUp: followUp)
        let resolveOnly = paused
        let window = session.window
        let reader = self.reader
        if !resolveOnly { diagnostics.markStartup(.firstReadStarted) }
        diagnostics.activity.set("read", busy: true)
        Task {
            let outcome = resolveOnly ? await reader.resolveWindow(window)
                : await reader.read(window: window, requestedAt: requestedAt)
            reading = nil
            lastReadEndedAt = .now
            diagnostics.activity.set("read", busy: false)
            if !session.ended {
                session.handle(outcome, requestedAt: requestedAt, triggeredAt: triggeredAt, trigger: trigger)
            }
            pump()
        }
    }

    // MARK: - Polling

    private func updatePolling() {
        let shouldPoll = started && kakaoFrontmost && kakaoRunning && state == .tracking
            && sessions.contains { $0.contentWanted }
        if shouldPoll {
            guard pollTask == nil else { return }
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: SessionManager.pollTick, tolerance: .milliseconds(100))
                    guard !Task.isCancelled, let self else { return }
                    self.pollTick()
                }
            }
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    /// One session per tick (round-robin among the visible ones): a geometry fallback (one IPC), and a read
    /// when it has had no content event for a while and was not read within `pollInterval`. Scrolls, lazily
    /// loaded rows and edited messages post no notification; this picks them up within a few seconds.
    private func pollTick() {
        let eligible = sessions.filter { $0.contentWanted && !$0.occlusionState.fullyCovered }
        guard !eligible.isEmpty else { return }
        let session = eligible[pollCursor % eligible.count]
        pollCursor &+= 1
        session.geometryChanged(stopwatch: nil)
        let now = ContinuousClock.now
        guard !paused, now - session.lastContentEventAt >= Self.pollQuietPeriod else { return }
        let interval = session.state == .tracking ? Self.pollInterval : Self.untrackedPollInterval
        if let last = session.lastFullReadAt, now - last < interval { return }
        diagnostics.recordPollRead()
        session.requestRead(trigger: .poll)
    }

    // MARK: - Permission / process

    func permissionLost() {
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

    func kakaoTerminated() {
        detach()
        kakaoRunning = false
        kakaoFrontmost = false
        setState(.kakaoNotRunning)
        onFrontmostChange?(false)
        updatePolling()
        Task { [reader] in await reader.clear() }
    }

    // MARK: - NSWorkspace

    private func subscribeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let kakaoID = KakaoProcess.bundleIdentifier
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (SessionManager, Bool) -> Void) {
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
        observe(NSWorkspace.didActivateApplicationNotification) { manager, isKakao in
            manager.frontmostChanged(isKakao)
        }
        observe(NSWorkspace.didLaunchApplicationNotification) { manager, isKakao in
            guard isKakao else { return }
            // AX is not ready immediately after launch.
            manager.scheduleRefresh(after: .seconds(1))
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { manager, isKakao in
            guard isKakao else { return }
            manager.kakaoTerminated()
        }
        observe(NSWorkspace.didWakeNotification) { manager, _ in
            manager.scheduleRefresh(after: .seconds(1))
        }
        // Windows on another Space / of a hidden app leave the on-screen list: sessions follow.
        observe(NSWorkspace.activeSpaceDidChangeNotification) { manager, _ in
            manager.scheduleEnumeration()
        }
        observe(NSWorkspace.didHideApplicationNotification) { manager, isKakao in
            if isKakao { manager.scheduleEnumeration() }
        }
        observe(NSWorkspace.didUnhideApplicationNotification) { manager, isKakao in
            if isKakao { manager.scheduleEnumeration() }
        }
    }

    private func frontmostChanged(_ isKakao: Bool) {
        guard kakaoFrontmost != isKakao else { return }
        kakaoFrontmost = isKakao
        // AppController recomputes visibility here (→ setContentWanted, which reads if dirty).
        onFrontmostChange?(isKakao)
        if isKakao {
            if observation == nil {
                refreshAttachment()
            } else {
                scheduleEnumeration()
                if let focused = focusedSession {
                    if focused.readDirty { focused.requestRead() } else { focused.probeAndMaybeRead(trigger: .other) }
                }
            }
        }
        updatePolling()
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
