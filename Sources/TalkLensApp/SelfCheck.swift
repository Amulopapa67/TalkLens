// SPDX-License-Identifier: MIT
// `TalkLens --self-check [fixture.axjson]`: builds the whole pipeline with MockEngine, runs one
// diff/preprocess/translate cycle on a synthetic fixture and prints counts only. No UI, no AX, no KakaoTalk.

import CoreGraphics
import Foundation
import KakaoAX
import TalkLensCore
import TalkLensTranslate

@MainActor
enum SelfCheck {
    static func run(fixturePath: String?) async -> Int32 {
        let settings = AppSettings(defaults: nil)
        let diagnostics = Diagnostics()
        let glossary = GlossaryStore(bundle: .main, loadUser: false)
        let service = TranslationService(engine: MockEngine(), target: settings.targetLocale)
        let model = SidebarViewModel(service: service, glossary: glossary.merged, settings: settings,
                                     diagnostics: diagnostics)
        // Constructed (not started) to make sure the live components initialise without side effects.
        let manager = SessionManager(reader: AXReader(), diagnostics: diagnostics)
        _ = manager.state

        var fixtureState = "none"
        var parsed: [ParsedMessage] = []
        var title = "self-check"
        if let fixturePath {
            do {
                let file = try AXSnapshotFile.load(contentsOf: URL(fileURLWithPath: fixturePath))
                title = file.window.title
                parsed = TranscriptParser().parse(window: file.root) ?? []
                fixtureState = parsed.isEmpty ? "loaded-empty" : "loaded"
            } catch {
                fixtureState = "missing"
            }
        }

        let chatKey = MessageIdentity.chatKey(forTitle: title)
        let snapshot = TranscriptSnapshot(chatKey: chatKey, messages: MessageIdentity.assign(parsed, chatKey: chatKey))
        model.setTrackerStatus(.active)
        model.ingest(snapshot: snapshot, title: nil, animate: false)
        var finished = await waitWithTimeout(model)
        let c = model.counts

        // Synthetic pass (made-up sentences, no real chat data): first load, then one appended row, to exercise
        // the incremental diff → preprocess → translate path and the latency bookkeeping.
        let synthKey = MessageIdentity.chatKey(forTitle: "self-check-synthetic")
        let base = Array(synthetic.dropLast())
        model.ingest(snapshot: TranscriptSnapshot(chatKey: synthKey, messages: MessageIdentity.assign(base, chatKey: synthKey)),
                     title: nil, animate: false)
        finished = await waitWithTimeout(model) && finished
        model.ingest(snapshot: TranscriptSnapshot(chatKey: synthKey, messages: MessageIdentity.assign(synthetic, chatKey: synthKey)),
                     title: nil, animate: false)
        finished = await waitWithTimeout(model) && finished
        let s = model.counts

        let placement = PanelPlacement.place(window: CGRect(x: 200, y: 200, width: 600, height: 700),
                                             panelWidth: CGFloat(settings.panelWidth),
                                             screens: [CGRect(x: 0, y: 0, width: 1728, height: 1080)],
                                             preferred: settings.edge, inputFrame: nil, gap: 6)
        print("TalkLens self-check: fixture=\(fixtureState) parsed=\(parsed.count) rows=\(c.rows) "
              + "needs_mt=\(c.needsMT) mt_done=\(c.done) mt_failed=\(c.failed) mt_pending=\(c.pending)")
        print("TalkLens self-check: synthetic rows=\(s.rows) needs_mt=\(s.needsMT) mt_done=\(s.done) "
              + "mt_failed=\(s.failed) mt_pending=\(s.pending) latency_samples=\(diagnostics.translationStats.count)")
        print("TalkLens self-check: glossary_entries=\(glossary.merged.entries.count) "
              + "placement=\(placement.edge.rawValue) completed=\(finished)")
        return finished ? 0 : 1
    }

    private static let synthetic: [ParsedMessage] = [
        ParsedMessage(author: nil, isMine: false, isSystem: true, timeRaw: nil, date: "2026-10-10",
                      body: "2026년 10월 10일 토요일"),
        ParsedMessage(author: "합성A", isMine: false, isSystem: false, timeRaw: "오후 3:00", date: "2026-10-10",
                      body: "내일 랩미팅은 오후 4시로 변경되었습니다."),
        ParsedMessage(author: nil, isMine: true, isSystem: false, timeRaw: "오후 3:01", date: "2026-10-10",
                      body: "ㅋㅋㅋ"),
        ParsedMessage(author: "합성A", isMine: false, isSystem: false, timeRaw: "오후 3:02", date: "2026-10-10",
                      body: "과제 마감은 금요일 자정입니다."),
    ]

    private static func waitWithTimeout(_ model: SidebarViewModel) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await model.waitForTranslations(); return true }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
