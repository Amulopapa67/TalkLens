// SPDX-License-Identifier: MIT

import CoreGraphics
import Testing
@testable import TalkLensCore

@Suite struct ScreenGeometryTests {
    // Primary screen 1440x900 (Cocoa frame origin 0,0) -> primaryMaxY = 900.
    let primaryMaxY: CGFloat = 900

    @Test func axToCocoaOnPrimaryScreen() {
        // A window at the very top-left in AX coordinates sits at the top in Cocoa coordinates.
        let ax = CGRect(x: 100, y: 0, width: 400, height: 300)
        #expect(ScreenGeometry.axToCocoa(ax, primaryMaxY: primaryMaxY) == CGRect(x: 100, y: 600, width: 400, height: 300))
        let bottom = CGRect(x: 0, y: 800, width: 50, height: 100)
        #expect(ScreenGeometry.axToCocoa(bottom, primaryMaxY: primaryMaxY).minY == 0)
    }

    @Test func roundTripOnMultipleScreens() {
        // Secondary above (AX y negative), below (AX y > primary height), left (x negative), right.
        let rects = [
            CGRect(x: 200, y: -1000, width: 800, height: 600),   // screen above primary
            CGRect(x: 100, y: 1200, width: 500, height: 400),    // screen below primary
            CGRect(x: -1800, y: 100, width: 700, height: 500),   // screen left of primary
            CGRect(x: 1600, y: -200, width: 900, height: 700),   // screen right, offset up
            CGRect(x: 1300, y: 50, width: 400, height: 300),     // spanning primary + right
        ]
        for r in rects {
            let cocoa = ScreenGeometry.axToCocoa(r, primaryMaxY: primaryMaxY)
            #expect(ScreenGeometry.cocoaToAX(cocoa, primaryMaxY: primaryMaxY) == r)
            #expect(cocoa.height == r.height && cocoa.width == r.width && cocoa.minX == r.minX)
        }
        // Above primary: AX y = -1000, h = 600 -> Cocoa y = 900 + 1000 - 600 = 1300.
        #expect(ScreenGeometry.axToCocoa(rects[0], primaryMaxY: primaryMaxY).minY == 1300)
        // Below primary: AX y = 1200, h = 400 -> Cocoa y = 900 - 1200 - 400 = -700.
        #expect(ScreenGeometry.axToCocoa(rects[1], primaryMaxY: primaryMaxY).minY == -700)
    }

    @Test func screenContainingMostOfWindow() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 875), CGRect(x: 1440, y: 0, width: 1920, height: 1055)]
        #expect(ScreenGeometry.screenIndex(containingMostOf: CGRect(x: 1300, y: 100, width: 400, height: 300),
                                           screens: screens) == 1)
        #expect(ScreenGeometry.screenIndex(containingMostOf: CGRect(x: 1200, y: 100, width: 400, height: 300),
                                           screens: screens) == 0)
        #expect(ScreenGeometry.screenIndex(containingMostOf: CGRect(x: 9000, y: 9000, width: 10, height: 10),
                                           screens: screens) == 1)
        #expect(ScreenGeometry.screenIndex(containingMostOf: .zero, screens: []) == nil)
    }
}

