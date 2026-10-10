// SPDX-License-Identifier: MIT
// Geometry the inline overlay needs from the parser: bubble frames, a margin around the viewport, and the
// viewport / table frames of a read. None of it may change message identity or replay output.

import CoreGraphics
import Foundation
import Testing
@testable import KakaoAX
import TalkLensCore

@Suite("InlineGeometryParserTests")
struct InlineGeometryParserTests {
    @Test("text bubbles report the enclosing bubble image; other rows fall back to the body frame")
    func bubbleFrames() throws {
        var c = SyntheticChat(title: "합성 말풍선")
        c.other("합성A", .text("내일 랩미팅은 오후 2시입니다."), time: "오후 3:12", help: "2026. 10. 10.")
        c.mine(.text("넵 알겠습니다!"), time: "오후 3:13", help: "2026. 10. 10.")
        c.other("합성B", .image(CGSize(width: 120, height: 90)), time: "오후 3:14")
        let m = TranscriptParser(referenceYear: 2026).parse(window: c.build(note: "").root) ?? []
        #expect(m.count == 3)
        for msg in m.prefix(2) {
            let body = try #require(msg.frame?.cgRect)
            let bubble = try #require(msg.bubbleFrame?.cgRect)
            // Observed insets: bubble = text area grown by 5 left, 8 right, 8 top, 7 bottom.
            #expect(bubble == CGRect(x: body.minX - 5, y: body.minY - 8, width: body.width + 13, height: body.height + 15))
        }
        // The image row has no bubble background: same as its content frame.
        #expect(m[2].bubbleFrame == m[2].frame)
        #expect(m[2].bubbleFrame != nil)
    }

    @Test("observed self-chat rows: bubble frames as recorded")
    func observedBubbles() throws {
        let m = TranscriptParser(referenceYear: 2026).parse(window: ObservedShapeTests.selfChatWindow()) ?? []
        let first = try #require(m.first { !$0.isSystem })
        #expect(first.frame == AXRect(x: 655, y: 339, width: 273, height: 16))
        #expect(first.bubbleFrame == AXRect(x: 650, y: 331, width: 286, height: 31))
    }

    @Test("bubble frames never change identities or replay output", arguments: ["synthetic_group_basic", "selfchat_01_initial"])
    func identityIgnoresGeometry(name: String) throws {
        let parsed = try Fixture.parse(name)
        var stripped = parsed
        for i in stripped.indices {
            stripped[i].frame = nil
            stripped[i].bubbleFrame = nil
        }
        let key = MessageIdentity.chatKey(forTitle: "t")
        #expect(MessageIdentity.assign(parsed, chatKey: key).map(\.id) == MessageIdentity.assign(stripped, chatKey: key).map(\.id))
        let file = try Fixture.load(name)
        let rendered = try ReplayRenderer.render(name: name, file: file, glossary: Glossary(entries: [])) { $0 }
        let json = String(decoding: try ReplayRenderer.encode(rendered), as: UTF8.self)
        #expect(!json.contains("bubble") && !json.contains("frame"))
    }

    @Test("visibleMargin 0 is the default visible-only parse", arguments: ["synthetic_200rows", "synthetic_nested_offscreen"])
    func zeroMarginIsDefault(name: String) throws {
        let file = try Fixture.load(name)
        let a = TranscriptParser(referenceYear: 2026).parse(window: file.root)
        let b = TranscriptParser(referenceYear: 2026, visibleMargin: 0).parse(window: file.root)
        #expect(a == b)
    }

    @Test("a viewport-height margin adds the rows just above the viewport, as a contiguous run with the same ids")
    func marginAbove() throws {
        let file = try Fixture.load("synthetic_200rows")
        let loc = try #require(TranscriptLocator.locate(inWindow: file.root))
        let viewport = try #require(loc.transcriptRoot.frame)
        let visible = TranscriptParser(referenceYear: 2026).parse(window: file.root) ?? []
        let wide = TranscriptParser(referenceYear: 2026, visibleMargin: viewport.height).parse(window: file.root) ?? []
        let uncut = TranscriptParser(referenceYear: 2026, visibleOnly: false).parse(window: file.root) ?? []
        #expect(wide.count > visible.count && wide.count < uncut.count)
        // Every emitted row lies within the grown band; the visible rows are a contiguous slice of it.
        let band = viewport.insetBy(dx: 0, dy: -viewport.height)
        #expect(wide.allSatisfy { m in m.bubbleFrame.map { $0.cgRect.intersects(band) } ?? true })
        let start = try #require(wide.firstIndex { $0.frame == visible.first?.frame })
        #expect(Array(wide[start..<(start + visible.count)]) == visible)
        // Same identities for the rows both parses emit (context rows keep author/time/date stable).
        let key = MessageIdentity.chatKey(forTitle: file.window.title)
        let visibleIDs = MessageIdentity.assign(visible, chatKey: key).map(\.id)
        let wideIDs = Set(MessageIdentity.assign(wide, chatKey: key).map(\.id))
        #expect(visibleIDs.allSatisfy { wideIDs.contains($0) })
    }

    @Test("rows scrolled out below the viewport (under the input box) are emitted within the margin")
    func marginBelow() throws {
        var c = SyntheticChat(title: "합성 아래쪽", options: .init(bottomAnchorRow: 3, spacerRow: false))
        c.other("합성A", .text("첫 번째 메시지입니다"))
        c.other(nil, .text("두 번째 메시지입니다"))
        c.mine(.text("세 번째 메시지입니다"))
        c.other("합성B", .text("네 번째 메시지입니다"))
        c.mine(.text("아래로 스크롤된 메시지 하나"))
        c.mine(.text("아래로 스크롤된 메시지 둘"))
        let root = c.build(note: "").root
        let visible = TranscriptParser(referenceYear: 2026).parse(window: root) ?? []
        #expect(!visible.contains { $0.body.hasPrefix("아래로") })
        let wide = TranscriptParser(referenceYear: 2026, visibleMargin: c.transcript.height).parse(window: root) ?? []
        #expect(wide.filter { $0.body.hasPrefix("아래로") }.count == 2)
        #expect(Array(wide.prefix(visible.count)) == visible)
        // Rows that are far below (more than the margin) are still cut off.
        let narrow = TranscriptParser(referenceYear: 2026, visibleMargin: 10).parse(window: root) ?? []
        #expect(!narrow.contains { $0.body.hasPrefix("아래로") })
    }

    @Test("a read reports the transcript viewport and the table frame")
    func readFrames() throws {
        let file = try Fixture.load("synthetic_200rows")
        let read = try KakaoChatReader.read(windowNode: file.root, parser: TranscriptParser(referenceYear: 2026))
        let viewport = try #require(read.transcriptFrame)
        let table = try #require(read.tableFrame)
        #expect(viewport == CGRect(x: 566, y: 285, width: 380, height: 432))
        // 200 rows: the table (document bounds) is far taller than the viewport and starts above it.
        #expect(table.height > viewport.height && table.minY < viewport.minY)
        #expect(InlineLayout.usesTableAnchor(tableFrame: table, viewport: viewport))
        // The observed empty chat window: table ≈ viewport (1 pt larger on each side).
        let empty = try KakaoChatReader.read(windowNode: ObservedShapeTests.emptyChatWindow())
        #expect(empty.tableFrame == CGRect(x: 565, y: 284, width: 382, height: 434))
        #expect(empty.transcriptFrame == CGRect(x: 566, y: 285, width: 380, height: 432))
    }
}
