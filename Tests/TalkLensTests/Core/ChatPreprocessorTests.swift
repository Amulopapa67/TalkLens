// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import TalkLensCore

@Suite struct ChatPreprocessorTests {
    let pre = ChatPreprocessor(glossary: CoreFixtures.glossary)

    private func run(_ body: String, isSystem: Bool = false) -> PreprocessedMessage {
        pre.process(CoreFixtures.message(body, isSystem: isSystem))
    }

    // MARK: normalize

    @Test func normalizeStripsZeroWidthAndCollapsesSpaces() {
        #expect(ChatPreprocessor.normalize("a\u{200B}b\u{FEFF}c\u{2060}d\u{200C}") == "abcd")
        #expect(ChatPreprocessor.normalize("  안녕   하세요\t\t여러분  ") == "안녕 하세요 여러분")
    }

    @Test func normalizeKeepsLineBreaksAndTrimsLines() {
        #expect(ChatPreprocessor.normalize("첫 줄  \n   둘째 줄") == "첫 줄\n둘째 줄")
        #expect(ChatPreprocessor.normalize("a\r\nb\rc") == "a\nb\nc")
        #expect(ChatPreprocessor.normalize("a\n\n\n\n\nb") == "a\n\nb")
        #expect(ChatPreprocessor.normalize("\n\na\n\n") == "a")
        #expect(ChatPreprocessor.normalize("a\n\nb") == "a\n\nb")
    }

    // MARK: classification

    @Test func systemRowsAreNotTranslated() {
        let r = run("김철수님이 들어왔습니다.", isSystem: true)
        #expect(r.kind == .system)
        #expect(r.textForMT == nil)
        #expect(r.segments.isEmpty)
        #expect(r.chips.isEmpty)
    }

    @Test func emptyAndWhitespaceOnly() {
        #expect(run("").kind == .empty)
        #expect(run(" \u{200B}\n ").kind == .empty)
    }

    @Test func urlOnlyMessages() {
        #expect(run("https://example.com/notice/123").kind == .urlOnly)
        #expect(run("http://a.kr/x https://b.kr/y").kind == .urlOnly)
        #expect(run("https://example.com 확인 부탁드려요").kind == .translate)
    }

    @Test func emojiOnlyMessages() {
        #expect(run("😂😂").kind == .emojiOnly)
        #expect(run("👍 🙏").kind == .emojiOnly)
        #expect(run("❤️").kind == .emojiOnly)
        #expect(run("👨‍👩‍👧").kind == .emojiOnly)
        #expect(run("123").kind != .emojiOnly)
    }

    @Test func jamoOnlyMessagesGetGlossaryNote() {
        let r = run("ㅋㅋㅋㅋ")
        #expect(r.kind == .jamoOnly)
        #expect(r.note?.contains("哈哈") == true)
        #expect(r.textForMT == nil)
        let ok = run("ㅇㅋ ㄱㄱ")
        #expect(ok.kind == .jamoOnly)
        #expect(ok.note == "OK · 走起 / 开始吧")
        #expect(run("ㅠㅠ...").kind == .jamoOnly)
        #expect(run("ㅁㄹ").note == nil)
    }

    @Test func numberAndTimeOnlyMessages() {
        for s in ["12345", "3:30", "오후 3:00", "10/15", "2026.10.10", "010-1234-5678"] {
            #expect(run(s).kind == .numberOrTimeOnly, "\(s)")
        }
        #expect(run("3시").kind == .translate)
    }

    @Test func nonKoreanTextIsAlreadyTarget() {
        #expect(run("好的，我知道了").kind == .alreadyTarget)
        #expect(run("See you tomorrow").kind == .alreadyTarget)
        #expect(run("ok ㅋㅋ").kind == .alreadyTarget)
        #expect(run("ok ㅋㅋ").chips.map(\.term) == ["ㅋㅋ"])
    }

    @Test func mixedKoreanEnglishIsTranslated() {
        #expect(run("Deadline은 Friday까지예요").kind == .translate)
        #expect(run("오늘 meeting 있어요").kind == .translate)
    }

    @Test func mostlyEnglishWithOneKoreanWordIsNotTranslated() {
        let r = run("Please submit the final report to the department office 행정실 by Friday")
        #expect(r.kind == .alreadyTarget)
        #expect(r.chips.map(\.term) == ["행정실"])
    }

