// SPDX-License-Identifier: MIT
// tlctl helpers: argument parsing, replay rendering, golden diffs, chat reader on recorded windows.

import Foundation
import Testing
@testable import KakaoAX
import TalkLensCore
import TalkLensTranslate

@Suite("DevToolsTests")
struct DevToolsTests {
    @Test("argument parsing: positionals, values, flags, --key=value")
    func parseArgs() throws {
        let a = try CLIArguments.parse(["fixtures/snapshots", "--engine", "mock", "--golden=fixtures/golden", "--update-golden"],
                                       valueOptions: ["--engine", "--golden", "--glossary"], flags: ["--update-golden"])
        #expect(a.positionals == ["fixtures/snapshots"])
        #expect(a.options["--engine"] == "mock")
        #expect(a.options["--golden"] == "fixtures/golden")
        #expect(a.has("--update-golden"))
        let b = try CLIArguments.parse(["--iterations", "7"], valueOptions: ["--iterations"], flags: [])
        #expect(b.int("--iterations") == 7)
    }

    @Test("argument parsing errors")
    func parseArgErrors() {
        #expect(throws: CLIArguments.ParseError.unknownOption("--nope")) {
            try CLIArguments.parse(["--nope"], valueOptions: [], flags: [])
        }
        #expect(throws: CLIArguments.ParseError.missingValue("--out")) {
            try CLIArguments.parse(["--out"], valueOptions: ["--out"], flags: [])
        }
        #expect(throws: CLIArguments.ParseError.missingValue("--out")) {
            try CLIArguments.parse(["--out", "--show-text-for", "x"], valueOptions: ["--out", "--show-text-for"], flags: [])
        }
    }

    @Test("replay output: one object per message with explicit nulls, sorted keys, trailing newline")
    func replayShape() throws {
        let file = try Fixture.load("synthetic_group_basic")
        let out = try ReplayRenderer.render(name: "synthetic_group_basic", file: file, glossary: .empty) {
            MockEngine.translateSync($0, target: "zh-Hans")
        }
        #expect(out.messages.count == 7)
        let data = try ReplayRenderer.encode(out)
        #expect(data.last == 0x0A)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["snapshot"] as? String == "synthetic_group_basic")
        #expect(obj["source"] as? String == "synthetic")
        let msgs = try #require(obj["messages"] as? [[String: Any]])
        let keys: Set<String> = ["id", "author", "isMine", "isSystem", "timeRaw", "date", "body", "attachments", "kind",
                                 "chips", "note", "translation"]
        #expect(msgs.allSatisfy { Set($0.keys) == keys })
        let mine = try #require(msgs.first { $0["isMine"] as? Bool == true })
        #expect(mine["author"] is NSNull)
        let first = msgs[0]
        #expect(first["author"] as? String == "합성A")
        #expect((first["translation"] as? String)?.hasPrefix("[mock→zh-Hans] ") == true)
        // System rows are not translated.
        let sys = try ReplayRenderer.render(name: "s", file: try Fixture.load("synthetic_dividers_system"), glossary: .empty) { $0 }
        #expect(sys.messages.filter(\.isSystem).allSatisfy { $0.translation == nil && $0.kind == "system" })
        // Rendering twice gives identical bytes (golden stability).
        let again = try ReplayRenderer.encode(try ReplayRenderer.render(name: "synthetic_group_basic", file: file, glossary: .empty) {
            MockEngine.translateSync($0, target: "zh-Hans")
        })
        #expect(again == data)
    }

    @Test("replay of a window without a transcript throws")
    func replayNoTranscript() {
        let file = AXSnapshotFile(meta: .init(source: "synthetic"), window: .init(title: "x", frame: nil),
                                  root: RecordedAXNode(role: AXRole.window))
        #expect(throws: ReplayError.transcriptNotFound) {
            try ReplayRenderer.render(name: "x", file: file, glossary: .empty) { $0 }
        }
    }

    @Test("golden diff excerpt")
    func goldenDiff() {
        #expect(GoldenDiff.firstDifferences(expected: "a\nb\nc", actual: "a\nb\nc").isEmpty)
        let d = GoldenDiff.firstDifferences(expected: "a\nb\nc\nd", actual: "a\nb\nX\nd")
        #expect(d == ["@@ line 3 @@", "  a", "  b", "- c", "+ X"])
        let added = GoldenDiff.firstDifferences(expected: "a\nb", actual: "a\nb\nc")
        #expect(added.last == "+ c")
    }

    @Test("chat reader on a recorded window assigns stable ids per chat")
    func chatReaderRecorded() throws {
        let file = try Fixture.load("synthetic_mine_continuation")
        let parser = TranscriptParser(referenceYear: 2026)
        let a = try KakaoChatReader.read(windowNode: file.root, parser: parser)
        let b = try KakaoChatReader.read(windowNode: file.root, parser: parser)
        #expect(a.title == "합성 1:1 대화")
        #expect(a.snapshot.chatKey == MessageIdentity.chatKey(forTitle: "합성 1:1 대화"))
        #expect(a.snapshot.messages.map(\.id) == b.snapshot.messages.map(\.id))
        #expect(a.snapshot.messages.count == 10)
        #expect(a.inputFrame != nil && a.windowFrame != nil)
        #expect(throws: KakaoReadError.transcriptNotFound) {
            try KakaoChatReader.read(windowNode: RecordedAXNode(role: AXRole.window), parser: parser)
        }
    }

    @Test("probe tags: keyed per run, 6 hex chars, not the plain short SHA-256")
    func runScopedTags() {
        let a = RunScopedTagger()
        let b = RunScopedTagger()
        let names = ["합성A", "합성B", "합성C", "합성D", "합성E", "합성F"]
        for n in names {
            let t = a.tag(n)
            #expect(t.count == 6 && t.allSatisfy { $0.isHexDigit })
            #expect(t == a.tag(n))                          // stable within a run
            #expect(t != Redactor.shortHash(n))             // not dictionary-reversible via plain SHA-256
        }
        // Different random keys give different tags (6 names: a full collision is ~2^-144).
        #expect(names.map(a.tag) != names.map(b.tag))
        // A fixed key is deterministic (HMAC-SHA256 test vector prefix, RFC 4231 case 2).
        let fixed = RunScopedTagger(key: Data("Jefe".utf8))
        #expect(fixed.tag("what do ya want for nothing?") == "5bdcc1")
    }
}
