// SPDX-License-Identifier: MIT
// Time and date label parsing (docs/architecture.md §4.5).

import Foundation

public enum TimeLabelParser {
    // "오후 3:12" / "下午 3:12" / "AM 9:30"
    private static let prefixedTime = CompiledRegex(#"(오전|오후|上午|下午|AM|PM|am|pm)\s*(\d{1,2}):(\d{2})(?!\d)"#)
    // "3:12 PM"
    private static let suffixedTime = CompiledRegex(#"(?<![\d:])(\d{1,2}):(\d{2})\s*(AM|PM|am|pm)\b"#)
    // "15:12"
    private static let bareTime = CompiledRegex(#"(?<![\d:])(\d{1,2}):(\d{2})(?![\d:])"#)

    // Year-month-day with numeric separators or 년/월/일, 年/月/日: "2026. 6. 2.", "2026-06-02", "2026년 6월 2일".
    private static let ymd = #"(\d{4})\s*(?:[.\-/]|년|年)\s*(\d{1,2})\s*(?:[.\-/]|월|月)\s*(\d{1,2})\s*(?:\.|일|日)?"#
    private static let ymdSearch = CompiledRegex(ymd)

    /// Optional weekday suffix on divider rows: "금요일", "(금)", "星期五", "周五", "Fri", "(Friday)".
    private static let weekday =
        #"(?:\s*,?\s*\(?\s*(?:[월화수목금토일](?:요일)?|星期[一二三四五六日天]|周[一二三四五六日天]|"#
        + #"(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*\.?)\s*\)?)?"#
    private static let leadingWeekday = #"(?:(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*\.?,?\s+)?"#

    private static let dividerYMD = CompiledRegex(#"^\s*"# + ymd + weekday + #"\s*$"#)
    private static let dividerMD = CompiledRegex(
        #"^\s*(\d{1,2})\s*[월月]\s*(\d{1,2})\s*[일日]"# + weekday + #"\s*$"#)
    // "October 10, 2026", "Friday, October 10, 2026", "Oct 3"
    private static let dividerEnglish = CompiledRegex(
        #"^\s*"# + leadingWeekday + #"([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\s*$"#)

    private static let monthNames: [String: Int] = {
        let names = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                     "october", "november", "december"]
        var map: [String: Int] = [:]
        for (i, n) in names.enumerated() {
            map[n] = i + 1
            map[String(n.prefix(3))] = i + 1
        }
        map["sept"] = 9
        return map
    }()

    /// Extracts a time token ("오후 3:12", "下午 3:12", "3:12 PM", "15:12") from a label, or nil.
    public static func extractTime(from label: String) -> String? {
        for r in [prefixedTime, suffixedTime, bareTime] {
            if let m = r.firstMatch(in: label) {
                return (label as NSString).substring(with: m.range)
            }
        }
        return nil
    }

    /// Minutes since midnight for a time token, or nil.
    public static func minuteOfDay(_ timeRaw: String) -> Int? {
        if let m = prefixedTime.firstMatch(in: timeRaw),
           let marker = m.group(1, in: timeRaw), let h = m.group(2, in: timeRaw).flatMap(Int.init),
           let min = m.group(3, in: timeRaw).flatMap(Int.init) {
            return twelveHour(h, min, pm: isPM(marker))
        }
        if let m = suffixedTime.firstMatch(in: timeRaw),
           let h = m.group(1, in: timeRaw).flatMap(Int.init), let min = m.group(2, in: timeRaw).flatMap(Int.init),
           let marker = m.group(3, in: timeRaw) {
            return twelveHour(h, min, pm: isPM(marker))
        }
        if let m = bareTime.firstMatch(in: timeRaw),
           let h = m.group(1, in: timeRaw).flatMap(Int.init), let min = m.group(2, in: timeRaw).flatMap(Int.init) {
            guard (0...23).contains(h), (0...59).contains(min) else { return nil }
            return h * 60 + min
        }
        return nil
    }

    /// AXHelp tooltip ("2026. 6. 2." or "2026-06-02") → "2026-06-02".
    public static func parseHelpDate(_ text: String) -> String? {
        if let iso = parseShortNumericDate(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return iso }
        guard let m = ymdSearch.firstMatch(in: text) else { return nil }
        return iso(m, text, yearGroup: 1, monthGroup: 2, dayGroup: 3, referenceYear: nil)
    }

    /// Date divider row text ("2026년 10월 10일 금요일", "10월 10일", "2026. 10. 10.", "2026-10-10") → "YYYY-MM-DD".
    /// `referenceYear` fills in a missing year. The whole row must be a date (plus an optional weekday), so
    /// ordinary messages that mention a date are rejected.
    public static func parseDividerDate(_ text: String, referenceYear: Int) -> String? {
        if let m = dividerYMD.firstMatch(in: text) {
            return iso(m, text, yearGroup: 1, monthGroup: 2, dayGroup: 3, referenceYear: nil)
        }
        if let m = dividerMD.firstMatch(in: text) {
            return iso(m, text, yearGroup: nil, monthGroup: 1, dayGroup: 2, referenceYear: referenceYear)
        }
        if let m = dividerEnglish.firstMatch(in: text),
           let name = m.group(1, in: text)?.lowercased(), let month = monthNames[name],
           let day = m.group(2, in: text).flatMap(Int.init) {
            let year = m.group(3, in: text).flatMap(Int.init) ?? referenceYear
            return TextScan.isoDate(year: year, month: month, day: day)
        }
        return nil
    }

    /// Whole-string US short date "M/D/YY" or "M/D/YYYY" (KakaoTalk's English UI AXHelp, e.g. "10/10/26")
    /// → "YYYY-MM-DD". Two-digit years are 20YY. When the first number cannot be a month but the second can,
    /// the string is read as D/M/Y instead.
    public static func parseShortNumericDate(_ text: String) -> String? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              parts[0].count <= 2, parts[1].count <= 2, parts[2].count == 2 || parts[2].count == 4,
              var month = Int(parts[0]), var day = Int(parts[1]), var year = Int(parts[2])
        else { return nil }
        if year < 100 { year += 2000 }
        if month > 12 && day <= 12 { swap(&month, &day) }
        return TextScan.isoDate(year: year, month: month, day: day)
    }

    // MARK: - Helpers

    private static func isPM(_ marker: String) -> Bool {
        marker == "오후" || marker == "下午" || marker.uppercased() == "PM"
    }

    /// 12-hour clock → minutes since midnight. Hour 0 is tolerated as 12 (e.g. "오전 0:05").
    private static func twelveHour(_ h: Int, _ min: Int, pm: Bool) -> Int? {
        guard (0...12).contains(h), (0...59).contains(min) else { return nil }
        let base = h % 12
        return (pm ? base + 12 : base) * 60 + min
    }

    private static func iso(_ m: NSTextCheckingResult, _ text: String, yearGroup: Int?, monthGroup: Int,
                            dayGroup: Int, referenceYear: Int?) -> String? {
        let year = yearGroup.flatMap { m.group($0, in: text) }.flatMap(Int.init) ?? referenceYear
        guard let year, let month = m.group(monthGroup, in: text).flatMap(Int.init),
              let day = m.group(dayGroup, in: text).flatMap(Int.init) else { return nil }
        return TextScan.isoDate(year: year, month: month, day: day)
    }
}
