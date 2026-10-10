// SPDX-License-Identifier: MIT

import Testing
@testable import TalkLensCore

@Suite struct MessageIdentityTests {
    let chat = MessageIdentity.chatKey(forTitle: "synthetic chat")

    @Test func sha256HexMatchesKnownVector() {
        #expect(MessageIdentity.sha256Hex("abc")
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(MessageIdentity.sha256Hex("").hasPrefix("e3b0c44298fc1c14"))
    }

    @Test func chatKeyIsStable16Hex() {
        let k = MessageIdentity.chatKey(forTitle: "A")
        #expect(k.count == 16)
        #expect(k == MessageIdentity.chatKey(forTitle: "A"))
        #expect(k != MessageIdentity.chatKey(forTitle: "B"))
        #expect(k.allSatisfy { $0.isHexDigit })
    }

    @Test func idsAreStableAcrossSnapshots() {
        let p = [CoreFixtures.parsed("안녕"), CoreFixtures.parsed("반가워요", author: "B")]
        let a = MessageIdentity.assign(p, chatKey: chat).map(\.id)
        let b = MessageIdentity.assign(p, chatKey: chat).map(\.id)
        #expect(a == b)
        #expect(a[0] != a[1])
        #expect(a[0].rawValue.count == 16)
    }

    @Test func duplicatesGetSequentialSuffixes() {
        let p = Array(repeating: CoreFixtures.parsed("ㅋㅋ"), count: 3)
        let ids = MessageIdentity.assign(p, chatKey: chat).map(\.id.rawValue)
        #expect(ids[1] == ids[0] + "#1")
        #expect(ids[2] == ids[0] + "#2")
        #expect(Set(ids).count == 3)
    }

    @Test func everyFieldContributesToTheKey() {
        let base = CoreFixtures.parsed("hello")
        let id0 = MessageIdentity.assign([base], chatKey: chat)[0].id
        var variants: [ParsedMessage] = []
        var v = base; v.author = "Z"; variants.append(v)
        v = base; v.date = "2026-10-11"; variants.append(v)
        v = base; v.timeRaw = "오후 3:13"; variants.append(v)
        v = base; v.body = "hello!"; variants.append(v)
        v = base; v.author = nil; v.isMine = true; variants.append(v)
        for variant in variants {
            #expect(MessageIdentity.assign([variant], chatKey: chat)[0].id != id0)
        }
        #expect(MessageIdentity.assign([base], chatKey: "other")[0].id != id0)
    }

    @Test func mineAndSystemRowsWithSameTextDiffer() {
        let mine = CoreFixtures.parsed("공지", author: nil, isMine: true, time: nil, date: nil)
        let system = CoreFixtures.parsed("공지", author: nil, isSystem: true, time: nil, date: nil)
        let ids = MessageIdentity.assign([mine, system], chatKey: chat).map(\.id.rawValue)
        #expect(ids[0] != ids[1])
        #expect(!ids[1].contains("#"))
    }

    @Test func bodyIsNormalizedBeforeHashing() {
        let a = CoreFixtures.parsed("안녕  하세요\u{200B}")
        let b = CoreFixtures.parsed("안녕 하세요")
        let ids = MessageIdentity.assign([a, b], chatKey: chat).map(\.id.rawValue)
        // Same normalized body -> same base key -> the second one gets "#1".
        #expect(ids[1] == ids[0] + "#1")
    }

    @Test func assigning200MessagesIsFast() {
        let lines = CoreFixtures.testMessages()
        let parsed = (0..<200).map { CoreFixtures.parsed(lines[$0 % lines.count]) }
        var samples: [Double] = []
        for _ in 0..<30 {
            let sw = Stopwatch()
            let out = MessageIdentity.assign(parsed, chatKey: chat)
            samples.append(sw.elapsedMilliseconds)
            #expect(Set(out.map(\.id)).count == 200)
        }
        // Identity is part of the 30 ms parse budget; keep it a small fraction of that.
        #expect(LatencyStats(samples).p95 < 10)
    }

    @Test func assignKeepsMessageFields() {
        let p = CoreFixtures.parsed("본문", author: "B")
        let m = MessageIdentity.assign([p], chatKey: chat)[0]
        #expect(m.body == "본문")
        #expect(m.author == "B")
        #expect(m.timeRaw == "오후 3:12")
    }
}
