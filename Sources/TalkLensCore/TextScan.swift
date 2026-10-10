// SPDX-License-Identifier: MIT
// Small text helpers shared by Redactor, Glossary, ChatPreprocessor and TimeLabelParser.

import Foundation

/// A precompiled NSRegularExpression that can be shared across concurrency domains.
/// NSRegularExpression is immutable and documented as thread-safe once created.
final class CompiledRegex: @unchecked Sendable {
    let regex: NSRegularExpression

    init(regex: NSRegularExpression) {
        self.regex = regex
    }

    /// Compiles `pattern`; crashes on an invalid pattern (only for literals written in this module).
    convenience init(_ pattern: String, options: NSRegularExpression.Options = []) {
        do {
            self.init(regex: try NSRegularExpression(pattern: pattern, options: options))
        } catch {
            preconditionFailure("invalid built-in regex: \(pattern)")
        }
    }

    /// Returns nil instead of crashing (for user-provided patterns).
    static func compile(_ pattern: String, options: NSRegularExpression.Options = []) -> CompiledRegex? {
        guard let r = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        return CompiledRegex(regex: r)
    }

    func firstMatch(in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    func matches(in text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    /// True when the regex matches the whole string.
    func matchesWhole(_ text: String) -> Bool {
        let len = (text as NSString).length
        guard let m = regex.firstMatch(in: text, options: [.anchored], range: NSRange(location: 0, length: len)) else {
            return false
        }
        return m.range.location == 0 && m.range.length == len
    }
}

extension NSTextCheckingResult {
    /// Substring of capture group `i`, or nil when the group did not participate.
    func group(_ i: Int, in text: String) -> String? {
        guard i < numberOfRanges else { return nil }
        let r = range(at: i)
        guard r.location != NSNotFound else { return nil }
        return (text as NSString).substring(with: r)
    }
}

enum TextScan {
    /// Precomposed Hangul syllables (가–힣).
    @inline(__always) static func isHangulSyllable(_ s: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7A3).contains(s.value)
    }

    /// Hangul compatibility jamo (ㄱ–ㅎ, ㅏ–ㅣ and archaic forms).
    @inline(__always) static func isCompatibilityJamo(_ s: Unicode.Scalar) -> Bool {
        (0x3131...0x318E).contains(s.value)
    }

    /// CJK unified ideographs (incl. extension A).
    @inline(__always) static func isCJKIdeograph(_ s: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value)
    }

    static func containsHangulSyllable(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isHangulSyllable)
    }

    static func daysInMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        default: return 0
        }
    }

    /// "YYYY-MM-DD" when the date is valid.
    static func isoDate(year: Int, month: Int, day: Int) -> String? {
        guard (1...9999).contains(year), (1...12).contains(month),
              day >= 1, day <= daysInMonth(month, year: year) else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
