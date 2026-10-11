// SPDX-License-Identifier: MIT
// Renders TalkLens' artwork: app icon (Resources/AppIcon.icns via an .iconset), README images (assets/*.png)
// and the DMG background (assets/dmg-background*.png). All chat text is synthetic.
//
// Usage: swift scripts/make_assets.swift        (run from the repository root; needs AppKit, no network)
// Palette: KakaoTalk-like yellow + dark brown. The mark is deliberately NOT Kakao's logo (no oval "TALK"
// bubble): a rounded-rectangle bubble with "가→文" and a lens.

import AppKit
import Foundation

// MARK: - Palette

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

let yellow = NSColor(hex: 0xFEE500)
let yellowLight = NSColor(hex: 0xFFF27A)
let brown = NSColor(hex: 0x3C1E1E)
let brownSoft = NSColor(hex: 0x6B4A3A)
let chatBG = NSColor(hex: 0xBACEE0)
let white = NSColor.white

// MARK: - Bitmap helpers

func render(width: Int, height: Int, _ draw: (CGRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
    // Flip so that y grows downward (layout reads top to bottom).
    ctx.cgContext.translateBy(x: 0, y: CGFloat(height))
    ctx.cgContext.scaleBy(x: 1, y: -1)
    draw(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
}

/// Draws text with its top-left at `point` in the flipped context.
@discardableResult
func text(_ s: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = brown,
          maxWidth: CGFloat = 10_000, align: NSTextAlignment = .left, lineSpacing: CGFloat = 0) -> CGSize {
    let para = NSMutableParagraphStyle()
    para.alignment = align
    para.lineSpacing = lineSpacing
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: para,
    ]
    let str = NSAttributedString(string: s, attributes: attrs)
    let bounds = str.boundingRect(with: CGSize(width: maxWidth, height: 10_000),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading])
    let w = align == .left ? ceil(bounds.width) : maxWidth
    let rect = CGRect(x: point.x, y: point.y, width: w, height: ceil(bounds.height))
    // NSString drawing in a flipped context needs a flipped graphics context flag.
    NSGraphicsContext.current = NSGraphicsContext(cgContext: NSGraphicsContext.current!.cgContext, flipped: true)
    str.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
}

