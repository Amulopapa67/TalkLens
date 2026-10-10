// SPDX-License-Identifier: MIT
// Incremental transcript reads: TranscriptRowCache + KakaoChatReader.read(window:cache:parser:).
// All chats are synthetic (SyntheticFixtureBuilder) or committed fixtures.

import CoreGraphics
import Foundation
import Testing
@testable import KakaoAX
import TalkLensCore
import TalkLensTranslate

@Suite("KakaoAX.IncrementalRead")
struct IncrementalReadTests {
    let parser = TranscriptParser(referenceYear: 2026)
    let t0 = ContinuousClock.now

    // MARK: - Helpers

    /// Cache with no prefetch band limit and no per-read budget: the tests below exercise the cache mechanics
    /// (identity, shifting, validation) on whole chats. Band/budget behaviour is tested in
    /// IncrementalReadBudgetTests.
    static func unlimitedCache<N: IncrementalAXNode>(_: N.Type) -> TranscriptRowCache<N> {
        TranscriptRowCache<N>(maxAnalysesPerRead: Int.max, prefetchViewports: 1_000_000)
    }

    static func smallChat(extra: Bool = false, spacer: Bool = false) -> SyntheticChat {
        var c = SyntheticChat(title: "합성 증분방", options: .init(windowHeight: 760, spacerRow: spacer))
        c.other("합성A", .text("내일 랩미팅은 오후 2시에서 4시로 변경되었습니다."))
        c.other(nil, .text("교수님께서 이번 주 금요일 세미나는 온라인으로 진행한다고 하셨어요."), time: "오후 3:12", help: "2026. 10. 10.")
        c.mine(.text("넵 알겠습니다!"), time: "오후 3:13", help: "2026. 10. 10.")
        c.other("합성B", .text("오늘 3교시 휴강입니다."), time: "오후 3:14", help: "2026. 10. 10.")
        c.mine(.text("수고하셨습니다~"), time: "오후 3:15", help: "2026. 10. 10.")
        if extra { c.mine(.text("오늘 점심 학식 vs 배달?"), time: "오후 3:16", help: "2026. 10. 10.") }
        return c
    }

    /// Full (non-incremental) parse of every row above the input, for comparison.
    func fullParse(_ window: RecordedAXNode, title: String) -> [ChatMessage] {
        let p = TranscriptParser(referenceYear: 2026, visibleOnly: false)
        let parsed = p.parse(window: window) ?? []
        return MessageIdentity.assign(parsed, chatKey: MessageIdentity.chatKey(forTitle: title))
    }

    func rowChildrenReads(_ world: FakeWorld, table: String = "w/0/0") -> Int {
        world.childrenReads.filter { $0.key.hasPrefix(table + "/") }.values.reduce(0, +)
    }

    /// Applies `transform` to the table row at `index`.
    static func mapRow(_ window: RecordedAXNode, _ index: Int, _ transform: (RecordedAXNode) -> RecordedAXNode) -> RecordedAXNode {
        window.modifyingFirst(role: AXRole.table) { table in
            var t = table
            t.children[index] = transform(t.children[index])
            return t
        }
    }

    // MARK: - Tests