    @Test func koreanTargetMeansKoreanIsAlreadyTarget() {
        let ko = ChatPreprocessor(glossary: .empty, targetLanguage: "ko")
        #expect(ko.process(CoreFixtures.message("안녕하세요")).kind == .alreadyTarget)
    }

    @Test func mentionOnlyIsNotSentToMT() {
        let r = run("@린루이")
        #expect(!r.kind.needsTranslation)
    }

    // MARK: segments

    @Test func mentionsAndURLsAreKeptVerbatim() {
        let r = run("@린루이 혹시 https://example.com/a 자료 보셨어요?")
        #expect(r.kind == .translate)
        #expect(r.segments.contains(.keep("@린루이")))
        #expect(r.segments.contains(.keep("https://example.com/a")))
        #expect(r.translatableTexts == ["혹시", "자료 보셨어요?"])
        #expect(r.assemble(translations: ["T1", "T2"]) == "@린루이 T1 https://example.com/a T2")
    }

    @Test func emailIsNotAMention() {
        let r = run("메일은 kim@example.com 으로 보내주세요")
        #expect(r.translatableTexts.joined().contains("kim@example.com"))
    }

    @Test func lineBreaksAreKeepSegments() {
        let r = run("첫째 줄입니다\n둘째 줄입니다")
        #expect(r.segments == [.translate("첫째 줄입니다"), .keep("\n"), .translate("둘째 줄입니다")])
        #expect(r.assemble(translations: ["L1", "L2"]) == "L1\nL2")
        #expect(r.assemble(translations: ["only one"]) == nil)
    }

    @Test func segmentsWithoutHangulSyllablesAreKept() {
        // A jamo-only line inside a multi-line message.
        let laugh = run("오늘 회의 끝났어요\nㅋㅋㅋ")
        #expect(laugh.kind == .translate)
        #expect(laugh.segments == [.translate("오늘 회의 끝났어요"), .keep("\n"), .keep("ㅋㅋㅋ")])
        #expect(laugh.translatableTexts == ["오늘 회의 끝났어요"])
        #expect(laugh.assemble(translations: ["T"]) == "T\nㅋㅋㅋ")
        // A number-only line.
        let number = run("계좌번호 알려드릴게요\n12345")
        #expect(number.segments == [.translate("계좌번호 알려드릴게요"), .keep("\n"), .keep("12345")])
        // Emoji after a URL.
        let emoji = run("자료 링크입니다 https://example.com/a 🙏")
        #expect(emoji.translatableTexts == ["자료 링크입니다"])
        #expect(emoji.segments.last == .keep("🙏"))
        #expect(emoji.assemble(translations: ["T"]) == "T https://example.com/a 🙏")
        // English-only line.
        let english = run("내일 발표 자료입니다\nSee slide 3")
        #expect(english.translatableTexts == ["내일 발표 자료입니다"])
        #expect(english.textForMT == "내일 발표 자료입니다\nSee slide 3")
    }

    @Test func keptSegmentsStillGetChipsAndExpansionDecidesFirst() {
        // "ㅋㅋㅋ" is kept verbatim but its glossary chip is still shown.
        let laugh = run("오늘 회의 끝났어요\nㅋㅋㅋ")
        #expect(laugh.chips.contains { $0.term.hasPrefix("ㅋ") })
        // "ㅇㅋ" expands to Hangul ("오케이"), so that line is still sent to MT.
        let ok = run("자료 확인했습니다\nㅇㅋ")
        #expect(ok.translatableTexts == ["자료 확인했습니다", "오케이"])
    }

    @Test func expandIsAppliedBeforeMT() {
        let r = run("자료 ㄱㅅ합니다 ㄱㄱ")
        #expect(r.kind == .translate)
        #expect(r.textForMT == "자료 감사합니다 고고")
        #expect(r.translatableTexts == ["자료 감사합니다 고고"])
    }

    @Test func glossaryDisabledMeansNoExpandNoChips() {
        let off = ChatPreprocessor(glossary: CoreFixtures.glossary, glossaryEnabled: false)
        let r = off.process(CoreFixtures.message("랩미팅 ㄱㄱ 합시다"))
        #expect(r.textForMT == "랩미팅 ㄱㄱ 합시다")
        #expect(r.chips.isEmpty)
        #expect(off.process(CoreFixtures.message("ㅋㅋㅋ")).note == nil)
    }