func measure(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, maxWidth: CGFloat) -> CGSize {
    let str = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)])
    let b = str.boundingRect(with: CGSize(width: maxWidth, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
    return CGSize(width: ceil(b.width), height: ceil(b.height))
}

func fillRound(_ rect: CGRect, radius: CGFloat, _ color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func shadow(_ blur: CGFloat, _ dy: CGFloat, alpha: CGFloat, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: -dy)   // flipped context: positive dy = downward
    s.shadowColor = NSColor.black.withAlphaComponent(alpha)
    s.set()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - Icon

/// The TalkLens mark in a `size`×`size` square at `origin`.
func drawIcon(origin: CGPoint, size s: CGFloat, background: Bool = true) {
    let o = origin
    if background {
        // macOS-style squircle with a soft vertical gradient.
        let inset = s * 0.085
        let rect = CGRect(x: o.x + inset, y: o.y + inset, width: s - 2 * inset, height: s - 2 * inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
        shadow(s * 0.03, s * 0.012, alpha: 0.25) {
            yellow.setFill()
            path.fill()
        }
        NSGradient(starting: yellowLight, ending: yellow)!.draw(in: path, angle: 90)
    }
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
    // "가 → 文"
    let glyph = s * 0.155
    let gy = b.midY - glyph * 0.62
    text("가", at: CGPoint(x: b.minX + s * 0.065, y: gy), size: glyph, weight: .heavy, color: yellow)
    text("文", at: CGPoint(x: b.maxX - s * 0.065 - glyph * 1.02, y: gy), size: glyph, weight: .heavy, color: white)
    let arrow = NSBezierPath()
    let ax = b.midX - s * 0.035, ay = b.midY
    arrow.move(to: CGPoint(x: ax, y: ay - s * 0.03))
    arrow.line(to: CGPoint(x: ax + s * 0.05, y: ay))
    arrow.line(to: CGPoint(x: ax, y: ay + s * 0.03))
    arrow.lineWidth = s * 0.022
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(hex: 0xFFF6B0).setStroke()
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
    NSColor(hex: 0xFFFBE0, alpha: 0.92).setFill()
    ring.fill()
    ring.lineWidth = s * 0.035
    brown.setStroke()
    ring.stroke()
}

// MARK: - Chat mock pieces (synthetic text)

struct Msg {
    var author: String?
    var original: String
    var translation: String?
    var mine = false
    var time: String?
}

let demoMessages: [Msg] = [
    Msg(author: "랩장", original: "내일 랩미팅은 오후 2시에서 4시로 변경되었습니다.", translation: "明天的组会从下午 2 点改到 4 点。"),
    Msg(author: nil, original: "회의실은 E3-1 1501호입니다.", translation: "会议室在 E3-1 1501 号。", time: "오후 3:12"),
    Msg(author: nil, original: "넵 알겠습니다!", translation: "好的，知道了！", mine: true, time: "오후 3:13"),
    Msg(author: "조교", original: "오늘 3교시 휴강입니다. 보강 일정은 추후 공지하겠습니다.", translation: "今天第 3 节课停课，补课时间另行通知。", time: "오후 3:20"),
    Msg(author: nil, original: "ㅋㅋㅋㅋ", translation: nil, mine: true, time: "오후 3:21"),
]

/// A KakaoTalk-like chat window mock. Returns the bubble rects (for overlays / hover card placement).
@discardableResult
func drawChatWindow(_ frame: CGRect, title: String, translated: Bool, hoverIndex: Int? = nil) -> [CGRect] {
    let radius: CGFloat = 22
    shadow(36, 18, alpha: 0.28) { fillRound(frame, radius: radius, chatBG) }
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).addClip()
    // Title bar.
    let bar = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 92)
    NSColor(hex: 0xA9C0D6).setFill()
    NSBezierPath(rect: bar).fill()
    for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        fillRound(CGRect(x: frame.minX + 26 + CGFloat(i) * 30, y: frame.minY + 22, width: 18, height: 18), radius: 9, NSColor(hex: UInt32(c)))
    }
    text(title, at: CGPoint(x: frame.minX + 26, y: frame.minY + 50), size: 24, weight: .semibold, color: brown)
    // Input area.
    let input = CGRect(x: frame.minX, y: frame.maxY - 92, width: frame.width, height: 92)
    white.setFill()
    NSBezierPath(rect: input).fill()
    text("Enter a message", at: CGPoint(x: frame.minX + 26, y: input.minY + 22), size: 21, color: NSColor(hex: 0xA0A0A0))
    fillRound(CGRect(x: frame.maxX - 116, y: input.minY + 18, width: 92, height: 50), radius: 12, NSColor(hex: 0xF2F2F2))
    text("Send", at: CGPoint(x: frame.maxX - 96, y: input.minY + 30), size: 20, weight: .medium, color: NSColor(hex: 0xAAAAAA))
    NSGraphicsContext.restoreGraphicsState()

    // Messages.
    var y = bar.maxY + 28
    var rects: [CGRect] = []
    let maxBubble = frame.width * 0.66
    for (i, m) in demoMessages.enumerated() {
        let font: CGFloat = 21
        let showTranslation = translated && m.translation != nil && hoverIndex != i
        let body = showTranslation ? m.translation! : m.original
        if let a = m.author, !m.mine {
            fillRound(CGRect(x: frame.minX + 24, y: y, width: 54, height: 54), radius: 20, NSColor(hex: m.author == "조교" ? 0x8FB8A8 : 0xC9A97E))
            text(String(a.prefix(1)), at: CGPoint(x: frame.minX + 39, y: y + 11), size: 24, weight: .bold, color: white)
            text(a, at: CGPoint(x: frame.minX + 92, y: y), size: 18, weight: .medium, color: brownSoft)
            y += 30
        }
        // The overlay covers the original bubble, so the bubble keeps the original's size in both windows.
        let size = measure(m.original, size: font, maxWidth: maxBubble - 36)
        let bw = size.width + 36, bh = size.height + 26
        let bx = m.mine ? frame.maxX - 26 - bw : frame.minX + 92
        let bubble = CGRect(x: bx, y: y, width: bw, height: bh)
        fillRound(bubble, radius: 16, m.mine ? yellow : white)
        if showTranslation {
            // TalkLens overlay: same colour as the bubble, a hairline accent shows it is a translation.
            NSColor(hex: 0x3C1E1E, alpha: 0.10).setStroke()
            let outline = NSBezierPath(roundedRect: bubble.insetBy(dx: 1, dy: 1), xRadius: 15, yRadius: 15)
            outline.lineWidth = 2
            outline.stroke()
        }
        text(body, at: CGPoint(x: bx + 18, y: y + 13), size: font, color: NSColor(hex: 0x1F1F1F), maxWidth: maxBubble - 36)
        if let t = m.time {
            let tw = measure(t, size: 15, maxWidth: 200).width
            let tx = m.mine ? bubble.minX - 10 - tw : bubble.maxX + 10
            text(t, at: CGPoint(x: tx, y: bubble.maxY - 22), size: 15, color: NSColor(hex: 0x5A6B7B))
        }
        rects.append(bubble)
        y = bubble.maxY + 16
    }
    return rects
}

