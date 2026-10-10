// SPDX-License-Identifier: MIT
// Geometry of the inline ("immersive") overlay: where each translation label goes over KakaoTalk's bubbles.
// Pure CGRect math, no AppKit. All "local" rects use the transcript viewport's top-left corner as origin
// (y grows downward, like AX coordinates).

import CoreGraphics
import Foundation

/// Distances of the transcript viewport's edges from the chat window's edges (AX coordinates).
public struct ViewportInsets: Hashable, Sendable {
    public var left: CGFloat
    public var top: CGFloat
    public var right: CGFloat
    public var bottom: CGFloat

    public init(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
}

public enum InlineLayout {
    /// One message as read from the AX tree (AX global coordinates).
    public struct Anchor: Hashable, Sendable {
        public let id: MessageID
        /// Body text area.
        public let body: CGRect
        /// Bubble background (falls back to the body).
        public let bubble: CGRect
        public let isMine: Bool

        public init(id: MessageID, body: CGRect, bubble: CGRect? = nil, isMine: Bool) {
            self.id = id
            self.body = body
            self.bubble = bubble ?? body
            self.isMine = isMine
        }
    }

    /// An anchor converted to viewport-local coordinates.
    public struct Placed: Hashable, Sendable {
        public let id: MessageID
        /// Area the translation label covers by default: the body text area grown by `coverInset`.
        public let cover: CGRect
        public let bubble: CGRect
        public let isMine: Bool
    }

    /// Final frame of a translation label.
    public struct LabelFrame: Hashable, Sendable {
        public let rect: CGRect
        /// The text only fits when shrunk (down to the minimum scale factor).
        public let scaled: Bool
        /// The label grows past the body text area (drawn with a shadow, like a tooltip).
        public let extended: Bool
    }

    /// The label covers the body text area plus this many points on each side.
    public static let coverInset: CGFloat = 2

    // MARK: - Coordinates

    /// AX rect → viewport-local rect, shifted down by `scrollDelta` (content moved down since the read).
    public static func toLocal(_ r: CGRect, viewportAX: CGRect, scrollDelta: CGFloat = 0) -> CGRect {
        CGRect(x: r.minX - viewportAX.minX, y: r.minY - viewportAX.minY + scrollDelta, width: r.width, height: r.height)
    }

    /// Anchors whose bubble overlaps the viewport (grown vertically by `margin`), in viewport-local
    /// coordinates, sorted top to bottom. Rows parsed with a margin are kept so they are already laid out when
    /// they scroll in.
    public static func place(rows: [Anchor], viewportAX: CGRect, scrollDelta: CGFloat = 0,
                             margin: CGFloat = 0) -> [Placed] {
        let band = CGRect(x: 0, y: -margin, width: viewportAX.width, height: viewportAX.height + 2 * margin)
        var out: [Placed] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            let bubble = toLocal(row.bubble, viewportAX: viewportAX, scrollDelta: scrollDelta)
            guard bubble.width > 0, bubble.height > 0, bubble.intersects(band) else { continue }
            let body = toLocal(row.body, viewportAX: viewportAX, scrollDelta: scrollDelta)
            out.append(Placed(id: row.id, cover: body.insetBy(dx: -coverInset, dy: -coverInset), bubble: bubble,
                              isMine: row.isMine))
        }
        // Stable sort by top edge.
        return out.enumerated().sorted { a, b in
            a.element.bubble.minY != b.element.bubble.minY ? a.element.bubble.minY < b.element.bubble.minY
                : a.offset < b.offset
        }.map(\.element)
    }

    /// Vertical scroll offset since the read: how far the scroll anchor (the transcript table, whose AX frame
    /// is its document bounds, or a row) moved relative to the window. Positive = content moved down.
    /// Window movement is subtracted out when both window frames are known.
    public static func scrollDelta(anchorNow: CGRect, windowNow: CGRect?, anchorAtRead: CGRect,
                                   windowAtRead: CGRect?) -> CGFloat {
        guard let windowNow, let windowAtRead else { return anchorNow.minY - anchorAtRead.minY }
        return (anchorNow.minY - windowNow.minY) - (anchorAtRead.minY - windowAtRead.minY)
    }

    /// True when the table's AX frame behaves like document bounds (taller than the viewport or starting
    /// above it), so its position tracks scrolling. Otherwise a row is used as the scroll anchor.
    public static func usesTableAnchor(tableFrame: CGRect, viewport: CGRect) -> Bool {
        tableFrame.height > viewport.height + 1 || tableFrame.minY < viewport.minY - 1
    }

    public static func insets(viewport: CGRect, window: CGRect) -> ViewportInsets {
        ViewportInsets(left: viewport.minX - window.minX, top: viewport.minY - window.minY,
                       right: window.maxX - viewport.maxX, bottom: window.maxY - viewport.maxY)
    }

