// SPDX-License-Identifier: MIT
// Wires WindowTracker → SidebarViewModel → OverlayPanel, and reacts to settings changes.

import AppKit
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
    private var onboardingModel: OnboardingModel?
    private var screenObserver: NSObjectProtocol?

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
        let actions = SidebarActions(
            openOnboarding: { [weak self] in self?.showOnboarding() },
            openSettings: { [weak self] in self?.showSettings() },
            resume: { [weak self] in self?.settings.paused = false }
        )
        panel = PanelController(rootView: SidebarView(model: model, settings: settings, actions: actions),
                                settings: settings)

        settings.onChange = { [weak self] key in self?.settingChanged(key) }
        tracker.onStateChange = { [weak self] state in self?.trackerStateChanged(state) }
        tracker.onRead = { [weak self] read, triggeredAt in self?.model.ingest(read, triggeredAt: triggeredAt) }
        tracker.onGeometry = { [weak self] geometry in self?.geometryChanged(geometry) }
        tracker.onFrontmostChange = { [weak self] _ in self?.updatePanelVisibility() }

        model.setPaused(settings.paused)
        tracker.setPaused(settings.paused)
        tracker.start()

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
    }

    func stop() {
        tracker.stop()
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
        updatePanelVisibility()
        if let stopwatch = geometry.stopwatch {
            diagnostics.recordFollow(stopwatch.elapsedMilliseconds)
        }
    }

    private func relayout() {
        let g = tracker.geometry
        panel?.place(windowAX: g.windowAX, inputAX: g.inputAX)
    }

    func updatePanelVisibility() {
        guard let panel else { return }
        let front = tracker.kakaoFrontmost
        var visible = settings.sidebarVisible && tracker.kakaoRunning && (front || settings.pinned)
        if tracker.geometry.minimized { visible = false }
        panel.setVisible(visible, kakaoFrontmost: front)
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
            panel?.applyOpacity()
        case .pinned, .sidebarVisible:
            updatePanelVisibility()
        case .paused:
            model.setPaused(settings.paused)
            tracker.setPaused(settings.paused)
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
