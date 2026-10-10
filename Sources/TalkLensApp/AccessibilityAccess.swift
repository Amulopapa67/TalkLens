// SPDX-License-Identifier: MIT
// Accessibility (TCC) permission helper for the app itself. Checking is passive; the system prompt is shown
// only when the user clicks a button (never automatically at launch).

import AppKit
import ApplicationServices

@MainActor
enum AccessibilityAccess {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    /// Passive check; never shows UI.
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Asks the system to show its Accessibility prompt. Call only from a user action.
    @discardableResult
    static func requestPrompt() -> Bool {
        // Literal key instead of kAXTrustedCheckOptionPrompt (a global var, not concurrency-safe in Swift 6).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings → Privacy & Security → Accessibility.
    static func openSystemSettings() {
        guard let url = settingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
