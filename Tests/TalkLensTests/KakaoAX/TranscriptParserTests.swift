// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Testing
@testable import KakaoAX
import TalkLensCore

@Suite("TranscriptParserTests")
struct TranscriptParserTests {
    @Test("group chat: author groups, continuation inherits author and the group's time")
    func groupBasic() throws {
        let all = try Fixture.parse("synthetic_group_basic")
        // The divider is an AXButton without text (as observed on 26.8.0): it is skipped, not emitted.
        #expect(all.count == 7)
        #expect(!all.contains { $0.isSystem })
        let m = Fixture.nonSystem(all)
        #expect(m.map(\.author) == ["합성A", "합성A", nil, "합성B", "합성C", "합성C", nil])
        #expect(m.map(\.isMine) == [false, false, true, false, false, false, true])
        // The first 합성A row has no time label; it takes the label of the next row in its group.
        #expect(m[0].timeRaw == "오후 3:12")
        #expect(m[1].timeRaw == "오후 3:12")
        #expect(m.allSatisfy { $0.date == "2026-10-10" })
        #expect(m[6].body == "오늘 점심 학식 vs 배달?")
        #expect(m.allSatisfy { $0.attachments.isEmpty })
    }

    @Test("1:1 chat: consecutive mine rows, partner continuation, duplicate bodies")
    func mineContinuation() throws {
        let m = try Fixture.parse("synthetic_mine_continuation")
        #expect(m.count == 10)
        #expect(m.filter(\.isMine).count == 4)
        #expect(m.filter(\.isMine).allSatisfy { $0.author == nil })
        #expect(m.filter { !$0.isMine }.allSatisfy { $0.author == "합성B" })
        #expect(m[1].timeRaw == "오전 10:05" && m[2].timeRaw == "오전 10:05")
        #expect(m[5].body == "😂😂" && m[5].timeRaw == "오전 10:07")
        #expect(m[7].body == "ㅋㅋㅋㅋ" && m[8].body == "ㅋㅋㅋㅋ")
        #expect(m[7].timeRaw == "오전 10:09")
        // The unread counter "1" is not taken as text, author or time.
        #expect(m[3].body == "好的，我知道了" && m[3].author == nil)
        let ids = MessageIdentity.assign(m, chatKey: "k").map(\.id.rawValue)
        #expect(Set(ids).count == ids.count)
        #expect(ids[8].hasSuffix("#1"))
    }