func drawHoverCard(near bubble: CGRect, msg: Msg, chips: [(String, String)]) {
    let w: CGFloat = 430
    let card = CGRect(x: bubble.minX + 40, y: bubble.maxY + 14, width: w, height: 136)
    shadow(24, 10, alpha: 0.22) { fillRound(card, radius: 16, white) }
    text("TalkLens", at: CGPoint(x: card.minX + 20, y: card.minY + 14), size: 15, weight: .bold, color: NSColor(hex: 0xB59A00))
    text(msg.translation ?? "", at: CGPoint(x: card.minX + 20, y: card.minY + 40), size: 21, weight: .semibold, color: brown, maxWidth: w - 40)
    var x = card.minX + 20
    for (term, gloss) in chips {
        let label = "\(term)  \(gloss)"
        let lw = measure(label, size: 16, weight: .medium, maxWidth: 400).width + 22
        fillRound(CGRect(x: x, y: card.minY + 88, width: lw, height: 32), radius: 9, NSColor(hex: 0xFFF6B0))
        text(label, at: CGPoint(x: x + 11, y: card.minY + 93), size: 16, weight: .medium, color: brown)
        x += lw + 10
    }
}

// MARK: - Images

let root = FileManager.default.currentDirectoryPath

// App icon (.iconset → .icns via iconutil in package scripts).
let iconset = "\(root)/build/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = render(width: px, height: px) { _ in drawIcon(origin: .zero, size: CGFloat(px)) }
        save(rep, "\(iconset)/icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png")
    }
}
save(render(width: 512, height: 512) { _ in drawIcon(origin: .zero, size: 512) }, "\(root)/assets/icon.png")

// README banner (2× for retina).
save(render(width: 2400, height: 900) { r in
    NSGradient(colors: [yellowLight, yellow, NSColor(hex: 0xF7D900)])!.draw(in: NSBezierPath(rect: r), angle: -90)
    // Soft decorative bubbles.
    for (cx, cy, rad, a) in [(2140.0, 140.0, 220.0, 0.10), (2260.0, 760.0, 300.0, 0.07), (120.0, 820.0, 180.0, 0.06)] {
        NSColor(hex: 0x3C1E1E, alpha: a).setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - rad, y: cy - rad, width: 2 * rad, height: 2 * rad)).fill()
    }
    drawIcon(origin: CGPoint(x: 150, y: 210), size: 480)
    text("TalkLens", at: CGPoint(x: 700, y: 220), size: 150, weight: .heavy, color: brown)
    text("KakaoTalk 沉浸式翻译 · 카카오톡 몰입형 번역 · Immersive translation for KakaoTalk",
         at: CGPoint(x: 708, y: 420), size: 46, weight: .semibold, color: brown)
    text("只读  ·  本机离线（Apple 翻译）·  开源  ·  macOS 15+", at: CGPoint(x: 708, y: 500), size: 40, weight: .medium, color: brownSoft)
    let pill = "Read-only · On-device · Open source"
    let pw = measure(pill, size: 38, weight: .semibold, maxWidth: 2000).width
    fillRound(CGRect(x: 708, y: 600, width: pw + 84, height: 92), radius: 46, brown)
    text(pill, at: CGPoint(x: 750, y: 622), size: 38, weight: .semibold, color: yellow)
}, "\(root)/assets/banner.png")

