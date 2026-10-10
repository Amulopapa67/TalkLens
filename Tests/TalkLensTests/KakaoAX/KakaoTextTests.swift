// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import KakaoAX

@Suite("KakaoTextTests")
struct KakaoTextTests {
    @Test("time tokens", arguments: [
        ("오후 3:12", "오후 3:12"), ("오전 10:05", "오전 10:05"), ("下午 3:12", "下午 3:12"),
        ("3:12 PM", "3:12 PM"), ("15:12", "15:12"), ("(23:59)", "23:59"),
    ])
    func timeTokens(input: String, expected: String) {
        #expect(KakaoText.extractTimeToken(from: input) == expected)
    }

    @Test("non-time tokens")
    func nonTimeTokens() {
        for s in ["김민준", "12345", "2026. 10. 10.", "25:61", "오후"] {
            #expect(KakaoText.extractTimeToken(from: s) == nil)
        }
    }

    @Test("minute of day")
    func minutes() {
        #expect(KakaoText.minuteOfDay("오전 12:05") == 5)
        #expect(KakaoText.minuteOfDay("오후 12:05") == 12 * 60 + 5)
        #expect(KakaoText.minuteOfDay("오후 3:12") == 15 * 60 + 12)
        #expect(KakaoText.minuteOfDay("3:12 PM") == 15 * 60 + 12)
        #expect(KakaoText.minuteOfDay("07:30") == 450)
        #expect(KakaoText.minuteOfDay(nil) == nil)
    }

    @Test("AXHelp dates")
    func helpDates() {
        #expect(KakaoText.parseHelpDate("2026. 6. 2.") == "2026-06-02")
        #expect(KakaoText.parseHelpDate("2026-10-10") == "2026-10-10")
        #expect(KakaoText.parseHelpDate("2026년 10월 9일 목요일") == "2026-10-09")
        #expect(KakaoText.parseHelpDate("2026. 13. 2.") == nil)
        #expect(KakaoText.parseHelpDate("오후 3:12") == nil)
        // Year-less forms need a reference year.
        #expect(KakaoText.parseHelpDate("10월 10일") == nil)
        #expect(KakaoText.parseHelpDate("10월 10일", referenceYear: 2026) == "2026-10-10")
        #expect(KakaoText.parseHelpDate("10. 9.", referenceYear: 2026) == "2026-10-09")
        #expect(KakaoText.parseHelpDate("10/09", referenceYear: 2026) == "2026-10-09")
        #expect(KakaoText.parseHelpDate("2026/10/09", referenceYear: 1999) == "2026-10-09")
    }

    @Test("divider dates")
    func dividers() {
        #expect(KakaoText.parseDividerDate("2026년 10월 10일 금요일", referenceYear: 2000) == "2026-10-10")
        #expect(KakaoText.parseDividerDate("10월 11일 토요일", referenceYear: 2026) == "2026-10-11")
        #expect(KakaoText.parseDividerDate("2026. 10. 10.", referenceYear: 2000) == "2026-10-10")
        #expect(KakaoText.parseDividerDate("2026-10-10", referenceYear: 2000) == "2026-10-10")
        #expect(KakaoText.parseDividerDate("10/15 (수) 연구실 대청소 있습니다", referenceYear: 2026) == nil)
        #expect(KakaoText.parseDividerDate("과제 2 마감이 10월 20일 23:59까지로", referenceYear: 2026) == nil)
        #expect(KakaoText.parseDividerDate("박서연님이 들어왔습니다.", referenceYear: 2026) == nil)
    }

    @Test("attachment and count tokens")
    func tokens() {
        #expect(KakaoText.isCountToken("1"))
        #expect(!KakaoText.isCountToken("1a"))
        #expect(KakaoText.isFileNameToken("과제2_보고서.pdf"))
        #expect(KakaoText.isAttachmentMetadataToken("유효기간 ~ 2026. 10. 24. · 용량 1.2MB"))
        #expect(!KakaoText.isAttachmentMetadataToken("김민준"))
        #expect(KakaoText.isAttachmentButtonTitle("저장"))
        #expect(KakaoText.isSystemMetadataToken("2026-10-10"))
        #expect(KakaoText.countURLTokens(in: "a https://x.y/1 b http://z.w") == 2)
    }

    @Test("body normalization keeps line breaks")
    func normalize() {
        #expect(KakaoText.normalizeBodyText("  a  \r\n b \r c  ") == "a\nb\nc")
        #expect(KakaoText.normalizeBodyText(nil) == "")
    }

    @Test("truncated link promotion")
    func promote() {
        let p = TranscriptParser(referenceYear: 2026)
        #expect(p.promoteLink("https://a.b/c...", fullLink: "https://a.b/c/d") == "https://a.b/c/d")
        #expect(p.promoteLink("보세요 https://a.b/c...", fullLink: "https://a.b/c/d") == "보세요 https://a.b/c/d")
        #expect(p.promoteLink("보세요 https://q.r/...", fullLink: "https://a.b/c/d") == "보세요 https://q.r/...\nhttps://a.b/c/d")
    }
}
