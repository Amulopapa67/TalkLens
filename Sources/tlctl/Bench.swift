// SPDX-License-Identifier: MIT
// `tlctl bench <dir> [--iterations 50]` — offline parse/diff timing against the budget (GOAL / verify G8).
// Parse is timed in the worst case (every row in the tree analysed, not only the visible ones).

import Foundation
import KakaoAX
import TalkLensCore

let parseBudgetMs = 30.0
let diffBudgetMs = 5.0

func runBench(arguments: [String]) -> Int32 {
    guard let args = parseArguments(arguments, command: "bench", values: ["--iterations"], flags: []) else { return ExitCode.fail }
    guard let input = args.positionals.first, args.positionals.count == 1 else {
        print("bench: expected exactly one <dir> argument (see `tlctl help`)")
        return ExitCode.fail
    }
    let iterations = max(1, args.int("--iterations") ?? 50)
    guard let files = snapshotFiles(at: input), !files.isEmpty else {
        print("bench: FAIL no .axjson snapshots at \(input)")
        return ExitCode.fail
    }

    var worstParseP95 = 0.0
    var worstDiffP95 = 0.0
    var maxRows = 0
    var failures: [String] = []

    for url in files {
        let name = url.deletingPathExtension().lastPathComponent
        guard let file = try? AXSnapshotFile.load(contentsOf: url) else {
            print("bench: \(name) FAIL cannot decode")
            failures.append(name)
            continue
        }
        let parser = TranscriptParser(referenceYear: file.recordedYear ?? 2026, maxRows: 400, visibleOnly: false)
        var parseSamples: [Double] = []
        parseSamples.reserveCapacity(iterations)
        var parsed: [ParsedMessage] = []
        var rows = 0
        var located = true
        for i in 0..<iterations {
            let w = Stopwatch()
            guard let loc = TranscriptLocator.locate(inWindow: file.root) else { located = false; break }
            let result = parser.parse(transcriptRoot: loc.transcriptRoot, inputFrame: loc.inputFrame)
            parseSamples.append(w.elapsedMilliseconds)
            if i == 0 {
                parsed = result
                rows = parser.collectRowCount(transcriptRoot: loc.transcriptRoot, inputFrame: loc.inputFrame)
            }
        }
        guard located else {
            print("bench: \(name) FAIL transcript not found")
            failures.append(name)
            continue
        }
        maxRows = max(maxRows, rows)

        let ids = MessageIdentity.assign(parsed, chatKey: MessageIdentity.chatKey(forTitle: file.window.title)).map(\.id)
        let k = max(1, ids.count / 10)
        let old = Array(ids.prefix(max(0, ids.count - k)))
        let new = Array(ids.suffix(max(0, ids.count - k)))
        var diffSamples: [Double] = []
        diffSamples.reserveCapacity(iterations)
        var sink = 0
        for _ in 0..<iterations {
            let w = Stopwatch()
            let d = TranscriptDiffer.diff(old: old, new: new)
            diffSamples.append(w.elapsedMilliseconds)
            sink &+= d.appended.count
        }
        _ = sink

        let ps = LatencyStats(parseSamples), ds = LatencyStats(diffSamples)
        worstParseP95 = max(worstParseP95, ps.p95)
        worstDiffP95 = max(worstDiffP95, ds.p95)
        let over = ps.p95 > parseBudgetMs || ds.p95 > diffBudgetMs
        if over { failures.append(name) }
        print("bench: \(name) rows=\(rows) messages=\(parsed.count) parse p50=\(formatMs(ps.p50))ms p95=\(formatMs(ps.p95))ms diff p50=\(formatMs(ds.p50))ms p95=\(formatMs(ds.p95))ms\(over ? " OVER BUDGET" : "")")
    }

    let summary = "parse p95=\(formatMs(worstParseP95))ms (≤\(Int(parseBudgetMs))) diff p95=\(formatMs(worstDiffP95))ms (≤\(Int(diffBudgetMs))) snapshots=\(files.count) maxRows=\(maxRows) iterations=\(iterations)"
    if !failures.isEmpty {
        print("bench: FAIL \(summary) failing=\(failures.joined(separator: ","))")
        return ExitCode.fail
    }
    print("bench: OK \(summary)")
    return ExitCode.ok
}
