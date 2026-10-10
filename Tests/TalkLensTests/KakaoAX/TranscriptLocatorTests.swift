// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Testing
@testable import KakaoAX

@Suite("TranscriptLocatorTests")
struct TranscriptLocatorTests {
    @Test("locates the transcript scroll area and the input box", arguments: SyntheticFixtures.names)
    func locatesOnEveryFixture(name: String) throws {
        let file = try Fixture.load(name)
        let loc = try #require(TranscriptLocator.locate(inWindow: file.root))
        #expect(loc.transcriptRoot.role == AXRole.scrollArea)
        #expect(loc.transcriptRoot.identifier == "_NS:29")
        let input = try #require(loc.inputFrame)
        #expect(input.minY >= loc.transcriptRoot.frame!.maxY)
        #expect(input.width == 370)
        #expect(KakaoChatReader.isChatWindow(file.root))
    }

    @Test("the header search field is not taken as the message input")
    func ignoresSearchField() throws {
        let file = try Fixture.load("synthetic_group_basic")
        let scan = TranscriptLocator.scanWindow(file.root)
        #expect(scan.inputCandidates.contains { $0.role == AXRole.textField })
        let loc = try #require(TranscriptLocator.locate(inWindow: file.root))
        let input = try #require(loc.inputFrame)
        #expect(input.width == 370 && input.minY > loc.transcriptRoot.frame!.maxY)
    }

    @Test("message text areas inside rows are never input candidates")
    func skipsRowInterior() throws {
        let file = try Fixture.load("synthetic_200rows")
        let scan = TranscriptLocator.scanWindow(file.root)
        #expect(scan.inputCandidates.count == 1)
        #expect(scan.visited < 100)
    }

    @Test("a small nested scroll area (message bubble) scores below zero")
    func rejectsTinyScrollArea() {
        let window = CGRect(x: 566, y: 197, width: 380, height: 640)
        let input = CGRect(x: 576, y: 728, width: 370, height: 65)
        let bubble = RecordedAXNode(role: AXRole.scrollArea, frame: CGRect(x: 627, y: 400, width: 120, height: 34))
        #expect(TranscriptLocator.spatialScore(bubble, windowFrame: window, inputFrame: input) < 0)
        let transcript = RecordedAXNode(role: AXRole.scrollArea, frame: CGRect(x: 566, y: 285, width: 380, height: 432))
        #expect(TranscriptLocator.spatialScore(transcript, windowFrame: window, inputFrame: input) > 0)
    }

    @Test("main window (friends/chatrooms/more navigation) is not a chat window")
    func mainWindowIsNotChat() {
        // Shape of the redacted KakaoTalk 26.8.0 main window observation.
        let row = RecordedAXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 80, y: 100, width: 300, height: 60), children: [
            RecordedAXNode(role: AXRole.cell, frame: CGRect(x: 80, y: 100, width: 300, height: 60), children: [
                RecordedAXNode(role: AXRole.button, nodeDescription: "<text>", frame: CGRect(x: 88, y: 108, width: 44, height: 44)),
                RecordedAXNode(role: AXRole.staticText, value: "<text>", frame: CGRect(x: 140, y: 108, width: 100, height: 16)),
                RecordedAXNode(role: AXRole.staticText, identifier: "Count Label", value: "3", frame: CGRect(x: 340, y: 130, width: 20, height: 16)),
                RecordedAXNode(role: AXRole.scrollArea, frame: CGRect(x: 140, y: 128, width: 180, height: 20), children: [
                    RecordedAXNode(role: AXRole.textArea, value: "<text>", frame: CGRect(x: 140, y: 128, width: 180, height: 20)),
                ]),
            ]),
        ])
        let main = RecordedAXNode(role: AXRole.window, title: "KakaoTalk", frame: CGRect(x: 0, y: 0, width: 400, height: 700), children: [
            RecordedAXNode(role: AXRole.button, identifier: "friends", frame: CGRect(x: 10, y: 60, width: 40, height: 40)),
            RecordedAXNode(role: AXRole.button, identifier: "chatrooms", frame: CGRect(x: 10, y: 110, width: 40, height: 40)),
            RecordedAXNode(role: AXRole.button, identifier: "more", frame: CGRect(x: 10, y: 160, width: 40, height: 40)),
            RecordedAXNode(role: AXRole.scrollArea, identifier: "_NS:101", frame: CGRect(x: 80, y: 52, width: 320, height: 648), children: [
                RecordedAXNode(role: AXRole.table, frame: CGRect(x: 80, y: 52, width: 320, height: 1260), children: [row]),
            ]),
        ])
        #expect(KakaoChatReader.isMainWindow(main))
        #expect(!KakaoChatReader.isChatWindow(main))
        // Preview text areas inside chat-list rows are not input candidates either.
        #expect(TranscriptLocator.locate(inWindow: main) == nil)
    }

    @Test("a window without an input box has no transcript location")
    func noInput() {
        let w = RecordedAXNode(role: AXRole.window, title: "x", frame: CGRect(x: 0, y: 0, width: 400, height: 600), children: [
            RecordedAXNode(role: AXRole.scrollArea, frame: CGRect(x: 0, y: 40, width: 400, height: 500)),
        ])
        #expect(TranscriptLocator.locate(inWindow: w) == nil)
        #expect(!KakaoChatReader.isChatWindow(w))
    }

    @Test("a disabled text area is not an input")
    func disabledInput() {
        let w = RecordedAXNode(role: AXRole.window, title: "x", frame: CGRect(x: 0, y: 0, width: 400, height: 600), children: [
            RecordedAXNode(role: AXRole.scrollArea, frame: CGRect(x: 0, y: 40, width: 400, height: 460)),
            RecordedAXNode(role: AXRole.textArea, value: "", frame: CGRect(x: 10, y: 510, width: 380, height: 60), enabled: false),
        ])
        #expect(TranscriptLocator.locate(inWindow: w) == nil)
    }
}
