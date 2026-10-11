// SPDX-License-Identifier: MIT
// The TalkLens mark drawn at runtime (same design as scripts/make_assets.swift): a dark-brown rounded-rectangle
// speech bubble with its tail at the bottom left, "가 > 文" inside, and a magnifier lens overlapping the
// bubble's bottom-right corner, on a KakaoTalk-yellow squircle.
//
// - `statusImage(_:)`: monochrome template for the menu bar (18×18 pt, vector drawing handler, so it is crisp
//   at 1× and 2×), with paused / activity / attention variants.
// - `colorImage(size:)`: the coloured app logo (About and onboarding windows).
//
// AppKit only; no dependency on other app types (rendered to PNG by a dev script for visual checks).

import AppKit

enum LogoArt {
    enum StatusVariant: Equatable, Sendable {
        /// Following / idle.
        case normal
        /// Translation paused: outlined, dimmed mark.
        case paused
        /// A read or a translation is in flight: small dot badge.
        case active
        /// Needs attention (no Accessibility permission, error): exclamation badge.
        case attention
    }

    static let statusSize = NSSize(width: 18, height: 18)

    private static let yellow = NSColor(srgbRed: 0xFE / 255, green: 0xE5 / 255, blue: 0x00, alpha: 1)
    private static let yellowLight = NSColor(srgbRed: 1, green: 0xF2 / 255, blue: 0x7A / 255, alpha: 1)
    private static let brown = NSColor(srgbRed: 0x3C / 255, green: 0x1E / 255, blue: 0x1E / 255, alpha: 1)
    private static let cream = NSColor(srgbRed: 1, green: 0xF6 / 255, blue: 0xB0 / 255, alpha: 1)
    private static let lensFill = NSColor(srgbRed: 1, green: 0xFB / 255, blue: 0xE0 / 255, alpha: 0.92)

    // MARK: - Menu bar template

