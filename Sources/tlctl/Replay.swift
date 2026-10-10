// SPDX-License-Identifier: MIT
// `tlctl replay <dir|file> --engine mock [--golden DIR] [--update-golden] [--glossary F]` — offline.
// Output may contain fixture text (synthetic or allowlisted self-chat recordings only).

import Foundation
import KakaoAX
import TalkLensCore
import TalkLensTranslate

func runReplay(arguments: [String]) -> Int32 {
    guard let args = parseArguments(arguments, command: "replay", values: ["--engine", "--golden", "--glossary"],
                                    flags: ["--update-golden"]) else { return ExitCode.fail }
    guard let input = args.positionals.first, args.positionals.count == 1 else {
        print("replay: expected exactly one <dir|file> argument (see `tlctl help`)")
        return ExitCode.fail
    }
    let engine = args.options["--engine"] ?? "mock"
    guard engine == "mock" else {
        print("replay: only --engine mock is supported offline")
        return ExitCode.fail
    }
    let update = args.has("--update-golden")
    let goldenDir = args.options["--golden"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    if update, goldenDir == nil {
        print("replay: --update-golden needs --golden DIR")
        return ExitCode.fail
    }

    let glossaryPath = args.options["--glossary"] ?? "fixtures/glossary.ko-zh.json"
    let glossary: Glossary
    do {
        glossary = try Glossary.load(contentsOf: URL(fileURLWithPath: glossaryPath, relativeTo: currentDirectoryURL))
    } catch {
        if args.options["--glossary"] != nil {
            print("replay: FAIL cannot load glossary \(glossaryPath): \(error.localizedDescription)")
            return ExitCode.fail
        }
        print("replay: warning: \(glossaryPath) not found; using an empty glossary")
        glossary = .empty
    }

    guard let files = snapshotFiles(at: input), !files.isEmpty else {
        print("replay: FAIL no .axjson snapshots at \(input)")
        return ExitCode.fail
    }
    if update, let goldenDir {
        try? FileManager.default.createDirectory(at: goldenDir, withIntermediateDirectories: true)
    }

    var differing = 0
    var messageTotal = 0
    for url in files {
        let name = url.deletingPathExtension().lastPathComponent
        let data: Data
        do {
            let file = try AXSnapshotFile.load(contentsOf: url)
            let output = try ReplayRenderer.render(name: name, file: file, glossary: glossary) {
                MockEngine.translateSync($0, target: "zh-Hans")
            }
            messageTotal += output.messages.count
            data = try ReplayRenderer.encode(output)
        } catch {
            print("replay: \(name) FAIL \(error)")
            differing += 1
            continue
        }

        guard let goldenDir else {
            FileHandle.standardOutput.write(data)
            continue
        }
        let goldenURL = goldenDir.appendingPathComponent(name + ".json")
        if update {
            do {
                try data.write(to: goldenURL, options: .atomic)
                print("replay: \(name) UPDATED \(goldenURL.path)")
            } catch {
                print("replay: \(name) FAIL cannot write golden: \(error.localizedDescription)")
                differing += 1
            }
            continue
        }
        guard let expected = try? String(contentsOf: goldenURL, encoding: .utf8) else {
            print("replay: \(name) DIFF (missing golden \(goldenURL.path))")
            differing += 1
            continue
        }
        let actual = String(decoding: data, as: UTF8.self)
        if expected == actual {
            print("replay: \(name) OK")
        } else {
            print("replay: \(name) DIFF")
            for line in GoldenDiff.firstDifferences(expected: expected, actual: actual) { print("    " + line) }
            differing += 1
        }
    }

    if update {
        if differing > 0 {
            print("replay: \(differing) of \(files.count) failed while updating golden")
            return ExitCode.fail
        }
        print("replay: updated \(files.count) golden file(s), \(messageTotal) message(s) — review before committing")
        return ExitCode.ok
    }
    if differing > 0 {
        print("replay: \(differing) of \(files.count) differ")
        return ExitCode.fail
    }
    if goldenDir == nil {
        print("replay: \(files.count) snapshot(s), \(messageTotal) message(s) (no --golden; nothing compared)")
        return ExitCode.ok
    }
    print("replay: \(files.count) snapshot(s), \(messageTotal) message(s), all match golden")
    return ExitCode.ok
}
