// SPDX-License-Identifier: MIT

import Testing
@testable import TalkLensCore

@Suite struct RedactorTests {
    @Test func redactTagsHangulCJKAndURL() {
        #expect(Redactor.redact("안녕하세요") == "<text len=5 ko>")
        #expect(Redactor.redact("好的") == "<text len=2 zh>")
        #expect(Redactor.redact("hello") == "<text len=5>")
        #expect(Redactor.redact("확인 https://example.com 好") == "<text len=24 ko zh url>")
        #expect(Redactor.redact("ㅋㅋㅋ") == "<text len=3 ko>")
        #expect(Redactor.redact("") == "<text len=0>")
    }

    @Test func redactNeverLeaksContent() {
        let secret = "교수님 내일 랩미팅 취소"
        let out = Redactor.redact(secret)
        #expect(!out.contains("교수님"))
        #expect(!out.contains("랩미팅"))
        #expect(out.hasPrefix("<text len="))
    }

    @Test func shortTimeAndDateLabelsStayVerbatim() {
        for label in ["오후 3:12", "오전 11:05", "下午 3:12", "3:12 PM", "AM 9:30", "15:12",
                      "2026. 6. 2.", "2026-06-02", "10월 10일", "2026년 10월 10일 금요일"] {
            #expect(Redactor.redact(label) == label, "label should stay verbatim: \(label)")
        }
    }

    @Test func messagesContainingATimeAreStillRedacted() {
        // Unlike the probe's unanchored check, the whole string must be a time/date label.
        #expect(Redactor.redact("오후 3:12에 만나요") == "<text len=12 ko>")
        #expect(Redactor.redact("10월 20일 23:59까지") != "10월 20일 23:59까지")
        #expect(Redactor.redact("meet 15:00") == "<text len=10>")
    }

    @Test func longTimeLikeStringsAreRedacted() {
        let long = "2026. 6. 2. 2026. 6. 3. 2026. 6. 4."
        #expect(long.count > 24)
        #expect(Redactor.redact(long).hasPrefix("<text len="))
    }

    @Test func redactTitleKeepsKakaoTalkMainWindow() {
        #expect(Redactor.redactTitle("KakaoTalk") == "KakaoTalk")
        #expect(Redactor.redactTitle("카카오톡") == "카카오톡")
        #expect(Redactor.redactTitle("김철수") == "<title len=3 ko>")
        #expect(Redactor.redactTitle("Lab Group") == "<title len=9>")
    }

    @Test func shortHashIsSixHexChars() {
        let h = Redactor.shortHash("abc")
        #expect(h.count == 6)
        #expect(h == "ba7816")
    }
}
