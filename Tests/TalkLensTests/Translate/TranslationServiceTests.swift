// SPDX-License-Identifier: MIT
// Scheduler tests: cache, dedupe, batching, priority, cancellation, assembly, errors. No network, no models.

import Foundation
import Testing
@testable import TalkLensCore
@testable import TalkLensTranslate

@Suite("Translate.TranslationService", .timeLimit(.minutes(1)))
struct TranslateServiceTests {
    let zh = Locale.Language(identifier: "zh-Hans")

    @Test func translatesAndSecondSubmitHitsCache() async {
        let engine = ScriptedEngine()
        let service = TranslationService(engine: engine, batchWindowMilliseconds: 0)
        let msgs = [Msg.text("m1", "안녕하세요"), Msg.text("m2", "감사합니다")]

        let first = await collect(await service.submit(msgs))
        #expect(first.count == 2)
        #expect(first.allSatisfy { !$0.fromCache && $0.error == nil })
        #expect(first.first { $0.id == MessageID("m1") }?.text == ScriptedEngine.render("안녕하세요", target: zh))

        let second = await collect(await service.submit(msgs))
        #expect(second.count == 2)
        #expect(second.allSatisfy { $0.fromCache })
        #expect(second.map(\.text) == first.sorted { $0.id.rawValue < $1.id.rawValue }.map(\.text))
        #expect(await engine.recorder.count == 1)
        let d = await service.diagnostics
        #expect(d.engineCalls == 1)
        #expect(d.itemsSent == 2)
        #expect(d.cacheHits == 2)
        #expect(d.cacheCount == 2)
        #expect(await service.cachedTranslation(for: msgs[0]) == ScriptedEngine.render("안녕하세요", target: zh))
    }

    @Test func identicalSegmentTextsAreSentOnce() async {
        let engine = ScriptedEngine()
        let service = TranslationService(engine: engine, batchWindowMilliseconds: 0)
        let msgs = [Msg.text("m1", "넵"), Msg.text("m2", "넵"), Msg.text("m3", "수고하셨습니다"),
                    Msg.segments("m4", [.translate("넵"), .keep("\n"), .translate("수고하셨습니다")])]
        let out = await collect(await service.submit(msgs))
        #expect(out.count == 4)
        #expect(out.allSatisfy { $0.text != nil })
        let sent = await engine.recorder.allTexts
        #expect(sent.sorted() == ["넵", "수고하셨습니다"].sorted())
    }

    @Test func batchSizeIsRespected() async {
        let engine = ScriptedEngine()
        let service = TranslationService(engine: engine, batchSize: 2, batchWindowMilliseconds: 0)
        let msgs = (1...5).map { Msg.text("m\($0)", "문장 \($0)") }
        let out = await collect(await service.submit(msgs))
        #expect(out.count == 5)
        let sizes = await engine.recorder.calls.map(\.count)
        #expect(sizes == [2, 2, 1])
    }

    @Test func engineCallsFollowPriorityOrder() async {
        let engine = ScriptedEngine()
        let service = TranslationService(engine: engine, batchSize: 1, batchWindowMilliseconds: 0)
        let texts = ["가장 최신", "두 번째", "세 번째", "네 번째"]
        let msgs = texts.enumerated().map { Msg.text("m\($0.offset)", $0.element) }
        let out = await collect(await service.submit(msgs))
        #expect(out.map(\.id.rawValue) == ["m0", "m1", "m2", "m3"])
        #expect(await engine.recorder.allTexts == texts)
    }

