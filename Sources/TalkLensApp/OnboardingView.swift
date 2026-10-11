// SPDX-License-Identifier: MIT
// Permission and language onboarding (F2). Polls permission / KakaoTalk state once per second while open.

import KakaoAX
import Observation
import SwiftUI
import TalkLensCore
import TalkLensTranslate

@MainActor
@Observable
final class OnboardingModel {
    private(set) var accessibilityGranted = AccessibilityAccess.isGranted
    private(set) var kakaoRunning = KakaoProcess.isRunning
    private(set) var kakaoVersion: String? = KakaoProcess.version
    private(set) var engineStatus: EngineStatus?
    private(set) var checkingEngine = false
    var showDownloadPrompt = false

    @ObservationIgnored private let service: TranslationService
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored var onAccessibilityGranted: (() -> Void)?
    @ObservationIgnored var onEngineStatus: ((EngineStatus) -> Void)?

    init(service: TranslationService) {
        self.service = service
    }

    var allGood: Bool { accessibilityGranted && engineStatus == .ready && kakaoRunning }

    func start() {
        refreshEngine()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Re-resolve the weak reference each tick so the model is never kept alive across the sleep.
                guard self?.poll() != nil else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() {
        let granted = AccessibilityAccess.isGranted
        if granted && !accessibilityGranted { onAccessibilityGranted?() }
        accessibilityGranted = granted
        kakaoRunning = KakaoProcess.isRunning
        kakaoVersion = kakaoRunning ? KakaoProcess.version : nil
    }

    func requestAccessibility() {
        AccessibilityAccess.requestPrompt()
        AccessibilityAccess.openSystemSettings()
    }

    func refreshEngine() {
        checkingEngine = true
        let service = self.service
        Task { [weak self] in
            let status = await service.status()
            guard let self else { return }
            self.engineStatus = status
            self.checkingEngine = false
            self.onEngineStatus?(status)
        }
    }

    /// Source of the checked pair: the chosen source (Korean by default, D-024), or Korean when the source is
    /// auto-detected.
    var sourceLanguage: Locale.Language = Locale.Language(identifier: LanguageCatalog.defaultSource)
}

struct OnboardingView: View {
    let model: OnboardingModel
    let settings: AppSettings
    let done: @MainActor () -> Void

    private var target: Locale.Language { settings.targetLocale }

    /// "韩语" for a fixed source; "韩语（自动检测）" when auto-detecting (the pair checked uses Korean).
    private var sourceName: String {
        let name = UIStrings.languageName(settings.languages.fallbackSource, uiLanguage)
        return settings.sourceLanguageID == nil ? tr(.autoDetected, name) : name
    }

    private var targetName: String { UIStrings.languageName(settings.targetLanguage, uiLanguage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr(.onboardingWelcome))
                .font(.title2.weight(.semibold))
            Text(tr(.onboardingIntro))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            step(ok: model.accessibilityGranted, title: tr(.onboardingAXTitle),
                 detail: tr(model.accessibilityGranted ? .onboardingAXGranted : .onboardingAXNeeded)) {
                if !model.accessibilityGranted {
                    Button(tr(.onboardingOpenSystemSettings)) { model.requestAccessibility() }
                }
            }

            step(ok: model.engineStatus == .ready, title: tr(.onboardingLanguageTitle, sourceName, targetName),
                 detail: engineDetail) {
                HStack {
                    if model.engineStatus == .needsDownload {
                        Button(tr(.downloadLanguages)) { model.showDownloadPrompt = true }
                    }
                    Button(tr(.onboardingRecheck)) { model.refreshEngine() }
                        .disabled(model.checkingEngine)
                }
            }
            if model.showDownloadPrompt {
                LanguageDownloadPrompt(source: model.sourceLanguage, target: target, language: uiLanguage) { _ in
                    model.showDownloadPrompt = false
                    model.refreshEngine()
                }
                .frame(maxWidth: .infinity, minHeight: 40)
            }

            step(ok: model.kakaoRunning, title: "KakaoTalk",
                 detail: kakaoDetail) {
                EmptyView()
            }

            Spacer(minLength: 0)
            HStack {
                Text(tr(.onboardingDisclaimer))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(tr(model.allGood ? .onboardingDone : .onboardingLater)) { done() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var kakaoDetail: String {
        guard model.kakaoRunning else { return tr(.onboardingKakaoNotRunning) }
        if let version = model.kakaoVersion { return tr(.onboardingKakaoRunningVersion, version) }
        return tr(.onboardingKakaoRunning)
    }

    private var engineDetail: String {
        guard let status = model.engineStatus else { return tr(.checking) }
        if status == .ready { return tr(.engineInstalledSentence) }
        if status == .needsDownload { return tr(.engineNeedsDownloadSentence) }
        if case .unsupported(let reason) = status {
            return tr(.engineUnavailable, FailureReason.unsupportedStatus(reason, language: uiLanguage))
        }
        return tr(.engineUnknownSentence)
    }

    @ViewBuilder
    private func step<Accessory: View>(ok: Bool, title: String, detail: String,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
        }
    }
}
