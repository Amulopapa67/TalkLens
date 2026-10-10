// SPDX-License-Identifier: MIT
// Shapes seen on real KakaoTalk 26.8.0 windows through redacted recordings (all text replaced by placeholders).

import CoreGraphics
import Foundation
import Testing
@testable import KakaoAX

@Suite("ObservedShapeTests")
struct ObservedShapeTests {
    /// An empty chat window: the table holds one 15 pt empty row and an AXColumn.
    static func emptyChatWindow() -> RecordedAXNode {
        RecordedAXNode(role: AXRole.window, subrole: "AXStandardWindow", identifier: "_NS:443", title: "<title>",
                       frame: CGRect(x: 566, y: 197, width: 380, height: 640), children: [
            RecordedAXNode(role: AXRole.scrollArea, identifier: "_NS:29", frame: CGRect(x: 566, y: 285, width: 380, height: 432), children: [
                RecordedAXNode(role: AXRole.table, identifier: "_NS:33", frame: CGRect(x: 565, y: 284, width: 382, height: 434), children: [
                    RecordedAXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 566, y: 285, width: 380, height: 15), children: [
                        RecordedAXNode(role: AXRole.cell, frame: CGRect(x: 566, y: 285, width: 380, height: 15)),
                    ]),
                    RecordedAXNode(role: AXRole.column, identifier: "AutomaticTableColumnIdentifier.0",
                                   frame: CGRect(x: 566, y: 285, width: 380, height: 432)),
                ]),
            ]),
            RecordedAXNode(role: AXRole.button, identifier: "_NS:164", nodeDescription: "<text>", frame: CGRect(x: 580, y: 235, width: 40, height: 40)),
            RecordedAXNode(role: AXRole.staticText, identifier: "_NS:144", value: "<text>", frame: CGRect(x: 631, y: 244.5, width: 45.5, height: 21)),
            RecordedAXNode(role: "AXSlider", identifier: "_NS:182", frame: CGRect(x: 875, y: 202, width: 62, height: 18)),
            RecordedAXNode(role: AXRole.scrollArea, identifier: "_NS:47", frame: CGRect(x: 576, y: 728, width: 370, height: 65), children: [
                RecordedAXNode(role: AXRole.textArea, identifier: "_NS:51", value: "", nodeDescription: "<text>",
                               frame: CGRect(x: 576, y: 728, width: 370, height: 65)),
            ]),
            RecordedAXNode(role: AXRole.button, title: "<text>", frame: CGRect(x: 877, y: 798, width: 62, height: 32), enabled: false),
            RecordedAXNode(role: AXRole.button, subrole: "AXCloseButton", frame: CGRect(x: 574, y: 205, width: 16, height: 16)),
        ])
    }

    @Test("observed empty chat window: located as a chat window, zero messages")
    func emptyChat() throws {
        let w = Self.emptyChatWindow()
        let loc = try #require(TranscriptLocator.locate(inWindow: w))
        #expect(loc.transcriptRoot.identifier == "_NS:29")
        #expect(loc.inputFrame == CGRect(x: 576, y: 728, width: 370, height: 65))
        #expect(KakaoChatReader.isChatWindow(w))
        #expect(TranscriptParser(referenceYear: 2026).parse(window: w) == [])
    }

    /// Observed self-chat rows (frames as recorded, text replaced by placeholders): a text-less divider button,
    /// four wide bubbles without time labels, two short bubbles with time labels left of them, a spacer row.
    static func selfChatWindow() -> RecordedAXNode {
        func row(_ y: Double, _ h: Double, _ kids: [RecordedAXNode]) -> RecordedAXNode {
            let r = CGRect(x: 566, y: y, width: 380, height: h)
            return RecordedAXNode(role: AXRole.row, subrole: "AXTableRow", frame: r,
                                  children: [RecordedAXNode(role: AXRole.cell, frame: r, children: kids)])
        }
        func bubble(_ img: CGRect, _ text: CGRect, _ body: String) -> [RecordedAXNode] {
            [RecordedAXNode(role: AXRole.image, frame: img), RecordedAXNode(role: AXRole.textArea, value: body, frame: text)]
        }
        let rows = [
            row(285, 36, [RecordedAXNode(role: AXRole.button, title: "", nodeDescription: "", frame: CGRect(x: 656, y: 294, width: 200, height: 28))]),
            row(321, 41, bubble(CGRect(x: 650, y: 331, width: 286, height: 31), CGRect(x: 655, y: 339, width: 273, height: 16), "<a>")),
            row(362, 52, bubble(CGRect(x: 644, y: 367, width: 292, height: 47), CGRect(x: 649, y: 375, width: 279, height: 32), "<b>")),
            row(414, 100, bubble(CGRect(x: 651, y: 419, width: 285, height: 95), CGRect(x: 656, y: 427, width: 272, height: 80), "<c>")),
            row(514, 52, bubble(CGRect(x: 649, y: 519, width: 287, height: 47), CGRect(x: 654, y: 527, width: 274, height: 32), "<d>")),
            row(566, 36, [RecordedAXNode(role: AXRole.staticText, value: "오후 1:23", help: "2026. 10. 10.", frame: CGRect(x: 817, y: 587, width: 43, height: 16))]
                + bubble(CGRect(x: 864, y: 571, width: 72, height: 31), CGRect(x: 869, y: 579, width: 59, height: 16), "<e>")),
            row(602, 41, [RecordedAXNode(role: AXRole.staticText, value: "오후 1:24", help: "2026. 10. 10.", frame: CGRect(x: 826.5, y: 628, width: 44.5, height: 16))]
                + bubble(CGRect(x: 875, y: 612, width: 61, height: 31), CGRect(x: 880, y: 620, width: 48, height: 16), "<f>")),
            row(643, 15, []),
        ]
        var w = emptyChatWindow()
        w.children[0].children[0].children = rows + [w.children[0].children[0].children.last!]
        return w
    }

    @Test("observed self-chat rows: all mine, bubble images are not attachments, group time filled backward")
    func selfChatRows() throws {
        let m = try #require(TranscriptParser(referenceYear: 2026).parse(window: Self.selfChatWindow()))
        #expect(m.map(\.body) == ["<a>", "<b>", "<c>", "<d>", "<e>", "<f>"])
        #expect(m.allSatisfy { $0.isMine && $0.author == nil && !$0.isSystem })
        #expect(m.allSatisfy { $0.attachments.isEmpty })
        #expect(m.prefix(5).allSatisfy { $0.timeRaw == "오후 1:23" })
        #expect(m[5].timeRaw == "오후 1:24")
        #expect(m.allSatisfy { $0.date == "2026-10-10" })
    }
}
