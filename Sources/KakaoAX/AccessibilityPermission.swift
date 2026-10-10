// Derived from kmsg (https://github.com/channprj/kmsg) @54cbff7 — MIT License, Copyright (c) 2026 Park Hee Chan. Modifications: kept isGranted / requestIfNeeded / openAccessibilitySettings only; prompt is opt-in (`prompt:` parameter); removed ensureGranted, activateFileViewerSelecting, the System Settings app fallback, polling and kmsg-specific instructions.
// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices
import Foundation

/// Accessibility (TCC) permission checks. Never triggers the system prompt unless explicitly asked.
public enum AccessibilityPermission {
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    /// Whether this process is trusted for Accessibility. Never prompts.
    public static func isGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Returns true when already granted. With `prompt: true` the system shows its permission dialog
    /// (used only by the app's onboarding flow, never by `tlctl probe`).
    @discardableResult
    public static func requestIfNeeded(prompt: Bool) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings at Privacy & Security > Accessibility via its URL scheme.
    @discardableResult
    public static func openAccessibilitySettings() -> Bool {
        guard let settingsURL else { return false }
        return NSWorkspace.shared.open(settingsURL)
    }
}
