// SPDX-License-Identifier: MIT

import CoreGraphics
import Testing
@testable import TalkLensCore

@Suite struct InlineLayoutTests {
    // Viewport (transcript scroll area) as observed on a real chat window: [566,285,380,432] (AX).
    let viewport = CGRect(x: 566, y: 285, width: 380, height: 432)
    let window = CGRect(x: 566, y: 197, width: 380, height: 640)

    func anchor(_ id: String, body: CGRect, bubble: CGRect? = nil, mine: Bool = false) -> InlineLayout.Anchor {
        InlineLayout.Anchor(id: MessageID(id), body: body, bubble: bubble, isMine: mine)
    }

    @Test func placeConvertsToViewportLocalAndInsetsCover() {
        let body = CGRect(x: 655, y: 339, width: 273, height: 16)
        let bubble = CGRect(x: 650, y: 331, width: 286, height: 31)
        let placed = InlineLayout.place(rows: [anchor("a", body: body, bubble: bubble, mine: true)], viewportAX: viewport)
        #expect(placed.count == 1)
        #expect(placed[0].cover == CGRect(x: 87, y: 52, width: 277, height: 20))
        #expect(placed[0].bubble == CGRect(x: 84, y: 46, width: 286, height: 31))
        #expect(placed[0].isMine)
        // Without a bubble the body is used as the bubble.
        let plain = InlineLayout.place(rows: [anchor("b", body: body)], viewportAX: viewport)
        #expect(plain[0].bubble == CGRect(x: 89, y: 54, width: 273, height: 16))
    }

    @Test func placeFiltersByViewportPlusMarginAndSorts() {
        let above = anchor("above", body: CGRect(x: 600, y: 285 - 300, width: 100, height: 16)) // 300 pt above
        let farAbove = anchor("far", body: CGRect(x: 600, y: 285 - 900, width: 100, height: 16))
        let visible = anchor("vis", body: CGRect(x: 600, y: 400, width: 100, height: 16))
        let below = anchor("below", body: CGRect(x: 600, y: 285 + 432 + 100, width: 100, height: 16))
        let rows = [visible, below, above, farAbove]
        let noMargin = InlineLayout.place(rows: rows, viewportAX: viewport)
        #expect(noMargin.map(\.id.rawValue) == ["vis"])
        let withMargin = InlineLayout.place(rows: rows, viewportAX: viewport, margin: 432)
        #expect(withMargin.map(\.id.rawValue) == ["above", "vis", "below"])
    }

    @Test func scrollDeltaShiftsPlacementAndHitTesting() {
        let row = anchor("a", body: CGRect(x: 600, y: 400, width: 100, height: 16))
        let shifted = InlineLayout.place(rows: [row], viewportAX: viewport, scrollDelta: -40)
        let expectedTop: CGFloat = 400 - 285 - 40 - 2
        #expect(shifted[0].cover.minY == expectedTop)
        let placed = InlineLayout.place(rows: [row], viewportAX: viewport)
        let point = CGPoint(x: 50, y: 115 + 8) // inside the body at scroll offset 0
        #expect(InlineLayout.hit(point, in: placed) == MessageID("a"))
        // Content scrolled up by 40: the same screen point is now below the bubble.
        #expect(InlineLayout.hit(point, in: placed, scrollDelta: -40) == nil)
        #expect(InlineLayout.hit(CGPoint(x: 50, y: point.y - 40), in: placed, scrollDelta: -40) == MessageID("a"))
    }

