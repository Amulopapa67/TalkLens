// SPDX-License-Identifier: MIT
// Locates the running KakaoTalk process. Never launches, activates or terminates it.
// STUB — core-dev: finish.

import AppKit
import ApplicationServices
import Foundation

public enum KakaoProcess {
    public static let bundleIdentifier = "com.kakao.KakaoTalkMac"

    public static var runningApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    public static var isRunning: Bool { runningApplication != nil }

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
