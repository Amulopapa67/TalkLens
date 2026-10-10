// Derived from kmsg (https://github.com/channprj/kmsg) @54cbff7 — MIT License, Copyright (c) 2026 Park Hee Chan. Modifications: KakaoTalkApp.swift reduced to process lookup, version and the application AX element; removed launch, launchViaOpenCommand, forceOpen, activate, activateAndWaitForWindow, ensureMainWindow, ensureWindowReopened, window waiting and hierarchy printing.
// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices
import Foundation

/// Locates the running KakaoTalk process. Never launches, activates, hides or terminates it.
public enum KakaoProcess {
    public static let bundleIdentifier = "com.kakao.KakaoTalkMac"

    public static var runningApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    public static var isRunning: Bool { runningApplication != nil }

    public static var processIdentifier: pid_t? { runningApplication?.processIdentifier }

    /// Whether KakaoTalk is the frontmost app (read-only query).
    public static var isFrontmost: Bool { runningApplication?.isActive ?? false }

    public static var version: String? {
        runningApplication?.bundleURL.flatMap { Bundle(url: $0) }?
            .infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Application AX element with a bounded messaging timeout, or nil when not running.
    public static func applicationNode() -> LiveAXNode? {
        guard let app = runningApplication else { return nil }
        return LiveAXNode.application(pid: app.processIdentifier)
    }

    public static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }
}
