// SPDX-License-Identifier: MIT
// Wires SessionManager (one ChatSession per open chat window) → per-session SidebarViewModel /
// InlineOverlayController, the sidebar panel (focused session only) and settings changes.

import AppKit
import ApplicationServices
import Foundation
import KakaoAX
import os
import SwiftUI
import TalkLensCore
import TalkLensTranslate

private let logger = Logger.talkLens("app")

extension ChatWindowRead: ChatWindowReadLike {}

@MainActor
final class AppController {
    let settings: AppSettings
    let diagnostics: Diagnostics
    let glossaryStore: GlossaryStore
    let service: TranslationService
    /// Row model shown by the sidebar while no chat window is followed (carries the app status only).
    let idleModel: SidebarViewModel
    let sidebarHost: SidebarModelHost
    let reader: AXReader
    let manager: SessionManager
    let loginItem: LoginItemController
    let presenter = WindowPresenter()
    /// Supported languages / pair status shown in settings.
    let languageStatus: LanguageStatusModel
    private(set) var panel: PanelController?
    /// Shared NSEvent monitors of all inline overlays.
    private let eventHub = InlineEventHub()
    private var onboardingModel: OnboardingModel?
    private var screenObserver: NSObjectProtocol?
    private var statsTask: Task<Void, Never>?
    private var engineStatus: EngineStatus?
    private var occlusionTask: Task<Void, Never>?
    private var occlusionInterval: Duration?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var occlusionRecheckTask: Task<Void, Never>?
    private var kakaoPID: pid_t?
    /// Called after the UI language changed (the status menu is rebuilt by AppDelegate).
    var onUILanguageChange: (@MainActor () -> Void)?
    /// Called when the menu bar icon variant may have changed (AppDelegate redraws it when it did).
    var onStatusIconChange: (@MainActor () -> Void)?
    /// Occlusion is re-checked this often while an overlay is shown (other apps' windows move without any
    /// notification to us), and at the slow rate while one could be shown but its chat window is hidden.
    static let occlusionInterval: Duration = .milliseconds(250)
    static let occlusionIdleInterval: Duration = .seconds(1)

    init(settings: AppSettings = AppSettings(defaults: .standard),
         engine: any TranslationEngine = AppleTranslationEngine()) {
        self.settings = settings
        diagnostics = Diagnostics()
        glossaryStore = GlossaryStore(bundle: .main, loadUser: true)
        service = TranslationService(engine: engine, source: settings.fallbackSourceLocale, target: settings.targetLocale)
        languageStatus = LanguageStatusModel(service: service)
        idleModel = SidebarViewModel(service: service, glossary: glossaryStore.merged, settings: settings,
                                     diagnostics: diagnostics, channel: "idle")
        sidebarHost = SidebarModelHost(model: idleModel)
        reader = AXReader()
        manager = SessionManager(reader: reader, diagnostics: diagnostics)
        loginItem = LoginItemController()
        Localizer.shared.apply(settings.uiLanguage)
    }

    /// The models of every followed chat window plus the idle model.
    private var allModels: [SidebarViewModel] { [idleModel] + manager.sessions.map(\.model) }

