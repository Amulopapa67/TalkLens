// SPDX-License-Identifier: MIT
// Current UI language for the whole app (D-024). Observable: SwiftUI views that call `tr(_:)` re-render when
// the language changes; AppKit parts (status menu, window titles) are refreshed through `onChange`.

import Foundation
import Observation
import TalkLensCore

@MainActor
@Observable
final class Localizer {
    static let shared = Localizer()

    private(set) var setting: UILanguageSetting = .system
    private(set) var language: UILanguage = UILanguage.system

    /// Called after the resolved language changed (menu rebuild, window titles).
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private var localeObserver: NSObjectProtocol?

    private init() {
        // "Follow system" re-resolves when the user's preferred languages change.
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Localizer.shared.apply(Localizer.shared.setting) }
        }
    }

    func apply(_ setting: UILanguageSetting) {
        self.setting = setting
        let resolved = setting.resolved()
        guard resolved != language else { return }
        language = resolved
        onChange?()
    }

    func text(_ key: UIKey, _ args: [any CustomStringConvertible]) -> String {
        UIStrings.text(key, language, arguments: args)
    }
}

/// Localized UI text in the current UI language.
@MainActor
func tr(_ key: UIKey, _ args: any CustomStringConvertible...) -> String {
    Localizer.shared.text(key, args)
}

/// Current UI language (reading it inside a SwiftUI body subscribes the view to language changes).
@MainActor
var uiLanguage: UILanguage { Localizer.shared.language }
