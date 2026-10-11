// SPDX-License-Identifier: MIT
// TranslationService with per-message source languages (D-023): grouping by pair, cache key, missing pairs.
// Also selftest planning for `--source auto`. Synthetic text only; no models, no network.

import Foundation
import Synchronization
import Testing
@testable import TalkLensCore
@testable import TalkLensTranslate

/// Records (source, texts) per call; pairs whose source is in `missing` report `.needsDownload`.
final class PairEngine: TranslationEngine, Sendable {
    let id = "pair"
    private let state = Mutex<(calls: [(source: String, texts: [String])], missing: Set<String>)>(([], []))

    init(missing: Set<String> = []) {
        state.withLock { $0.missing = missing }
    }

    var calls: [(source: String, texts: [String])] { state.withLock { $0.calls } }

    func install(_ source: String) {
        state.withLock { _ = $0.missing.remove(source) }
    }

    func status(source: Locale.Language, target: Locale.Language) async -> EngineStatus {
        let id = LanguageCatalog.pairID(source)
        return state.withLock { $0.missing.contains(id) } ? .needsDownload : .ready
    }

    func translate(_ items: [TranslationItem], source: Locale.Language,
                   target: Locale.Language) async throws -> [TranslationResult] {
        let src = LanguageCatalog.pairID(source)
        state.withLock { $0.calls.append((src, items.map(\.text))) }
        return items.map { TranslationResult(id: $0.id, text: "<\(src)→\(target.minimalIdentifier)>" + $0.text) }
    }
}

private func message(_ id: String, _ text: String, source: String?) -> PreprocessedMessage {
    PreprocessedMessage(message: Msg.chat(id, text), kind: .translate, textForMT: text, segments: [.translate(text)],
                        chips: [], note: nil, sourceLanguage: source)
}

@Suite("Translate.MultiSource", .timeLimit(.minutes(1)))
struct MultiSourceServiceTests {
    @Test func engineCallsAreGroupedBySourceLanguage() async {
        let engine = PairEngine()
        let service = TranslationService(engine: engine, batchWindowMilliseconds: 0)
        let msgs = [message("m1", "안녕하세요", source: "ko"), message("m2", "おはようございます", source: "ja"),
                    message("m3", "감사합니다", source: "ko"), message("m4", "Good morning", source: "en"),
                    message("m5", "수고하셨습니다", source: nil)]  // nil → service source (ko)
        let out = await collect(await service.submit(msgs))
        #expect(out.count == 5)
        #expect(out.allSatisfy { $0.error == nil })
        let calls = engine.calls
        #expect(calls.map(\.source) == ["ko", "ja", "en"])
        #expect(calls[0].texts == ["안녕하세요", "감사합니다", "수고하셨습니다"])
        #expect(out.first { $0.id == MessageID("m2") }?.text == "<ja→zh>おはようございます")
        #expect(out.first { $0.id == MessageID("m2") }?.pair == LanguagePair(source: "ja", target: "zh-Hans"))
    }

    @Test func cacheKeyIncludesThePerMessageSource() async {
        let engine = PairEngine()
        let service = TranslationService(engine: engine, batchWindowMilliseconds: 0)
        // Same text, two sources: two cache entries, two engine items.
        let msgs = [message("a", "Gift", source: "en"), message("b", "Gift", source: "de")]
        let first = await collect(await service.submit(msgs))
        #expect(Set(first.compactMap(\.text)) == ["<en→zh>Gift", "<de→zh>Gift"])
        #expect(engine.calls.count == 2)
        #expect(await service.diagnostics.cacheCount == 2)
        #expect(await service.cachedTranslation(for: msgs[1]) == "<de→zh>Gift")
        #expect(await service.cachedTranslation(for: message("c", "Gift", source: "fr")) == nil)
        let second = await collect(await service.submit(msgs))
        #expect(second.allSatisfy { $0.fromCache })
        #expect(engine.calls.count == 2)
    }

    @Test func missingPairFailsOnlyItsMessagesWithAClearReason() async {
        let engine = PairEngine(missing: ["ja"])
        let service = TranslationService(engine: engine, batchWindowMilliseconds: 0)
        let msgs = [message("k", "안녕하세요", source: "ko"), message("j", "おはようございます", source: "ja")]
        let out = await collect(await service.submit(msgs))
        let ja = out.first { $0.id == MessageID("j") }
        #expect(ja?.text == nil)
        #expect(ja?.error == .notInstalled)
        let pair = LanguagePair(source: "ja", target: "zh-Hans")
        #expect(ja?.pair == pair)
        #expect(FailureReason.describe(.notInstalled, pair: pair) == "需要下载 日本語→中文（简体） 翻译语言")
        #expect(out.first { $0.id == MessageID("k") }?.text == "<ko→zh>안녕하세요")
        #expect(!engine.calls.contains { $0.source == "ja" })
        #expect(FailureReason.missingPairsBanner([pair]) == "需要下载翻译语言：日本語→中文（简体）")
        #expect(FailureReason.missingPairsBanner([]) == nil)

        // After the download (and an invalidation) the same message goes through.
        engine.install("ja")
        await service.invalidateLanguageStatus()
        let retry = await collect(await service.submit([msgs[1]]))
        #expect(retry.first?.text == "<ja→zh>おはようございます")
    }

    @Test func perPairStatusIsReported() async {
        let engine = PairEngine(missing: ["th"])
        let service = TranslationService(engine: engine)
        let zh = Locale.Language(identifier: "zh-Hans")
        #expect(await service.status(source: Locale.Language(identifier: "th"), target: zh) == .needsDownload)
        #expect(await service.status(source: Locale.Language(identifier: "ko"), target: zh) == .ready)
        #expect(await service.status() == .ready)  // fallback pair ko → zh-Hans
    }

    @Test func preprocessorAndServiceTogetherUseDetectedSources() async {
        let engine = PairEngine()
        let service = TranslationService(engine: engine, batchWindowMilliseconds: 0)
        let pre = ChatPreprocessor(glossary: .empty, sourceLanguage: nil, targetLanguage: "zh-Hans")
        let bodies = ["내일 회의는 오후 3시입니다", "See you tomorrow at the library", "好的，我知道了"]
        let prepared = bodies.enumerated().map { pre.process(Msg.chat("p\($0.offset)", $0.element)) }
        #expect(prepared.map(\.kind) == [.translate, .translate, .alreadyTarget])
        let out = await collect(await service.submit(prepared))
        #expect(out.count == 2)
        #expect(Set(engine.calls.map(\.source)) == ["ko", "en"])
    }

    // MARK: selftest

    @Test func selftestPlanDetectsSourcesPerLineWithAuto() throws {
        let lines = ["안녕하세요 여러분", "See you tomorrow at the library", "好的，我知道了", "😂😂"]
        let plan = SelftestSupport.plan(lines: lines, source: "auto", target: "zh-Hans")
        #expect(plan.items.map(\.source) == ["ko", "en", "ko"])
        #expect(plan.items.map(\.index) == [0, 1, 3])
        #expect(plan.alreadyTarget == [2])
        #expect(plan.sources == ["ko", "en"])
        #expect(plan.sourceCounts == ["ko": 2, "en": 1])
        let fixed = SelftestSupport.plan(lines: lines, source: "ko", target: "zh-Hans")
        #expect(fixed.items.count == 4 && fixed.alreadyTarget.isEmpty && fixed.sources == ["ko"])
        let o = try SelftestOptions.parse(["--source", "auto"])
        #expect(o.isAuto)
        #expect(!SelftestOptions().isAuto)
    }
}
