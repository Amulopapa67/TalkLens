// SPDX-License-Identifier: MIT
// AX ↔ Cocoa coordinate conversion and sidebar placement (docs/architecture.md §6.2). Pure CGRect math.

import CoreGraphics
import Foundation

public enum ScreenGeometry {
    /// AX rect (top-left origin of primary screen, y down) → Cocoa rect (bottom-left origin, y up).
    /// `primaryMaxY` = NSScreen.screens[0].frame.maxY.
    public static func axToCocoa(_ r: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryMaxY - r.minY - r.height, width: r.width, height: r.height)
    }

    /// Cocoa rect → AX rect. The flip is its own inverse.
    public static func cocoaToAX(_ r: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryMaxY - r.minY - r.height, width: r.width, height: r.height)
    }

    /// Index of the screen sharing the largest area with `rect`; when none intersects, the screen whose
    /// center is nearest to the rect's center. nil only for an empty `screens` list.
    public static func screenIndex(containingMostOf rect: CGRect, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        var best: Int?
        var bestArea: CGFloat = 0
        for (i, s) in screens.enumerated() {
            let inter = s.intersection(rect)
            guard !inter.isNull else { continue }
            let area = inter.width * inter.height
            if area > bestArea {
                bestArea = area
                best = i
            }
        }
        if let best { return best }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var nearest = 0
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for (i, s) in screens.enumerated() {
            let dx = s.midX - c.x
            let dy = s.midY - c.y
            let d = dx * dx + dy * dy
            if d < nearestDistance {
                nearestDistance = d
                nearest = i
            }
        }
        return nearest
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
    ///   (`.left` tries left → right → inside; `.inside` always overlays the window)
    /// - inputFrame: chat input box frame; the `inside` placement keeps clear of it
    ///
    /// A side placement "fits" only when it lies horizontally inside the visibleFrame of the screen that
    /// contains most of the window. The result is clamped vertically into that visibleFrame.
    public static func place(window: CGRect, panelWidth: CGFloat, screens: [CGRect],
                             preferred: PanelEdge = .right, inputFrame: CGRect? = nil,
                             gap: CGFloat = 6) -> (frame: CGRect, edge: PanelEdge) {
        let right = CGRect(x: window.maxX + gap, y: window.minY, width: panelWidth, height: window.height)
        guard let idx = ScreenGeometry.screenIndex(containingMostOf: window, screens: screens) else {
            return (right, .right)
        }
        let vf = screens[idx]
        let left = CGRect(x: window.minX - gap - panelWidth, y: window.minY, width: panelWidth, height: window.height)

        func fits(_ r: CGRect) -> Bool { r.minX >= vf.minX && r.maxX <= vf.maxX }

        let order: [PanelEdge]
        switch preferred {
        case .right: order = [.right, .left]
        case .left: order = [.left, .right]
        case .inside: order = []
        }
        for edge in order {
            let candidate = edge == .right ? right : left
            if fits(candidate) {
                return (clampVertically(candidate, into: vf), edge)
            }
        }
        return (insideFrame(window: window, panelWidth: panelWidth, visibleFrame: vf, inputFrame: inputFrame), .inside)
    }

    /// Panel overlaid on the window's right edge, above the input box, kept within the visible frame.
    static func insideFrame(window: CGRect, panelWidth: CGFloat, visibleFrame vf: CGRect,
                            inputFrame: CGRect?) -> CGRect {
        let width = min(panelWidth, window.width, vf.width)
        var maxX = min(window.maxX, vf.maxX)
        if maxX - width < vf.minX { maxX = vf.minX + width }
        var minY = window.minY
        if let input = inputFrame, input.maxY > minY, input.maxY < window.maxY {
            minY = input.maxY
        }
        minY = max(minY, vf.minY)
        let maxY = min(window.maxY, vf.maxY)
        let height = max(0, maxY - minY)
        return CGRect(x: maxX - width, y: minY, width: width, height: height)
    }

    /// Shrinks to the visible height if needed and shifts the rect vertically into `vf`.
    static func clampVertically(_ r: CGRect, into vf: CGRect) -> CGRect {
        let height = min(r.height, vf.height)
        let y = max(vf.minY, min(r.minY, vf.maxY - height))
        return CGRect(x: r.minX, y: y, width: r.width, height: height)
    }
}
