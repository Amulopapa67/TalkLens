// SPDX-License-Identifier: MIT
// `tlctl selftest --engine apple|mock --source ko|auto|<lang> --target zh-Hans --input F [--batch]`
// (docs/architecture.md §7). `--source auto` detects each line's language (D-023).
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

    // Source per line: fixed, or detected per line with `--source auto` (lines already in the target language
    // are not sent; undecidable lines such as emoji fall back to Korean).
    let plan = SelftestSupport.plan(lines: lines, source: o.source, target: o.target)
    if o.isAuto {
        let summary = plan.sourceCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        print("selftest: auto-detected sources: \(summary.joined(separator: " ")), already-target=\(plan.alreadyTarget.count)")
    }

    // Every pair must be ready; a missing pair excludes its lines (fixed source: the whole run is a SKIP).
    var notReady: [(source: String, status: EngineStatus)] = []
    var readySources: Set<String> = []
    for src in plan.sources {
        let status = await engine.status(source: Locale.Language(identifier: src), target: target)
        if status == .ready { readySources.insert(src) } else { notReady.append((src, status)) }
    }
    for (src, status) in notReady where o.isAuto {
        print("selftest: pair \(src)→\(o.target) not ready (\(status)); its lines are skipped")
    }
    let work = plan.items.filter { readySources.contains($0.source) }
    if work.isEmpty || (!o.isAuto && !notReady.isEmpty) {
        if let first = notReady.first,
           let skip = SelftestSupport.skipLine(for: first.status, source: first.source, target: o.target) {
            print(skip)
            return 3
        }
        print("selftest: FAIL: nothing to translate (every line is already in \(o.target))")
        return 1
    }
    for i in plan.alreadyTarget {
        print(String(format: "[%d] ", i + 1) + SelftestSupport.oneLine(lines[i]) + " → (already \(o.target), not sent)")
    }

    var samples: [Double] = []
    if !o.batchOnly {
        for w in work {
            let item = TranslationItem(id: "line-\(w.index + 1)", text: w.text)
            let watch = Stopwatch()
            do {
                let results = try await engine.translate([item], source: Locale.Language(identifier: w.source),
                                                         target: target)
                let ms = watch.elapsedMilliseconds
                guard let text = results.first(where: { $0.id == item.id })?.text else {
                    print("selftest: FAIL: line \(w.index + 1): missing result")
                    return 1
                }
                samples.append(ms)
                let tag = o.isAuto ? " [\(w.source)]" : ""
                print(String(format: "[%d] ", w.index + 1) + SelftestSupport.oneLine(w.text) + " → "
                      + SelftestSupport.oneLine(text) + String(format: " (%.1f ms)", ms) + tag)
            } catch {
                return failure(error, context: "line \(w.index + 1)", options: o, source: w.source)
            }
        }
    }

    // Batched pass: one engine call per source language.
    let items = work.map { TranslationItem(id: "line-\($0.index + 1)", text: $0.text) }
    var byID: [String: String] = [:]
    var batchMs = 0.0
    for src in plan.sources where readySources.contains(src) {
        let group = work.filter { $0.source == src }.map { TranslationItem(id: "line-\($0.index + 1)", text: $0.text) }
        guard !group.isEmpty else { continue }
        let batchWatch = Stopwatch()
        do {
            let results = try await engine.translate(group, source: Locale.Language(identifier: src), target: target)
            for r in results where byID[r.id] == nil { byID[r.id] = r.text }
        } catch {
            return failure(error, context: "batch", options: o, source: src)
        }
        batchMs += batchWatch.elapsedMilliseconds
    }
    let translated = items.filter { byID[$0.id] != nil }.count
    print(String(format: "batch: %d/%d items in %.1f ms", translated, items.count, batchMs))
    if o.batchOnly {
        for (w, item) in zip(work, items) {
            print(String(format: "[%d] ", w.index + 1) + SelftestSupport.oneLine(item.text) + " → "
                  + SelftestSupport.oneLine(byID[item.id] ?? "<missing>"))
        }
        samples = Array(repeating: batchMs / Double(items.count), count: items.count)
    }
    guard translated == items.count else {
        print("selftest: FAIL: batch returned \(translated)/\(items.count) results")
        return 1
    }

    let stats = LatencyStats(samples)
    print(SelftestSupport.okLine(translated: o.batchOnly ? translated : samples.count, total: items.count,
                                 p50: stats.p50, p95: stats.p95, batchMilliseconds: batchMs,
                                 engine: engine.id, source: o.source, target: o.target))
    return 0
}

/// Maps a thrown error to the final line and exit code. `notInstalled` is a SKIP; everything else FAILs.
private func failure(_ error: any Error, context: String, options o: SelftestOptions, source: String) -> Int32 {
    let mapped = (error as? TranslationEngineError) ?? .failed(String(describing: type(of: error)))
    if mapped == .notInstalled {
        print(SelftestSupport.skipLine(for: .needsDownload, source: source, target: o.target)
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
