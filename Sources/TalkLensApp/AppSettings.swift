// SPDX-License-Identifier: MIT
// User preferences, persisted in UserDefaults. Preferences only — chat content is never stored here.

import Foundation
import Observation
import TalkLensCore

@MainActor
@Observable
final class AppSettings {
    enum Key: String, CaseIterable {
        case targetLanguage, showOriginal, fontSize, opacity, edge, panelWidth
        case glossaryEnabled, pinned, sidebarVisible, paused, onboardingShown, displayMode
    }

    /// How translations are shown.
    enum DisplayMode: String, CaseIterable, Sendable {
        /// Transparent click-through overlay that paints each translation over its bubble.
        case inline
        /// Docked sidebar panel next to the chat window.
        case sidebar

        var name: String {
            switch self {
            case .inline: return "沉浸式（覆盖在气泡上）"
            case .sidebar: return "侧栏"
            }
        }
    }

    struct LanguageOption: Hashable, Sendable {
        let id: String
        let name: String
    }

    static let targetLanguages: [LanguageOption] = [
        LanguageOption(id: "zh-Hans", name: "简体中文"),
        LanguageOption(id: "zh-Hant", name: "繁體中文"),
        LanguageOption(id: "en", name: "English"),
        LanguageOption(id: "ja", name: "日本語"),
    ]

    static let fontSizeRange: ClosedRange<Double> = 11...20
    static let opacityRange: ClosedRange<Double> = 0.5...1.0
    static let panelWidthRange: ClosedRange<Double> = 240...480

    static func edgeName(_ edge: PanelEdge) -> String {
        let names: [PanelEdge: String] = [.right: "右侧外贴", .left: "左侧外贴", .inside: "内嵌（避让输入框）"]
        return names[edge] ?? edge.rawValue
    }

    @ObservationIgnored private let defaults: UserDefaults?
    /// Called after a preference changes (not during init).
    @ObservationIgnored var onChange: ((Key) -> Void)?

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

    /// `defaults == nil` keeps everything in memory (used by --self-check).
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        func value<T>(_ key: Key, _ fallback: T) -> T {
            (defaults?.object(forKey: AppSettings.storageKey(key)) as? T) ?? fallback
        }
        let lang: String = value(.targetLanguage, "zh-Hans")
        targetLanguage = AppSettings.targetLanguages.contains { $0.id == lang } ? lang : "zh-Hans"
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
    }

    var targetLocale: Locale.Language { Locale.Language(identifier: targetLanguage) }

    private static func storageKey(_ key: Key) -> String { "talklens." + key.rawValue }

    private static func clamp(_ v: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(v, range.lowerBound), range.upperBound)
    }

    private func save(_ key: Key, _ value: Any) {
        defaults?.set(value, forKey: AppSettings.storageKey(key))
        onChange?(key)
    }
}
