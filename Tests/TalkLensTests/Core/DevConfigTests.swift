// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import TalkLensCore

@Suite struct DevConfigTests {
    @Test func loadIgnoresPlaceholdersAndEmptyEntries() throws {
        let json = #"{"allowed_text_chats": ["<your self-chat window title>", "", "Self Chat"]}"#
        let cfg = try DevConfig.load(from: Data(json.utf8))
        #expect(cfg.allowedTextChats == ["Self Chat"])
    }

    @Test func missingKeyMeansEmptyAllowlist() throws {
        let cfg = try DevConfig.load(from: Data(#"{"_comment": "x"}"#.utf8))
        #expect(cfg == .empty)
    }

    @Test func invalidJSONThrows() {
        #expect(throws: (any Error).self) { try DevConfig.load(from: Data("not json".utf8)) }
    }

    @Test func exampleFileYieldsEmptyAllowlist() throws {
        let data = try Data(contentsOf: CoreFixtures.url(".lens-dev.example.json"))
        #expect(try DevConfig.load(from: data) == .empty)
    }

    @Test func loadInDirectoryFallsBackToEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tl-devcfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(DevConfig.load(inDirectory: dir) == .empty)
        try Data(#"{"allowed_text_chats": ["Me"]}"#.utf8).write(to: dir.appendingPathComponent(".lens-dev.json"))
        #expect(DevConfig.load(inDirectory: dir).allowedTextChats == ["Me"])
        try Data("{broken".utf8).write(to: dir.appendingPathComponent(".lens-dev.json"))
        #expect(DevConfig.load(inDirectory: dir) == .empty)
    }

    @Test func allowsTextRequiresExactAllowlistedMatch() {
        let cfg = DevConfig(allowedTextChats: ["Me"])
        #expect(cfg.allowsText(windowTitle: "Me", requested: "Me"))
        #expect(!cfg.allowsText(windowTitle: "Me 2", requested: "Me"))       // window title differs
        #expect(!cfg.allowsText(windowTitle: "Other", requested: "Other"))   // not allowlisted
        #expect(!cfg.allowsText(windowTitle: "Me", requested: nil))
        #expect(!cfg.allowsText(windowTitle: "Me", requested: ""))
        #expect(!DevConfig.empty.allowsText(windowTitle: "Me", requested: "Me"))
    }
}
