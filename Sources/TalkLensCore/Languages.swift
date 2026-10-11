// SPDX-License-Identifier: MIT
// Language catalog, persisted language preferences and per-message language detection (D-023).
//
// Detection is script-first (Hangul / kana / Han / Thai / Cyrillic are unambiguous) and asks
// NLLanguageRecognizer only to tell Latin-script languages apart and Simplified from Traditional Chinese.
// Everything runs on-device; nothing here logs or stores text.

import Foundation
import NaturalLanguage

/// A selectable language: BCP-47 id plus its native display name.
public struct LanguageOption: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A (source, target) translation pair, both catalog ids when known (e.g. "ja" → "zh-Hans").
public struct LanguagePair: Hashable, Sendable, CustomStringConvertible {
    public let source: String
    public let target: String
    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }

    public var description: String { "\(source)→\(target)" }

    /// "日本語→中文（简体）" — native names from the catalog.
    public var displayName: String {
        "\(LanguageCatalog.displayName(source))→\(LanguageCatalog.displayName(target))"
    }
}

/// Writing systems used by the catalog languages.
public enum LanguageScript: String, Sendable, Hashable {
    case hangul, kana, han, latin, cyrillic, thai
}

public enum LanguageCatalog {
    /// Sentinel id for "detect the source language of every message".
    public static let autoID = "auto"
    public static let autoOption = LanguageOption(id: autoID, name: "自动检测")
    public static let defaultTarget = "zh-Hans"
    /// Source assumed for messages whose language could not be decided (and the fallback pair shown in status).
    public static let fallbackSource = "ko"

    /// Every language TalkLens offers, in menu order.
    public static let all: [LanguageOption] = [
        LanguageOption(id: "ko", name: "한국어"),
        LanguageOption(id: "en", name: "English"),
        LanguageOption(id: "ja", name: "日本語"),
        LanguageOption(id: "zh-Hans", name: "中文（简体）"),
        LanguageOption(id: "zh-Hant", name: "中文（繁體）"),
        LanguageOption(id: "es", name: "Español"),
        LanguageOption(id: "fr", name: "Français"),
        LanguageOption(id: "de", name: "Deutsch"),
        LanguageOption(id: "ru", name: "Русский"),
        LanguageOption(id: "vi", name: "Tiếng Việt"),
        LanguageOption(id: "th", name: "ไทย"),
        LanguageOption(id: "id", name: "Bahasa Indonesia"),
    ]

    public static let allIDs: Set<String> = Set(all.map(\.id))

    public static func contains(_ id: String) -> Bool { allIDs.contains(id) }

    /// Native name for a catalog id ("自动检测" for auto); the id itself otherwise.
    public static func displayName(_ id: String) -> String {
        if id == autoID { return autoOption.name }
        if let o = all.first(where: { $0.id == id }) { return o.name }
        return canonicalID(id).flatMap { c in all.first { $0.id == c }?.name } ?? id
    }

    /// Source picker: auto + catalog languages, intersected with `supported` (catalog ids) when known and
    /// non-empty; the static list otherwise.
    public static func sourceOptions(supported: Set<String>?) -> [LanguageOption] {
        [autoOption] + targetOptions(supported: supported)
    }

    /// Target picker: catalog languages intersected with `supported` when known and non-empty.
    public static func targetOptions(supported: Set<String>?) -> [LanguageOption] {
        guard let supported, !supported.isEmpty else { return all }
        let filtered = all.filter { supported.contains($0.id) }
        return filtered.isEmpty ? all : filtered
    }

    /// Maps any BCP-47 identifier ("zh-TW", "ko-KR", "en-US", "zh-Hans-CN") to a catalog id, or nil.
    public static func canonicalID(_ identifier: String) -> String? {
        if allIDs.contains(identifier) { return identifier }
        let language = Locale.Language(identifier: identifier)
        return canonicalID(language)
    }

    /// Maps a Locale.Language to a catalog id, or nil when it is not in the catalog.
    public static func canonicalID(_ language: Locale.Language) -> String? {
        guard let code = language.languageCode?.identifier else { return nil }
        if code == "zh" {
            let script = language.maximalIdentifier
            return script.hasPrefix("zh-Hant") ? "zh-Hant" : "zh-Hans"
        }
        // Indonesian has the legacy code "in"; Locale normalizes it, but be lenient.
        if code == "in" { return "id" }
        return allIDs.contains(code) ? code : nil
    }