@Suite struct PanelPlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)   // visibleFrame of a single screen

    @Test func rightSideWhenRoomAvailable() {
        let w = CGRect(x: 100, y: 100, width: 600, height: 500)
        let p = PanelPlacement.place(window: w, panelWidth: 320, screens: [screen])
        #expect(p.edge == .right)
        #expect(p.frame == CGRect(x: 706, y: 100, width: 320, height: 500))
    }

    @Test func fallsBackToLeftWhenRightIsBlocked() {
        let w = CGRect(x: 800, y: 100, width: 600, height: 500)
        let p = PanelPlacement.place(window: w, panelWidth: 320, screens: [screen])
        #expect(p.edge == .left)
        #expect(p.frame == CGRect(x: 474, y: 100, width: 320, height: 500))
    }

    @Test func insideWhenBothSidesBlockedAvoidsInputBox() {
        let w = CGRect(x: 100, y: 50, width: 1240, height: 800)
        let input = CGRect(x: 100, y: 50, width: 1240, height: 90)
        let p = PanelPlacement.place(window: w, panelWidth: 320, screens: [screen], inputFrame: input)
        #expect(p.edge == .inside)
        #expect(p.frame.maxX == w.maxX)
        #expect(p.frame.width == 320)
        #expect(p.frame.minY >= input.maxY)
        #expect(p.frame.maxY == w.maxY)
        #expect(screen.contains(p.frame))
    }

    @Test func insideWithoutInputFrameUsesWholeHeight() {
        let w = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let p = PanelPlacement.place(window: w, panelWidth: 320, screens: [screen])
        #expect(p.edge == .inside)
        #expect(p.frame == CGRect(x: 1120, y: 0, width: 320, height: 875))
    }

    @Test func preferredLeftAndInsideAreRespected() {
        let w = CGRect(x: 500, y: 100, width: 400, height: 500)
        let left = PanelPlacement.place(window: w, panelWidth: 320, screens: [screen], preferred: .left)
        #expect(left.edge == .left)
        #expect(left.frame.maxX == w.minX - 6)
        let inside = PanelPlacement.place(window: w, panelWidth: 320, screens: [screen], preferred: .inside)
        #expect(inside.edge == .inside)
        // Preferred left but blocked on the left -> right.
        let w2 = CGRect(x: 50, y: 100, width: 400, height: 500)
        #expect(PanelPlacement.place(window: w2, panelWidth: 320, screens: [screen], preferred: .left).edge == .right)
    }

    @Test func verticalClampIntoVisibleFrame() {
        // Window extends above the visible frame (behind the menu bar) and below the Dock area.
        let vf = CGRect(x: 0, y: 70, width: 1440, height: 805)
        let w = CGRect(x: 100, y: 20, width: 500, height: 900)
        let p = PanelPlacement.place(window: w, panelWidth: 320, screens: [vf])
        #expect(p.edge == .right)
        #expect(p.frame.minY >= vf.minY && p.frame.maxY <= vf.maxY)
        let low = CGRect(x: 100, y: 0, width: 500, height: 300)
        let q = PanelPlacement.place(window: low, panelWidth: 320, screens: [vf])
        #expect(q.frame.minY == vf.minY)
        #expect(q.frame.height == 300)
    }

    @Test func multiScreenUsesScreenWithMostOfTheWindow() {
        // Primary on the left, secondary 1920 wide on the right.
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let secondary = CGRect(x: 1440, y: -200, width: 1920, height: 1055)
        // Window mostly on the secondary, at its right edge -> right is blocked there -> left.
        let w = CGRect(x: 2800, y: 0, width: 560, height: 600)
        let p = PanelPlacement.place(window: w, panelWidth: 320, screens: [primary, secondary])
        #expect(p.edge == .left)
        #expect(secondary.contains(p.frame))
        // Window near the primary's right edge but mostly on the primary: right side would cross onto
        // the secondary screen, which does not count as fitting -> left.
        let w2 = CGRect(x: 900, y: 100, width: 600, height: 500)
        let p2 = PanelPlacement.place(window: w2, panelWidth: 320, screens: [primary, secondary])
        #expect(p2.edge == .left)
        #expect(primary.contains(p2.frame))
    }

    @Test func windowSpanningScreensOnSecondaryAbove() {
        // Secondary screen stacked above the primary (Cocoa y > primary height).
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let above = CGRect(x: 0, y: 900, width: 1440, height: 875)
        let w = CGRect(x: 200, y: 700, width: 500, height: 600)  // 175 on primary, 400 on the upper screen
        let p = PanelPlacement.place(window: w, panelWidth: 320, screens: [primary, above])
        #expect(p.edge == .right)
        #expect(above.contains(p.frame))
    }

    @Test func noScreensReturnsUnclampedRight() {
        let w = CGRect(x: 10, y: 10, width: 100, height: 100)
        let p = PanelPlacement.place(window: w, panelWidth: 50, screens: [])
        #expect(p.edge == .right)
        #expect(p.frame == CGRect(x: 116, y: 10, width: 50, height: 100))
    }
}
