// SPDX-License-Identifier: MIT
// TranslationService.warmUp (D-027): one fixed synthetic word through the engine, never cached, skipped when
// the pair is not installed; `immediate` submits skip the batch collect window. Synthetic text only.

import Foundation
import Testing
@testable import TalkLensCore
@testable import TalkLensTranslate

@Suite("Translate.WarmUp", .timeLimit(.minutes(1)))
struct WarmUpTests {
    let ko = Locale.Language(identifier: "ko")
    let zh = Locale.Language(identifier: "zh-Hans")

    @Test func warmUpTranslatesOneSyntheticWordAndDoesNotCacheIt() async {
        let engine = PairEngine()
        let service = TranslationService(engine: engine, source: ko, target: zh, batchWindowMilliseconds: 0)
        #expect(await service.warmUp())
        #expect(engine.calls.count == 1)
        #expect(engine.calls.first?.texts == [TranslationService.warmUpText(for: ko)])
        let d = await service.diagnostics
        #expect(d.warmUps == 1)
        #expect(d.engineCalls == 0)
        #expect(d.cacheCount == 0)
    }

    @Test func warmUpIsSkippedWhenThePairIsNotInstalled() async {
        let engine = PairEngine(missing: ["ko"])
        let service = TranslationService(engine: engine, source: ko, target: zh, batchWindowMilliseconds: 0)
        #expect(await service.warmUp() == false)
        #expect(engine.calls.isEmpty)
    }

    @Test func warmUpWordsAreFixedPerLanguage() {
        #expect(TranslationService.warmUpText(for: ko) == "안녕하세요")
        #expect(TranslationService.warmUpText(for: Locale.Language(identifier: "en")) == "hello")
        #expect(TranslationService.warmUpText(for: Locale.Language(identifier: "zh-Hant")) == "你好")
    }

    @Test func immediateSubmitSkipsTheCollectWindow() async {
        let engine = PairEngine()
        // A long collect window: an immediate submit must not wait for it.
        let service = TranslationService(engine: engine, source: ko, target: zh, batchWindowMilliseconds: 2000)
        let watch = Stopwatch()
        let outcomes = await collect(await service.submit([Msg.text("m1", "안녕")], immediate: true))
        #expect(outcomes.count == 1)
        #expect(watch.elapsedMilliseconds < 1500)
    }
}
