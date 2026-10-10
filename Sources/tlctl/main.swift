// SPDX-License-Identifier: MIT
// Placeholder; core-dev (KakaoAX/tlctl) replaces this. `selftest` lives in Selftest.swift (translate-dev).
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "selftest" {
    exit(await runSelftest(arguments: Array(args.dropFirst())))
}
print("tlctl: not implemented yet")
exit(1)
