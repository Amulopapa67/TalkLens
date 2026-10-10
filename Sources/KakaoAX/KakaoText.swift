// Derived from kmsg (https://github.com/channprj/kmsg) @54cbff7 — MIT License, Copyright (c) 2026 Park Hee Chan. Modifications: pure text heuristics of TranscriptReader.swift (extractTimeToken, minuteOfDay, parseHelpDate, parseSystemDate, count/system/attachment tokens, URL counting, normalizeBodyText, scoreBodyCandidate) extracted into a Sendable namespace with precompiled regexes; dates returned as "YYYY-MM-DD" strings with an explicit reference year; added "YYYY년 M월 D일 요일" dividers and 上午/下午 / AM-PM time tokens.
// SPDX-License-Identifier: MIT
//
// KakaoAX keeps its own copies of these heuristics so the parser does not depend on TalkLensCore's
// TimeLabelParser (the two may diverge; KakaoAX only needs what KakaoTalk's AX tree actually shows).

import Foundation

public enum KakaoText {
    private static func re(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure is a programming error.
        try! NSRegularExpression(pattern: pattern)
    }

    private static let meridiemKo = re(#"(오전|오후)\s*([1-9]|1[0-2]):([0-5][0-9])"#)
    private static let meridiemZh = re(#"(上午|下午)\s*([1-9]|1[0-2]):([0-5][0-9])"#)
    private static let meridiemEn = re(#"\b([1-9]|1[0-2]):([0-5][0-9])\s?([AaPp][Mm])\b"#)
    private static let clock24Whole = re(#"^([01]?[0-9]|2[0-3]):([0-5][0-9])$"#)
    private static let clock24Any = re(#"([01]?[0-9]|2[0-3]):([0-5][0-9])"#)

    private static let helpDotted = re(#"(\d{4})\.\s*(\d{1,2})\.\s*(\d{1,2})\.?"#)
    private static let helpDashed = re(#"(\d{4})-(\d{1,2})-(\d{1,2})"#)
    private static let helpKorean = re(#"(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일"#)
    private static let helpSlashed = re(#"(\d{4})/(\d{1,2})/(\d{1,2})"#)
    private static let helpKoreanNoYear = re(#"^(\d{1,2})월\s*(\d{1,2})일"#)
    private static let helpDottedNoYear = re(#"^(\d{1,2})\.\s*(\d{1,2})\.?(?:\s|$)"#)
    private static let helpSlashedNoYear = re(#"^(\d{1,2})/(\d{1,2})(?:\s|$)"#)

    private static let dividerKoreanFull = re(#"^(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일(?:\s*\S+)?$"#)
    private static let dividerKoreanShort = re(#"^(\d{1,2})월\s*(\d{1,2})일(?:\s*\S+)?$"#)
    private static let dividerNumeric = re(#"^(\d{4})\s*[./-]\s*(\d{1,2})\s*[./-]\s*(\d{1,2})\.?(?:\s*\S+)?$"#)

    private static let systemTokenISO = re(#"^\d{4}-\d{2}-\d{2}"#)
    private static let systemTokenNumeric = re(#"^\d{4}[./-]\s*\d{1,2}[./-]\s*\d{1,2}"#)
    private static let systemTokenKorean = re(#"^\d{1,2}월\s*\d{1,2}일"#)
    private static let systemTokenKoreanYear = re(#"^\d{4}년\s*\d{1,2}월\s*\d{1,2}일"#)

    private static let attachmentExtension = re(#"\.(pdf|png|jpe?g|gif|webp|heic|zip|hwp|hwpx|docx?|pptx?|xlsx?|txt|csv|mp4|mov)$"#)
    private static let urlToken = re(#"https?://\S+"#)

    // MARK: - Helpers

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, in text: String) -> String? {
        guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: text) else { return nil }
        return String(text[r])
    }

    private static func matchedString(_ m: NSTextCheckingResult, in text: String) -> String? {
        Range(m.range, in: text).map { String(text[$0]) }
    }

    private static func ymd(_ y: Int, _ m: Int, _ d: Int) -> String? {
        guard (1900...2999).contains(y), (1...12).contains(m), (1...31).contains(d) else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    // MARK: - Time

    /// Time token in a label ("오후 3:12", "下午 3:12", "3:12 PM", "15:12"), or nil.
    public static func extractTimeToken(from token: String) -> String? {
        guard token.contains(":") else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for regex in [meridiemKo, meridiemZh, meridiemEn] {
            if let m = firstMatch(regex, in: trimmed) { return matchedString(m, in: trimmed) }
        }
        for part in trimmed.split(whereSeparator: \.isWhitespace) {
            let normalized = String(part).trimmingCharacters(in: .punctuationCharacters)
            if firstMatch(clock24Whole, in: normalized) != nil { return normalized }
        }
        return nil
    }

    /// Minutes since midnight of a time token, or nil.
    public static func minuteOfDay(_ timeRaw: String?) -> Int? {
        guard let timeRaw, timeRaw.contains(":") else { return nil }
        let text = timeRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = firstMatch(meridiemKo, in: text) ?? firstMatch(meridiemZh, in: text),
           let marker = group(m, 1, in: text), let h = group(m, 2, in: text).flatMap(Int.init),
           let mm = group(m, 3, in: text).flatMap(Int.init) {
            let pm = marker == "오후" || marker == "下午"
            return (h % 12 + (pm ? 12 : 0)) * 60 + mm
        }
        if let m = firstMatch(meridiemEn, in: text), let h = group(m, 1, in: text).flatMap(Int.init),
           let mm = group(m, 2, in: text).flatMap(Int.init), let marker = group(m, 3, in: text) {
            let pm = marker.lowercased() == "pm"
            return (h % 12 + (pm ? 12 : 0)) * 60 + mm
        }
        if let m = firstMatch(clock24Any, in: text), let h = group(m, 1, in: text).flatMap(Int.init),
           let mm = group(m, 2, in: text).flatMap(Int.init) {
            return h * 60 + mm
        }
        return nil
    }

    // MARK: - Dates

    /// AXHelp tooltip of a time label ("2026. 6. 2.", "2026-06-02", "2026년 6월 2일", "2026/6/2") → "2026-06-02".
    /// With `referenceYear`, year-less forms ("6월 2일", "6. 2.", "06/02") are accepted too.
    /// (KakaoTalk 26.8.0 shows an 8-character tooltip whose exact format is not verified yet.)
    public static func parseHelpDate(_ text: String, referenceYear: Int? = nil) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed.first?.isNumber == true else { return nil }
        if let referenceYear, trimmed.count < 8 || !trimmed.prefix(4).allSatisfy(\.isNumber) {
            for regex in [helpKoreanNoYear, helpDottedNoYear, helpSlashedNoYear] {
                if let m = firstMatch(regex, in: trimmed),
                   let mo = group(m, 1, in: trimmed).flatMap(Int.init),
                   let d = group(m, 2, in: trimmed).flatMap(Int.init) {
                    return ymd(referenceYear, mo, d)
                }
            }
        }
        for regex in [helpDotted, helpDashed, helpKorean, helpSlashed] {
            if let m = firstMatch(regex, in: trimmed),
               let y = group(m, 1, in: trimmed).flatMap(Int.init),
               let mo = group(m, 2, in: trimmed).flatMap(Int.init),
               let d = group(m, 3, in: trimmed).flatMap(Int.init) {
                return ymd(y, mo, d)
            }
        }
        return nil
    }

    /// Date divider text ("2026년 10월 10일 금요일", "10월 10일 금요일", "2026. 10. 10.", "2026-10-10") → "YYYY-MM-DD".
    /// The whole text must be a date (optionally followed by one weekday word). `referenceYear` fills a missing year.
    public static func parseDividerDate(_ text: String, referenceYear: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40, trimmed.first?.isNumber == true else { return nil }
        if let m = firstMatch(dividerKoreanFull, in: trimmed) ?? firstMatch(dividerNumeric, in: trimmed),
           let y = group(m, 1, in: trimmed).flatMap(Int.init),
           let mo = group(m, 2, in: trimmed).flatMap(Int.init),
           let d = group(m, 3, in: trimmed).flatMap(Int.init) {
            return ymd(y, mo, d)
        }
        if let m = firstMatch(dividerKoreanShort, in: trimmed),
           let mo = group(m, 1, in: trimmed).flatMap(Int.init),
           let d = group(m, 2, in: trimmed).flatMap(Int.init) {
            return ymd(referenceYear, mo, d)
        }
        return nil
    }

    // MARK: - Token classes

    /// Purely numeric token (unread counters such as "1").
    public static func isCountToken(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return t.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    /// Date-like metadata token ("2026-10-10…", "2026. 10. 10.", "10월 10일…").
    public static func isSystemMetadataToken(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first, first.isNumber else { return false }
        return [systemTokenISO, systemTokenNumeric, systemTokenKorean, systemTokenKoreanYear]
            .contains { firstMatch($0, in: t) != nil }
    }

    /// File-attachment metadata ("expiry…", "size:…", "만료", "용량", "·", "name.pdf").
    public static func isAttachmentMetadataToken(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let lowered = t.lowercased()
        if lowered.hasPrefix("expiry") || lowered.hasPrefix("size:") { return true }
        if lowered.contains("만료") || lowered.contains("용량") || lowered.contains("유효기간") { return true }
        if t == "·" { return true }
        return isFileNameToken(t)
    }

    /// "report.pdf"-like token.
    public static func isFileNameToken(_ token: String) -> Bool {
        let lowered = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lowered.contains(".") else { return false }
        return firstMatch(attachmentExtension, in: lowered) != nil
    }

    /// "Save" / "저장" buttons shown on file bubbles.
    public static func isAttachmentButtonTitle(_ title: String) -> Bool {
        let lowered = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["save", "save as", "저장", "다른 이름으로 저장"].contains(lowered)
    }

    // MARK: - Text

    public static func countURLTokens(in text: String) -> Int {
        guard text.contains("://") else { return 0 }
        return urlToken.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    public static func urlTokens(in text: String) -> [String] {
        guard text.contains("://") else { return [] }
        return urlToken.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    public static func isURLOnlyText(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        return !t.contains(where: \.isWhitespace)
    }

    /// Text that shows a truncated URL ("https://…...") whose full form may be in an AXLink title.
    public static func shouldPromoteLinkTitle(for text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.contains("http://") || lower.contains("https://") else { return false }
        return text.contains("...") || text.contains("…")
    }

    /// CRLF → LF, each line trimmed of spaces, whole text trimmed; inner line breaks kept.
    public static func normalizeBodyText(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        let canonical = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return canonical
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Non-empty trimmed lines of a static text.
    public static func metadataTokens(from text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Body candidate score: longer, multi-line, spaced and URL-bearing text wins.
    public static func scoreBodyCandidate(_ text: String) -> Int {
        var score = min(text.count * 10, 500)
        if text.contains("\n") { score += 60 }
        if text.contains(" ") { score += 40 }
        let lower = text.lowercased()
        if lower.contains("http://") || lower.contains("https://") { score += 180 }
        return score
    }
}
