// SPDX-License-Identifier: MIT
// Channel isolation of TranslationService: one channel per followed chat window. Synthetic text only.

import Foundation
import Testing
@testable import TalkLensCore
@testable import TalkLensTranslate

/// Records the highest number of engine calls that ran at the same time.
actor ConcurrencyMeter {
    private var running = 0
    private(set) var maxRunning = 0
    private(set) var order: [String] = []
    func enter(_ first: String) {
        running += 1
        maxRunning = max(maxRunning, running)
        order.append(first)
    }
    func leave() { running -= 1 }
}

struct MeteredEngine: TranslationEngine {
    let id = "metered"
    let meter = ConcurrencyMeter()
    let delay: Duration

    func status(source: Locale.Language, target: Locale.Language) async -> EngineStatus { .ready }

    func translate(_ items: [TranslationItem], source: Locale.Language,
                   target: Locale.Language) async throws -> [TranslationResult] {
        await meter.enter(items.first?.text ?? "")
        let deadline = ContinuousClock.now + delay
        while ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        await meter.leave()
        return items.map { TranslationResult(id: $0.id, text: "<t>" + $0.text) }
    }
}

@Suite("Translate.TranslationService.channels", .timeLimit(.minutes(1)))
struct TranslationChannelTests {
    @Test func twoChannelsDoNotCancelEachOther() async {
        let engine = ScriptedEngine(delay: .milliseconds(80))
        let service = TranslationService(engine: engine, batchSize: 1, batchWindowMilliseconds: 0)
        let a = await service.submit([Msg.text("a1", "채널 A 첫째"), Msg.text("a2", "채널 A 둘째")], channel: "A")
        let b = await service.submit([Msg.text("b1", "채널 B 첫째")], channel: "B")
        async let outA = collect(a)
        async let outB = collect(b)
        let (ra, rb) = await (outA, outB)
        #expect(Set(ra.map(\.id.rawValue)) == ["a1", "a2"])
        #expect(ra.allSatisfy { $0.text != nil && $0.error == nil })
        #expect(rb.map(\.id.rawValue) == ["b1"])
        #expect(rb.first?.text != nil)
    }

    @Test func sameChannelStillCancels() async {
        let engine = ScriptedEngine(delay: .milliseconds(150))
        let service = TranslationService(engine: engine, batchSize: 1, batchWindowMilliseconds: 0)
        let old = await service.submit([Msg.text("o1", "옛 문장 1"), Msg.text("o2", "옛 문장 2")], channel: "A")
        let oldTask = Task { await collect(old) }
        #expect(await waitUntil { await engine.recorder.count >= 1 })
        let fresh = await collect(await service.submit([Msg.text("n1", "새 문장")], channel: "A"))
        #expect(await oldTask.value.isEmpty)
        #expect(fresh.map(\.id.rawValue) == ["n1"])
        // The unstarted second old batch was dropped.
        #expect(await engine.recorder.allTexts == ["옛 문장 1", "새 문장"])
    }

    @Test func cancellingOneChannelLeavesOthersRunning() async {
        let engine = ScriptedEngine(delay: .milliseconds(60))
        let service = TranslationService(engine: engine, batchSize: 1, batchWindowMilliseconds: 0)
        let a = await service.submit([Msg.text("a1", "취소될 A")], channel: "A")
        let b = await service.submit([Msg.text("b1", "남을 B")], channel: "B")
        await service.cancel(channel: "A")
        let ra = await collect(a)
        let rb = await collect(b)
        #expect(ra.isEmpty)
        #expect(rb.map(\.id.rawValue) == ["b1"])
        #expect(await service.activeChannelCount == 0)
    }

    @Test func inFlightTextIsSharedAcrossChannels() async {
        let engine = ScriptedEngine(delay: .milliseconds(150))
        let service = TranslationService(engine: engine, batchWindowMilliseconds: 0)
        let a = await service.submit([Msg.text("a1", "같은 공지")], channel: "A")
        #expect(await waitUntil { await engine.recorder.count >= 1 })
        let b = await service.submit([Msg.text("b1", "같은 공지"), Msg.text("b2", "B 전용")], channel: "B")
        async let outA = collect(a)
        async let outB = collect(b)
        let (ra, rb) = await (outA, outB)
        #expect(ra.map(\.id.rawValue) == ["a1"])
        #expect(Set(rb.map(\.id.rawValue)) == ["b1", "b2"])
        #expect((ra + rb).allSatisfy { $0.text != nil })
        let sent = await engine.recorder.allTexts
        #expect(sent.filter { $0 == "같은 공지" }.count == 1)
        // A third channel is answered from the shared cache.
        let c = await collect(await service.submit([Msg.text("c1", "같은 공지")], channel: "C"))
        #expect(c.first?.fromCache == true)
    }

    @Test func engineCallsAreSerializedAcrossChannels() async {
        let engine = MeteredEngine(delay: .milliseconds(40))
        let service = TranslationService(engine: engine, batchSize: 1, batchWindowMilliseconds: 0)
        let streams = [
            await service.submit([Msg.text("a1", "A1"), Msg.text("a2", "A2")], channel: "A"),
            await service.submit([Msg.text("b1", "B1"), Msg.text("b2", "B2")], channel: "B"),
            await service.submit([Msg.text("c1", "C1")], channel: "C"),
        ]
        var total = 0
        for s in streams { total += await collect(s).count }
        #expect(total == 5)
        #expect(await engine.meter.maxRunning == 1)
    }

    @Test func preferredChannelGoesFirst() async {
        let engine = MeteredEngine(delay: .milliseconds(60))
        let service = TranslationService(engine: engine, batchSize: 1, batchWindowMilliseconds: 0)
        await service.setPreferredChannel("P")
        let first = await service.submit([Msg.text("x1", "X1"), Msg.text("x2", "X2")], channel: "X")
        #expect(await waitUntil { await engine.meter.order.count >= 1 })
        let other = await service.submit([Msg.text("y1", "Y1")], channel: "Y")
        try? await Task.sleep(for: .milliseconds(5))
        let preferred = await service.submit([Msg.text("p1", "P1")], channel: "P")
        _ = await collect(first)
        _ = await collect(other)
        _ = await collect(preferred)
        let order = await engine.meter.order
        // X1 was already running; the preferred channel's waiting batch runs right after it.
        #expect(order.first == "X1")
        #expect(order.dropFirst().first == "P1")
    }
}
