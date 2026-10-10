// SPDX-License-Identifier: MIT
// The committed synthetic fixtures must equal what SyntheticFixtureBuilder produces.
// Regenerate with:  TALKLENS_WRITE_FIXTURES=1 swift test --filter SyntheticFixtureTests

import Foundation
import Testing
@testable import KakaoAX

@Suite("SyntheticFixtureTests")
struct SyntheticFixtureTests {
    @Test("committed synthetic fixtures match the builder", arguments: SyntheticFixtures.names)
    func committedMatchesBuilder(name: String) throws {
        let built = SyntheticFixtures.make(name)
        if ProcessInfo.processInfo.environment["TALKLENS_WRITE_FIXTURES"] == "1" {
            try FileManager.default.createDirectory(at: FixturePaths.snapshots, withIntermediateDirectories: true)
            try built.encoded(pretty: name != "synthetic_200rows").write(to: FixturePaths.snapshot(name), options: .atomic)
        }
        let committed = try Fixture.load(name)
        #expect(committed.meta == built.meta)
        #expect(committed.window == built.window)
        #expect(committed.root == built.root)
        #expect(committed.meta.source == "synthetic")
    }

    @Test("no fixture claims to be a self-chat recording")
    func noSelfChatFixtures() throws {
        let files = try FileManager.default.contentsOfDirectory(at: FixturePaths.snapshots, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "axjson" }
        #expect(files.count >= 6)
        for f in files where f.lastPathComponent.hasPrefix("synthetic_") {
            #expect(try AXSnapshotFile.load(contentsOf: f).meta.source == "synthetic")
        }
    }

    @Test("the 200-row fixture has at least 200 message rows")
    func largeFixtureSize() throws {
        let file = try Fixture.load("synthetic_200rows")
        let rows = AXTree.findAll(in: file.root, maxNodes: 20_000) { $0.role == AXRole.row }
        #expect(rows.count >= 204)
        let all = try Fixture.parse("synthetic_200rows", visibleOnly: false)
        #expect(Fixture.nonSystem(all).count == 200)
        #expect(all.filter(\.isSystem).count == 4)
    }
}
