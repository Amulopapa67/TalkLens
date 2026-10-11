// SPDX-License-Identifier: MIT
// SwiftUI view that asks the system to download missing translation languages
// (`.translationTask` + `prepareTranslation()`); must be shown in a visible window (settings/onboarding).

import SwiftUI
import TalkLensCore
@preconcurrency import Translation

public struct LanguageDownloadPrompt: View {
    let source: Locale.Language
    let target: Locale.Language
    /// Interface language of the prompt's text (D-024).
    let language: UILanguage
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
    public init(source: Locale.Language, target: Locale.Language, language: UILanguage = .system,
                onFinish: @escaping @MainActor (Bool) -> Void) {
        self.source = source
        self.target = target
        self.language = language
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(UIStrings.text(.downloadTitle, language))
                .font(.headline)
            Text(UIStrings.text(.downloadBody, language, Self.displayName(source, language),
                                Self.displayName(target, language)))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(buttonTitle) { requestDownload() }
                    .disabled(phase == .downloading || phase == .checking || phase == .installed
                              || phase == .unsupported)
                Text(statusText)
                    .foregroundStyle(.secondary)
            }
            Text(UIStrings.text(.downloadFooter, language))
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
        UIStrings.text(phase == .notInstalled ? .downloadTryAgain : .downloadLanguages, language)
    }

    private var statusText: String {
        let key: UIKey
        switch phase {
        case .checking: key = .checking
        case .needsDownload: key = .downloadNotYet
        case .downloading: key = .downloadWaiting
        case .installed: key = .engineReady
        case .notInstalled: key = .downloadStillNot
        case .unsupported: key = .downloadUnsupported
        }
        return UIStrings.text(key, language)
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

    /// Localized name of a translation language (catalog languages from the UI string table; others from
    /// Foundation in the UI language).
    static func displayName(_ language: Locale.Language, _ ui: UILanguage) -> String {
        if let id = LanguageCatalog.canonicalID(language) { return UIStrings.languageName(id, ui) }
        let code = language.languageCode?.identifier ?? language.minimalIdentifier
        return Locale(identifier: ui.rawValue).localizedString(forLanguageCode: code) ?? language.minimalIdentifier
    }
}
