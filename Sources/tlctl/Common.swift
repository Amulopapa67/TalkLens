// SPDX-License-Identifier: MIT
// Shared helpers for tlctl subcommands. Output never contains raw chat text or titles unless a command
// documents otherwise (replay prints synthetic / self-chat fixture text only).

import Foundation
import KakaoAX
import TalkLensCore

enum ExitCode {
    static let ok: Int32 = 0
    static let fail: Int32 = 1
    static let skip: Int32 = 3
}

func printUsage() {
    print("""
    usage: tlctl <command> [options]

      probe [--summary]                      live: find KakaoTalk + chat window, print a redacted summary
      watch --seconds N                      live: print redacted AX events and diff counts for N seconds
      record --out F.axjson [--show-text-for TITLE]
                                             live: record the current chat window subtree (redacted unless
                                             TITLE is the window title AND in .lens-dev.json allowed_text_chats)
      replay <dir|file> --engine mock [--golden DIR] [--update-golden] [--glossary F]
                                             offline: parse + preprocess + mock-translate .axjson snapshots
      bench <dir> [--iterations 50]          offline: parse/diff p50/p95 against the budget
      selftest --engine apple --source ko|auto --target zh-Hans --input F
                                             Apple Translation latency self-test

    exit codes: 0 OK, 3 SKIP (reason on the last line), 1 FAIL
    """)
}

/// Parses arguments or prints the error + usage. nil → caller exits 1.
func parseArguments(_ args: [String], command: String, values: Set<String>, flags: Set<String>) -> CLIArguments? {
    do {
        return try CLIArguments.parse(args, valueOptions: values, flags: flags)
    } catch {
        print("\(command): \(error) (see `tlctl help`)")
        return nil
    }
}

/// Live preconditions shared by probe / watch / record. Returns a SKIP reason, or nil when OK.
func livePreconditionSkipReason() -> String? {
    let running = KakaoProcess.isRunning
    let trusted = KakaoProcess.isAccessibilityTrusted
    print("kakao: running=\(running ? "yes" : "no")\(running ? " version=\(KakaoProcess.version ?? "?")" : "")")
    print("accessibility: trusted=\(trusted ? "yes" : "no")")
    var reasons: [String] = []
    if !running { reasons.append("KakaoTalk is not running (start it and open a chat window)") }
    if !trusted {
        reasons.append("Accessibility permission not granted to this terminal (System Settings > Privacy & Security > Accessibility)")
    }
    return reasons.isEmpty ? nil : reasons.joined(separator: "; ")
}

func formatMs(_ v: Double) -> String { String(format: "%.2f", v) }

var currentDirectoryURL: URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true) }

func macOSVersionString() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}

/// `*.axjson` files of a directory (sorted by name), or the file itself.
func snapshotFiles(at path: String) -> [URL]? {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
    let url = URL(fileURLWithPath: path)
    guard isDir.boolValue else { return [url] }
    let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    return items.filter { $0.pathExtension == "axjson" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
}
