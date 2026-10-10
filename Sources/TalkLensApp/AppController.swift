// SPDX-License-Identifier: MIT
// Wires WindowTracker → SidebarViewModel → OverlayPanel (sidebar mode) / InlineOverlayController (inline
// mode), and reacts to settings changes.

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
    let model: SidebarViewModel
    let reader: AXReader
    let tracker: WindowTracker
    let loginItem: LoginItemController
    let presenter = WindowPresenter()
    private(set) var panel: PanelController?
    private(set) var inline: InlineOverlayController?
    private var onboardingModel: OnboardingModel?
    private var screenObserver: NSObjectProtocol?
    private var statsTask: Task<Void, Never>?

    init(settings: AppSettings = AppSettings(defaults: .standard),
         engine: any TranslationEngine = AppleTranslationEngine()) {
        self.settings = settings
        diagnostics = Diagnostics()
        glossaryStore = GlossaryStore(bundle: .main, loadUser: true)
        service = TranslationService(engine: engine, target: settings.targetLocale)
        model = SidebarViewModel(service: service, glossary: glossaryStore.merged, settings: settings,
                                 diagnostics: diagnostics)
        reader = AXReader()
        tracker = WindowTracker(reader: reader, diagnostics: diagnostics)
        loginItem = LoginItemController()
    }

    func start() {
        // Client-side default IPC timeout for every AX element we message (the 6 s system default would let a
        // busy KakaoTalk stall our reads). This configures our own AX client only; nothing is sent to KakaoTalk.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
        let actions = SidebarActions(
            openOnboarding: { [weak self] in self?.showOnboarding() },
            openSettings: { [weak self] in self?.showSettings() },
            resume: { [weak self] in self?.settings.paused = false }
        )
        panel = PanelController(rootView: SidebarView(model: model, settings: settings, actions: actions),
                                settings: settings)
        inline = InlineOverlayController(model: model, tracker: tracker, diagnostics: diagnostics)

        settings.onChange = { [weak self] key in self?.settingChanged(key) }
        tracker.onStateChange = { [weak self] state in self?.trackerStateChanged(state) }
        tracker.onRead = { [weak self] read, triggeredAt in
            guard let self else { return }
            self.model.ingest(read, triggeredAt: triggeredAt)
            self.inline?.ingest(read, anchor: self.tracker.scrollAnchor)
        }
        tracker.onGeometry = { [weak self] geometry in self?.geometryChanged(geometry) }
        tracker.onFrontmostChange = { [weak self] _ in self?.updatePanelVisibility() }
        tracker.onTranscriptRowsChanged = { [weak self] in self?.inline?.transcriptRowsChanged() }
        applyDisplayModeToReader()

        model.setPaused(settings.paused)
        tracker.setPaused(settings.paused)
        tracker.start()
        updatePanelVisibility()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }

        Task { [weak self] in
            guard let self else { return }
            await self.model.refreshEngineStatus()
            self.maybeShowOnboarding()
        }
        logger.info("started glossary=\(self.glossaryStore.merged.entries.count)")
        startStatsLogging()
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
        tracker.stop()
        inline?.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        onboardingModel?.stop()
        Task { [service] in
            await service.cancelAll()
            await service.clearCache()
        }
    }

    // MARK: - Tracker → panel / model

    private func trackerStateChanged(_ state: WindowTracker.State) {
        let status: SidebarViewModel.Status
        switch state {
        case .idle: status = .starting
        case .noPermission: status = .noPermission
        case .kakaoNotRunning: status = .kakaoNotRunning
        case .noChatWindow: status = .noChatWindow
        case .transcriptNotFound: status = .transcriptNotFound
        case .tracking: status = .active
        }
        model.setTrackerStatus(status)
        if state == .noChatWindow || state == .kakaoNotRunning || state == .noPermission {
            panel?.place(windowAX: nil, inputAX: nil)
        }
        updatePanelVisibility()
    }

    private func geometryChanged(_ geometry: WindowTracker.Geometry) {
        guard let panel else { return }
        panel.place(windowAX: geometry.windowAX, inputAX: geometry.inputAX)
        inline?.geometryChanged(geometry)
        updatePanelVisibility()
        if let stopwatch = geometry.stopwatch {
            diagnostics.recordFollow(stopwatch.elapsedMilliseconds)
        }
    }

    private func relayout() {
        let g = tracker.geometry
        panel?.place(windowAX: g.windowAX, inputAX: g.inputAX)
        inline?.screensChanged()
        updatePanelVisibility()
    }

    var isInlineMode: Bool { settings.displayMode == .inline }

    func updatePanelVisibility() {
        guard let panel else { return }
        let front = tracker.kakaoFrontmost
        let inlineMode = isInlineMode
        // `sidebarVisible` is the menu's "show translations" switch in both modes. The inline overlay only
        // makes sense over a frontmost KakaoTalk, so `pinned` applies to the sidebar only.
        let wanted = settings.sidebarVisible && (front || (!inlineMode && settings.pinned))
        var visible = !inlineMode && wanted && tracker.kakaoRunning && panel.placementValid
        if tracker.geometry.minimized { visible = false }
        panel.setVisible(visible, kakaoFrontmost: front)
        let overlayActive = inlineMode && wanted && front && tracker.kakaoRunning && tracker.state == .tracking
            && !tracker.geometry.minimized && tracker.geometry.windowAX != nil && !settings.paused
        inline?.setActive(overlayActive)
        // Nothing is read or translated while nothing can be seen; the tracker reads once on return.
        tracker.setContentWanted(wanted)
    }

    private func applyDisplayModeToReader() {
        let inlineMode = isInlineMode
        Task { [reader] in await reader.setInlineMargin(inlineMode) }
    }

    // MARK: - Settings

    private func settingChanged(_ key: AppSettings.Key) {
        switch key {
        case .targetLanguage:
            model.retarget(settings.targetLanguage)
        case .glossaryEnabled:
            model.updateGlossary(glossaryStore.merged)
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
            // Re-read with the new row margin (inline mode also parses rows just outside the viewport).
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                self?.tracker.requestRead()
            }
        case .paused:
            model.setPaused(settings.paused)
            tracker.setPaused(settings.paused)
            updatePanelVisibility()
        case .fontSize, .showOriginal, .onboardingShown:
            break
        }
    }

    func reloadGlossary() {
        glossaryStore.reload()
        model.updateGlossary(glossaryStore.merged)
    }

    // MARK: - Windows

    private func maybeShowOnboarding() {
        let needsPermission = !AccessibilityAccess.isGranted
        let needsLanguage = model.engineStatus == .needsDownload
        if !settings.onboardingShown || needsPermission || needsLanguage {
            settings.onboardingShown = true
            showOnboarding()
        }
    }

    func showOnboarding() {
        let onboarding = onboardingModel ?? OnboardingModel(service: service)
        onboarding.onAccessibilityGranted = { [weak self] in self?.tracker.refreshAttachment() }
        onboarding.onEngineStatus = { [weak self] _ in
            Task { [weak self] in await self?.model.refreshEngineStatus() }
        }
        onboardingModel = onboarding
        let target = settings.targetLocale
        let targetName = AppSettings.targetLanguages.first { $0.id == settings.targetLanguage }?.name
            ?? settings.targetLanguage
        presenter.show(id: "onboarding", title: "TalkLens 引导", size: CGSize(width: 480, height: 460),
                       onClose: { [weak self] in
                           self?.onboardingModel?.stop()
                           self?.onboardingModel = nil
                       }) {
            OnboardingView(model: onboarding, target: target, targetName: targetName,
                           done: { [weak self] in self?.presenter.close("onboarding") })
        }
    }

    func showSettings() {
        presenter.show(id: "settings", title: "TalkLens 设置", size: CGSize(width: 480, height: 620)) {
            SettingsView(settings: settings, glossary: glossaryStore, loginItem: loginItem,
                         reloadGlossary: { [weak self] in self?.reloadGlossary() })
        }
    }

    func showAbout() {
        presenter.show(id: "about", title: "关于 TalkLens", size: CGSize(width: 460, height: 360)) {
            AboutView(diagnostics: diagnostics)
        }
    }

    /// One-line, content-free status for the menu.
    var menuStatusLine: String {
        if settings.paused { return "状态：已暂停" }
        switch tracker.state {
        case .idle: return "状态：启动中"
        case .noPermission: return "状态：需要辅助功能权限"
        case .kakaoNotRunning: return "状态：KakaoTalk 未运行"
        case .noChatWindow: return "状态：没有打开的聊天窗口"
        case .transcriptNotFound: return "状态：未找到聊天记录区域"
        case .tracking:
            let c = model.counts
            return "状态：跟随中 · \(c.rows) 条 · 已译 \(c.done)"
        }
    }
}