    @Test func scrollDeltaSubtractsWindowMovement() {
        let tableAtRead = CGRect(x: 565, y: -400, width: 382, height: 1200)
        // Pure scroll: the table moved down 120 inside a still window.
        #expect(InlineLayout.scrollDelta(anchorNow: tableAtRead.offsetBy(dx: 0, dy: 120), windowNow: window,
                                         anchorAtRead: tableAtRead, windowAtRead: window) == 120)
        // Pure window move: the table moved with the window, no scroll.
        let moved = window.offsetBy(dx: 30, dy: 200)
        #expect(InlineLayout.scrollDelta(anchorNow: tableAtRead.offsetBy(dx: 30, dy: 200), windowNow: moved,
                                         anchorAtRead: tableAtRead, windowAtRead: window) == 0)
        // Both: moved 200 and scrolled up 50.
        #expect(InlineLayout.scrollDelta(anchorNow: tableAtRead.offsetBy(dx: 30, dy: 150), windowNow: moved,
                                         anchorAtRead: tableAtRead, windowAtRead: window) == -50)
        // Unknown window frames: raw anchor movement.
        #expect(InlineLayout.scrollDelta(anchorNow: tableAtRead.offsetBy(dx: 0, dy: -10), windowNow: nil,
                                         anchorAtRead: tableAtRead, windowAtRead: window) == -10)
    }

    @Test func viewportFollowsWindowMoveAndResize() {
        let insets = InlineLayout.insets(viewport: viewport, window: window)
        #expect(insets == ViewportInsets(left: 0, top: 88, right: 0, bottom: 120))
        #expect(InlineLayout.viewport(window: window, insets: insets) == viewport)
        let moved = window.offsetBy(dx: -700, dy: -1200) // e.g. onto a secondary screen above-left
        #expect(InlineLayout.viewport(window: moved, insets: insets) == viewport.offsetBy(dx: -700, dy: -1200))
        let resized = CGRect(x: 566, y: 197, width: 500, height: 800)
        #expect(InlineLayout.viewport(window: resized, insets: insets) == CGRect(x: 566, y: 285, width: 500, height: 592))
        let tiny = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(InlineLayout.viewport(window: tiny, insets: insets).height == 0)
    }

    @Test func tableAnchorOnlyWhenTableFrameIsDocumentBounds() {
        #expect(InlineLayout.usesTableAnchor(tableFrame: CGRect(x: 565, y: -500, width: 382, height: 1300), viewport: viewport))
        #expect(InlineLayout.usesTableAnchor(tableFrame: CGRect(x: 565, y: 200, width: 382, height: 400), viewport: viewport))
        // Same as the viewport (short chat, or AX reports the clipped frame): fall back to a row anchor.
        #expect(!InlineLayout.usesTableAnchor(tableFrame: viewport, viewport: viewport))
    }

    // Fake text metrics: 10 pt per character, 17 pt per line, plus 2 pt vertical padding.
    func height(chars: Int) -> (CGFloat) -> CGFloat {
        { width in
            let perLine = max(1, Int(width / 10))
            let lines = (chars + perLine - 1) / perLine
            return CGFloat(lines) * 17 + 2
        }
    }

    @Test func labelFitsInCoverOrWidensWithinBubble() {
        let cover = CGRect(x: 100, y: 50, width: 104, height: 20)
        let bubble = CGRect(x: 97, y: 44, width: 117, height: 31)
        let fit = InlineLayout.labelFrame(cover: cover, bubble: bubble, isMine: false, singleLineWidth: 60,
                                          minScale: 0.75, lineHeight: 17, height: height(chars: 6))
        #expect(fit == InlineLayout.LabelFrame(rect: cover, scaled: false, extended: false))
        // A one-character body ("넵") whose translation is wider: widens inside the bubble.
        let smallCover = CGRect(x: 200, y: 50, width: 16, height: 20)
        let smallBubble = CGRect(x: 195, y: 44, width: 29, height: 31)
        let other = InlineLayout.labelFrame(cover: smallCover, bubble: smallBubble, isMine: false, singleLineWidth: 26,
                                            minScale: 0.75, lineHeight: 17, height: height(chars: 2))
        #expect(other.rect == CGRect(x: 198, y: 50, width: 26, height: 20)) // pulled left to stay in the bubble
        let mine = InlineLayout.labelFrame(cover: smallCover, bubble: smallBubble, isMine: true, singleLineWidth: 26,
                                           minScale: 0.75, lineHeight: 17, height: height(chars: 2))
        #expect(mine.rect == CGRect(x: 195, y: 50, width: 26, height: 20)) // grows leftwards, clamped to the bubble
        #expect(!mine.extended)
    }

    @Test func labelShrinksThenExtendsDownToBubblePlusOneLine() {
        let cover = CGRect(x: 0, y: 0, width: 100, height: 20)
        let bubble = CGRect(x: -3, y: -6, width: 113, height: 31)
        // 12 characters: 2 lines at full size, 1 line at 0.75 (width 133 → 13 chars) → shrink in place.
        let scaled = InlineLayout.labelFrame(cover: cover, bubble: bubble, isMine: false, singleLineWidth: 100,
                                             minScale: 0.75, lineHeight: 17, height: height(chars: 12))
        #expect(scaled.scaled && !scaled.extended && scaled.rect.height == 20)
        // 20 characters: 2 lines even at 0.75 → grows down (36 pt), within bubble.maxY + 17 = 25 + 17 = 42.
        let grown = InlineLayout.labelFrame(cover: cover, bubble: bubble, isMine: false, singleLineWidth: 100,
                                            minScale: 0.75, lineHeight: 17, height: height(chars: 20))
        #expect(grown.extended && !grown.scaled && grown.rect.height == 36)
        // 60 characters: capped at 42 and marked as needing to shrink.
        let capped = InlineLayout.labelFrame(cover: cover, bubble: bubble, isMine: false, singleLineWidth: 100,
                                             minScale: 0.75, lineHeight: 17, height: height(chars: 60))
        #expect(capped.extended && capped.scaled && capped.rect.height == 42)
        #expect(InlineLayout.lineLimit(height: 40, lineHeight: 17, minScale: 0.75) == 3)
        #expect(InlineLayout.lineLimit(height: 5, lineHeight: 17, minScale: 0.75) == 1)
    }

    @Test func noteGoesBelowBubbleOnlyWhenTheGapAllows() {
        let bounds = CGRect(x: 0, y: -432, width: 380, height: 1296)
        let bubble = CGRect(x: 56, y: 100, width: 60, height: 31)
        let size = CGSize(width: 50, height: 14)
        #expect(InlineLayout.noteFrame(bubble: bubble, size: size, isMine: false, nextTop: 160, bounds: bounds)
                == CGRect(x: 56, y: 132, width: 50, height: 14))
        #expect(InlineLayout.noteFrame(bubble: bubble, size: size, isMine: true, nextTop: nil, bounds: bounds)?.maxX == 116)
        #expect(InlineLayout.noteFrame(bubble: bubble, size: size, isMine: false, nextTop: 140, bounds: bounds) == nil)
    }

    @Test func popoverPrefersAboveThenBelowAndStaysInside() {
        let bounds = CGRect(x: 4, y: 4, width: 372, height: 424)
        let size = CGSize(width: 200, height: 60)
        let mid = CGRect(x: 300, y: 200, width: 70, height: 31)
        let above = InlineLayout.popoverFrame(bubble: mid, size: size, isMine: true, bounds: bounds)
        #expect(above == CGRect(x: 170, y: 134, width: 200, height: 60))
        let top = CGRect(x: 10, y: 20, width: 70, height: 31)
        let below = InlineLayout.popoverFrame(bubble: top, size: size, isMine: false, bounds: bounds)
        #expect(below == CGRect(x: 10, y: 57, width: 200, height: 60))
        let wideLeft = InlineLayout.popoverFrame(bubble: CGRect(x: -50, y: 200, width: 30, height: 31), size: size,
                                                 isMine: false, bounds: bounds)
        #expect(wideLeft.minX == 4)
    }
}