    func start() {
        // Client-side default IPC timeout for every AX element we message (the 6 s system default would let a
        // busy KakaoTalk stall our reads). This configures our own AX client only; nothing is sent to KakaoTalk.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
        let actions = SidebarActions(
            openOnboarding: { [weak self] in self?.showOnboarding() },
            openSettings: { [weak self] in self?.showSettings() },
            resume: { [weak self] in self?.settings.paused = false },
            downloadLanguages: { [weak self] pair in self?.showLanguageDownload(pair) }
        )
        panel = PanelController(rootView: SidebarRootView(host: sidebarHost, settings: settings, actions: actions),
                                settings: settings)
        eventHub.overlays = { [weak self] in
            guard let self else { return [] }
            // Focused window first: when occlusion data lags, a scroll goes to the window most likely on top.
            let focused = self.manager.focusedSession
            let ordered = self.manager.sessions.sorted { a, b in (a === focused) && !(b === focused) }
            return ordered.map(\.inline).filter(\.active)
        }

        settings.onChange = { [weak self] key in self?.settingChanged(key) }
        Localizer.shared.onChange = { [weak self] in self?.uiLanguageChanged() }
        manager.makeModel = { [weak self] channel in self?.makeModel(channel: channel) }
        manager.onStateChange = { [weak self] state in self?.managerStateChanged(state) }
        diagnostics.activity.onChange = { [weak self] _ in self?.onStatusIconChange?() }
        manager.onSessionsChanged = { [weak self] in self?.sessionsChanged() }
        manager.onSessionGeometry = { [weak self] session in self?.geometryChanged(session) }
        manager.onSessionStateChange = { [weak self] _ in self?.updatePanelVisibility() }
        manager.onFrontmostChange = { [weak self] _ in self?.updatePanelVisibility() }
        applyDisplayModeToReader()
        WindowOcclusion().warmUp()
        subscribeWindowOrderChanges()

        idleModel.setPaused(settings.paused)
        manager.setPaused(settings.paused)
        // Warm Apple Translation up for the configured pair while the chat windows are enumerated and read.
        warmUpTranslation()
        manager.start()
        updatePanelVisibility()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }

