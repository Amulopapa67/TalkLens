// SPDX-License-Identifier: MIT
// Fixture paths and loaders for KakaoAX tests.

import Foundation
@testable import KakaoAX
import TalkLensCore

enum FixturePaths {
    /// Repository root (this file is Tests/TalkLensTests/KakaoAX/FixtureSupport.swift).
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let snapshots = root.appendingPathComponent("fixtures/snapshots", isDirectory: true)
    static let golden = root.appendingPathComponent("fixtures/golden", isDirectory: true)
    static let glossary = root.appendingPathComponent("fixtures/glossary.ko-zh.json")

    static func snapshot(_ name: String) -> URL { snapshots.appendingPathComponent(name + ".axjson") }
}

enum Fixture {
    static func load(_ name: String) throws -> AXSnapshotFile {
        try AXSnapshotFile.load(contentsOf: FixturePaths.snapshot(name))
    }

    /// Locate + parse a committed fixture (visible rows only, like the product).
    static func parse(_ name: String, visibleOnly: Bool = true) throws -> [ParsedMessage] {
        let file = try load(name)
        let parser = TranscriptParser(referenceYear: 2026, visibleOnly: visibleOnly)
        return parser.parse(window: file.root) ?? []
    }

    /// Non-system messages.
    static func nonSystem(_ messages: [ParsedMessage]) -> [ParsedMessage] { messages.filter { !$0.isSystem } }
}
