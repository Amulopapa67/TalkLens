// SPDX-License-Identifier: MIT
// RecordedAXNode JSON, the redacting snapshot encoder and the record policy (DevConfig gating).

import CoreGraphics
import Foundation
import Testing
@testable import KakaoAX
import TalkLensCore

@Suite("RecordingTests")
struct RecordingTests {
    @Test("RecordedAXNode JSON round-trip; nil attributes and empty children omitted")
    func roundTrip() throws {
        let node = RecordedAXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 1, y: 2.5, width: 3, height: 4), children: [
            RecordedAXNode(role: AXRole.textArea, value: "안녕", help: "2026. 10. 10.", enabled: false),
        ])
        let data = try JSONEncoder().encode(node)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"frame\":[1,2.5,3,4]"))
        #expect(!json.contains("title"))
        #expect(!json.contains("\"children\":[]"))
        let back = try JSONDecoder().decode(RecordedAXNode.self, from: data)
        #expect(back == node)
        #expect(back.frame == CGRect(x: 1, y: 2.5, width: 3, height: 4))
        #expect(back.children[0].isEnabled == false)
        #expect(back.nodeCount == 2)
    }

    @Test("decodes the architecture §8 shape (description key, explicit nulls)")
    func decodesDocShape() throws {
        let json = #"{"role":"AXScrollArea","subrole":null,"title":null,"value":null,"description":"d","help":null,"frame":[0,0,10,10],"children":[]}"#
        let n = try JSONDecoder().decode(RecordedAXNode.self, from: Data(json.utf8))
        #expect(n.nodeDescription == "d" && n.children.isEmpty && n.isEnabled)
    }

    @Test("snapshot file round-trip and recorded year")
    func snapshotFile() throws {
        let file = SyntheticFixtures.make("synthetic_group_basic")
        let back = try JSONDecoder().decode(AXSnapshotFile.self, from: try file.encoded())
        #expect(back.root == file.root)
        #expect(back.recordedYear == 2026)
        #expect(try file.encoded().last == 0x0A)
    }

    @Test("redacted recording never contains message text or the title")
    func redactedEncoderLeaksNothing() throws {
        let file = try Fixture.load("synthetic_multiline_long")
        let policy = RecordPolicy.decide(config: DevConfig(allowedTextChats: ["다른 방"]), windowTitle: file.window.title,
                                         requestedTitle: file.window.title)
        #expect(policy == .redacted)
        let result = AXSnapshotEncoder { policy.transform($0, $1) }.encode(file.root)
        let json = String(decoding: try JSONEncoder().encode(result.root), as: UTF8.self)
        for needle in ["합성B", "합성A", "합성C", "합성 연구실", "안녕하세요", "린루이", "카드"] {
            #expect(!json.contains(needle), "leaked \(needle)")
        }
        #expect(result.nodeCount == file.root.nodeCount)
        #expect(!result.truncated)
        // Structure (roles, frames) is preserved so the locator still works on redacted recordings.
        #expect(TranscriptLocator.locate(inWindow: result.root) != nil)
    }

    @Test("encoder honours depth and node limits")
    func encoderLimits() throws {
        let file = try Fixture.load("synthetic_200rows")
        let byNodes = AXSnapshotEncoder(maxDepth: 40, maxNodes: 50) { _, t in t }.encode(file.root)
        #expect(byNodes.nodeCount <= 50 && byNodes.truncated)
        let byDepth = AXSnapshotEncoder(maxDepth: 1, maxNodes: 8_000) { _, t in t }.encode(file.root)
        #expect(byDepth.truncated)
        #expect(byDepth.root.children.allSatisfy { $0.children.isEmpty })
    }

    @Test("raw text only for an allowlisted, explicitly requested, matching title")
    func policyGating() {
        let cfg = DevConfig(allowedTextChats: ["린루이"])
        #expect(RecordPolicy.decide(config: cfg, windowTitle: "린루이", requestedTitle: "린루이") == .selfChat(title: "린루이"))
        #expect(RecordPolicy.decide(config: cfg, windowTitle: "린루이", requestedTitle: nil) == .redacted)
        #expect(RecordPolicy.decide(config: cfg, windowTitle: "다른 방", requestedTitle: "린루이") == .redacted)
        #expect(RecordPolicy.decide(config: cfg, windowTitle: "다른 방", requestedTitle: "다른 방") == .redacted)
        #expect(RecordPolicy.decide(config: .empty, windowTitle: "린루이", requestedTitle: "린루이") == .redacted)
    }

    @Test("self-chat recording keeps text but never the real title")
    func selfChatPolicy() {
        let p = RecordPolicy.selfChat(title: "린루이")
        #expect(p.source == "self-chat" && p.storesRawText)
        #expect(p.storedWindowTitle("린루이") == "<self-chat>")
        #expect(p.transform(.title, "린루이") == "<self-chat>")
        #expect(p.transform(.value, "넵 알겠습니다!") == "넵 알겠습니다!")
        let r = RecordPolicy.redacted
        #expect(r.source == "redacted-live" && !r.storesRawText)
        #expect(r.transform(.value, "넵 알겠습니다!") != "넵 알겠습니다!")
    }

    @Test("identifiers go through the transform hook; structural ids survive redaction")
    func identifierTransform() throws {
        let leaf = RecordedAXNode(role: AXRole.staticText, identifier: "합성A 프로필", value: "x")
        let window = RecordedAXNode(role: AXRole.window, identifier: "_NS:443", children: [
            RecordedAXNode(role: AXRole.column, identifier: "AutomaticTableColumnIdentifier.0"),
            RecordedAXNode(role: AXRole.staticText, identifier: "Count Label", value: "1"),
            RecordedAXNode(role: AXRole.button, identifier: "chatrooms"),
            leaf,
        ])
        var seen: [AXTextAttribute] = []
        _ = AXSnapshotEncoder { attr, text in seen.append(attr); return text }.encode(window)
        #expect(seen.filter { $0 == .identifier }.count == 5)

        let redacted = AXSnapshotEncoder { RecordPolicy.redacted.transform($0, $1) }.encode(window).root
        #expect(redacted.identifier == "_NS:443")
        #expect(redacted.children.map(\.identifier) == ["AutomaticTableColumnIdentifier.0", "Count Label", "chatrooms",
                                                        "<text len=7 ko>"])
        let json = String(decoding: try JSONEncoder().encode(redacted), as: UTF8.self)
        #expect(!json.contains("합성A"))

        // Self-chat: identifiers are kept, except a verbatim title.
        let selfChat = RecordPolicy.selfChat(title: "합성A 프로필")
        #expect(selfChat.transform(.identifier, "_NS:51") == "_NS:51")
        #expect(selfChat.transform(.identifier, "합성A 프로필") == "<self-chat>")
    }
}
