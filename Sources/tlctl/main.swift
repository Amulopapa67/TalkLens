// SPDX-License-Identifier: MIT
// tlctl — TalkLens developer / acceptance CLI (docs/architecture.md §7).
// Exit codes: 0 OK, 3 SKIP (reason on the last line), 1 FAIL / usage error.
// `selftest` lives in Selftest.swift (translate-dev).

import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let tlctlArguments = Array(CommandLine.arguments.dropFirst())
let tlctlCommand = tlctlArguments.first ?? "help"
let tlctlRest = Array(tlctlArguments.dropFirst())

switch tlctlCommand {
case "probe":
    exit(runProbe(arguments: tlctlRest))
case "watch":
    exit(runWatch(arguments: tlctlRest))
case "record":
    exit(runRecord(arguments: tlctlRest))
case "replay":
    exit(runReplay(arguments: tlctlRest))
case "bench":
    exit(runBench(arguments: tlctlRest))
case "selftest":
    exit(await runSelftest(arguments: tlctlRest))
case "help", "--help", "-h":
    printUsage()
    exit(1)
default:
    printUsage()
    print("tlctl: unknown command '\(tlctlCommand)'")
    exit(1)
}