    /// Catalog id or, outside the catalog, the minimal identifier (for display and pair keys).
    public static func pairID(_ language: Locale.Language) -> String {
        canonicalID(language) ?? language.minimalIdentifier
    }

    /// Macro-language family: zh-Hans and zh-Hant are one family ("zh"); every other id is its own.
    public static func family(_ id: String) -> String {
        let c = canonicalID(id) ?? id
        return c.hasPrefix("zh") ? "zh" : c
    }

    /// Same language for the purpose of "already in the target language" (zh-Hans ≈ zh-Hant).
    public static func sameFamily(_ a: String, _ b: String) -> Bool {
        family(a) == family(b)
    }

    public static func isChinese(_ id: String) -> Bool { family(id) == "zh" }

    /// Writing system of a catalog language.
    public static func script(of id: String) -> LanguageScript {
        switch family(id) {
        case "ko": return .hangul
        case "ja": return .kana
        case "zh": return .han
        case "ru": return .cyrillic
        case "th": return .thai
        default: return .latin
        }
    }

    static func nlLanguage(_ id: String) -> NLLanguage? {
        switch id {
        case "ko": return .korean
        case "en": return .english
        case "ja": return .japanese
        case "zh-Hans": return .simplifiedChinese
        case "zh-Hant": return .traditionalChinese
        case "es": return .spanish
        case "fr": return .french
        case "de": return .german
        case "ru": return .russian
        case "vi": return .vietnamese
        case "th": return .thai
        case "id": return .indonesian
        default: return nil
        }
    }

    static func catalogID(_ nl: NLLanguage) -> String? {
        all.first { nlLanguage($0.id) == nl }?.id
    }
}

/// Persisted source / target choice. Lives in TalkLensCore so it can be unit-tested; AppSettings wraps it.
public struct LanguagePreferences: Equatable, Sendable {
    public static let sourceKey = "talklens.sourceLanguage"
    public static let targetKey = "talklens.targetLanguage"

    /// "auto" or a catalog id.
    public var source: String
    /// A catalog id.
    public var target: String

    public init(source: String = LanguageCatalog.autoID, target: String = LanguageCatalog.defaultTarget) {
        self.source = LanguagePreferences.validSource(source)
        self.target = LanguagePreferences.validTarget(target)
    }

    /// Source for ChatPreprocessor: nil = auto-detect.
    public var sourceLanguage: String? { source == LanguageCatalog.autoID ? nil : source }

    /// Source used for status checks and for messages without a detected language.
    public var fallbackSource: String { sourceLanguage ?? LanguageCatalog.fallbackSource }

    /// Reads both values; anything missing or not in the catalog falls back to auto / zh-Hans.
    public static func load(from defaults: UserDefaults?) -> LanguagePreferences {
        LanguagePreferences(source: defaults?.string(forKey: sourceKey) ?? LanguageCatalog.autoID,
                            target: defaults?.string(forKey: targetKey) ?? LanguageCatalog.defaultTarget)
    }

    public func save(to defaults: UserDefaults?) {
        defaults?.set(source, forKey: Self.sourceKey)
        defaults?.set(target, forKey: Self.targetKey)
    }

    public static func validSource(_ id: String) -> String {
        if id == LanguageCatalog.autoID { return id }
        return LanguageCatalog.canonicalID(id) ?? LanguageCatalog.autoID
    }

    public static func validTarget(_ id: String) -> String {
        LanguageCatalog.canonicalID(id) ?? LanguageCatalog.defaultTarget
    }
}

/// Dominant language of a piece of chat text.
public struct DetectedLanguage: Equatable, Sendable {
    /// Catalog id.
    public let language: String
    /// 0…1: share of the (weighted) letters in this language's script, times the recognizer's probability
    /// for Latin-script / Chinese-variant decisions.
    public let confidence: Double
}

public enum LanguageDetector {
    /// Latin and Cyrillic letters weigh less than a CJK / Hangul character (a word vs. a syllable), so that
    /// "明日のmeetingは3時から" counts as Japanese.
    static let alphabetWeight = 0.35

    struct ScriptCounts {
        var hangul = 0.0, kana = 0.0, han = 0.0, latin = 0.0, cyrillic = 0.0, thai = 0.0, other = 0.0
        var total: Double { hangul + kana + han + latin + cyrillic + thai + other }
    }