    @Test("first read emits every loaded message like a full parse")
    func firstReadMatchesFullParse() throws {
        for name in ["synthetic_group_basic", "synthetic_200rows"] {
            let file = try Fixture.load(name)
            let world = FakeWorld()
            let root = FakeAXNode.load(file.root, into: world)
            let cache = Self.unlimitedCache(FakeAXNode.self)
            let read = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0)
            let full = fullParse(file.root, title: file.window.title)
            #expect(read.snapshot.messages.map(\.id) == full.map(\.id), "\(name)")
            #expect(read.snapshot.messages.map(\.body) == full.map(\.body), "\(name)")
            #expect(read.rowsAnalyzed == read.rowsTotal, "\(name)")
            #expect(read.rowsTotal > 0)
        }
    }

    @Test("cache hit: the second read analyses no row and walks no row subtree")
    func cacheHit() throws {
        let file = try Fixture.load("synthetic_200rows")
        let world = FakeWorld()
        let root = FakeAXNode.load(file.root, into: world)
        let cache = Self.unlimitedCache(FakeAXNode.self)
        let first = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0)
        #expect(first.rowsAnalyzed == first.rowsTotal)
        #expect(rowChildrenReads(world) > 0)

        world.resetCounters()
        let second = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0 + .milliseconds(100))
        #expect(second.rowsAnalyzed == 0)
        #expect(second.rowsTotal == first.rowsTotal)
        #expect(rowChildrenReads(world) == 0)
        #expect(second.snapshot.messages.map(\.id) == first.snapshot.messages.map(\.id))
        #expect(second.snapshot.messages.map(\.frame) == first.snapshot.messages.map(\.frame))
        #expect(second.visibleIDs == first.visibleIDs)
    }

    @Test("scroll: table origin shift moves every frame, nothing is analysed")
    func scrollShiftsFrames() throws {
        let file = try Fixture.load("synthetic_200rows")
        let world = FakeWorld()
        let root = FakeAXNode.load(file.root, into: world)
        let cache = Self.unlimitedCache(FakeAXNode.self)
        let first = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0)

        // The user scrolls up by 300 pt: the table (document bounds) and all rows move down.
        let scrolled = file.root.modifyingFirst(role: AXRole.table) { $0.shifted(dx: 0, dy: 300) }
        FakeAXNode.load(scrolled, into: world)
        let second = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0 + .milliseconds(50))
        #expect(second.rowsAnalyzed == 0)
        #expect(second.snapshot.messages.map(\.id) == first.snapshot.messages.map(\.id))
        for (a, b) in zip(first.snapshot.messages, second.snapshot.messages) {
            let fa = try #require(a.frame), fb = try #require(b.frame)
            #expect(fb.y == fa.y + 300 && fb.x == fa.x)
            if let ba = a.bubbleFrame, let bb = b.bubbleFrame { #expect(bb.y == ba.y + 300) }
        }
        #expect(second.visibleIDs != first.visibleIDs)
        #expect(second.tableFrame?.minY == (first.tableFrame?.minY ?? 0) + 300)
        // The shifted frames are exactly what a fresh full parse of the scrolled tree reports.
        let full = fullParse(scrolled, title: file.window.title)
        let fullByID = Dictionary(uniqueKeysWithValues: full.map { ($0.id, $0.frame) })
        for m in second.snapshot.messages where fullByID[m.id] != nil { #expect(fullByID[m.id]! == m.frame) }
    }

    @Test("a horizontal window move shifts frames too")
    func windowMoveShiftsFrames() throws {
        let file = try Fixture.load("synthetic_group_basic")
        let world = FakeWorld()
        let root = FakeAXNode.load(file.root, into: world)
        let cache = Self.unlimitedCache(FakeAXNode.self)
        let first = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0)
        FakeAXNode.load(file.root.shifted(dx: -120, dy: 40), into: world)
        let second = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0 + .milliseconds(50))
        #expect(second.rowsAnalyzed == 0)
        for (a, b) in zip(first.snapshot.messages, second.snapshot.messages) {
            #expect(b.frame?.x == a.frame.map { $0.x - 120 } && b.frame?.y == a.frame.map { $0.y + 40 })
        }
        #expect(second.visibleIDs == first.visibleIDs)
    }

    @Test("appended row: exactly one row is analysed")
    func appendedRow() throws {
        let before = Self.smallChat().build(note: "")
        let after = Self.smallChat(extra: true).build(note: "")
        let world = FakeWorld()
        let root = FakeAXNode.load(before.root, into: world)
        let cache = Self.unlimitedCache(FakeAXNode.self)
        _ = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0)
        FakeAXNode.load(after.root, into: world)
        let read = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0 + .milliseconds(200))
        #expect(read.rowsAnalyzed == 1)
        let full = fullParse(after.root, title: after.window.title)
        #expect(read.snapshot.messages.map(\.id) == full.map(\.id))
        #expect(read.snapshot.messages.map(\.frame) == full.map(\.frame))
        #expect(read.snapshot.messages.last?.body == "오늘 점심 학식 vs 배달?")
        #expect(read.visibleIDs.contains(try #require(read.snapshot.messages.last?.id)))
    }

    @Test("chained author stays correct when only the new continuation row is analysed")
    func chainedAuthorOnAppend() throws {
        func chat(_ n: Int) -> AXSnapshotFile {
            var c = SyntheticChat(title: "합성 연속방", options: .init(windowHeight: 760, spacerRow: false))
            c.mine(.text("넵 알겠습니다!"), time: "오후 3:10", help: "2026. 10. 10.")
            c.other("합성C", .text("출석 체크는 KLMS에서 해주세요."))
            if n > 0 { c.other(nil, .text("중간고사 범위는 1장부터 6장까지입니다.")) }
            if n > 1 { c.other(nil, .text("수고하셨습니다~"), time: "오후 3:12", help: "2026. 10. 10.") }
            return c.build(note: "")
        }
        let world = FakeWorld()
        let root = FakeAXNode.load(chat(0).root, into: world)
        let cache = Self.unlimitedCache(FakeAXNode.self)
        _ = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0)
        for n in 1...2 {
            let file = chat(n)
            FakeAXNode.load(file.root, into: world)
            let read = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0 + .seconds(n))
            #expect(read.rowsAnalyzed == 1)
            let others = read.snapshot.messages.filter { !$0.isMine && !$0.isSystem }
            #expect(others.count == n + 1)
            #expect(others.allSatisfy { $0.author == "합성C" })
            // Time back-fill reaches cached rows above the new one (same as a full parse).
            #expect(read.snapshot.messages.map(\.id) == fullParse(file.root, title: file.window.title).map(\.id))
        }
    }

    @Test("transcript width change re-analyses every row")
    func widthChange() throws {
        let file = try Fixture.load("synthetic_group_basic")
        let world = FakeWorld()
        let root = FakeAXNode.load(file.root, into: world)
        let cache = Self.unlimitedCache(FakeAXNode.self)
        let first = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0)
        let narrower = file.root.modifyingFirst(role: AXRole.scrollArea) { sa in
            var s = sa
            if let f = sa.frame { s.rect = AXRectArray(CGRect(x: f.minX, y: f.minY, width: f.width - 40, height: f.height)) }
            return s
        }
        FakeAXNode.load(narrower, into: world)
        let second = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0 + .milliseconds(100))
        #expect(second.rowsAnalyzed == second.rowsTotal)
        #expect(second.rowsTotal == first.rowsTotal)
        let third = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0 + .milliseconds(200))
        #expect(third.rowsAnalyzed == 0)
    }

    @Test("lazy content: an empty row near the viewport is re-analysed at most every 2 s")
    func lazyContentRow() throws {
        let full = Self.smallChat().build(note: "")
        // Row 3 has not loaded its content yet: an empty cell.
        let lazy = Self.mapRow(full.root, 3) { row in
            var r = row
            r.children = [RecordedAXNode(role: AXRole.cell, frame: row.frame)]
            return r
        }
        let world = FakeWorld()
        let root = FakeAXNode.load(lazy, into: world)
        let cache = Self.unlimitedCache(FakeAXNode.self)
        let first = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0)
        #expect(first.snapshot.messages.count == 4)

        FakeAXNode.load(full.root, into: world) // content arrives
        let soon = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0 + .milliseconds(500))
        #expect(soon.rowsAnalyzed == 0)
        #expect(soon.snapshot.messages.count == 4)

        let later = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0 + .seconds(3))
        #expect(later.rowsAnalyzed == 1)
        #expect(later.snapshot.messages.count == 5)
        #expect(later.snapshot.messages.map(\.id) == fullParse(full.root, title: full.window.title).map(\.id))
    }

    @Test("an empty row far from the viewport is not re-analysed")
    func farEmptyRowStaysCached() throws {
        let file = try Fixture.load("synthetic_200rows")
        let world = FakeWorld()
        let root = FakeAXNode.load(file.root, into: world)
        let cache = Self.unlimitedCache(FakeAXNode.self)
        let first = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0)
        world.resetCounters()
        // Row 0 (a divider far above the viewport) stays cached; only the empty spacer row at the bottom of
        // the viewport is near enough to be retried.
        let second = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0 + .seconds(5))
        #expect(second.rowsAnalyzed == 1)
        #expect(world.childrenReads(under: "w/0/0/0") == 0)
        #expect(world.childrenReads(under: "w/0/0/\(first.rowsTotal - 1)") > 0)
        #expect(second.snapshot.messages.count == first.snapshot.messages.count)
    }

    @Test("visibleIDs are the messages a visible-only parse reports")
    func visibleIDs() throws {
        for name in ["synthetic_nested_offscreen", "synthetic_200rows", "selfchat_02_more_messages"] {
            let file = try Fixture.load(name)
            let world = FakeWorld()
            let root = FakeAXNode.load(file.root, into: world)
            let read = try KakaoChatReader.read(window: root.refreshed(), cache: Self.unlimitedCache(FakeAXNode.self),
                                                parser: TranscriptParser(referenceYear: file.recordedYear ?? 2026), now: t0)
            let visible = try #require(TranscriptParser(referenceYear: file.recordedYear ?? 2026).parse(window: file.root))
            let ours = read.snapshot.messages.filter { read.visibleIDs.contains($0.id) }
            #expect(ours.map(\.body) == visible.map(\.body), "\(name)")
            #expect(ours.map(\.frame) == visible.map(\.frame), "\(name)")
            #expect(read.snapshot.messages.count >= ours.count)
        }
        // Off-screen rows (above and below the viewport) are loaded but not visible.
        let file = try Fixture.load("synthetic_nested_offscreen")
        let root = FakeAXNode.load(file.root, into: FakeWorld())
        let read = try KakaoChatReader.read(window: root.refreshed(), cache: Self.unlimitedCache(FakeAXNode.self), parser: parser, now: t0)
        #expect(read.snapshot.messages.count > read.visibleIDs.count)
        #expect(read.snapshot.messages.last?.body == "넵 알겠습니다!")
        #expect(!read.visibleIDs.contains(try #require(read.snapshot.messages.last?.id)))
    }

    @Test("a recycled row element in the viewport is detected by its frame and re-analysed")
    func recycledRowElement() throws {
        // With the spacer row, the new message takes the spacer's index (same fake identity, new content).
        let before = Self.smallChat(spacer: true).build(note: "")
        let after = Self.smallChat(extra: true, spacer: true).build(note: "")
        let world = FakeWorld()
        let root = FakeAXNode.load(before.root, into: world)
        let cache = Self.unlimitedCache(FakeAXNode.self)
        _ = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0)
        FakeAXNode.load(after.root, into: world)
        let read = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0 + .milliseconds(200))
        #expect(read.rowsAnalyzed == 2) // the reused element + the new spacer
        #expect(read.snapshot.messages.map(\.id) == fullParse(after.root, title: after.window.title).map(\.id))
    }

    @Test("visible rows are refreshed after a while (edited / deleted messages)")
    func staleVisibleRowsRefresh() throws {
        let file = Self.smallChat().build(note: "")
        let edited = Self.mapRow(file.root, 4) { row in
            row.modifyingFirst(role: AXRole.textArea) { ta in
                var t = ta
                t.value = "삭제된 메시지입니다."
                return t
            }
        }
        let world = FakeWorld()
        let root = FakeAXNode.load(file.root, into: world)
        let cache = Self.unlimitedCache(FakeAXNode.self)
        _ = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0)
        FakeAXNode.load(edited, into: world)
        let soon = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0 + .seconds(1))
        #expect(soon.rowsAnalyzed == 0)
        #expect(soon.snapshot.messages.last?.body == "수고하셨습니다~")
        let later = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0 + .seconds(30))
        #expect(later.rowsAnalyzed == later.visibleIDs.count)
        #expect(later.snapshot.messages.last?.body == "삭제된 메시지입니다.")
    }

    @Test("window change and a drastically shrunk row list reset the cache")
    func resets() throws {
        let big = try Fixture.load("synthetic_200rows")
        let small = Self.smallChat().build(note: "")
        let world = FakeWorld()
        let cache = Self.unlimitedCache(FakeAXNode.self)
        let root = FakeAXNode.load(big.root, into: world)
        _ = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0)

        // Same window element, another chat: the row list shrinks from 205 to 5 rows.
        FakeAXNode.load(small.root, into: world)
        let switched = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0 + .seconds(1))
        #expect(switched.rowsAnalyzed == switched.rowsTotal)
        #expect(switched.snapshot.messages.map(\.id) == fullParse(small.root, title: small.window.title).map(\.id))

        // Another window element: everything is analysed again.
        let otherWorld = FakeWorld()
        let other = FakeAXNode(id: "w2", world: otherWorld, recorded: small.root)
        otherWorld.load(other)
        let moved = try KakaoChatReader.read(window: other.refreshed(), cache: cache, parser: parser, now: t0 + .seconds(2))
        #expect(moved.rowsAnalyzed == moved.rowsTotal)
    }

    @Test("an invalid cached table is located again")
    func relocate() throws {
        let file = try Fixture.load("synthetic_group_basic")
        let world = FakeWorld()
        let root = FakeAXNode.load(file.root, into: world)
        let cache = Self.unlimitedCache(FakeAXNode.self)
        let first = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0)
        // The table is now wrapped in a group: the cached table identity no longer is a table.
        let wrapped = file.root.modifyingFirst(role: AXRole.scrollArea) { sa in
            var s = sa
            s.children = [RecordedAXNode(role: AXRole.group, frame: sa.frame, children: sa.children)]
            return s
        }
        FakeAXNode.load(wrapped, into: world)
        let second = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser, now: t0 + .seconds(1))
        #expect(second.rowsAnalyzed == second.rowsTotal)
        #expect(second.snapshot.messages.map(\.id) == first.snapshot.messages.map(\.id))
    }

    @Test("snapshot keeps the newest maxRows messages")
    func capNewest() throws {
        let file = try Fixture.load("synthetic_200rows")
        let root = FakeAXNode.load(file.root, into: FakeWorld())
        let capped = TranscriptParser(referenceYear: 2026, maxRows: 12)
        let read = try KakaoChatReader.read(window: root.refreshed(), cache: Self.unlimitedCache(FakeAXNode.self), parser: capped, now: t0)
        let full = fullParse(file.root, title: file.window.title)
        #expect(read.snapshot.messages.count == 12)
        #expect(read.snapshot.messages.map(\.id) == Array(full.suffix(12)).map(\.id))
    }

    @Test("the cache also works on RecordedAXNode windows")
    func recordedNodes() throws {
        let file = try Fixture.load("selfchat_01_initial")
        let cache = Self.unlimitedCache(RecordedAXNode.self)
        let p = TranscriptParser(referenceYear: file.recordedYear ?? 2026)
        let a = try KakaoChatReader.read(window: file.root, cache: cache, parser: p, now: t0)
        let b = try KakaoChatReader.read(window: file.root, cache: cache, parser: p, now: t0 + .milliseconds(10))
        #expect(a.rowsAnalyzed == a.rowsTotal && a.rowsTotal > 0)
        #expect(b.rowsAnalyzed == 0)
        #expect(a.snapshot.messages.map(\.id) == b.snapshot.messages.map(\.id))
        #expect(a.title == file.window.title || a.title == file.root.title)
    }

    @Test("golden output is unchanged by the parser refactor")
    func goldenUnchanged() throws {
        let glossary = try Glossary.load(contentsOf: FixturePaths.glossary)
        let files = try FileManager.default.contentsOfDirectory(at: FixturePaths.snapshots, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "axjson" }
        #expect(files.count >= 10)
        for url in files {
            let name = url.deletingPathExtension().lastPathComponent
            let file = try AXSnapshotFile.load(contentsOf: url)
            let output = try ReplayRenderer.render(name: name, file: file, glossary: glossary) {
                MockEngine.translateSync($0, target: "zh-Hans")
            }
            let actual = try ReplayRenderer.encode(output)
            let expected = try Data(contentsOf: FixturePaths.golden.appendingPathComponent(name + ".json"))
            #expect(actual == expected, "\(name)")
        }
    }
}
