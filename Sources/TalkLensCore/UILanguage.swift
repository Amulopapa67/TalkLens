// SPDX-License-Identifier: MIT
// App UI language (D-024): the five languages the interface is written in, the persisted user choice
// ("follow system" or one of them) and resolution of "follow system" against Locale.preferredLanguages.

import Foundation

/// A language the TalkLens interface is available in.
public enum UILanguage: String, CaseIterable, Sendable, Hashable, Identifiable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
    case ko
    case ja

    public var id: String { rawValue }

    /// The language's name in itself, as shown in the language picker.
    public var nativeName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ko: return "한국어"
        case .ja: return "日本語"
        }
    }

    public var isChinese: Bool { self == .zhHans || self == .zhHant }

    /// Used when nothing in the preferred languages matches.
    public static let fallback: UILanguage = .en

    /// Maps one BCP-47 identifier ("zh-Hant-TW", "zh-HK", "ko-KR", "ja", "en-GB") to a UI language, or nil.
    public static func match(_ identifier: String) -> UILanguage? {
        let language = Locale.Language(identifier: identifier)
        guard let code = language.languageCode?.identifier else { return nil }
        switch code {
        case "zh":
            // maximalIdentifier fills in the script from the region (zh-TW / zh-HK / zh-MO → Hant).
            return language.maximalIdentifier.hasPrefix("zh-Hant") ? .zhHant : .zhHans
        case "en": return .en
        case "ko": return .ko
        case "ja": return .ja
        default: return nil
        }
    }

    /// First of `preferredLanguages` (most preferred first) that TalkLens has a UI for; English otherwise.
    public static func resolve(preferredLanguages: [String]) -> UILanguage {
        for identifier in preferredLanguages {
            if let match = match(identifier) { return match }
        }
        return fallback
    }

    /// The system's best match right now.
    public static var system: UILanguage { resolve(preferredLanguages: Locale.preferredLanguages) }
}

/// Persisted UI language choice: follow the system (default) or a fixed language.
public enum UILanguageSetting: String, CaseIterable, Sendable, Hashable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
    case ko
    case ja

    public static let storageKey = "talklens.uiLanguage"

    public var id: String { rawValue }

    /// The fixed language, or nil for "follow system".
    public var fixedLanguage: UILanguage? { UILanguage(rawValue: rawValue) }

    public init(_ language: UILanguage) {
        self = UILanguageSetting(rawValue: language.rawValue) ?? .system
    }

    /// The language to display: the fixed one, or the best match of `preferredLanguages`.
    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> UILanguage {
        fixedLanguage ?? UILanguage.resolve(preferredLanguages: preferredLanguages)
    }

    /// Missing or unknown stored values mean "follow system".
    public static func load(from defaults: UserDefaults?) -> UILanguageSetting {
        defaults?.string(forKey: storageKey).flatMap(UILanguageSetting.init(rawValue:)) ?? .system
    }

    public func save(to defaults: UserDefaults?) {
        defaults?.set(rawValue, forKey: Self.storageKey)
    }
}
