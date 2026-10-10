// SPDX-License-Identifier: MIT
// MockEngine determinism, Apple engine pure mappings, selftest helpers. No installed languages needed.

import Foundation
import Testing
@testable import TalkLensCore
@testable import TalkLensTranslate

@Suite("Translate.Engines")
struct TranslateEngineTests {
    @Test func mockEngineIsDeterministic() async throws {
        let engine = MockEngine()
        let items = [TranslationItem(id: "1", text: "안녕하세요"), TranslationItem(id: "2", text: "넵")]
        let zh = Locale.Language(identifier: "zh-Hans")
        let a = try await engine.translate(items, source: Locale.Language(identifier: "ko"), target: zh)
        let b = try await engine.translate(items, source: Locale.Language(identifier: "ko"), target: zh)
        #expect(a == b)
        #expect(a == [TranslationResult(id: "1", text: "[mock→zh-Hans] 안녕하세요"),
                      TranslationResult(id: "2", text: "[mock→zh-Hans] 넵")])
        #expect(MockEngine.translateSync("안녕하세요", target: "zh-Hans") == "[mock→zh-Hans] 안녕하세요")
        #expect(engine.id == "mock")
        #expect(await engine.status(source: Locale.Language(identifier: "ko"), target: zh) == .ready)
    }

    @Test func appleStatusMapping() {
        typealias E = AppleTranslationEngine
        #expect(E.mapStatus(.installed, route: .uiLess, source: "ko", target: "zh-Hans") == .ready)
        #expect(E.mapStatus(.installed, route: .hosted, source: "ko", target: "zh-Hans") == .ready)
        #expect(E.mapStatus(.installed, route: .unavailable, source: "ko", target: "zh-Hans")
                == .unsupported(E.hostRequiredReason))
        #expect(E.mapStatus(.supported, route: .uiLess, source: "ko", target: "zh-Hans") == .needsDownload)
        #expect(E.mapStatus(.supported, route: .unavailable, source: "ko", target: "zh-Hans") == .needsDownload)
        if case .unsupported(let reason) = E.mapStatus(.unsupported, route: .uiLess, source: "ko", target: "xx") {
            #expect(reason.contains("ko→xx"))
        } else {
            Issue.record("expected .unsupported")
        }
        #expect(AppleTranslationEngine().id == "apple")
    }

    @Test func appleErrorMapping() {
        typealias E = AppleTranslationEngine
        #expect(E.mapError(CancellationError()) == .cancelled)
        #expect(E.mapError(TranslationEngineError.notInstalled) == .notInstalled)
        let ns = NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "secret text"])
        #expect(E.mapError(ns) == .failed("Test#7"))   // never echoes descriptions
        #expect(TranslationService.engineError(ns) == .failed("Test#7"))
        #expect(TranslationService.engineError(CancellationError()) == .cancelled)
    }

    @Test func appleResultMatching() throws {
        typealias E = AppleTranslationEngine
        let items = [TranslationItem(id: "a", text: "x"), TranslationItem(id: "b", text: "y")]
        let byID = try E.matchResults(items: items, responses: [("b", "Y"), ("a", "X")])
        #expect(byID == [TranslationResult(id: "a", text: "X"), TranslationResult(id: "b", text: "Y")])
        let byPosition = try E.matchResults(items: items, responses: [(nil, "X"), (nil, "Y")])
        #expect(byPosition == byID)
        #expect(throws: TranslationEngineError.failed("missing result")) {
            try E.matchResults(items: items, responses: [("a", "X")])
        }
    }
}

@Suite("Translate.Selftest")
struct TranslateSelftestTests {
    @Test func parsesInputFile() {
        let contents = """
        # comment line
        첫 번째 문장

           # indented comment
        두 번째\\n세 번째 줄
          앞뒤 공백  \r
        """
        let lines = SelftestSupport.parseInput(contents)
        #expect(lines == ["첫 번째 문장", "두 번째\n세 번째 줄", "앞뒤 공백"])
        #expect(SelftestSupport.oneLine(lines[1]) == "두 번째\\n세 번째 줄")
    }

    @Test func parsesFixtureFileIfPresent() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/test_messages_ko.txt")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = SelftestSupport.parseInput(contents)
        #expect(!lines.isEmpty)
        #expect(lines.allSatisfy { !$0.hasPrefix("#") && !$0.contains("\\n") })
        #expect(lines.contains { $0.contains("\n") })
    }

    @Test func parsesArguments() throws {
        let o = try SelftestOptions.parse(["--engine", "mock", "--source", "ko", "--target", "en",
                                           "--input", "f.txt", "--batch", "--timeout", "30"])
        #expect(o.engine == "mock")
        #expect(o.source == "ko")
        #expect(o.target == "en")
        #expect(o.input == "f.txt")
        #expect(o.batchOnly)
        #expect(o.timeoutSeconds == 30)
        #expect(try SelftestOptions.parse([]) == SelftestOptions())
        #expect(SelftestOptions().timeoutSeconds < 240)
        #expect(throws: SelftestOptions.ParseError.invalidValue("--engine", "google")) {
            try SelftestOptions.parse(["--engine", "google"])
        }
        #expect(throws: SelftestOptions.ParseError.missingValue("--input")) {
            try SelftestOptions.parse(["--input"])
        }
        #expect(throws: SelftestOptions.ParseError.unknownArgument("--bogus")) {
            try SelftestOptions.parse(["--bogus"])
        }
    }

    @Test func skipAndOkLines() {
        #expect(SelftestSupport.skipLine(for: .ready, source: "ko", target: "zh-Hans") == nil)
        let download = SelftestSupport.skipLine(for: .needsDownload, source: "ko", target: "zh-Hans") ?? ""
        #expect(download.hasPrefix("selftest: SKIP: "))
        #expect(download.contains(" — System Settings → General → Language & Region → Translation Languages"))
        #expect(download.contains("Korean"))
        #expect(download.contains("Chinese (Simplified)"))
        let host = SelftestSupport.skipLine(for: .unsupported(AppleTranslationEngine.hostRequiredReason),
                                            source: "ko", target: "zh-Hans") ?? ""
        #expect(host.contains("macOS 26"))
        let ok = SelftestSupport.okLine(translated: 3, total: 3, p50: 12.34, p95: 56.78, batchMilliseconds: 90,
                                        engine: "apple", source: "ko", target: "zh-Hans")
        #expect(ok == "selftest: OK: 3/3 translated, p50=12.3 ms, p95=56.8 ms, batch=90.0 ms (apple, ko→zh-Hans)")
    }
}

@Suite("Translate.AppleLive", .timeLimit(.minutes(1)))
struct TranslateAppleLiveTests {
    /// Exercises the real framework without requiring installed languages: either a translation comes back,
    /// or the error is mapped to `.notInstalled` / `.unsupported` (never a raw framework error).
    @Test func appleEngineFailsCleanlyOrTranslates() async {
        let engine = AppleTranslationEngine()
        let ko = Locale.Language(identifier: "ko")
        let zh = Locale.Language(identifier: "zh-Hans")
        let status = await engine.status(source: ko, target: zh)
        do {
            let r = try await engine.translate([TranslationItem(id: "t1", text: "안녕하세요")], source: ko, target: zh)
            #expect(r.map(\.id) == ["t1"])
            #expect(status == .ready)
        } catch let e as TranslationEngineError {
            switch e {
            case .notInstalled: #expect(status == .needsDownload)
            case .unsupported: break
            default: Issue.record("unexpected engine error \(e)")
            }
        } catch {
            Issue.record("unmapped error type \(type(of: error))")
        }
    }
}
