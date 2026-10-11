// SPDX-License-Identifier: MIT
// Multi-language source / target (D-023): detection, classification, segment keep rule, glossary scope,
// language catalog and persisted preferences. Synthetic sentences only.

import Foundation
import Testing
@testable import TalkLensCore

@Suite struct MultiLanguageTests {
    private func pre(_ source: String?, _ target: String = "zh-Hans",
                     glossary: Glossary = .empty) -> ChatPreprocessor {
        ChatPreprocessor(glossary: glossary, sourceLanguage: source, targetLanguage: target)
    }

    private func run(_ p: ChatPreprocessor, _ body: String) -> PreprocessedMessage {
        p.process(CoreFixtures.message(body))
    }

    // MARK: Korean unchanged

    @Test func defaultSourceIsKoreanAndTranslatedMessagesCarryIt() {
        let p = ChatPreprocessor(glossary: CoreFixtures.glossary)
        #expect(p.sourceLanguage == "ko")
        #expect(ChatPreprocessor(glossary: .empty, sourceLanguage: "auto").sourceLanguage == nil)
        #expect(ChatPreprocessor(glossary: .empty, sourceLanguage: "ko-KR").sourceLanguage == "ko")
        let r = run(p, "내일 랩미팅 있어요")
        #expect(r.kind == .translate)
        #expect(r.sourceLanguage == "ko")
        #expect(run(p, "ㅋㅋㅋ").sourceLanguage == nil)
    }

    @Test func autoDetectGivesTheKoreanResultForKoreanFixtureLines() {
        let ko = pre("ko", glossary: CoreFixtures.glossary)
        let auto = pre(nil, glossary: CoreFixtures.glossary)
        for (i, line) in CoreFixtures.testMessages().enumerated() {
            let a = ko.process(CoreFixtures.message(line, id: "k\(i)"))
            let b = auto.process(CoreFixtures.message(line, id: "k\(i)"))
            #expect(a == b, "fixture line \(i + 1): auto \(b.kind) vs ko \(a.kind)")
        }
    }

    // MARK: auto-detect classification

    @Test func autoDetectsEnglishJapaneseAndChineseSources() {
        let toZh = pre(nil, "zh-Hans")
        let en = run(toZh, "See you tomorrow at the library")
        #expect(en.kind == .translate)
        #expect(en.sourceLanguage == "en")
        #expect(en.translatableTexts == ["See you tomorrow at the library"])
        let ja = run(toZh, "明日の会議は午後三時からです")
        #expect(ja.kind == .translate)
        #expect(ja.sourceLanguage == "ja")
        #expect(run(toZh, "明日のmeetingは3時からです").sourceLanguage == "ja")
        let zhToEn = run(pre(nil, "en"), "我们明天下午三点开会")
        #expect(zhToEn.kind == .translate)
        #expect(zhToEn.sourceLanguage.map(LanguageCatalog.isChinese) == true)
    }

    @Test func autoTargetLanguageMessagesAreAlreadyTarget() {
        #expect(run(pre(nil, "zh-Hans"), "好的，我知道了").kind == .alreadyTarget)
        // Same macro-language: Traditional text with a Simplified target (and vice versa) is not translated.
        #expect(run(pre(nil, "zh-Hans"), "我們明天見，謝謝你").kind == .alreadyTarget)
        #expect(run(pre(nil, "zh-Hant"), "好的，我知道了").kind == .alreadyTarget)
        let toEn = pre(nil, "en")
        #expect(run(toEn, "See you tomorrow at the library").kind == .alreadyTarget)
        let ko = run(toEn, "안녕하세요 여러분")
        #expect(ko.kind == .translate)
        #expect(ko.sourceLanguage == "ko")
        #expect(run(pre(nil, "ko"), "안녕하세요 여러분").kind == .alreadyTarget)
        #expect(run(pre(nil, "ja"), "明日の会議は午後三時からです").kind == .alreadyTarget)
    }

