// SPDX-License-Identifier: MIT
// Which parts of the followed KakaoTalk chat window are covered by other windows, so the inline overlay
// (a `.floating` window) never paints over them.
//
// Window-server metadata only: owner pid, window number, layer, alpha and bounds from
// CGWindowListCopyWindowInfo. No window images are requested and window titles are not read. Nothing is sent
// to KakaoTalk (no AX IPC); one call costs well under 1 ms once the window-server connection is warm.

import AppKit
import CoreGraphics
import os

private let logger = Logger.talkLens("occlusion")

/// Result of one occlusion check, in AX / CoreGraphics global coordinates (top-left origin, y down).
struct OcclusionSnapshot: Equatable {
    /// False when the chat window is not in the on-screen window list (closed, hidden, minimized, or on
    /// another Space).
    var onScreen: Bool
    /// Parts of the chat window covered by windows above it (each clipped to the chat window frame).
    var occluders: [CGRect]
    /// True when a single window above covers the whole chat window.
    var fullyCovered: Bool

    static let notOnScreen = OcclusionSnapshot(onScreen: false, occluders: [], fullyCovered: false)

    /// On screen and at least partly visible.
    var chatVisible: Bool { onScreen && !fullyCovered }
}

/// The subset of a window-list entry that occlusion needs.
struct WindowListEntry: Equatable, Sendable {
    let number: CGWindowID
    let pid: pid_t
    let layer: Int
    let alpha: Double
    let bounds: CGRect
}

@MainActor
final class WindowOcclusion {
    /// CG bounds and the AX frame of the same window agree to the point; allow small rounding differences.
    nonisolated static let matchTolerance: CGFloat = 2
    /// Windows above this layer (Dock, menu bar, pop-up menus, ...) are drawn above the `.floating` overlay by
    /// the window server anyway, so they need no mask. Layer 0 (normal) up to the floating level does.
    nonisolated static let maxOccluderLayer = Int(CGWindowLevelForKey(.floatingWindow))
    /// A cached match is kept while the AX frame lags the window server (e.g. mid-drag) as long as the two
    /// frames still overlap this much.
    nonisolated static let cachedMatchMinOverlap: CGFloat = 0.5

    private var cachedWindow: CGWindowID?
    private(set) var last: OcclusionSnapshot = .notOnScreen
    private var warmed = false

    /// Opens the window-server connection off the main thread (the first call takes tens of milliseconds).
    func warmUp() {
        guard !warmed else { return }
        warmed = true
        Task.detached(priority: .utility) {
            _ = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        }
    }

    /// Recomputes the occlusion of the KakaoTalk window whose AX frame is `chatFrame`.
    @discardableResult
    func update(kakaoPID: pid_t, chatFrame: CGRect) -> OcclusionSnapshot {
        let windows = Self.onScreenWindows()
        let (snapshot, matched) = Self.evaluate(windows: windows, kakaoPID: kakaoPID, chatFrame: chatFrame,
                                                ownPID: getpid(), cachedWindow: cachedWindow)
        cachedWindow = matched
        if snapshot != last {
            logger.debug("onScreen=\(snapshot.onScreen, privacy: .public) occluders=\(snapshot.occluders.count, privacy: .public) full=\(snapshot.fullyCovered, privacy: .public)")
        }
        last = snapshot
        return snapshot
    }

    func reset() {
        cachedWindow = nil
        last = .notOnScreen
    }

    /// On-screen windows, front to back (metadata only).
    nonisolated static func onScreenWindows() -> [WindowListEntry] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [WindowListEntry] = []
        out.reserveCapacity(raw.count)
        for info in raw {
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            out.append(WindowListEntry(number: number, pid: pid, layer: layer, alpha: alpha, bounds: bounds))
        }
        return out
    }

    /// Pure matching + occlusion. `windows` is front-to-back (the order CGWindowListCopyWindowInfo returns),
    /// so every entry before the chat window is above it — the same set `.optionOnScreenAboveWindow` would
    /// return, taken from one consistent snapshot.
    nonisolated static func evaluate(windows: [WindowListEntry], kakaoPID: pid_t, chatFrame: CGRect,
                                     ownPID: pid_t, cachedWindow: CGWindowID?)
        -> (snapshot: OcclusionSnapshot, matched: CGWindowID?) {
        guard chatFrame.width > 0, chatFrame.height > 0 else { return (.notOnScreen, nil) }
        var exact: [Int] = []
        var cachedIndex: Int?
        for (i, w) in windows.enumerated() where w.pid == kakaoPID && w.layer == 0 {
            if matches(w.bounds, chatFrame) { exact.append(i) }
            if w.number == cachedWindow { cachedIndex = i }
        }
        let index: Int
        if let cachedIndex, exact.contains(cachedIndex) {
            index = cachedIndex
        } else if let back = exact.last {
            // Several KakaoTalk windows with the same frame cannot be told apart without titles. The backmost
            // one is the conservative choice: the others then count as occluders, so nothing is painted over
            // a window that might not be ours.
            index = back
        } else if let cachedIndex, overlapFraction(windows[cachedIndex].bounds, chatFrame) >= cachedMatchMinOverlap {
            // The AX frame lags the window server while the window is dragged or resized.
            index = cachedIndex
        } else {
            return (.notOnScreen, nil)
        }
        let chatBounds = windows[index].bounds
        var occluders: [CGRect] = []
        var fullyCovered = false
        for w in windows[..<index] {
            guard w.layer >= 0, w.layer <= maxOccluderLayer, w.alpha >= 0.01,
                  w.bounds.width > 0, w.bounds.height > 0 else { continue }
            // Our own overlay / sidebar panels sit at the floating level and are never occluders; our normal
            // windows (settings, onboarding, about) are, like any other app's.
            if w.pid == ownPID && w.layer != 0 { continue }
            let clipped = w.bounds.intersection(chatBounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { continue }
            occluders.append(clipped)
            if w.bounds.contains(chatBounds) { fullyCovered = true }
        }
        let snapshot = OcclusionSnapshot(onScreen: true, occluders: occluders, fullyCovered: fullyCovered)
        return (snapshot, windows[index].number)
    }

    nonisolated static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= matchTolerance && abs(a.minY - b.minY) <= matchTolerance
            && abs(a.width - b.width) <= matchTolerance && abs(a.height - b.height) <= matchTolerance
    }

    nonisolated static func overlapFraction(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, b.width > 0, b.height > 0 else { return 0 }
        return (i.width * i.height) / (b.width * b.height)
    }
}
