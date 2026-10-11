// SPDX-License-Identifier: MIT
// UI language setting and string table (D-024): completeness, placeholder consistency, follow-system
// resolution, language labels and the Korean source default.

import Foundation
import Testing
@testable import TalkLensCore

@Suite struct UIStringsTests {
    private func freshDefaults() throws -> (UserDefaults, String) {
        let suite = "talklens.tests.ui.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    // MARK: Table

    @Test func everyKeyHasTextInEveryLanguage() {
        #expect(UILanguage.allCases.count == 5)
        #expect(UILanguageSetting.allCases.count == 6) // follow system + five languages
        for key in UIKey.allCases {
            for language in UILanguage.allCases {
                let text = UIStrings.template(key, language)
                #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(key) \(language)")
            }
        }
    }

    @Test func placeholdersMatchAcrossLanguages() {
        for key in UIKey.allCases {
            let reference = UIStrings.placeholders(in: UIStrings.template(key, .en))
            // Contiguous from {0}: no gaps that would leave an argument unused.
            #expect(reference == Array(0..<reference.count), "\(key)")
            for language in UILanguage.allCases {
                let p = UIStrings.placeholders(in: UIStrings.template(key, language))
                #expect(p == reference, "\(key) \(language): \(p) vs \(reference)")
            }
        }
    }

    @Test func formattingSubstitutesPositionalArguments() {
        #expect(UIStrings.text(.onboardingLanguageTitle, .zhHans, "韩语", "简体中文") == "翻译语言（韩语 → 简体中文）")
        #expect(UIStrings.text(.stateCounts, .en, 12, 3) == "Messages 12 · Translated 3")
        #expect(UIStrings.text(.aboutVersion, .ko, "1.0") == "버전 1.0")
        #expect(UIStrings.text(.menuQuit, .ja) == "TalkLens を終了")
        for language in UILanguage.allCases {
            #expect(!UIStrings.text(.newMessages, language, 4).contains("{"))
        }
    }

    @Test func japaneseAndKoreanAreActuallyLocalized() {
        // Guards against copy-paste: the Korean / Japanese column must not just repeat the Chinese or English.
        var sameAsChinese = 0
        var sameAsEnglish = 0
        for key in UIKey.allCases {
            let ko = UIStrings.template(key, .ko), ja = UIStrings.template(key, .ja)
            if ko == UIStrings.template(key, .en) { sameAsEnglish += 1 }
            if ja == UIStrings.template(key, .zhHans) { sameAsChinese += 1 }
        }
        // A few strings are legitimately identical (e.g. "設定", "{0}" style labels); never the majority.
        #expect(sameAsEnglish <= 2)
        #expect(sameAsChinese <= 6)
        #expect(UIStrings.template(.menuSettings, .ko) == "설정…")
    }

    // MARK: Follow system

    @Test func followSystemResolvesBestMatch() {
        #expect(UILanguage.resolve(preferredLanguages: ["zh-Hant-TW"]) == .zhHant)
        #expect(UILanguage.resolve(preferredLanguages: ["zh-TW"]) == .zhHant)
        #expect(UILanguage.resolve(preferredLanguages: ["zh-HK"]) == .zhHant)
        #expect(UILanguage.resolve(preferredLanguages: ["zh-Hans-CN"]) == .zhHans)
        #expect(UILanguage.resolve(preferredLanguages: ["ko-KR"]) == .ko)
        #expect(UILanguage.resolve(preferredLanguages: ["ja"]) == .ja)
        #expect(UILanguage.resolve(preferredLanguages: ["en-GB"]) == .en)
        #expect(UILanguage.resolve(preferredLanguages: ["fr"]) == .en)
        #expect(UILanguage.resolve(preferredLanguages: []) == .en)
        // The first supported entry wins.
        #expect(UILanguage.resolve(preferredLanguages: ["fr-FR", "de", "ja-JP", "ko"]) == .ja)
    }

    @Test func settingPersistsAndResolves() throws {
        let (defaults, suite) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(UILanguageSetting.load(from: defaults) == .system)
        #expect(UILanguageSetting.storageKey == "talklens.uiLanguage")
        #expect(UILanguageSetting.system.resolved(preferredLanguages: ["ko-KR"]) == .ko)
        #expect(UILanguageSetting.ja.resolved(preferredLanguages: ["ko-KR"]) == .ja)

        UILanguageSetting.zhHant.save(to: defaults)
        #expect(defaults.string(forKey: "talklens.uiLanguage") == "zh-Hant")
        #expect(UILanguageSetting.load(from: defaults) == .zhHant)

        defaults.set("tlh", forKey: UILanguageSetting.storageKey)
        #expect(UILanguageSetting.load(from: defaults) == .system)
        #expect(UILanguageSetting.load(from: nil) == .system)
        #expect(UILanguageSetting(.ko) == .ko)
    }

    // MARK: Language labels

    @Test func languageOptionLabels() {
        #expect(UIStrings.languageOptionLabel("ko", .en) == "한국어 (Korean)")
        #expect(UIStrings.languageOptionLabel("ko", .ko) == "한국어")
        #expect(UIStrings.languageOptionLabel("ja", .zhHans) == "日本語（日语）")
        #expect(UIStrings.languageOptionLabel("en", .en) == "English")
        #expect(UIStrings.languageOptionLabel("zh-Hans", .zhHant) == "简体中文")
        #expect(UIStrings.languageOptionLabel("zh-Hant", .ja) == "繁體中文（中国語（繁体字））")
        #expect(UIStrings.languageOptionLabel(LanguageCatalog.autoID, .zhHans) == "智能识别（自动检测）")
        #expect(UIStrings.uiLanguageOptionLabel(.ko, .en) == "한국어 (Korean)")
        for language in UILanguage.allCases {
            for option in LanguageCatalog.all {
                #expect(!UIStrings.languageName(option.id, language).isEmpty)
            }
        }
        let pair = LanguagePair(source: "ko", target: "zh-Hans")
        #expect(UIStrings.pairName(pair, .en) == "Korean→Chinese (Simplified)")
        #expect(UIStrings.pairName(pair, .ja) == "韓国語→中国語（簡体字）")
        #expect(UIStrings.list(["a", "b"], .zhHans) == "a、b")
        #expect(UIStrings.list(["a", "b"], .en) == "a, b")
    }

    // MARK: Source language default

    @Test func freshInstallDefaultsToKorean() throws {
        let (defaults, suite) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = LanguagePreferences.load(from: defaults)
        #expect(LanguageCatalog.defaultSource == "ko")
        #expect(prefs.source == "ko")
        #expect(prefs.sourceLanguage == "ko")
        #expect(prefs.target == "zh-Hans")
        #expect(LanguagePreferences().source == "ko")
        #expect(LanguagePreferences.load(from: nil).source == "ko")
        // The pair checked by onboarding / status is ko→target.
        #expect(prefs.fallbackSource == "ko")
    }

    @Test func storedSourceIsRespected() throws {
        let (defaults, suite) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        // Existing installs that chose auto-detect keep it.
        defaults.set("auto", forKey: LanguagePreferences.sourceKey)
        let auto = LanguagePreferences.load(from: defaults)
        #expect(auto.source == LanguageCatalog.autoID)
        #expect(auto.sourceLanguage == nil)
        #expect(auto.fallbackSource == "ko")

        defaults.set("ja", forKey: LanguagePreferences.sourceKey)
        #expect(LanguagePreferences.load(from: defaults).source == "ja")
        LanguagePreferences(source: "en", target: "ko").save(to: defaults)
        #expect(LanguagePreferences.load(from: defaults) == LanguagePreferences(source: "en", target: "ko"))
    }

    @Test func sourcePickerListsAutoDetectFirst() {
        let options = LanguageCatalog.sourceOptions(supported: nil)
        #expect(options.first?.id == LanguageCatalog.autoID)
        #expect(options.dropFirst().map(\.id) == LanguageCatalog.all.map(\.id))
        #expect(options.contains { $0.id == "ko" })
    }
}
