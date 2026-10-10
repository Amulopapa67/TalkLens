// SPDX-License-Identifier: MIT
// `tlctl record --out F.axjson [--show-text-for TITLE]` — live, read-only.
// Raw text is stored only for an allowlisted self-chat (.lens-dev.json); the real title is never stored.

import Foundation
import KakaoAX
import TalkLensCore

func runRecord(arguments: [String]) -> Int32 {
    guard let args = parseArguments(arguments, command: "record", values: ["--out", "--show-text-for"], flags: []) else {
        return ExitCode.fail
    }
    guard let out = args.options["--out"], !out.isEmpty else {
        print("record: --out F.axjson is required (see `tlctl help`)")
        return ExitCode.fail
    }
    if let reason = livePreconditionSkipReason() {
        print("record: SKIP \(reason)")
        return ExitCode.skip
    }
    guard let app = KakaoProcess.applicationNode(), let window = KakaoChatReader.currentChatWindow(app: app) else {
        print("record: SKIP no open chat window (open a chat in KakaoTalk)")
        return ExitCode.skip
    }

    let title = window.title ?? ""
    let config = DevConfig.load(inDirectory: currentDirectoryURL)
    let policy = RecordPolicy.decide(config: config, windowTitle: title, requestedTitle: args.options["--show-text-for"])
    if args.options["--show-text-for"] != nil, !policy.storesRawText {
        print("record: warning: --show-text-for does not match the current window title or is not in .lens-dev.json allowed_text_chats; recording redacted")
    }

    let watch = Stopwatch()
    let encoder = AXSnapshotEncoder(maxDepth: 40, maxNodes: 8_000) { attr, text in policy.transform(attr, text) }
    let result = encoder.encode(window)
    var root = result.root
    root.title = policy.storedWindowTitle(title)

    let iso = ISO8601DateFormatter()
    let file = AXSnapshotFile(
        meta: .init(source: policy.source, kakaoVersion: KakaoProcess.version, macOS: macOSVersionString(),
                    recordedAt: iso.string(from: Date()),
                    note: result.truncated ? "truncated at depth 40 / 8000 nodes" : nil),
        window: .init(title: policy.storedWindowTitle(title), frame: window.frame.map(AXRectArray.init)),
        root: root)
    do {
        let url = URL(fileURLWithPath: out)
        try file.encoded(pretty: true).write(to: url, options: .atomic)
    } catch {
        print("record: FAIL could not write \(out): \(error.localizedDescription)")
        return ExitCode.fail
    }
    if !policy.storesRawText {
        print("record: warning: this is a REDACTED live recording (source=redacted-live); never commit it to fixtures/snapshots")
    }
    print("record: OK source=\(policy.source) nodes=\(result.nodeCount) truncated=\(result.truncated) elapsed=\(formatMs(watch.elapsedMilliseconds))ms out=\(out)")
    return ExitCode.ok
}
