// SPDX-License-Identifier: MIT
// Read-only chats (KakaoTalk Channel / business notification accounts) have no message input box; a static
// notice sits where the input would be (observed on 26.8.0, D-021). The transcript must still be found.

import CoreGraphics
import Foundation
import Testing
@testable import KakaoAX
import TalkLensCore

@Suite("KakaoAX.InputlessWindow")
struct InputlessWindowTests {
    /// The synthetic chat window with its input scroll area replaced by a static notice.
    static func inputless(_ name: String) throws -> RecordedAXNode {
        var window = try Fixture.load(name).root
        window.children = window.children.map { child in
            let isInput = child.role == AXRole.scrollArea && child.children.contains { $0.role == AXRole.textArea }
            guard isInput else { return child }
            return RecordedAXNode(role: AXRole.staticText, value: "합성 안내 문구", frame: child.frame)
        }
        window.children.removeAll { $0.role == AXRole.textArea || $0.role == AXRole.textField }
        return window
    }

    @Test("locator finds the transcript without an input box")
    func locatesTranscript() throws {
        let window = try Self.inputless("synthetic_group_basic")
        let loc = try #require(TranscriptLocator.locate(inWindow: window))
        #expect(loc.inputFrame == nil)
        #expect(loc.input == nil)
        #expect(loc.transcriptRoot.role == AXRole.scrollArea)
        #expect(KakaoChatReader.isChatWindow(window))
    }

    @Test("messages are parsed the same as with an input box")
    func parsesMessages() throws {
        let file = try Fixture.load("synthetic_group_basic")
        let parser = TranscriptParser(referenceYear: 2026)
        let withInput = parser.parse(window: file.root) ?? []
        let without = parser.parse(window: try Self.inputless("synthetic_group_basic")) ?? []
        #expect(!without.isEmpty)
        #expect(without.map(\.body) == withInput.map(\.body))
    }

    @Test("incremental reads keep the input-less location cached")
    func incrementalCachesLocation() throws {
        let window = try Self.inputless("synthetic_group_basic")
        let world = FakeWorld()
        let root = FakeAXNode.load(window, into: world)
        let cache = TranscriptRowCache<FakeAXNode>()
        let parser = TranscriptParser(referenceYear: 2026)
        let first = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser)
        #expect(!first.snapshot.messages.isEmpty)
        #expect(first.inputFrame == nil)
        let second = try KakaoChatReader.read(window: root.refreshed(), cache: cache, parser: parser)
        #expect(second.rowsAnalyzed == 0)
        #expect(second.snapshot.messages.map(\.id) == first.snapshot.messages.map(\.id))
    }

    @Test("the main window is still not a chat window")
    func mainWindowRejected() {
        let main = RecordedAXNode(role: AXRole.window, title: "KakaoTalk",
                                  frame: CGRect(x: 0, y: 0, width: 480, height: 740), children: [
            RecordedAXNode(role: AXRole.button, identifier: "friends"),
            RecordedAXNode(role: AXRole.button, identifier: "chatrooms"),
            RecordedAXNode(role: AXRole.scrollArea, frame: CGRect(x: 80, y: 90, width: 400, height: 640), children: [
                RecordedAXNode(role: AXRole.table, frame: CGRect(x: 80, y: 90, width: 400, height: 640)),
            ]),
        ])
        #expect(!KakaoChatReader.isChatWindow(main))
    }
}
