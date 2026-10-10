// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import TalkLensCore

@Suite struct GlossaryTests {
    let g = CoreFixtures.glossary

    @Test func loadsStarterGlossary() {
        #expect(g.entries.count == 56)
        let lab = g.entries.first { $0.ko == "랩미팅" }
        #expect(lab?.pattern == "랩\\s?미팅")
        #expect(g.entries.first { $0.ko == "ㅇㅇ" }?.standaloneOnly == true)
        #expect(g.entries.first { $0.ko == "ㄱㄱ" }?.expand == "고고")
    }

    @Test func literalAndRegexChipsInOrder() {
        let chips = g.chips(in: "교수님께서 랩 미팅 전에 과제 확인하래요")
        #expect(chips.map(\.term) == ["교수님", "랩미팅", "과제"])
        #expect(chips[1].gloss == "组会")
        #expect(chips[1].kind == "lab")
    }

    @Test func regexEntriesMatchVariants() {
        #expect(g.chips(in: "ㅋㅋㅋㅋㅋ").map(\.term) == ["ㅋㅋ"])
        #expect(g.chips(in: "다들 파이팅!").map(\.gloss) == ["加油"])
        #expect(g.chips(in: "ㅜㅠㅜ").map(\.term) == ["ㅠㅠ"])
    }

    @Test func leftmostLongestWins() {
        // "추후 공지" (regex, longer) beats "공지" (literal) at an overlapping position.
        let chips = g.chips(in: "보강 일정은 추후 공지하겠습니다.")
        #expect(chips.map(\.term) == ["보강", "추후 공지"])
        // Custom: longer literal beats a shorter one starting at the same index.
        let custom = Glossary(entries: [GlossaryEntry(ko: "단톡", zh: "A"), GlossaryEntry(ko: "단톡방", zh: "B")])
        #expect(custom.chips(in: "단톡방에 올려").map(\.gloss) == ["B"])
    }

    @Test func chipsAreDeduplicatedByTerm() {
        let chips = g.chips(in: "과제 하고 또 과제 ㅋㅋ ㅋㅋㅋ")
        #expect(chips.map(\.term) == ["과제", "ㅋㅋ"])
    }

    @Test func standaloneOnlyEntriesNeedWholeMessage() {
        #expect(g.chips(in: "ㅇㅇ").map(\.term) == ["ㅇㅇ"])
        #expect(g.chips(in: " ㅇㅇ ").map(\.term) == ["ㅇㅇ"])
        #expect(g.chips(in: "ㅇㅇ 알겠어").isEmpty)
        #expect(g.standaloneNote(for: "ㅇㅇ") == "嗯嗯 / 好")
        #expect(g.standaloneNote(for: "ㅇㅇ~") == "嗯嗯 / 好")
        #expect(g.standaloneNote(for: "ㅇㅇ 알겠어") == nil)
        #expect(g.standaloneNote(for: "과제") == nil)
    }

    @Test func anchoredRegexOnlyMatchesWholeMessage() {
        #expect(g.chips(in: "넵!").map(\.term) == ["넵"])
        #expect(g.chips(in: "넵 알겠습니다!").isEmpty)
    }

    @Test func expandReplacesOnlyExpandableTokens() {
        #expect(g.expand("ㅇㅋ ㄱㄱ") == "오케이 고고")
        #expect(g.expand("자료 ㄱㅅ합니다") == "자료 감사합니다")
        #expect(g.expand("랩미팅 ㅋㅋ") == "랩미팅 ㅋㅋ")
        #expect(g.expand("") == "")
    }

    @Test func emptyGlossaryDoesNothing() {
        #expect(Glossary.empty.chips(in: "랩미팅").isEmpty)
        #expect(Glossary.empty.expand("ㄱㄱ") == "ㄱㄱ")
        #expect(Glossary.empty.standaloneNote(for: "ㅇㅇ") == nil)
    }

    @Test func mergedOverridesAndKeepsMatchersWorking() {
        let user = Glossary(entries: [GlossaryEntry(ko: "랩미팅", zh: "实验室例会", kind: "lab", pattern: "랩\\s?미팅"),
                                      GlossaryEntry(ko: "GPU", zh: "显卡")])
        let m = g.merged(with: user)
        #expect(m.entries.count == 57)
        #expect(m.chips(in: "랩미팅 GPU").map(\.gloss) == ["实验室例会", "显卡"])
    }

    @Test func invalidRegexFallsBackToLiteral() {
        let bad = Glossary(entries: [GlossaryEntry(ko: "abc", zh: "X", pattern: "([unclosed")])
        #expect(bad.chips(in: "xx abc yy").map(\.gloss) == ["X"])
    }

    @Test func glossaryIsSendableAcrossTasks() async {
        let shared = g
        let counts = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<4 { group.addTask { shared.chips(in: "랩미팅 과제 ㅋㅋ").count } }
            var out: [Int] = []
            for await c in group { out.append(c) }
            return out
        }
        #expect(counts == [3, 3, 3, 3])
    }
}
