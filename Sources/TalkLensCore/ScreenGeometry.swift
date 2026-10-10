// SPDX-License-Identifier: MIT
// AX ↔ Cocoa coordinate conversion and sidebar placement (docs/architecture.md §6.2). Pure CGRect math.
// STUB — core-dev: implement and test (multi-screen included).

import CoreGraphics
import Foundation

public enum ScreenGeometry {
    /// AX rect (top-left origin of primary screen, y down) → Cocoa rect (bottom-left origin, y up).
    /// `primaryMaxY` = NSScreen.screens[0].frame.maxY.
    public static func axToCocoa(_ r: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryMaxY - r.minY - r.height, width: r.width, height: r.height)
    }

    public static func cocoaToAX(_ r: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryMaxY - r.minY - r.height, width: r.width, height: r.height)
    }
}

public enum PanelEdge: String, Sendable, Codable, CaseIterable {
    case right, left, inside
}

public enum PanelPlacement {
    /// Where to put the sidebar for a chat window. All rects in Cocoa coordinates.
    /// - window: chat window frame
    /// - screens: visibleFrame of every screen
    /// - preferred: user preference (right by default); falls back right → left → inside
    /// - inputFrame: chat input box frame; the `inside` placement keeps clear of it
    public static func place(window: CGRect, panelWidth: CGFloat, screens: [CGRect],
                             preferred: PanelEdge = .right, inputFrame: CGRect? = nil,
                             gap: CGFloat = 6) -> (frame: CGRect, edge: PanelEdge) {
        (CGRect(x: window.maxX + gap, y: window.minY, width: panelWidth, height: window.height), .right)
    }
}
