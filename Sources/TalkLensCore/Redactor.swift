// SPDX-License-Identifier: MIT
// Redaction for every log line and default CLI output: message text and chat titles become
// "<text len=N ko>" / "<title len=N ko>" placeholders. Short strings that are *entirely* a time or date
// label (e.g. "오후 3:12", "2026. 6. 2.") stay verbatim so timing structure remains debuggable.

import Foundation

public enum Redactor {
    /// Labels longer than this are always redacted, even when they look like times/dates.
    static let maxVerbatimLabelLength = 24

    /// Whole-string time/date label: one or more time/date/weekday tokens separated by spaces,
    /// commas or parentheses. Anchored on both ends so messages that merely *contain* a time are redacted.
    private static let labelRegex: CompiledRegex = {
        let token = [
            #"(?:오전|오후|上午|下午|AM|PM|am|pm)\s*\d{1,2}:\d{2}"#,
            #"\d{1,2}:\d{2}(?:\s*(?:AM|PM|am|pm))?"#,
            #"\d{4}\s*[.\-/]\s*\d{1,2}\s*[.\-/]\s*\d{1,2}\.?"#,
            #"(?:\d{4}\s*[년年]\s*)?\d{1,2}\s*[월月]\s*\d{1,2}\s*[일日]"#,
            #"[월화수목금토일]요일"#,
            #"\([월화수목금토일]\)"#,
            #"星期[一二三四五六日天]"#,
        ].joined(separator: "|")
        return CompiledRegex(#"^\s*(?:"# + token + #")(?:[\s,]*(?:"# + token + #"))*\s*$"#)
    }()

    /// True for short strings that consist only of time/date tokens.
    public static func isTimeOrDateLabel(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= maxVerbatimLabelLength else { return false }
        return labelRegex.matchesWhole(text)
    }

    /// "<text len=N [ko] [zh] [url]>"; short pure time/date labels are returned verbatim.
    public static func redact(_ text: String) -> String {
        if isTimeOrDateLabel(text) { return text }
        var hasHangul = false
        var hasCJK = false
        for s in text.unicodeScalars {
            if TextScan.isHangulSyllable(s) || TextScan.isCompatibilityJamo(s) { hasHangul = true }
            if TextScan.isCJKIdeograph(s) { hasCJK = true }
            if hasHangul && hasCJK { break }
        }
        var tags = ["len=\(text.count)"]
        if hasHangul { tags.append("ko") }
        if hasCJK { tags.append("zh") }
        if text.contains("http") { tags.append("url") }
        return "<text \(tags.joined(separator: " "))>"
    }

    /// Redacts a chat window title. KakaoTalk's own main-window titles ("KakaoTalk", "카카오톡") stay verbatim.
    public static func redactTitle(_ title: String) -> String {
        if title == "KakaoTalk" || title == "카카오톡" { return title }
        let hasHangul = TextScan.containsHangulSyllable(title)
        return "<title len=\(title.count)\(hasHangul ? " ko" : "")>"
    }

    /// First 6 hex chars of a SHA-256, for log correlation without content.
    public static func shortHash(_ text: String) -> String {
        String(MessageIdentity.sha256Hex(text).prefix(6))
    }
}
