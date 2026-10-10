// SPDX-License-Identifier: MIT
// TalkLens entry point: a menu bar (LSUIElement) app built on the AppKit lifecycle, or a headless
// `--self-check` run used by scripts to smoke-test the bundled binary.

import AppKit
import Foundation

let arguments = CommandLine.arguments
if let flagIndex = arguments.firstIndex(of: "--self-check") {
    let path = flagIndex + 1 < arguments.count ? arguments[flagIndex + 1] : nil
    Task { @MainActor in
        let code = await SelfCheck.run(fixturePath: path)
        exit(code)
    }
    dispatchMain()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