    /// Template image (black + alpha; the menu bar tints it for light / dark / highlighted states).
    static func statusImage(_ variant: StatusVariant) -> NSImage {
        let image = NSImage(size: statusSize, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawStatusMark(ctx, variant: variant)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "TalkLens"
        return image
    }

    /// Geometry of the 18 pt mark (flipped: y grows downward).
    private enum M {
        static let bubble = CGRect(x: 0.6, y: 1.6, width: 14.6, height: 10.0)
        static let radius: CGFloat = 3.0
        static let tail: [CGPoint] = [CGPoint(x: 2.8, y: 11.0), CGPoint(x: 1.8, y: 15.6), CGPoint(x: 6.8, y: 11.0)]
        static let lensCenter = CGPoint(x: 14.2, y: 12.9)
        static let lensRadius: CGFloat = 2.6
        static let lensLine: CGFloat = 1.4
        static let lensGap: CGFloat = 0.8
        static let handleEnd = CGPoint(x: 17.3, y: 16.0)
        static let handleLine: CGFloat = 1.9
        static let badgeCenter = CGPoint(x: 14.7, y: 3.3)
    }

    private static func drawStatusMark(_ ctx: CGContext, variant: StatusVariant) {
        let ink = NSColor.black.cgColor
        let paused = variant == .paused
        // Backing scale of this rendering (1× / 2×): real glyphs only where they have enough pixels.
        let scale = abs(ctx.userSpaceToDeviceSpaceTransform.a)
        ctx.saveGState()
        ctx.setAlpha(paused ? 0.55 : 1)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let tail = CGMutablePath()
        tail.addLines(between: M.tail)
        tail.closeSubpath()
        ctx.setFillColor(ink)
        ctx.setStrokeColor(ink)
        if paused {
            // Outlined bubble with a solid tail; glyphs as two thin bars.
            ctx.setLineWidth(1.2)
            ctx.addPath(CGPath(roundedRect: M.bubble.insetBy(dx: 0.6, dy: 0.6), cornerWidth: M.radius - 0.6,
                               cornerHeight: M.radius - 0.6, transform: nil))
            ctx.strokePath()
            ctx.addPath(tail)
            ctx.fillPath()
            for bar in glyphBars() { ctx.fill(bar) }
        } else {
            ctx.addPath(CGPath(roundedRect: M.bubble, cornerWidth: M.radius, cornerHeight: M.radius, transform: nil))
            ctx.addPath(tail)
            ctx.fillPath()
            // "가 > 文" (2×) or two glyph bars (1×) cut out of the bubble.
            ctx.setBlendMode(.clear)
            if scale >= 1.5 {
                drawGlyphCutout(ctx)
            } else {
                for bar in glyphBars() { ctx.fill(bar) }
            }
            ctx.setBlendMode(.normal)
        }
        // Lens: clear a gap around the ring, then the ring (transparent inside) and the handle.
        let c = M.lensCenter, r = M.lensRadius
        ctx.setBlendMode(.clear)
        let gap = r + M.lensLine / 2 + M.lensGap
        ctx.fillEllipse(in: CGRect(x: c.x - gap, y: c.y - gap, width: 2 * gap, height: 2 * gap))
        ctx.setBlendMode(.normal)
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(M.lensLine)
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.setLineWidth(M.handleLine)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: c.x + r * 0.75, y: c.y + r * 0.75))
        ctx.addLine(to: M.handleEnd)
        ctx.strokePath()
        // Badges (top-right, over the bubble's corner).
        let b = M.badgeCenter
        switch variant {
        case .active:
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: b.x - 3.5, y: b.y - 3.5, width: 7, height: 7))
            ctx.setBlendMode(.normal)
            ctx.setFillColor(ink)
            ctx.fillEllipse(in: CGRect(x: b.x - 2.4, y: b.y - 2.4, width: 4.8, height: 4.8))
        case .attention:
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: b.x - 4.2, y: b.y - 4.2, width: 8.4, height: 8.4))
            ctx.setBlendMode(.normal)
            ctx.setFillColor(ink)
            ctx.fillEllipse(in: CGRect(x: b.x - 3.3, y: b.y - 3.3, width: 6.6, height: 6.6))
            // "!" cut out of the badge.
            ctx.setBlendMode(.clear)
            ctx.fill(CGRect(x: b.x - 0.6, y: b.y - 2.3, width: 1.2, height: 2.8))
            ctx.fill(CGRect(x: b.x - 0.6, y: b.y + 1.1, width: 1.2, height: 1.2))
            ctx.setBlendMode(.normal)
        case .normal, .paused:
            break
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// "가文" at menu-bar size (drawn with the current blend mode, i.e. cut out of the bubble). The logo's ">"
    /// is dropped here: at 18 pt there is no room for it between the two glyphs.
    private static func drawGlyphCutout(_ ctx: CGContext) {
        let b = M.bubble
        let size: CGFloat = 5.7
        let font = NSFont.systemFont(ofSize: size, weight: .heavy)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let y = b.midY - (font.ascender - font.descender) / 2 - 0.3
        NSAttributedString(string: "가", attributes: attributes).draw(at: CGPoint(x: b.minX + 1.5, y: y))
        NSAttributedString(string: "文", attributes: attributes).draw(at: CGPoint(x: b.maxX - 2.4 - size, y: y))
    }

    /// Two short bars standing in for the glyphs (1× and the paused variant).
    private static func glyphBars() -> [CGRect] {
        let b = M.bubble
        let y = (b.midY - 1).rounded()
        return [CGRect(x: b.minX + 2.4, y: y, width: 4, height: 2),
                CGRect(x: b.minX + 7.4, y: y, width: 3, height: 2)]
    }

    // MARK: - Colour logo

    /// The coloured logo (squircle + bubble + glyphs + lens), `size`×`size` points.
    static func colorImage(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            drawColorLogo(in: rect)
            return true
        }
    }

    private static func drawColorLogo(in rect: CGRect) {
        let s = min(rect.width, rect.height)
        let o = rect.origin
        // Squircle with a soft vertical gradient.
        let inset = s * 0.085
        let square = CGRect(x: o.x + inset, y: o.y + inset, width: s - 2 * inset, height: s - 2 * inset)
        let squircle = NSBezierPath(roundedRect: square, xRadius: square.width * 0.225, yRadius: square.width * 0.225)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = s * 0.03
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.set()
        yellow.setFill()
        squircle.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: yellowLight, ending: yellow)?.draw(in: squircle, angle: 90)
        // Speech bubble: rounded rectangle + tail (bottom-left).
        let b = CGRect(x: o.x + s * 0.20, y: o.y + s * 0.27, width: s * 0.60, height: s * 0.40)
        let bubble = NSBezierPath(roundedRect: b, xRadius: s * 0.11, yRadius: s * 0.11)
        let tail = NSBezierPath()
        tail.move(to: CGPoint(x: b.minX + s * 0.10, y: b.maxY - s * 0.02))
        tail.line(to: CGPoint(x: b.minX + s * 0.06, y: b.maxY + s * 0.11))
        tail.line(to: CGPoint(x: b.minX + s * 0.24, y: b.maxY - s * 0.02))
        tail.close()
        brown.setFill()
        bubble.fill()
        tail.fill()
        // "가 > 文"
        let glyph = s * 0.155
        let gy = b.midY - glyph * 0.62
        drawText("가", at: CGPoint(x: b.minX + s * 0.065, y: gy), size: glyph, color: yellow)
        drawText("文", at: CGPoint(x: b.maxX - s * 0.065 - glyph * 1.02, y: gy), size: glyph, color: .white)
        let arrow = NSBezierPath()
        let ax = b.midX - s * 0.035, ay = b.midY
        arrow.move(to: CGPoint(x: ax, y: ay - s * 0.03))
        arrow.line(to: CGPoint(x: ax + s * 0.05, y: ay))
        arrow.line(to: CGPoint(x: ax, y: ay + s * 0.03))
        arrow.lineWidth = s * 0.022
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        cream.setStroke()
        arrow.stroke()
        // Lens: ring + handle at the bottom right, overlapping the bubble edge.
        let r = s * 0.105
        let c = CGPoint(x: b.maxX - s * 0.02, y: b.maxY + s * 0.02)
        let handle = NSBezierPath()
        handle.move(to: CGPoint(x: c.x + r * 0.7, y: c.y + r * 0.7))
        handle.line(to: CGPoint(x: c.x + r * 1.55, y: c.y + r * 1.55))
        handle.lineWidth = s * 0.05
        handle.lineCapStyle = .round
        brown.setStroke()
        handle.stroke()
        let ring = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        lensFill.setFill()
        ring.fill()
        ring.lineWidth = s * 0.035
        brown.setStroke()
        ring.stroke()
    }

    private static func drawText(_ string: String, at point: CGPoint, size: CGFloat, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .heavy), .foregroundColor: color,
        ]
        NSAttributedString(string: string, attributes: attributes).draw(at: point)
    }
}