    static func scriptOf(_ s: Unicode.Scalar) -> LanguageScript? {
        let v = s.value
        if TextScan.isHangulSyllable(s) { return .hangul }
        if (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) || (0xFF66...0xFF9F).contains(v) {
            // Prolonged sound mark / middle dot alone are not letters, but they only occur with kana.
            return .kana
        }
        if TextScan.isCJKIdeograph(s) || (0xF900...0xFAFF).contains(v) { return .han }
        if (0x0E01...0x0E5B).contains(v) { return s.properties.isAlphabetic ? .thai : nil }
        if (0x0400...0x04FF).contains(v) { return s.properties.isAlphabetic ? .cyrillic : nil }
        if s.properties.isAlphabetic && (v < 0x0250 || (0x1E00...0x1EFF).contains(v)) { return .latin }
        return nil
    }

    /// True when `text` contains at least one letter of `script` (Hangul: precomposed syllables only, exactly
    /// the rule used for Korean before D-023; kana: kana or Han, since Japanese is written with both).
    public static func containsLetters(of script: LanguageScript, in text: String) -> Bool {
        switch script {
        case .hangul:
            return TextScan.containsHangulSyllable(text)
        case .kana:
            return text.unicodeScalars.contains { let sc = scriptOf($0); return sc == .kana || sc == .han }
        default:
            return text.unicodeScalars.contains { scriptOf($0) == script }
        }
    }

    static func counts(_ text: String) -> ScriptCounts {
        var c = ScriptCounts()
        for s in text.unicodeScalars {
            switch scriptOf(s) {
            case .hangul: c.hangul += 1
            case .kana: c.kana += 1
            case .han: c.han += 1
            case .latin: c.latin += alphabetWeight
            case .cyrillic: c.cyrillic += alphabetWeight
            case .thai: c.thai += 1
            case nil:
                if s.properties.isAlphabetic && !s.properties.isWhitespace
                    && !TextScan.isCompatibilityJamo(s) && s.properties.generalCategory != .nonspacingMark {
                    c.other += 1
                }
            }
        }
        return c
    }

    /// Dominant language of `text` (URLs / mentions should be removed by the caller), or nil when the text has
    /// no letters or is in a script outside the catalog. `hint` (a catalog id) nudges the recognizer among
    /// languages sharing a script.
    public static func detect(_ text: String, hint: String? = nil) -> DetectedLanguage? {
        let c = counts(text)
        let total = c.total
        guard total > 0 else { return nil }
        let japanese = c.kana > 0 ? c.kana + c.han : 0
        let chinese = c.kana > 0 ? 0 : c.han
        let groups: [(LanguageScript?, Double)] = [
            (.hangul, c.hangul), (.kana, japanese), (.han, chinese), (.latin, c.latin),
            (.cyrillic, c.cyrillic), (.thai, c.thai), (nil, c.other),
        ]
        guard let best = groups.max(by: { $0.1 < $1.1 }), best.1 > 0, let script = best.0 else { return nil }
        let share = best.1 / total
        switch script {
        case .hangul: return DetectedLanguage(language: "ko", confidence: share)
        case .kana: return DetectedLanguage(language: "ja", confidence: share)
        case .thai: return DetectedLanguage(language: "th", confidence: share)
        case .cyrillic: return DetectedLanguage(language: "ru", confidence: share)
        case .han:
            // The script decides "Chinese"; the recognizer only picks the variant (default Simplified).
            let id = recognize(text, among: ["zh-Hans", "zh-Hant"], hint: hint)?.0 ?? "zh-Hans"
            return DetectedLanguage(language: id, confidence: share)
        case .latin:
            let latin = ["en", "es", "fr", "de", "vi", "id"]
            guard let (id, p) = recognize(text, among: latin, hint: hint) else {
                return DetectedLanguage(language: "en", confidence: 0)
            }
            return DetectedLanguage(language: id, confidence: share * p)
        }
    }

    /// NLLanguageRecognizer constrained to `candidates` (catalog ids); `hint` gets a strong prior.
    static func recognize(_ text: String, among candidates: [String], hint: String?) -> (String, Double)? {
        let languages = candidates.compactMap(LanguageCatalog.nlLanguage)
        guard !languages.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = languages
        if let hint, candidates.contains(hint), let nl = LanguageCatalog.nlLanguage(hint) {
            var hints: [NLLanguage: Double] = [:]
            for l in languages { hints[l] = l == nl ? 0.7 : 0.3 / Double(max(1, languages.count - 1)) }
            recognizer.languageHints = hints
        }
        recognizer.processString(text)
        guard let top = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              let id = LanguageCatalog.catalogID(top.key) else { return nil }
        return (id, top.value)
    }
}