        Task { [weak self] in
            guard let self else { return }
            await self.refreshEngineStatus()
            self.maybeShowOnboarding()
        }
        logger.info("started glossary=\(self.glossaryStore.merged.entries.count)")
        startStatsLogging()
    }

    private func makeModel(channel: String) -> SidebarViewModel {
        let model = SidebarViewModel(service: service, glossary: glossaryStore.merged, settings: settings,
                                     diagnostics: diagnostics, channel: channel)
        model.setEngineStatus(engineStatus)
        model.setPaused(settings.paused)
        return model
    }

    /// Checks the translation engine once and shares the result with every model.
    private func refreshEngineStatus() async {
        let status = await service.status()
        engineStatus = status
        for model in allModels { model.setEngineStatus(status) }
        onStatusIconChange?()
    }

    /// One fixed synthetic word through the engine (inside the TranslationService actor, through the engine's
    /// session store), so the first real batch reuses a warm session. Skipped when the pair is not installed
    /// or translation is paused. Never user content.
    private func warmUpTranslation() {
        guard !settings.paused else { return }
        let service = self.service
        let diagnostics = self.diagnostics
        diagnostics.activity.set("warm-up", busy: true)
        Task {
            let warmed = await service.warmUp()
            diagnostics.activity.set("warm-up", busy: false)
            if warmed { diagnostics.markStartup(.warmUp) }
        }
    }

    /// Every 30 s, log the in-memory timing summary (numbers only) so PERF.md can be filled from `log show`.
    private func startStatsLogging() {
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30), tolerance: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                let line = self.diagnostics.summaryLine
                logger.info("\(line, privacy: .public)")
            }
        }
    }

    func stop() {
        statsTask?.cancel()
        statsTask = nil
        occlusionTask?.cancel()
        occlusionTask = nil
        occlusionInterval = nil
        occlusionRecheckTask?.cancel()
        occlusionRecheckTask = nil
        manager.stop()
        eventHub.setEnabled(false)
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceObservers = []
        onboardingModel?.stop()
        Task { [service] in
            await service.cancelAll()
            await service.clearCache()
        }
    }

    // MARK: - Sessions → panel / overlays

    private func managerStateChanged(_ state: SessionManager.State) {
        let status: SidebarViewModel.Status
        switch state {
        case .idle: status = .starting
        case .noPermission: status = .noPermission
        case .kakaoNotRunning: status = .kakaoNotRunning
        case .noChatWindow: status = .noChatWindow
        case .tracking: status = .starting
        }
        idleModel.setTrackerStatus(status)
        if state != .tracking { panel?.place(windowAX: nil, inputAX: nil) }
        updatePanelVisibility()
        onStatusIconChange?()
    }

    /// Sessions were created / ended or the focused one changed: the sidebar follows the focused session and
    /// its translations get the engine first.
    private func sessionsChanged() {
        let focused = manager.focusedSession
        let model = focused?.model ?? idleModel
        if sidebarHost.model !== model { sidebarHost.model = model }
        let g = focused?.geometry
        panel?.place(windowAX: g?.windowAX, inputAX: g?.inputAX)
        let channel = focused?.channel
        Task { [service] in await service.setPreferredChannel(channel) }
        updatePanelVisibility()
    }

    private func geometryChanged(_ session: ChatSession) {
        guard let panel else { return }
        let g = session.geometry
        if session === manager.focusedSession { panel.place(windowAX: g.windowAX, inputAX: g.inputAX) }
        session.inline.geometryChanged()
        updatePanelVisibility()
        if let stopwatch = g.stopwatch {
            diagnostics.recordFollow(stopwatch.elapsedMilliseconds)
        }
    }

    private func relayout() {
        let g = manager.focusedSession?.geometry
        panel?.place(windowAX: g?.windowAX, inputAX: g?.inputAX)
        for session in manager.sessions { session.inline.screensChanged() }
        updatePanelVisibility()
    }

    var isInlineMode: Bool { settings.displayMode == .inline }

    func updatePanelVisibility() {
        guard let panel else { return }
        let front = manager.kakaoFrontmost
        let inlineMode = isInlineMode
        let running = manager.kakaoRunning
        if !running { kakaoPID = nil }
        // Overlays can only sit over chat windows while translation runs; one window-list snapshot (metadata
        // only, no IPC to KakaoTalk) serves every session's occlusion.
        let overlaysPossible = inlineMode && settings.sidebarVisible && !settings.paused && running
            && !manager.sessions.isEmpty
        let windows = overlaysPossible ? WindowOcclusion.onScreenWindows() : nil
        if overlaysPossible, kakaoPID == nil { kakaoPID = KakaoProcess.processIdentifier }
        let focused = manager.focusedSession
        var anyCandidate = false
        var anyShown = false
        for session in manager.sessions {
            let g = session.geometry
            let candidate = overlaysPossible && !g.minimized && g.windowAX != nil
            session.refreshOcclusion(windows: candidate ? windows : nil, kakaoPID: kakaoPID)
            let chatVisible = session.occlusionState.chatVisible
            // The overlay follows the chat window itself: it stays while any part of the window is on screen,
            // even behind other apps — whatever covers it is masked out (WindowOcclusion).
            let overlayActive = candidate && session.state == .tracking && chatVisible
            session.inline.setActive(overlayActive)
            let isFocused = session === focused
            // Read and translate whatever is on the current Space even while it is fully covered or KakaoTalk is
            // in the background (reads are incremental and cheap), so translations are ready the moment the
            // window shows; only drawing is suppressed (D-027). Windows on another Space / minimized are not read
            // (sessions end or wait); the session reads once on return.
            let wanted: Bool
            if inlineMode {
                wanted = settings.sidebarVisible && (session.occlusionState.onScreen || (front && isFocused))
            } else {
                wanted = settings.sidebarVisible && isFocused
            }
            session.setContentWanted(wanted)
            anyCandidate = anyCandidate || candidate
            anyShown = anyShown || overlayActive
        }
        manager.contentWantedChanged()
        eventHub.setEnabled(anyShown)
        // `sidebarVisible` is the menu's "show translations" switch in both modes. The sidebar follows a
        // frontmost KakaoTalk (or stays when pinned) and shows the focused chat window.
        let wantedPanel = settings.sidebarVisible && (front || settings.pinned)
        var visible = !inlineMode && wantedPanel && running && panel.placementValid
        if focused?.geometry.minimized == true { visible = false }
        panel.setVisible(visible, kakaoFrontmost: front)
        scheduleOcclusionChecks(candidate: anyCandidate, shown: anyShown)
    }

    // MARK: - Occlusion (inline mode)

    /// Other apps' windows move, open and close without telling us: re-check on a timer while an overlay is
    /// shown (fast) or could be shown once its chat window is on screen again (slow).
    private func scheduleOcclusionChecks(candidate: Bool, shown: Bool) {
        let interval: Duration? = candidate ? (shown ? Self.occlusionInterval : Self.occlusionIdleInterval) : nil
        guard interval != occlusionInterval else { return }
        occlusionInterval = interval
        occlusionTask?.cancel()
        occlusionTask = nil
        guard let interval else { return }
        occlusionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval, tolerance: interval / 5)
                guard !Task.isCancelled, let self else { return }
                self.updatePanelVisibility()
            }
        }
    }

    /// App activation, hide/unhide and Space switches reorder windows: re-check at once and again shortly
    /// after (the activated app may order its windows front a moment later).
    private func subscribeWindowOrderChanges() {
        let center = NSWorkspace.shared.notificationCenter
        let names = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowOrderChanged() }
            }
            workspaceObservers.append(token)
        }
    }

    private func windowOrderChanged() {
        updatePanelVisibility()
        occlusionRecheckTask?.cancel()
        occlusionRecheckTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            self.occlusionRecheckTask = nil
            self.updatePanelVisibility()
        }
    }

    private func applyDisplayModeToReader() {
        let inlineMode = isInlineMode
        Task { [reader] in await reader.setInlineMargin(inlineMode) }
    }

    // MARK: - Settings

    private func settingChanged(_ key: AppSettings.Key) {
        switch key {
        case .sourceLanguage, .targetLanguage:
            for model in allModels { model.languagesChanged() }
            Task { [weak self] in
                // After the change reached the service: the new pair may need a download.
                try? await Task.sleep(for: .milliseconds(100))
                await self?.refreshEngineStatus()
            }
        case .glossaryEnabled:
            for model in allModels { model.updateGlossary(glossaryStore.merged) }
        case .edge, .panelWidth:
            relayout()
        case .opacity:
            // The sidebar's background fill observes the setting directly.
            break
        case .pinned, .sidebarVisible:
            updatePanelVisibility()
        case .displayMode:
            logger.info("display mode=\(self.settings.displayMode.rawValue, privacy: .public)")
            applyDisplayModeToReader()
            updatePanelVisibility()
            // Re-read so the overlays (or the sidebar) start from fresh frames.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                self?.manager.requestReadAll()
            }
        case .paused:
            for model in allModels { model.setPaused(settings.paused) }
            manager.setPaused(settings.paused)
            updatePanelVisibility()
            onStatusIconChange?()
        case .uiLanguage:
            Localizer.shared.apply(settings.uiLanguage)
            // A switch between "follow system" and the language it resolves to changes no text but the
            // menu's check mark (refreshed whenever the menu opens).
        case .fontSize, .showOriginal, .onboardingShown:
            break
        }
    }

    /// SwiftUI views observe Localizer directly; AppKit titles are refreshed here.
    private func uiLanguageChanged() {
        logger.info("ui language=\(Localizer.shared.language.rawValue, privacy: .public)")
        presenter.refreshTitles()
        onUILanguageChange?()
    }

    func reloadGlossary() {
        glossaryStore.reload()
        for model in allModels { model.updateGlossary(glossaryStore.merged) }
    }

    // MARK: - Windows

    private func maybeShowOnboarding() {
        let needsPermission = !AccessibilityAccess.isGranted
        let needsLanguage = engineStatus == .needsDownload
        if !settings.onboardingShown || needsPermission || needsLanguage {
            settings.onboardingShown = true
            showOnboarding()
        }
    }

    func showOnboarding() {
        let onboarding = onboardingModel ?? OnboardingModel(service: service)
        onboarding.onAccessibilityGranted = { [weak self] in self?.manager.refreshAttachment() }
        onboarding.onEngineStatus = { [weak self] _ in
            Task { [weak self] in await self?.refreshEngineStatus() }
        }
        onboardingModel = onboarding
        // Checks the chosen source (Korean by default, D-024; Korean as well when auto-detecting) → target.
        onboarding.sourceLanguage = settings.fallbackSourceLocale
        presenter.show(id: "onboarding", title: { tr(.windowOnboarding) }, size: CGSize(width: 480, height: 460),
                       onClose: { [weak self] in
                           self?.onboardingModel?.stop()
                           self?.onboardingModel = nil
                       }) {
            OnboardingView(model: onboarding, settings: settings,
                           done: { [weak self] in self?.presenter.close("onboarding") })
        }
    }

    func showSettings() {
        presenter.show(id: "settings", title: { tr(.windowSettings) }, size: CGSize(width: 480, height: 620)) {
            SettingsView(settings: settings, glossary: glossaryStore, loginItem: loginItem,
                         reloadGlossary: { [weak self] in self?.reloadGlossary() },
                         languages: languageStatus,
                         languagesInstalled: { [weak self] in self?.languagesInstalled() })
        }
    }

    /// Shows the system download prompt for one pair (must be a visible window: `prepareTranslation()`).
    func showLanguageDownload(_ pair: LanguagePair) {
        let id = "download-\(pair.source)-\(pair.target)"
        presenter.show(id: id, title: { tr(.windowDownload) }, size: CGSize(width: 440, height: 220)) {
            LanguageDownloadPrompt(source: Locale.Language(identifier: pair.source),
                                   target: Locale.Language(identifier: pair.target),
                                   language: uiLanguage) { [weak self] installed in
                if installed {
                    self?.languagesInstalled()
                    self?.presenter.close(id)
                }
            }
        }
    }

    /// A pair was downloaded: forget cached statuses and re-submit failed messages everywhere.
    func languagesInstalled() {
        Task { [weak self] in
            guard let self else { return }
            await self.service.invalidateLanguageStatus()
            await self.refreshEngineStatus()
            for model in self.allModels { model.retryFailed() }
        }
    }

    /// Every pair (over all followed chat windows) that failed because it is not installed.
    var missingPairs: [LanguagePair] {
        Array(Set(allModels.flatMap(\.missingPairs))).sorted { $0.description < $1.description }
    }

    func showAbout() {
        presenter.show(id: "about", title: { tr(.menuAbout) }, size: CGSize(width: 460, height: 360)) {
            AboutView(diagnostics: diagnostics)
        }
    }

    /// One-line, content-free status for the menu.
    var menuStatusLine: String {
        tr(.statusLine, menuStatusDetail)
    }

    private var menuStatusDetail: String {
        if settings.paused { return tr(.statePaused) }
        switch manager.state {
        case .idle: return tr(.stateStarting)
        case .noPermission: return tr(.stateNoPermission)
        case .kakaoNotRunning: return tr(.stateKakaoNotRunning)
        case .noChatWindow: return tr(.stateNoChatWindow)
        case .tracking:
            guard let focused = manager.focusedSession else { return tr(.stateStarting) }
            if focused.state == .transcriptNotFound { return tr(.stateTranscriptNotFound) }
            let c = focused.model.counts
            let windows = manager.sessions.count
            var parts = [windows > 1 ? tr(.stateFollowingMany, windows) : tr(.stateFollowingOne),
                         tr(.stateCounts, c.rows, c.done)]
            if isInlineMode, focused.occlusionState.fullyCovered { parts.append(tr(.stateCovered)) }
            let missing = missingPairs.count
            if missing > 0 { parts.append(tr(.stateMissingPairs, missing)) }
            return parts.joined(separator: " · ")
        }
    }

    /// Menu bar icon variant: attention (no permission / languages missing) > paused > busy > normal.
    var statusIconVariant: LogoArt.StatusVariant {
        if manager.state == .noPermission { return .attention }
        switch engineStatus {
        case .needsDownload?, .unsupported?: return .attention
        default: break
        }
        if !missingPairs.isEmpty { return .attention }
        if settings.paused { return .paused }
        return diagnostics.activity.shown ? .active : .normal
    }
}