    @Test func autoMostlyEnglishMessageWithAKoreanWordIsEnglish() {
        // With source ko this is "already target" (D-013); with auto it is an English message.
        let text = "Please submit the final report to the department office 행정실 by Friday"
        #expect(run(pre("ko"), text).kind == .alreadyTarget)
        let auto = run(pre(nil), text)
        #expect(auto.kind == .translate)
        #expect(auto.sourceLanguage == "en")
    }

    @Test func autoKeepsGenericRulesForEmojiURLNumbersAndJamo() {
        let auto = pre(nil, "en")
        #expect(run(auto, "😂😂").kind == .emojiOnly)
        #expect(run(auto, "https://example.com/a").kind == .urlOnly)
        #expect(run(auto, "12345").kind == .numberOrTimeOnly)
        #expect(run(auto, "ㅋㅋㅋ").kind == .jamoOnly)
    }

    // MARK: fixed non-Korean source

    @Test func fixedSourceLeavesOtherScriptsAndTargetUntranslated() {
        let en = pre("en", "zh-Hans")
        #expect(run(en, "안녕하세요 여러분").kind == .alreadyTarget)  // no Latin letters
        #expect(run(en, "好的，我知道了").kind == .alreadyTarget)
        #expect(run(en, "ㅋㅋㅋ").kind != .jamoOnly)            // jamo rule is Korean-only
        let ok = run(en, "Meeting moved to 3pm, see you there")
        #expect(ok.kind == .translate)
        #expect(ok.sourceLanguage == "en")
        // Confidently another Latin-script language (French) is left as is.
        let fr = run(en, "Bonjour à tous, la réunion de demain matin est annulée à cause de la grève des transports")
        #expect(fr.kind == .alreadyTarget)
        // Same family as the target: nothing to do.
        #expect(run(pre("zh-Hant", "zh-Hans"), "我們明天見").kind == .alreadyTarget)
    }

    @Test func fixedJapaneseSourceTrustsHanOnlyText() {
        let ja = pre("ja", "en")
        let kanji = run(ja, "明日会議")
        #expect(kanji.kind == .translate)
        #expect(kanji.sourceLanguage == "ja")
        #expect(run(ja, "안녕하세요").kind == .alreadyTarget)
    }

    // MARK: segment keep rule per script