    @Test func resubmitCancelsOldStreamAndDropsUnstartedBatches() async {
        let engine = ScriptedEngine(delay: .milliseconds(150))
        let service = TranslationService(engine: engine, batchSize: 1, batchWindowMilliseconds: 0)
        let old = await service.submit([Msg.text("a1", "옛날 1"), Msg.text("a2", "옛날 2"), Msg.text("a3", "옛날 3")])
        let oldTask = Task { await collect(old) }
        // Wait until the first old batch is running.
        #expect(await waitUntil { await engine.recorder.count >= 1 })

        let fresh = await collect(await service.submit([Msg.text("b1", "새 메시지")]))
        let oldOutcomes = await oldTask.value
        #expect(oldOutcomes.isEmpty)
        #expect(fresh.map(\.id.rawValue) == ["b1"])
        #expect(fresh.first?.text == ScriptedEngine.render("새 메시지", target: zh))
        let sent = await engine.recorder.allTexts
        #expect(sent == ["옛날 1", "새 메시지"])
        // The in-flight old call still filled the cache.
        #expect(await waitUntil { await service.cachedTranslation(for: Msg.text("a1", "옛날 1")) != nil })
    }

    @Test func textInFlightFromCancelledSubmissionIsAwaitedNotResent() async {
        let engine = ScriptedEngine(delay: .milliseconds(150))
        let service = TranslationService(engine: engine, batchWindowMilliseconds: 0)
        let old = await service.submit([Msg.text("a1", "공지 확인 부탁드려요")])
        #expect(await waitUntil { await engine.recorder.count >= 1 })
        let out = await collect(await service.submit([Msg.text("b1", "공지 확인 부탁드려요"),
                                                      Msg.text("b2", "다른 문장")]))
        withExtendedLifetime(old) {}
        #expect(Set(out.map(\.id.rawValue)) == ["b1", "b2"])
        #expect(out.allSatisfy { $0.text != nil })
        let sent = await engine.recorder.allTexts
        #expect(sent.filter { $0 == "공지 확인 부탁드려요" }.count == 1)
    }

    @Test func batchWindowLetsResubmitCoalesce() async {
        let engine = ScriptedEngine()
        let service = TranslationService(engine: engine, batchWindowMilliseconds: 200)
        let old = await service.submit([Msg.text("m1", "첫 번째")])
        let out = await collect(await service.submit([Msg.text("m2", "두 번째"), Msg.text("m1", "첫 번째")]))
        withExtendedLifetime(old) {}
        #expect(out.count == 2)
        #expect(await engine.recorder.calls == [["두 번째", "첫 번째"]])
    }

    @Test func cancelAllFinishesStream() async {
        let engine = ScriptedEngine(delay: .milliseconds(100))
        let service = TranslationService(engine: engine, batchWindowMilliseconds: 300)
        let stream = await service.submit([Msg.text("m1", "취소될 문장")])
        await service.cancelAll()
        let out = await collect(stream)
        #expect(out.isEmpty)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await engine.recorder.count == 0)
    }

    @Test func targetChangeChangesCacheKey() async {
        let engine = ScriptedEngine()
        let service = TranslationService(engine: engine, batchWindowMilliseconds: 0)
        let msgs = [Msg.text("m1", "회의 시간 변경")]
        let zhOut = await collect(await service.submit(msgs))
        #expect(zhOut.first?.text == ScriptedEngine.render("회의 시간 변경", target: zh))

        let en = Locale.Language(identifier: "en")
        await service.setTarget(en)
        #expect(await service.cachedTranslation(for: msgs[0]) == nil)
        let enOut = await collect(await service.submit(msgs))
        #expect(enOut.first?.fromCache == false)
        #expect(enOut.first?.text == ScriptedEngine.render("회의 시간 변경", target: en))
        #expect(await engine.recorder.count == 2)

        await service.setTarget(zh)
        let back = await collect(await service.submit(msgs))
        #expect(back.first?.fromCache == true)
        #expect(back.first?.text == zhOut.first?.text)
    }