    /// Viewport for a (moved or resized) window, keeping the edge distances learned at the last read.
    public static func viewport(window: CGRect, insets i: ViewportInsets) -> CGRect {
        CGRect(x: window.minX + i.left, y: window.minY + i.top,
               width: max(0, window.width - i.left - i.right), height: max(0, window.height - i.top - i.bottom))
    }

    // MARK: - Labels

    /// Frame of the label for one translation.
    /// - cover / bubble: viewport-local rects from `place`
    /// - singleLineWidth: width of the translation on one line at full size, padding included
    /// - height: label height (padding included) needed at full size for a given label width
    /// - minScale: smallest font scale the label may use (SwiftUI minimumScaleFactor)
    /// - lineHeight: one line at full size
    ///
    /// Rules: the label is at least the cover; it may widen up to the bubble width (towards the bubble's
    /// inner side: leftwards for my messages, rightwards for others'), staying inside the bubble. If the text
    /// does not fit even at `minScale`, the label grows downward to at most the bubble's bottom plus one line.
    public static func labelFrame(cover: CGRect, bubble: CGRect, isMine: Bool, singleLineWidth: CGFloat,
                                  minScale: CGFloat, lineHeight: CGFloat,
                                  height: (CGFloat) -> CGFloat) -> LabelFrame {
        let maxWidth = max(cover.width, bubble.width)
        let width = min(max(singleLineWidth.rounded(.up), cover.width), maxWidth)
        var x: CGFloat
        if isMine {
            x = cover.maxX - width
            if bubble.width >= width, x < bubble.minX { x = bubble.minX }
        } else {
            x = cover.minX
            if bubble.width >= width, x + width > bubble.maxX { x = bubble.maxX - width }
        }
        let full = height(width)
        if full <= cover.height + 0.5 {
            return LabelFrame(rect: CGRect(x: x, y: cover.minY, width: width, height: cover.height),
                              scaled: false, extended: false)
        }
        let scale = min(max(minScale, 0.1), 1)
        let shrunk = height(width / scale) * scale
        if shrunk <= cover.height + 0.5 {
            return LabelFrame(rect: CGRect(x: x, y: cover.minY, width: width, height: cover.height),
                              scaled: true, extended: false)
        }
        let limit = max(cover.maxY, bubble.maxY) - cover.minY + lineHeight
        let h = min(full, limit)
        return LabelFrame(rect: CGRect(x: x, y: cover.minY, width: width, height: max(h, cover.height)),
                          scaled: full > limit, extended: true)
    }

    /// Lines that fit in `height` at the smallest scale (at least 1).
    public static func lineLimit(height: CGFloat, lineHeight: CGFloat, minScale: CGFloat) -> Int {
        guard lineHeight > 0 else { return 1 }
        return max(1, Int((height / (lineHeight * max(minScale, 0.1))).rounded(.down)))
    }

    /// A small note (e.g. for ㅋㅋㅋ) just below the bubble, aligned with its inner edge; nil when it does not
    /// fit in the gap above the next bubble (`nextTop`) or inside `bounds`.
    public static func noteFrame(bubble: CGRect, size: CGSize, isMine: Bool, nextTop: CGFloat?,
                                 bounds: CGRect, gap: CGFloat = 1) -> CGRect? {
        let y = bubble.maxY + gap
        let x = isMine ? bubble.maxX - size.width : bubble.minX
        let r = CGRect(x: x, y: y, width: size.width, height: size.height)
        if let nextTop, r.maxY > nextTop - gap { return nil }
        guard r.minX >= bounds.minX, r.maxX <= bounds.maxX, r.maxY <= bounds.maxY else { return nil }
        return r
    }

    /// Hover card for one bubble: above it when there is room in `bounds`, else below, else pinned to the
    /// top; horizontally aligned with the bubble's inner edge and kept inside `bounds`.
    public static func popoverFrame(bubble: CGRect, size: CGSize, isMine: Bool, bounds: CGRect,
                                    gap: CGFloat = 6) -> CGRect {
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        var x = isMine ? bubble.maxX - width : bubble.minX
        x = min(max(x, bounds.minX), bounds.maxX - width)
        let above = bubble.minY - gap - height
        let below = bubble.maxY + gap
        let y: CGFloat
        if above >= bounds.minY {
            y = above
        } else if below + height <= bounds.maxY {
            y = below
        } else {
            y = bounds.minY
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The placed message under `point` (viewport-local, current scroll offset), if any. Later (lower)
    /// bubbles win on overlap.
    public static func hit(_ point: CGPoint, in placed: [Placed], scrollDelta: CGFloat = 0) -> MessageID? {
        for p in placed.reversed() where p.bubble.union(p.cover).offsetBy(dx: 0, dy: scrollDelta).contains(point) {
            return p.id
        }
        return nil
    }
}
