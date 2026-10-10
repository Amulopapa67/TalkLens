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
        #expect(m.map(\.author) == ["김민준", "김민준", nil, "박서연", "이도윤", "이도윤", nil])
        #expect(m.map(\.isMine) == [false, false, true, false, false, false, true])
        // The first 김민준 row has no time label; it takes the label of the next row in its group.
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
        #expect(m.filter { !$0.isMine }.allSatisfy { $0.author == "박서연" })
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
        #expect(system.map(\.body) == ["2026년 10월 9일 목요일", "박서연님이 들어왔습니다.", "2026년 10월 10일 금요일",
                                       "이도윤님이 나갔습니다.", "10월 11일 토요일"])
        #expect(system.allSatisfy { $0.author == nil && !$0.isMine })
        let m = Fixture.nonSystem(all)
        // No AXHelp on these rows: the date comes from the preceding divider.
        #expect(m[0].author == "김민준" && m[0].date == "2026-10-09")
        #expect(m[1].author == "박서연" && m[1].date == "2026-10-09")
        #expect(m[2].date == "2026-10-10")
        #expect(m[3].isMine && m[3].body == "10/15 (수) 연구실 대청소 있습니다")
        // Year-less divider uses the reference year.
        #expect(m[4].date == "2026-10-11" && m[4].author == "김민준")
        // A notice breaks author chaining: 박서연's row has its own explicit name.
        #expect(all[3].author == "박서연")
        // Year-less AXHelp ("10월 10일") uses the reference year.
        #expect(m[2].author == "이도윤" && m[2].date == "2026-10-10")
    }

    @Test("images, stickers, files and links are counted; truncated URLs are promoted")
    func attachmentsLinks() throws {
        let m = try Fixture.parse("synthetic_attachments_links")
        #expect(m.count == 8)
        #expect(m[0].author == "김민준" && m[0].body.isEmpty && m[0].attachments == AttachmentSummary(images: 1))
        #expect(m[0].timeRaw == "오후 2:01")
        // Link preview texts below the body are not taken as the author.
        #expect(m[1].author == "김민준" && m[1].body == "https://example.com/notice/123" && m[1].attachments.links == 1)
        #expect(m[3].isMine && m[3].attachments.images == 1 && m[3].body.isEmpty)
        #expect(m[4].author == "박서연" && m[4].attachments == AttachmentSummary(files: 1) && m[4].body.isEmpty)
        #expect(m[5].body == "자료는 여기 있어요 https://example.com/files/share/2026/fall/lab-seminar-schedule")
        #expect(m[5].author == "박서연" && m[5].attachments.links == 1)
        #expect(m[6].author == "이도윤" && m[6].attachments.images == 1)
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
        #expect(m[4].author == "이도윤" && m[5].author == "이도윤")
    }

    @Test("nested scroll-area bodies, button avatars and off-screen rows")
    func nestedOffscreen() throws {
        let visible = try Fixture.parse("synthetic_nested_offscreen")
        // Rows fully above or below the visible transcript are dropped; a partly visible row is kept.
        #expect(visible.count == 9)
        #expect(visible[0].author == "박서연" && visible[0].date == "2026-10-08")
        #expect(visible[2].isSystem && visible[2].date == "2026-10-09")
        #expect(!visible.contains { $0.body == "오늘 점심 학식 vs 배달?" })
        let m = Fixture.nonSystem(visible)
        #expect(m.map(\.author) == ["박서연", nil, "이도윤", "이도윤", nil, "김민준", "박서연", "박서연"])
        #expect(m[2].body == "오늘 3교시 휴강입니다. 보강 일정은 추후 공지하겠습니다.")

        let all = try Fixture.parse("synthetic_nested_offscreen", visibleOnly: false)
        // Everything above the input is analysed; rows below the input box are still excluded.
        #expect(all.count == 11)
        #expect(all.first?.author == "김민준" && all.first?.date == "2026-10-08")
    }

    @Test("left continuation with an earlier time does not inherit the author")
    func timeGuard() {
        var c = SyntheticChat(title: "t")
        c.other("김민준", .text("첫 번째"), time: "오후 3:20")
        c.other(nil, .text("두 번째"), time: "오후 3:10")
        let m = TranscriptParser(referenceYear: 2026).parse(window: c.build(note: "").root) ?? []
        #expect(m.count == 2)
        #expect(m[0].author == "김민준")
        #expect(m[1].author == nil)
    }

    @Test("my message between two of theirs breaks the chain; side falls back to time carry-over")
    func chainBreak() {
        var c = SyntheticChat(title: "t")
        c.other("김민준", .text("하나"), time: "오전 9:00", help: "2026. 3. 2.")
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

    @Test("parsing is deterministic")
    func deterministic() throws {
        let a = try Fixture.parse("synthetic_attachments_links")
        let b = try Fixture.parse("synthetic_attachments_links")
        #expect(a == b)
    }
}