    @Test func multiSegmentAssemblyKeepsPreservedSegments() async {
        let engine = ScriptedEngine()
        let service = TranslationService(engine: engine, batchWindowMilliseconds: 0)
        let msg = Msg.segments("m1", [.keep("@린루이 "), .translate("오늘 참석 가능하세요?"), .keep("\n"),
                                      .keep("https://example.com/a"), .keep("\n"), .translate("확인 부탁드립니다")])
        let out = await collect(await service.submit([msg]))
        let expected = "@린루이 " + ScriptedEngine.render("오늘 참석 가능하세요?", target: zh) + "\n"
            + "https://example.com/a\n" + ScriptedEngine.render("확인 부탁드립니다", target: zh)
        #expect(out.first?.text == expected)
        #expect(await engine.recorder.allTexts == ["오늘 참석 가능하세요?", "확인 부탁드립니다"])
    }

    @Test func engineErrorYieldsErrorOutcomeAndServiceKeepsWorking() async {
        let engine = ScriptedEngine(failingTexts: ["실패 문장"])
        let service = TranslationService(engine: engine, batchSize: 1, batchWindowMilliseconds: 0)
        let out = await collect(await service.submit([Msg.text("bad", "실패 문장"), Msg.text("ok", "정상 문장")]))
        let bad = out.first { $0.id == MessageID("bad") }
        let ok = out.first { $0.id == MessageID("ok") }
        #expect(bad?.text == nil)
        #expect(bad?.error == .failed("injected"))
        #expect(ok?.text == ScriptedEngine.render("정상 문장", target: zh))
        #expect(ok?.error == nil)

        let again = await collect(await service.submit([Msg.text("ok2", "또 다른 문장")]))
        #expect(again.first?.text != nil)
        #expect(await service.diagnostics.failedCalls == 1)
    }

    @Test func nonTranslatableKindsAreSkipped() async {
        let engine = ScriptedEngine()
        let service = TranslationService(engine: engine, batchWindowMilliseconds: 0)
        let msgs = [Msg.skipped("s1", "ㅋㅋㅋ", kind: .jamoOnly), Msg.skipped("s2", "😂", kind: .emojiOnly),
                    Msg.skipped("s3", "https://example.com", kind: .urlOnly),
                    Msg.skipped("s4", "날짜 구분선", kind: .system),
                    Msg.segments("s5", [.keep("https://example.com")])]
        let out = await collect(await service.submit(msgs))
        #expect(out.isEmpty)
        #expect(await engine.recorder.count == 0)

        let mixed = await collect(await service.submit(msgs + [Msg.text("t1", "번역 필요")]))
        #expect(mixed.map(\.id.rawValue) == ["t1"])
    }

    @Test func latencyIsRecorded() async {
        let engine = ScriptedEngine(delay: .milliseconds(20))
        let service = TranslationService(engine: engine, batchWindowMilliseconds: 0)
        let msgs = [Msg.text("m1", "지연 측정")]
        let out = await collect(await service.submit(msgs))
        #expect(out.count == 1)
        #expect((out.first?.latencyMilliseconds ?? -1) >= 15)
        let cached = await collect(await service.submit(msgs))
        #expect((cached.first?.latencyMilliseconds ?? -1) >= 0)
        #expect(cached.first?.fromCache == true)
    }

    @Test func cacheIsBoundedAndClearable() async {
        let engine = ScriptedEngine()
        let service = TranslationService(engine: engine, cacheCapacity: 2, batchWindowMilliseconds: 0)
        _ = await collect(await service.submit([Msg.text("m1", "하나"), Msg.text("m2", "둘"), Msg.text("m3", "셋")]))
        #expect(await service.diagnostics.cacheCount == 2)
        await service.clearCache()
        #expect(await service.diagnostics.cacheCount == 0)
        #expect(await service.cachedTranslation(for: Msg.text("m1", "하나")) == nil)
    }

    @Test func outcomesDeliveredEvenWhenBatchExceedsCacheCapacity() async {
        let engine = ScriptedEngine()
        let service = TranslationService(engine: engine, cacheCapacity: 1, batchWindowMilliseconds: 0)
        let out = await collect(await service.submit((1...4).map { Msg.text("m\($0)", "문장 \($0)") }))
        #expect(out.count == 4)
        #expect(out.allSatisfy { $0.text != nil })
    }
}
