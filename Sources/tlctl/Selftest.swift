// SPDX-License-Identifier: MIT
// `tlctl selftest --engine apple|mock --source ko --target zh-Hans --input F [--batch]` (docs/architecture.md §7).
// Input lines are synthetic test sentences, so printing source and translation is allowed here.
// Exit codes: 0 OK, 3 SKIP (reason — fix on the last line), 1 FAIL.

import Foundation
import Synchronization
import TalkLensCore
import TalkLensTranslate

/// Returns the process exit code: 0 OK, 3 SKIP (reason printed), 1 FAIL.
func runSelftest(arguments: [String]) async -> Int32 {
    let options: SelftestOptions
    do {
        options = try SelftestOptions.parse(arguments)
    } catch {
        print(SelftestOptions.usage)
        print("selftest: FAIL: \(error)")
        return 1
    }
    let result = await raceTimeout(seconds: options.timeoutSeconds) {
        await selftestBody(options)
    }
    guard let code = result else {
        print("selftest: FAIL: timed out after \(Int(options.timeoutSeconds)) s")
        return 1
    }
    return code
}

private func selftestBody(_ o: SelftestOptions) async -> Int32 {
    let engine: any TranslationEngine = o.engine == "mock" ? MockEngine() : AppleTranslationEngine()
    let source = Locale.Language(identifier: o.source)
    let target = Locale.Language(identifier: o.target)

    let contents: String
    do {
        contents = try String(contentsOfFile: o.input, encoding: .utf8)
    } catch {
        print("selftest: FAIL: cannot read input file \(o.input)")
        return 1
    }
    let lines = SelftestSupport.parseInput(contents)
    guard !lines.isEmpty else {
        print("selftest: FAIL: no test sentences in \(o.input)")
        return 1
    }
    print("selftest: engine=\(engine.id) \(o.source)→\(o.target) lines=\(lines.count) input=\(o.input)")

    let status = await engine.status(source: source, target: target)
    if let skip = SelftestSupport.skipLine(for: status, source: o.source, target: o.target) {
        print(skip)
        return 3
    }

    var samples: [Double] = []
    if !o.batchOnly {
        for (i, line) in lines.enumerated() {
            let item = TranslationItem(id: "line-\(i + 1)", text: line)
            let watch = Stopwatch()
            do {
                let results = try await engine.translate([item], source: source, target: target)
                let ms = watch.elapsedMilliseconds
                guard let text = results.first(where: { $0.id == item.id })?.text else {
                    print("selftest: FAIL: line \(i + 1): missing result")
                    return 1
                }
                samples.append(ms)
                print(String(format: "[%d] ", i + 1) + SelftestSupport.oneLine(line) + " → "
                      + SelftestSupport.oneLine(text) + String(format: " (%.1f ms)", ms))
            } catch {
                return failure(error, context: "line \(i + 1)", options: o)
            }
        }
    }

    let items = lines.enumerated().map { TranslationItem(id: "line-\($0.offset + 1)", text: $0.element) }
    let batchWatch = Stopwatch()
    let batchResults: [TranslationResult]
    do {
        batchResults = try await engine.translate(items, source: source, target: target)
    } catch {
        return failure(error, context: "batch", options: o)
    }
    let batchMs = batchWatch.elapsedMilliseconds
    let byID = Dictionary(batchResults.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
    let translated = items.filter { byID[$0.id] != nil }.count
    print(String(format: "batch: %d/%d items in %.1f ms", translated, items.count, batchMs))
    if o.batchOnly {
        for (i, item) in items.enumerated() {
            print(String(format: "[%d] ", i + 1) + SelftestSupport.oneLine(item.text) + " → "
                  + SelftestSupport.oneLine(byID[item.id] ?? "<missing>"))
        }
        samples = Array(repeating: batchMs / Double(items.count), count: items.count)
    }
    guard translated == items.count else {
        print("selftest: FAIL: batch returned \(translated)/\(items.count) results")
        return 1
    }

    let stats = LatencyStats(samples)
    print(SelftestSupport.okLine(translated: o.batchOnly ? translated : samples.count, total: lines.count,
                                 p50: stats.p50, p95: stats.p95, batchMilliseconds: batchMs,
                                 engine: engine.id, source: o.source, target: o.target))
    return 0
}

/// Maps a thrown error to the final line and exit code. `notInstalled` is a SKIP; everything else FAILs.
private func failure(_ error: any Error, context: String, options o: SelftestOptions) -> Int32 {
    let mapped = (error as? TranslationEngineError) ?? .failed(String(describing: type(of: error)))
    if mapped == .notInstalled {
        print(SelftestSupport.skipLine(for: .needsDownload, source: o.source, target: o.target)
              ?? "selftest: SKIP: translation languages are not installed")
        return 3
    }
    print("selftest: FAIL: \(context): \(mapped)")
    return 1
}

/// Thread-safe "first caller wins" flag.
private final class Once: Sendable {
    private let state = Mutex(false)
    func claim() -> Bool {
        state.withLock { done in
            if done { return false }
            done = true
            return true
        }
    }
}

/// Runs `work`, returning nil if it does not finish within `seconds`. The work is not awaited after a
/// timeout (Apple Translation calls may ignore cancellation), so the caller can exit promptly.
private func raceTimeout(seconds: Double, _ work: @escaping @Sendable () async -> Int32) async -> Int32? {
    await withCheckedContinuation { (cont: CheckedContinuation<Int32?, Never>) in
        let once = Once()
        let worker = Task {
            let code = await work()
            if once.claim() { cont.resume(returning: code) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if once.claim() {
                worker.cancel()
                cont.resume(returning: nil)
            }
        }
    }
}
