// SPDX-License-Identifier: MIT
// Pure helpers behind `tlctl selftest` (argument parsing, input file parsing, status → SKIP messages).
// Kept in this module so they can be unit-tested (the test target cannot import the tlctl executable).

import Foundation

public struct SelftestOptions: Sendable, Equatable {
    public var engine: String = "apple"
    public var source: String = "ko"
    public var target: String = "zh-Hans"
    public var input: String = "fixtures/test_messages_ko.txt"
    /// Only run the batched pass (skip per-line timing).
    public var batchOnly: Bool = false
    /// Overall timeout; must stay well below verify.sh's 240 s.
    public var timeoutSeconds: Double = 180

    public init() {}

    public static let usage =
        "usage: tlctl selftest --engine apple|mock --source ko --target zh-Hans --input FILE [--batch] [--timeout SECONDS]"

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingValue(String)
        case unknownArgument(String)
        case invalidValue(String, String)

        public var description: String {
            switch self {
            case .missingValue(let flag): return "missing value for \(flag)"
            case .unknownArgument(let a): return "unknown argument \(a)"
            case .invalidValue(let flag, let v): return "invalid value \(v) for \(flag)"
            }
        }
    }

    public static func parse(_ arguments: [String]) throws -> SelftestOptions {
        var o = SelftestOptions()
        var i = 0
        func value(_ flag: String) throws -> String {
            guard i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") else { throw ParseError.missingValue(flag) }
            i += 1
            return arguments[i]
        }
        while i < arguments.count {
            let a = arguments[i]
            switch a {
            case "--engine":
                let v = try value(a)
                guard v == "apple" || v == "mock" else { throw ParseError.invalidValue(a, v) }
                o.engine = v
            case "--source": o.source = try value(a)
            case "--target": o.target = try value(a)
            case "--input": o.input = try value(a)
            case "--batch": o.batchOnly = true
            case "--timeout":
                let v = try value(a)
                guard let s = Double(v), s > 0 else { throw ParseError.invalidValue(a, v) }
                o.timeoutSeconds = s
            default: throw ParseError.unknownArgument(a)
            }
            i += 1
        }
        return o
    }
}

public enum SelftestSupport {
    /// Parses the selftest input: skips blank lines and lines starting with `#`; a literal `\n` becomes a newline.
    public static func parseInput(_ contents: String) -> [String] {
        contents
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.replacingOccurrences(of: "\\n", with: "\n") }
    }

    /// Single-line rendering for console output (newlines shown as `\n`).
    public static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\\n").replacingOccurrences(of: "\n", with: "\\n")
    }

    /// English display name of a language for user-facing hints.
    public static func displayName(_ identifier: String) -> String {
        let language = Locale.Language(identifier: identifier)
        let max = language.maximalIdentifier
        if max.hasPrefix("zh-Hans") { return "Chinese (Simplified)" }
        if max.hasPrefix("zh-Hant") { return "Chinese (Traditional)" }
        let code = language.languageCode?.identifier ?? identifier
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? identifier
    }

    /// The fix for missing languages, shown after the SKIP reason.
    public static func downloadFix(source: String, target: String) -> String {
        "System Settings → General → Language & Region → Translation Languages: download "
            + "\(displayName(source)) and \(displayName(target))"
    }

    /// Last line for a SKIP (exit 3), or nil when the engine is ready.
    public static func skipLine(for status: EngineStatus, source: String, target: String) -> String? {
        switch status {
        case .ready:
            return nil
        case .needsDownload:
            return "selftest: SKIP: \(displayName(source)) → \(displayName(target)) translation languages are not installed"
                + " — \(downloadFix(source: source, target: target))"
        case .unsupported(let reason):
            let fix: String
            if reason == AppleTranslationEngine.hostRequiredReason {
                fix = "upgrade to macOS 26 or later for UI-less translation, or test inside TalkLens.app"
            } else {
                fix = "choose a language pair supported by Apple Translation"
            }
            return "selftest: SKIP: \(reason) — \(fix)"
        }
    }

    /// Final OK line.
    public static func okLine(translated: Int, total: Int, p50: Double, p95: Double, batchMilliseconds: Double?,
                              engine: String, source: String, target: String) -> String {
        var s = String(format: "selftest: OK: %d/%d translated, p50=%.1f ms, p95=%.1f ms", translated, total,
                       p50, p95)
        if let b = batchMilliseconds { s += String(format: ", batch=%.1f ms", b) }
        return s + " (\(engine), \(source)→\(target))"
    }
}
