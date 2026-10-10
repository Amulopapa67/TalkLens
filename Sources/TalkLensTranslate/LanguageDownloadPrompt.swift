// SPDX-License-Identifier: MIT
// SwiftUI view that asks the system to download missing translation languages
// (`.translationTask` + `prepareTranslation()`); must be shown in a visible window (settings/onboarding).

import SwiftUI
@preconcurrency import Translation

public struct LanguageDownloadPrompt: View {
    let source: Locale.Language
    let target: Locale.Language
    let onFinish: @MainActor (Bool) -> Void

    private enum Phase: Equatable {
        case checking
        case needsDownload
        case downloading
        case installed
        case notInstalled
        case unsupported
    }

    @State private var phase: Phase = .checking
    @State private var configuration: TranslationSession.Configuration?

    /// `onFinish(true)` when the languages are installed afterwards.
    public init(source: Locale.Language, target: Locale.Language, onFinish: @escaping @MainActor (Bool) -> Void) {
        self.source = source
        self.target = target
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Translation languages")
                .font(.headline)
            Text("TalkLens translates on this Mac with Apple Translation. It needs these languages downloaded: "
                 + "\(Self.displayName(source)) and \(Self.displayName(target)). Nothing is sent over the network.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(buttonTitle) { requestDownload() }
                    .disabled(phase == .downloading || phase == .checking || phase == .installed
                              || phase == .unsupported)
                Text(statusText)
                    .foregroundStyle(.secondary)
            }
            Text("You can also download them in System Settings → General → Language & Region → Translation Languages.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .task { await refresh(report: false) }
        .translationTask(configuration) { session in
            // Shows the system download sheet; must run while this view is visible.
            do {
                try await session.prepareTranslation()
            } catch {
                // Declined or failed; the availability re-check below decides the outcome.
            }
            await refresh(report: true)
        }
    }

    private var buttonTitle: String {
        phase == .notInstalled ? "Try again" : "Download languages…"
    }

    private var statusText: String {
        switch phase {
        case .checking: return "Checking…"
        case .needsDownload: return "Not downloaded yet"
        case .downloading: return "Waiting for download…"
        case .installed: return "Installed"
        case .notInstalled: return "Still not installed"
        case .unsupported: return "This language pair is not supported"
        }
    }

    private func requestDownload() {
        phase = .downloading
        if configuration == nil {
            configuration = TranslationSession.Configuration(source: source, target: target)
        } else {
            // Re-runs the translationTask action with the same languages.
            configuration?.invalidate()
        }
    }

    private func refresh(report: Bool) async {
        let state = await AppleTranslationEngine.languageState(source: source, target: target, preferLowLatency: true)
        switch state {
        case .installed: phase = .installed
        case .supported: phase = report ? .notInstalled : .needsDownload
        case .unsupported: phase = .unsupported
        }
        if report || state == .installed { onFinish(state == .installed) }
    }

    static func displayName(_ language: Locale.Language) -> String {
        let id = language.maximalIdentifier
        let english = Locale(identifier: "en")
        if language.minimalIdentifier == "zh" || id.hasPrefix("zh-Hans") {
            return "Chinese (Simplified)"
        }
        if id.hasPrefix("zh-Hant") { return "Chinese (Traditional)" }
        return english.localizedString(forLanguageCode: language.languageCode?.identifier ?? id) ?? id
    }
}