    @Test func longTextIsSplitAtSentenceBoundaries() {
        let small = ChatPreprocessor(glossary: .empty, maxSegmentLength: 20)
        let text = "첫 번째 문장입니다. 두 번째 문장이에요! 세 번째 문장인가요? 네 번째."
        let r = small.process(CoreFixtures.message(text))
        let pieces = r.translatableTexts
        #expect(pieces.count >= 3)
        #expect(pieces.allSatisfy { $0.count <= 20 })
        #expect(pieces[0] == "첫 번째 문장입니다.")
        let rebuilt = r.assemble(translations: pieces)
        #expect(rebuilt == text)
    }

    @Test func overlongSentenceIsHardSplit() {
        let small = ChatPreprocessor(glossary: .empty, maxSegmentLength: 10)
        let text = String(repeating: "가", count: 35)
        let r = small.process(CoreFixtures.message(text))
        #expect(r.translatableTexts.map(\.count) == [10, 10, 10, 5])
        #expect(r.assemble(translations: r.translatableTexts) == text)
    }

    @Test func defaultMaxSegmentLengthKeepsNormalMessagesWhole() {
        let text = String(repeating: "안녕하세요. ", count: 100)  // 700 chars
        let r = run(text)
        #expect(r.translatableTexts.count == 1)
        let long = String(repeating: "안녕하세요. ", count: 300)  // 2100 chars
        let r2 = run(long)
        #expect(r2.translatableTexts.count >= 3)
        #expect(r2.translatableTexts.allSatisfy { $0.count <= 1000 })
    }

    // MARK: fixtures

    @Test func fixtureMessagesClassifyAsExpected() {
        let lines = CoreFixtures.testMessages()
        #expect(lines.count == 28)
        let expected: [String: MessageKind] = [
            "ㅋㅋㅋㅋ": .jamoOnly,
            "ㅇㅋ ㄱㄱ": .jamoOnly,
            "https://example.com/notice/123": .urlOnly,
            "12345": .numberOrTimeOnly,
            "😂😂": .emojiOnly,
            "好的，我知道了": .alreadyTarget,
        ]
        for (i, line) in lines.enumerated() {
            let r = pre.process(CoreFixtures.message(line, id: "f\(i)"))
            let want = expected[line] ?? .translate
            #expect(r.kind == want, "fixture line \(i + 1) -> \(r.kind), want \(want)")
            if want == .translate {
                #expect(!r.translatableTexts.isEmpty)
                #expect(r.assemble(translations: r.translatableTexts) == r.textForMT)
            } else {
                #expect(r.textForMT == nil && r.segments.isEmpty)
            }
        }
    }

    @Test func fixtureSpecificDetails() {
        let lines = CoreFixtures.testMessages()
        func find(_ prefix: String) -> PreprocessedMessage {
            let line = lines.first { $0.hasPrefix(prefix) } ?? ""
            return pre.process(CoreFixtures.message(line))
        }
        #expect(find("ㅋㅋㅋㅋ").note?.contains("哈哈") == true)
        let mention = find("@린루이")
        #expect(mention.segments.first == .keep("@린루이"))
        #expect(mention.chips.map(\.term).contains("회식"))
        #expect(find("내일 랩미팅은").chips.map(\.term).contains("랩미팅"))
        let multi = find("안녕하세요 여러분,")
        #expect(multi.segments.filter { $0 == .keep("\n") }.count == 3)
        #expect(multi.translatableTexts.count == 4)
        #expect(multi.chips.map(\.term) == ["출입 카드", "행정실", "개인 톡"])
        #expect(find("헐 대박").chips.map(\.term) == ["헐", "대박", "ㄷㄷ"])
    }

    @Test func preprocessing200MessagesIsFast() {
        let lines = CoreFixtures.testMessages()
        let msgs = (0..<200).map { CoreFixtures.message(lines[$0 % lines.count], id: "p\($0)") }
        _ = msgs.map(pre.process)  // warm-up (regex compile, NL model)
        let sw = Stopwatch()
        let out = msgs.map(pre.process)
        let ms = sw.elapsedMilliseconds
        #expect(out.count == 200)
        #expect(ms < 100, "preprocess 200 took \(ms) ms")
    }
}
