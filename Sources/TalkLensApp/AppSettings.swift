// SPDX-License-Identifier: MIT
// User preferences, persisted in UserDefaults. Preferences only — chat content is never stored here.

import Foundation
import Observation
import TalkLensCore

@MainActor
@Observable
final class AppSettings {
    enum Key: String, CaseIterable {
        case sourceLanguage, targetLanguage, showOriginal, fontSize, opacity, edge, panelWidth
        case glossaryEnabled, pinned, sidebarVisible, paused, onboardingShown, displayMode, uiLanguage
    }

    /// How translations are shown.
    enum DisplayMode: String, CaseIterable, Sendable {
        /// Transparent click-through overlay that paints each translation over its bubble.
        case inline
        /// Docked sidebar panel next to the chat window.
        case sidebar

        var nameKey: UIKey {
            switch self {
            case .inline: return .displayModeInline
            case .sidebar: return .displayModeSidebar
            }
        }
    }

    static let fontSizeRange: ClosedRange<Double> = 11...20
    static let opacityRange: ClosedRange<Double> = 0.5...1.0
    static let panelWidthRange: ClosedRange<Double> = 240...480

    static func edgeKey(_ edge: PanelEdge) -> UIKey {
        switch edge {
        case .right: return .edgeRight
        case .left: return .edgeLeft
        case .inside: return .edgeInside
        }
    }

    @ObservationIgnored private let defaults: UserDefaults?
    /// Called after a preference changes (not during init).
    @ObservationIgnored var onChange: ((Key) -> Void)?

    /// "auto" (detect per message) or a catalog id.
    var sourceLanguage: String { didSet { save(.sourceLanguage, sourceLanguage) } }
    var targetLanguage: String { didSet { save(.targetLanguage, targetLanguage) } }
    var showOriginal: Bool { didSet { save(.showOriginal, showOriginal) } }
    var fontSize: Double { didSet { save(.fontSize, fontSize) } }
    var opacity: Double { didSet { save(.opacity, opacity) } }
    var edge: PanelEdge { didSet { save(.edge, edge.rawValue) } }
    var panelWidth: Double { didSet { save(.panelWidth, panelWidth) } }
    var glossaryEnabled: Bool { didSet { save(.glossaryEnabled, glossaryEnabled) } }
    /// Keep the sidebar visible even when KakaoTalk is not frontmost.
    var pinned: Bool { didSet { save(.pinned, pinned) } }
    var sidebarVisible: Bool { didSet { save(.sidebarVisible, sidebarVisible) } }
    var paused: Bool { didSet { save(.paused, paused) } }
    var onboardingShown: Bool { didSet { save(.onboardingShown, onboardingShown) } }
    var displayMode: DisplayMode { didSet { save(.displayMode, displayMode.rawValue) } }
    /// Interface language: follow the system (default) or a fixed language (D-024).
    var uiLanguage: UILanguageSetting { didSet { save(.uiLanguage, uiLanguage.rawValue) } }

    /// `defaults == nil` keeps everything in memory (used by --self-check).
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        func value<T>(_ key: Key, _ fallback: T) -> T {
            (defaults?.object(forKey: AppSettings.storageKey(key)) as? T) ?? fallback
        }
        let languages = LanguagePreferences.load(from: defaults)
        sourceLanguage = languages.source
        targetLanguage = languages.target
        showOriginal = value(.showOriginal, false)
        fontSize = AppSettings.clamp(value(.fontSize, 13.0), AppSettings.fontSizeRange)
        // Background opacity of the sidebar (text always stays fully opaque).
        opacity = AppSettings.clamp(value(.opacity, 0.96), AppSettings.opacityRange)
        edge = PanelEdge(rawValue: value(.edge, PanelEdge.right.rawValue)) ?? .right
        panelWidth = AppSettings.clamp(value(.panelWidth, 320.0), AppSettings.panelWidthRange)
        glossaryEnabled = value(.glossaryEnabled, true)
        pinned = value(.pinned, false)
        sidebarVisible = value(.sidebarVisible, true)
        paused = value(.paused, false)
        onboardingShown = value(.onboardingShown, false)
        displayMode = DisplayMode(rawValue: value(.displayMode, DisplayMode.inline.rawValue)) ?? .inline
        uiLanguage = UILanguageSetting.load(from: defaults)
    }

    var targetLocale: Locale.Language { Locale.Language(identifier: targetLanguage) }

    var languages: LanguagePreferences { LanguagePreferences(source: sourceLanguage, target: targetLanguage) }
    /// Source for ChatPreprocessor: nil = auto-detect.
    var sourceLanguageID: String? { languages.sourceLanguage }
    /// Source for status checks and messages without a detected language (Korean when auto).
    var fallbackSourceLocale: Locale.Language { Locale.Language(identifier: languages.fallbackSource) }

    private static func storageKey(_ key: Key) -> String { "talklens." + key.rawValue }

    private static func clamp(_ v: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(v, range.lowerBound), range.upperBound)
    }

    private func save(_ key: Key, _ value: Any) {
        defaults?.set(value, forKey: AppSettings.storageKey(key))
        onChange?(key)
    }
}
