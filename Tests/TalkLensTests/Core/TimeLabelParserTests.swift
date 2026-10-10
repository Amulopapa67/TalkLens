// SPDX-License-Identifier: MIT

import Testing
@testable import TalkLensCore

@Suite struct TimeLabelParserTests {
    @Test func extractTimeFindsSupportedFormats() {
        #expect(TimeLabelParser.extractTime(from: "오후 3:12") == "오후 3:12")
        #expect(TimeLabelParser.extractTime(from: "  오전 11:05 ") == "오전 11:05")
        #expect(TimeLabelParser.extractTime(from: "下午 3:12") == "下午 3:12")
        #expect(TimeLabelParser.extractTime(from: "3:12 PM") == "3:12 PM")
        #expect(TimeLabelParser.extractTime(from: "AM 9:30") == "AM 9:30")
        #expect(TimeLabelParser.extractTime(from: "15:12") == "15:12")
        #expect(TimeLabelParser.extractTime(from: "읽음 1 오후 3:12") == "오후 3:12")
    }

    @Test func extractTimeRejectsNonTimes() {
        #expect(TimeLabelParser.extractTime(from: "안녕하세요") == nil)
        #expect(TimeLabelParser.extractTime(from: "") == nil)
        #expect(TimeLabelParser.extractTime(from: "123:456") == nil)
    }

    @Test func minuteOfDayHandles12HourClock() {
        #expect(TimeLabelParser.minuteOfDay("오전 12:05") == 5)
        #expect(TimeLabelParser.minuteOfDay("오후 12:30") == 750)
        #expect(TimeLabelParser.minuteOfDay("오후 3:12") == 15 * 60 + 12)
        #expect(TimeLabelParser.minuteOfDay("오전 9:00") == 540)
        #expect(TimeLabelParser.minuteOfDay("下午 1:00") == 780)
        #expect(TimeLabelParser.minuteOfDay("上午 12:00") == 0)
        #expect(TimeLabelParser.minuteOfDay("11:59 PM") == 1439)
        #expect(TimeLabelParser.minuteOfDay("12:01 AM") == 1)
        #expect(TimeLabelParser.minuteOfDay("PM 12:00") == 720)
    }

    @Test func minuteOfDayHandles24HourClockAndInvalid() {
        #expect(TimeLabelParser.minuteOfDay("00:00") == 0)
        #expect(TimeLabelParser.minuteOfDay("23:59") == 1439)
        #expect(TimeLabelParser.minuteOfDay("24:00") == nil)
        #expect(TimeLabelParser.minuteOfDay("12:60") == nil)
        #expect(TimeLabelParser.minuteOfDay("오후 13:00") == nil)
        #expect(TimeLabelParser.minuteOfDay("hello") == nil)
    }

    @Test func parseHelpDateFormats() {
        #expect(TimeLabelParser.parseHelpDate("2026. 6. 2.") == "2026-06-02")
        #expect(TimeLabelParser.parseHelpDate("2026-06-02") == "2026-06-02")
        #expect(TimeLabelParser.parseHelpDate("2026.10.10") == "2026-10-10")
        #expect(TimeLabelParser.parseHelpDate("2026년 6월 2일 오후 3:12") == "2026-06-02")
        #expect(TimeLabelParser.parseHelpDate("2026. 13. 2.") == nil)
        #expect(TimeLabelParser.parseHelpDate("2026-02-30") == nil)
        #expect(TimeLabelParser.parseHelpDate("오후 3:12") == nil)
    }

    @Test func parseDividerDateKoreanAndNumeric() {
        #expect(TimeLabelParser.parseDividerDate("2026년 10월 10일 금요일", referenceYear: 2000) == "2026-10-10")
        #expect(TimeLabelParser.parseDividerDate("10월 10일 (금)", referenceYear: 2026) == "2026-10-10")
        #expect(TimeLabelParser.parseDividerDate("1월 3일", referenceYear: 2027) == "2027-01-03")
        #expect(TimeLabelParser.parseDividerDate("2026. 10. 10.", referenceYear: 2000) == "2026-10-10")
        #expect(TimeLabelParser.parseDividerDate("2026-10-10", referenceYear: 2000) == "2026-10-10")
        #expect(TimeLabelParser.parseDividerDate("2026年10月10日 星期五", referenceYear: 2000) == "2026-10-10")
    }

    @Test func parseDividerDateEnglish() {
        #expect(TimeLabelParser.parseDividerDate("Friday, October 10, 2026", referenceYear: 2000) == "2026-10-10")
        #expect(TimeLabelParser.parseDividerDate("Oct 3", referenceYear: 2026) == "2026-10-03")
    }

    @Test func parseDividerDateRejectsMessagesMentioningDates() {
        #expect(TimeLabelParser.parseDividerDate("과제 마감이 10월 20일 23:59까지로 연장되었습니다.",
                                                 referenceYear: 2026) == nil)
        #expect(TimeLabelParser.parseDividerDate("hello", referenceYear: 2026) == nil)
        #expect(TimeLabelParser.parseDividerDate("2월 30일", referenceYear: 2026) == nil)
    }
}