// Before / after demo (2×).
save(render(width: 2400, height: 1060) { r in
    NSColor(hex: 0xFFFBEA).setFill()
    NSBezierPath(rect: r).fill()
    text("KakaoTalk", at: CGPoint(x: 120, y: 56), size: 44, weight: .bold, color: brownSoft)
    text("+ TalkLens 沉浸式", at: CGPoint(x: 1300, y: 56), size: 44, weight: .bold, color: brown)
    let left = CGRect(x: 100, y: 140, width: 1000, height: 860)
    let right = CGRect(x: 1290, y: 140, width: 1000, height: 860)
    drawChatWindow(left, title: "합성 연구실 단톡방", translated: false)
    let rects = drawChatWindow(right, title: "합성 연구실 단톡방", translated: true, hoverIndex: 3)
    // Arrow between the windows.
    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: 1135, y: 570))
    arrow.line(to: CGPoint(x: 1255, y: 570))
    arrow.move(to: CGPoint(x: 1225, y: 540))
    arrow.line(to: CGPoint(x: 1255, y: 570))
    arrow.line(to: CGPoint(x: 1225, y: 600))
    arrow.lineWidth = 12
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    brown.setStroke()
    arrow.stroke()
    // Hover card over the TA message, showing the translation + glossary chips while the bubble shows the original.
    drawHoverCard(near: rects[3], msg: demoMessages[3], chips: [("휴강", "停课"), ("보강", "补课")])
    // Cursor.
    let cur = NSBezierPath()
    let cx = rects[3].midX + 60, cy = rects[3].midY + 4
    cur.move(to: CGPoint(x: cx, y: cy))
    cur.line(to: CGPoint(x: cx, y: cy + 46))
    cur.line(to: CGPoint(x: cx + 12, y: cy + 35))
    cur.line(to: CGPoint(x: cx + 22, y: cy + 56))
    cur.line(to: CGPoint(x: cx + 30, y: cy + 52))
    cur.line(to: CGPoint(x: cx + 20, y: cy + 32))
    cur.line(to: CGPoint(x: cx + 36, y: cy + 32))
    cur.close()
    NSColor.black.setFill()
    cur.fill()
    white.setStroke()
    cur.lineWidth = 3
    cur.stroke()
}, "\(root)/assets/demo.png")

// DMG background: 660×420 points, with @2x.
func dmgBackground(scale: CGFloat) -> NSBitmapImageRep {
    render(width: Int(660 * scale), height: Int(420 * scale)) { r in
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.scaleBy(x: scale, y: scale)
        let rect = CGRect(x: 0, y: 0, width: 660, height: 420)
        NSGradient(starting: NSColor(hex: 0xFFF7C2), ending: NSColor(hex: 0xFEE500))!.draw(in: NSBezierPath(rect: rect), angle: -90)
        text("TalkLens", at: CGPoint(x: 0, y: 34), size: 34, weight: .heavy, color: brown, maxWidth: 660, align: .center)
        text("KakaoTalk 沉浸式翻译 · Immersive translation for KakaoTalk", at: CGPoint(x: 0, y: 82), size: 14,
             weight: .medium, color: brownSoft, maxWidth: 660, align: .center)
        // Arrow from the app slot (x≈180) to the Applications slot (x≈480), icons centred at y≈220.
        let arrow = NSBezierPath()
        arrow.move(to: CGPoint(x: 262, y: 220))
        arrow.curve(to: CGPoint(x: 398, y: 220), controlPoint1: CGPoint(x: 300, y: 196), controlPoint2: CGPoint(x: 360, y: 196))
        arrow.move(to: CGPoint(x: 384, y: 205))
        arrow.line(to: CGPoint(x: 398, y: 220))
        arrow.line(to: CGPoint(x: 380, y: 230))
        arrow.lineWidth = 5
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        brown.withAlphaComponent(0.8).setStroke()
        arrow.stroke()
        text("拖到「应用程序」完成安装  ·  Drag to Applications to install", at: CGPoint(x: 0, y: 338), size: 14,
             weight: .semibold, color: brown, maxWidth: 660, align: .center)
        text("首次打开：右键 → 打开  ·  First launch: right-click → Open", at: CGPoint(x: 0, y: 362), size: 12,
             color: brownSoft, maxWidth: 660, align: .center)
        _ = r
    }
}
save(dmgBackground(scale: 1), "\(root)/assets/dmg-background.png")
save(dmgBackground(scale: 2), "\(root)/assets/dmg-background@2x.png")
