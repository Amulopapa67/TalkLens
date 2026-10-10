import Testing
@testable import TalkLensCore
@testable import KakaoAX

// Real KakaoTalk 26.8.0 (English UI) time-label AXHelp is "10/10/26"; time value is "6:01\u{202F}PM".
@Suite("Short numeric dates (KakaoTalk English UI)")
struct ShortNumericDateTests {
    @Test func usShortDateTwoDigitYear() {
        #expect(TimeLabelParser.parseShortNumericDate("10/10/26") == "2026-10-10")
        #expect(TimeLabelParser.parseHelpDate("10/10/26") == "2026-10-10")
    }

    @Test func usShortDateFourDigitYearAndPadding() {
        #expect(TimeLabelParser.parseShortNumericDate("6/2/2026") == "2026-06-02")
    }

    @Test func dayFirstWhenMonthImpossible() {
        #expect(TimeLabelParser.parseShortNumericDate("25/12/26") == "2026-12-25")
    }

    @Test func rejectsNonDates() {
        #expect(TimeLabelParser.parseShortNumericDate("10/15") == nil)
        #expect(TimeLabelParser.parseShortNumericDate("13/13/26") == nil)
        #expect(TimeLabelParser.parseShortNumericDate("a/b/c") == nil)
    }

    @Test func kakaoTextHelpDateAcceptsUSFormat() {
        #expect(KakaoText.parseHelpDate("10/10/26", referenceYear: 2026) == "2026-10-10")
    }

    @Test func narrowNoBreakSpaceTimeLabel() {
        #expect(TimeLabelParser.extractTime(from: "6:01\u{202F}PM") != nil)
        #expect(TimeLabelParser.minuteOfDay("6:01\u{202F}PM") == 18 * 60 + 1)
    }
}