    @Test func segmentsWithoutSourceScriptLettersAreKept() {
        let en = run(pre(nil, "ja"), "Please check the slides\n12345\n好的")
        #expect(en.sourceLanguage == "en")
        #expect(en.segments == [.translate("Please check the slides"), .keep("\n"), .keep("12345"), .keep("\n"),
                                .keep("好的")])
        let ja = run(pre("ja", "zh-Hans"), "明日は休みです\n안녕")
        #expect(ja.segments == [.translate("明日は休みです"), .keep("\n"), .keep("안녕")])
        let ru = run(pre(nil, "en"), "Привет всем, встреча завтра\nOK 👍")
        #expect(ru.sourceLanguage == "ru")
        #expect(ru.translatableTexts == ["Привет всем, встреча завтра"])
        // Korean: exactly the Hangul-syllable rule.
        let ko = run(pre(nil), "오늘 회의 끝났어요\nSee slide 3")
        #expect(ko.segments == [.translate("오늘 회의 끝났어요"), .keep("\n"), .keep("See slide 3")])
    }

    // MARK: glossary scope

    @Test func glossaryAppliesOnlyToKoreanMessages() {
        let g = CoreFixtures.glossary
        let autoZh = pre(nil, "zh-Hans", glossary: g)
        #expect(run(autoZh, "내일 랩미팅 있어요").chips.map(\.term).contains("랩미팅"))
        let english = run(autoZh, "Are you coming to the 회식 tonight with everyone else?")
        #expect(english.sourceLanguage == "en")
        #expect(english.chips.isEmpty)
        #expect(run(pre("en", "zh-Hans", glossary: g), "Lab meeting 랩미팅 moved to Friday afternoon").chips.isEmpty)
        // Non-Chinese target: Chinese glosses hidden, but source-side expansion still applies.
        let toEn = run(pre("ko", "en", glossary: g), "자료 ㄱㅅ합니다 랩미팅")
        #expect(toEn.chips.isEmpty)
        #expect(toEn.textForMT == "자료 감사합니다 랩미팅")
        #expect(run(pre("ko", "en", glossary: g), "ㅋㅋㅋ").note == nil)
        // Auto-detected jamo keeps its Chinese note for a Chinese target.
        #expect(run(autoZh, "ㅋㅋㅋㅋ").note?.contains("哈哈") == true)
    }

    // MARK: detector / catalog / preferences

    @Test func detectorUsesScriptsAndRecognizer() {
        #expect(LanguageDetector.detect("สวัสดีครับ พรุ่งนี้เจอกัน")?.language == "th")
        #expect(LanguageDetector.detect("Привет, как дела?")?.language == "ru")
        #expect(LanguageDetector.detect("Hola a todos, ¿cómo están? Nos vemos mañana en la oficina")?.language == "es")
        #expect(LanguageDetector.detect("12345 !!") == nil)
        #expect(LanguageDetector.detect("مرحبا بكم") == nil)  // script outside the catalog
        #expect(ChatPreprocessor.detectSourceLanguage("Deadline은 Friday까지예요") == "ko")
        #expect(ChatPreprocessor.detectSourceLanguage("https://example.com 😂") == nil)
    }

    @Test func catalogMapsIdentifiersAndIntersectsSupportedLanguages() {
        #expect(LanguageCatalog.all.count == 12)
        #expect(LanguageCatalog.canonicalID("zh-TW") == "zh-Hant")
        #expect(LanguageCatalog.canonicalID("zh-Hant-TW") == "zh-Hant")
        #expect(LanguageCatalog.canonicalID("zh-Hans-CN") == "zh-Hans")
        #expect(LanguageCatalog.canonicalID("ko-Kore-KR") == "ko")
        #expect(LanguageCatalog.canonicalID("en-GB") == "en")
        #expect(LanguageCatalog.canonicalID("pt-BR") == nil)
        #expect(LanguageCatalog.sameFamily("zh-Hans", "zh-Hant"))
        #expect(!LanguageCatalog.sameFamily("ja", "zh-Hans"))
        #expect(LanguageCatalog.targetOptions(supported: ["ko", "en", "xx"]).map(\.id) == ["ko", "en"])
        #expect(LanguageCatalog.targetOptions(supported: nil).count == 12)
        #expect(LanguageCatalog.targetOptions(supported: []).count == 12)
        let sources = LanguageCatalog.sourceOptions(supported: ["ja"])
        #expect(sources.map(\.id) == ["auto", "ja"])
        #expect(LanguagePair(source: "ja", target: "zh-Hans").displayName == "日本語→中文（简体）")
    }

    @Test func languagePreferencesPersistSourceAndTarget() throws {
        let suite = "talklens.tests.languages.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // D-024: a fresh install defaults to Korean (auto-detect stays selectable).
        let initial = LanguagePreferences.load(from: defaults)
        #expect(initial.source == "ko")
        #expect(initial.target == "zh-Hans")
        #expect(initial.sourceLanguage == "ko")
        #expect(initial.fallbackSource == "ko")

        LanguagePreferences(source: "ja", target: "en").save(to: defaults)
        #expect(defaults.string(forKey: "talklens.sourceLanguage") == "ja")
        #expect(defaults.string(forKey: "talklens.targetLanguage") == "en")
        let loaded = LanguagePreferences.load(from: defaults)
        #expect(loaded == LanguagePreferences(source: "ja", target: "en"))
        #expect(loaded.sourceLanguage == "ja")

        // Unknown stored values fall back to the defaults (ko, D-024); regional ids are normalized.
        defaults.set("klingon", forKey: LanguagePreferences.sourceKey)
        defaults.set("zh-TW", forKey: LanguagePreferences.targetKey)
        let odd = LanguagePreferences.load(from: defaults)
        #expect(odd.source == "ko")
        #expect(odd.target == "zh-Hant")
        #expect(LanguagePreferences.load(from: nil) == LanguagePreferences())
    }
}
