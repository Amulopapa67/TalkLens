// SPDX-License-Identifier: MIT
// Shared helpers for TalkLensCore tests: repo-relative fixture paths and message builders.

import Foundation
@testable import TalkLensCore

enum CoreFixtures {
    /// Repo root, derived from this file's location (Tests/TalkLensTests/Core/CoreTestSupport.swift).
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Core
        .deletingLastPathComponent()  // TalkLensTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    static func url(_ relativePath: String) -> URL {
        repoRoot.appendingPathComponent(relativePath)
    }

    /// The starter glossary shipped in fixtures/.
    static let glossary: Glossary = {
        do {
            return try Glossary.load(contentsOf: url("fixtures/glossary.ko-zh.json"))
        } catch {
            fatalError("cannot load fixtures/glossary.ko-zh.json: \(error)")
        }
    }()

    /// Non-comment lines of fixtures/test_messages_ko.txt with the literal "\n" turned into line breaks.
    static func testMessages() -> [String] {
        guard let text = try? String(contentsOf: url("fixtures/test_messages_ko.txt"), encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.replacingOccurrences(of: "\\n", with: "\n") }
    }

    static func parsed(_ body: String, author: String? = "A", isMine: Bool = false, isSystem: Bool = false,
                       time: String? = "오후 3:12", date: String? = "2026-10-10") -> ParsedMessage {
        ParsedMessage(author: author, isMine: isMine, isSystem: isSystem, timeRaw: time, date: date, body: body)
    }

    static func message(_ body: String, isSystem: Bool = false, id: String = "m1") -> ChatMessage {
        ChatMessage(id: MessageID(id), parsed: parsed(body, isSystem: isSystem))
    }

    static func ids(_ names: [String]) -> [MessageID] { names.map(MessageID.init) }
}
