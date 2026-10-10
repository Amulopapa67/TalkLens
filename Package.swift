// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
import Foundation
import PackageDescription

// With Command Line Tools only (no Xcode), the default build system does not find the swift-testing macro
// plugin, so `@Test` fails to expand. Point the compiler at it when present (no effect under Xcode).
let cltTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSwiftSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: cltTestingPlugins)
    ? [.unsafeFlags(["-plugin-path", cltTestingPlugins])]
    : []
let testLinkerSettings: [LinkerSetting] = FileManager.default.fileExists(atPath: cltTestingPlugins)
    ? [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                     "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"])]
    : []

let package = Package(
    name: "TalkLens",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "TalkLensApp", targets: ["TalkLensApp"]),
        .executable(name: "tlctl", targets: ["tlctl"]),
        .library(name: "TalkLensCore", targets: ["TalkLensCore"]),
        .library(name: "KakaoAX", targets: ["KakaoAX"]),
        .library(name: "TalkLensTranslate", targets: ["TalkLensTranslate"]),
    ],
    targets: [
        // Pure logic: models, identity, diff, preprocess, glossary, cache, time parsing. No AppKit.
        .target(name: "TalkLensCore"),
        // Read-only subset of kmsg + AXNodeLike abstraction + transcript parser.
        .target(name: "KakaoAX", dependencies: ["TalkLensCore"]),
        // Translation engines and scheduler.
        .target(name: "TalkLensTranslate", dependencies: ["TalkLensCore"]),
        // Menu bar app.
        .executableTarget(name: "TalkLensApp", dependencies: ["KakaoAX", "TalkLensCore", "TalkLensTranslate"]),
        // Developer / acceptance CLI.
        .executableTarget(name: "tlctl", dependencies: ["KakaoAX", "TalkLensCore", "TalkLensTranslate"]),
        // One test target so `swift test` reports a single "Test run with N tests" line (verify.sh G3).
        .testTarget(name: "TalkLensTests", dependencies: ["KakaoAX", "TalkLensCore", "TalkLensTranslate"],
                    swiftSettings: testSwiftSettings, linkerSettings: testLinkerSettings),
    ]
)