    @Test("dividers and notices are system rows; dates carry over from dividers")
    func dividersSystem() throws {
        let all = try Fixture.parse("synthetic_dividers_system")
        #expect(all.count == 10)
        let system = all.filter(\.isSystem)
        // Dividers: a titled AXButton, a centered static text, and a year-less titled button.
        #expect(system.map(\.body) == ["2026년 10월 9일 목요일", "합성B님이 들어왔습니다.", "2026년 10월 10일 금요일",
                                       "합성C님이 나갔습니다.", "10월 11일 토요일"])
        #expect(system.allSatisfy { $0.author == nil && !$0.isMine })
        let m = Fixture.nonSystem(all)
        // No AXHelp on these rows: the date comes from the preceding divider.
        #expect(m[0].author == "합성A" && m[0].date == "2026-10-09")
        #expect(m[1].author == "합성B" && m[1].date == "2026-10-09")
        #expect(m[2].date == "2026-10-10")
        #expect(m[3].isMine && m[3].body == "10/15 (수) 연구실 대청소 있습니다")
        // Year-less divider uses the reference year.
        #expect(m[4].date == "2026-10-11" && m[4].author == "합성A")
        // A notice breaks author chaining: 합성B's row has its own explicit name.
        #expect(all[3].author == "합성B")
        // Year-less AXHelp ("10월 10일") uses the reference year.
        #expect(m[2].author == "합성C" && m[2].date == "2026-10-10")
    }

    @Test("images, stickers, files and links are counted; truncated URLs are promoted")
    func attachmentsLinks() throws {
        let m = try Fixture.parse("synthetic_attachments_links")
        #expect(m.count == 8)
        #expect(m[0].author == "합성A" && m[0].body.isEmpty && m[0].attachments == AttachmentSummary(images: 1))
        #expect(m[0].timeRaw == "오후 2:01")
        // Link preview texts below the body are not taken as the author.
        #expect(m[1].author == "합성A" && m[1].body == "https://example.com/notice/123" && m[1].attachments.links == 1)
        #expect(m[3].isMine && m[3].attachments.images == 1 && m[3].body.isEmpty)
        #expect(m[4].author == "합성B" && m[4].attachments == AttachmentSummary(files: 1) && m[4].body.isEmpty)
        #expect(m[5].body == "자료는 여기 있어요 https://example.com/files/share/2026/fall/lab-seminar-schedule")
        #expect(m[5].author == "합성B" && m[5].attachments.links == 1)
        #expect(m[6].author == "합성C" && m[6].attachments.images == 1)
        #expect(m[7].isMine && m[7].attachments.links == 1)
    }

    @Test("multi-line and long bodies are kept whole")
    func multilineLong() throws {
        let m = try Fixture.parse("synthetic_multiline_long")
        #expect(m.count == 6)
        #expect(m[0].body == SyntheticFixtures.longParagraph)
        #expect(m[0].body.count > 1000)
        #expect(m[1].body.split(separator: "\n").count == 4)
        #expect(m[1].body.hasPrefix("안녕하세요 여러분,\n다음 주"))
        #expect(m[3].isMine && m[3].body == "네 확인했습니다.\n카드는 목요일에 반납할게요.")
        #expect(m[4].author == "합성C" && m[5].author == "합성C")
    }

    @Test("nested scroll-area bodies, button avatars and off-screen rows")
    func nestedOffscreen() throws {
        let visible = try Fixture.parse("synthetic_nested_offscreen")
        // Rows fully above or below the visible transcript are dropped; a partly visible row is kept.
        #expect(visible.count == 9)
        #expect(visible[0].author == "합성B" && visible[0].date == "2026-10-08")
        #expect(visible[2].isSystem && visible[2].date == "2026-10-09")
        #expect(!visible.contains { $0.body == "오늘 점심 학식 vs 배달?" })
        let m = Fixture.nonSystem(visible)
        #expect(m.map(\.author) == ["합성B", nil, "합성C", "합성C", nil, "합성A", "합성B", "합성B"])
        #expect(m[2].body == "오늘 3교시 휴강입니다. 보강 일정은 추후 공지하겠습니다.")

        let all = try Fixture.parse("synthetic_nested_offscreen", visibleOnly: false)
        // Everything above the input is analysed; rows below the input box are still excluded.
        #expect(all.count == 11)
        #expect(all.first?.author == "합성A" && all.first?.date == "2026-10-08")
    }

    @Test("left continuation with an earlier time does not inherit the author")
    func timeGuard() {
        var c = SyntheticChat(title: "t")
        c.other("합성A", .text("첫 번째"), time: "오후 3:20")
        c.other(nil, .text("두 번째"), time: "오후 3:10")
        let m = TranscriptParser(referenceYear: 2026).parse(window: c.build(note: "").root) ?? []
        #expect(m.count == 2)
        #expect(m[0].author == "합성A")
        #expect(m[1].author == nil)
    }

    @Test("my message between two of theirs breaks the chain; side falls back to time carry-over")
    func chainBreak() {
        var c = SyntheticChat(title: "t")
        c.other("합성A", .text("하나"), time: "오전 9:00", help: "2026. 3. 2.")
        c.mine(.text("둘"), time: "오전 9:01")
        c.other(nil, .text("셋"))
        let m = TranscriptParser(referenceYear: 2026).parse(window: c.build(note: "").root) ?? []
        #expect(m.count == 3)
        #expect(m[2].author == nil)
        #expect(m[2].timeRaw == "오전 9:00") // per-side carry-over (left)
        #expect(m.allSatisfy { $0.date == "2026-03-02" })
    }

    @Test("frames are reported in AX coordinates")
    func frames() throws {
        let m = try Fixture.parse("synthetic_group_basic")
        let mine = try #require(m.first { $0.isMine })
        let f = try #require(mine.frame)
        // Text area inset 8 pt from the bubble, whose right edge is 10 pt from the transcript's.
        #expect(f.x + f.width == 928)
        #expect(f.y > 285 && f.y < 837)
    }

    @Test("maxRows keeps the most recent rows")
    func maxRows() throws {
        let file = try Fixture.load("synthetic_200rows")
        // 11 rows = 10 messages + the trailing empty spacer row.
        let parser = TranscriptParser(referenceYear: 2026, maxRows: 11, visibleOnly: false)
        let m = parser.parse(window: file.root) ?? []
        #expect(m.count == 10)
        let full = TranscriptParser(referenceYear: 2026, visibleOnly: false).parse(window: file.root) ?? []
        #expect(Array(full.suffix(10)).map(\.body) == m.map(\.body))
    }

    // MARK: context rows around the viewport (M4 review M1)

    @Test("group head above the viewport: visible rows keep author, date and the uncut ids")
    func contextAboveViewport() throws {
        let title = "합성 맥락방"
        var c = SyntheticChat(title: title, options: .init(windowHeight: 400, spacerRow: false))
        c.divider("2026년 10월 9일 목요일")
        c.other("합성A", .text("첫 번째 메시지입니다"))
        for i in 1...7 { c.other(nil, .text("이어지는 메시지 \(i)번")) }
        c.other(nil, .text("마지막 메시지입니다"), time: "오후 3:12")
        let root = c.build(note: "").root

        let visible = TranscriptParser(referenceYear: 2026).parse(window: root) ?? []
        let uncut = TranscriptParser(referenceYear: 2026, visibleOnly: false).parse(window: root) ?? []
        // The viewport really cuts the group: divider and group head are off-screen.
        #expect(uncut.count == 10)
        #expect(visible.count >= 3 && visible.count < 8)
        #expect(!visible.contains { $0.isSystem || $0.body == "첫 번째 메시지입니다" })
        // Context: author chaining, divider date and the group's time label all apply.
        #expect(visible.allSatisfy { $0.author == "합성A" && $0.timeRaw == "오후 3:12" && $0.date == "2026-10-09" })
        let key = MessageIdentity.chatKey(forTitle: title)
        let visibleIDs = MessageIdentity.assign(visible, chatKey: key).map(\.id)
        let uncutIDs = MessageIdentity.assign(uncut, chatKey: key).map(\.id)
        #expect(visibleIDs == Array(uncutIDs.suffix(visibleIDs.count)))
        #expect(Array(uncut.suffix(visible.count)) == visible)
    }

    @Test("group-last time label below the viewport (behind the input filter) still back-fills")
    func contextBelowViewport() throws {
        var c = SyntheticChat(title: "합성 맥락방", options: .init(bottomAnchorRow: 2, spacerRow: false))
        c.other("합성B", .text("위쪽 메시지입니다"))
        c.other(nil, .text("가운데 메시지입니다"))
        c.other(nil, .text("보이는 마지막 메시지입니다"))
        // Below the transcript and below the input box.
        c.other(nil, .text("화면 아래 메시지입니다"), time: "오후 4:05", help: "2026. 10. 10.")
        c.mine(.text("내 메시지입니다"), time: "오후 4:06", help: "2026. 10. 10.")
        let root = c.build(note: "").root

        let visible = TranscriptParser(referenceYear: 2026).parse(window: root) ?? []
        #expect(visible.map(\.body) == ["위쪽 메시지입니다", "가운데 메시지입니다", "보이는 마지막 메시지입니다"])
        #expect(visible.allSatisfy { $0.author == "합성B" && $0.timeRaw == "오후 4:05" && $0.date == "2026-10-10" })
        // Without the viewport filter the rows below the input are still context only, never emitted.
        let all = TranscriptParser(referenceYear: 2026, visibleOnly: false).parse(window: root) ?? []
        #expect(all == visible)
    }

    @Test("visible parse equals the matching run of the uncut parse", arguments: ["synthetic_200rows", "synthetic_nested_offscreen"])
    func visibleIsSliceOfUncut(name: String) throws {
        let visible = try Fixture.parse(name)
        let uncut = try Fixture.parse(name, visibleOnly: false)
        let start = try #require(uncut.firstIndex { $0.frame == visible.first?.frame && $0.body == visible.first?.body })
        #expect(visible.count < uncut.count)
        #expect(Array(uncut[start..<min(uncut.count, start + visible.count)]) == visible)
    }

    @Test("context is bounded to 20 rows on each side")
    func contextIsBounded() throws {
        var c = SyntheticChat(title: "합성 맥락방", options: .init(windowHeight: 400, spacerRow: false))
        c.divider("2026년 10월 9일 목요일")
        c.other("합성A", .text("첫 번째 메시지입니다"))
        // ~25 continuation rows end up above the viewport: the divider and group head are out of context range.
        for i in 1...30 { c.other(nil, .text("이어지는 메시지 \(i)번")) }
        let root = c.build(note: "").root
        let parser = TranscriptParser(referenceYear: 2026)
        let visible = parser.parse(window: root) ?? []
        #expect(!visible.isEmpty)
        #expect(visible.allSatisfy { $0.author == nil && $0.date == nil })
        let loc = try #require(TranscriptLocator.locate(inWindow: root))
        #expect(parser.collectRowCount(transcriptRoot: loc.transcriptRoot, inputFrame: loc.inputFrame)
                == visible.count + TranscriptParser.contextRows)
    }

    @Test("parsing is deterministic")
    func deterministic() throws {
        let a = try Fixture.parse("synthetic_attachments_links")
        let b = try Fixture.parse("synthetic_attachments_links")
        #expect(a == b)
    }
}
