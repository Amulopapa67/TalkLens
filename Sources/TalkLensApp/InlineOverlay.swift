// SPDX-License-Identifier: MIT
// Inline ("immersive") display mode: a transparent, click-through window over the chat window's transcript
// viewport that paints each translation over its bubble's text area.
//
// Read-only: nothing is injected into KakaoTalk. The overlay ignores all mouse events (clicks, selection,
// right-click and scrolling go straight to KakaoTalk). Scroll, mouse-move and modifier-flag events are only
// *observed* through NSEvent monitors; no event is ever posted. While following a scroll, the only AX
// traffic is one position/size read of the scroll anchor element per display frame.
//
// Occlusion: the overlay sits at `.floating`, so it would paint over any window that covers the chat window.
// AppController feeds the covered rects (window-server metadata, see WindowOcclusion) into `setOccluders`;
// they are cut out of a CAShapeLayer mask on the viewport container (scrolling never touches the mask), and
// hover / hover cards ignore covered areas.

import AppKit
import KakaoAX
import os
import SwiftUI
import TalkLensCore

private let logger = Logger.talkLens("inline")

/// Borderless, non-activating, click-through overlay window.
final class InlineOverlayWindow: NSPanel {
    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                  styleMask: [.nonactivatingPanel, .borderless],
                  backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // Same Space behaviour as the sidebar panel (D-007).
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Flipped, clipping container: the hosting view inside it is shifted by the scroll offset.
final class InlineContainerView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Fixed metrics of the overlay labels (KakaoTalk's body text is about 14 pt).
enum InlineStyle {
    static let fontSize: CGFloat = 14
    static let minScale: CGFloat = 0.75
    static let padding = CGSize(width: 3, height: 1)
    static let noteFontSize: CGFloat = 10
    static let popoverFontSize: CGFloat = 13
    static let popoverChipsFontSize: CGFloat = 11
    static let popoverMaxWidth: CGFloat = 280
    static let popoverPadding = CGSize(width: 8, height: 6)
    /// KakaoTalk's own-message bubble (approximate sRGB).
    static let mineFill = Color(.sRGB, red: 0.98, green: 0.90, blue: 0.31)
    static let otherFillLight = Color.white
    static let otherFillDark = Color(.sRGB, red: 0.20, green: 0.20, blue: 0.21)
    static let darkInk = Color(.sRGB, white: 0.08)
    static let lightInk = Color(.sRGB, white: 0.92)
}

// MARK: - State

/// One translation label, in content coordinates (viewport-local at read time, shifted down by the margin).
struct InlineLabel: Identifiable, Equatable {
    let id: MessageID
    let rect: CGRect
    let text: String
    let isMine: Bool
    let extended: Bool
    let lineLimit: Int
    let badge: Bool
}

struct InlineNote: Identifiable, Equatable {
    let id: MessageID
    let rect: CGRect
    let text: String
}

struct InlinePopover: Equatable {
    let id: MessageID
    let rect: CGRect
    let text: String
    let chips: String?
}

@MainActor
@Observable
final class InlineOverlayState {
    var labels: [InlineLabel] = []
    var notes: [InlineNote] = []
    var popover: InlinePopover?
    /// Label hidden because the pointer is over its bubble (the original shows through).
    var hiddenID: MessageID?
}

// MARK: - Views

struct InlineOverlayView: View {
    let state: InlineOverlayState

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(state.labels) { label in
                InlineLabelView(label: label, hidden: state.hiddenID == label.id)
                    .offset(x: label.rect.minX, y: label.rect.minY)
            }
            ForEach(state.notes) { note in
                InlineNoteView(note: note)
                    .offset(x: note.rect.minX, y: note.rect.minY)
            }
            if let popover = state.popover {
                InlinePopoverView(popover: popover)
                    .offset(x: popover.rect.minX, y: popover.rect.minY)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct InlineLabelView: View {
    let label: InlineLabel
    let hidden: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var appeared = false

    var body: some View {
        let dark = scheme == .dark
        let fill = label.isMine ? InlineStyle.mineFill : (dark ? InlineStyle.otherFillDark : InlineStyle.otherFillLight)
        let ink = (label.isMine || !dark) ? InlineStyle.darkInk : InlineStyle.lightInk
        Text(label.text)
            .font(.system(size: InlineStyle.fontSize))
            .foregroundStyle(ink)
            .lineLimit(label.lineLimit)
            .minimumScaleFactor(InlineStyle.minScale)
            .allowsTightening(true)
            .truncationMode(.tail)
            .padding(.horizontal, InlineStyle.padding.width)
            .padding(.vertical, InlineStyle.padding.height)
            .frame(width: label.rect.width, height: label.rect.height, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: label.extended ? 6 : 4, style: .continuous)
                    .fill(fill)
                    .shadow(color: .black.opacity(label.extended ? 0.22 : 0), radius: 3, y: 1)
            )
            .overlay(alignment: .topTrailing) {
                if label.badge {
                    Text("词")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.9)))
                        .offset(x: 3, y: -3)
                }
            }
            .opacity(appeared && !hidden ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: hidden)
            .onAppear { withAnimation(.easeOut(duration: 0.15)) { appeared = true } }
    }
}

struct InlineNoteView: View {
    let note: InlineNote

    var body: some View {
        Text(note.text)
            .font(.system(size: InlineStyle.noteFontSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: note.rect.width, height: note.rect.height)
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
    }
}

struct InlinePopoverView: View {
    let popover: InlinePopover

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(popover.text)
                .font(.system(size: InlineStyle.popoverFontSize))
                .foregroundStyle(.primary)
            if let chips = popover.chips {
                Text(chips)
                    .font(.system(size: InlineStyle.popoverChipsFontSize))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, InlineStyle.popoverPadding.width)
        .padding(.vertical, InlineStyle.popoverPadding.height)
        .frame(width: popover.rect.width, height: popover.rect.height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        )
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}

// MARK: - Text measurement

/// Memoized text sizes (system font). The cache holds translation strings in memory only and is cleared
/// whenever the overlay is deactivated.
@MainActor
final class TextMeasurer {
    private struct Key: Hashable {
        let text: String
        let fontSize: CGFloat
        let width: CGFloat
    }

    static let cacheCap = 4_000
    static let unbounded: CGFloat = 100_000
    private var cache: [Key: CGSize] = [:]

    func size(_ text: String, fontSize: CGFloat, width: CGFloat) -> CGSize {
        let key = Key(text: text, fontSize: fontSize, width: max(1, width.rounded(.down)))
        if let cached = cache[key] { return cached }
        if cache.count >= Self.cacheCap { cache.removeAll(keepingCapacity: true) }
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
        let r = attributed.boundingRect(with: CGSize(width: key.width, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = CGSize(width: ceil(r.width), height: ceil(r.height))
        cache[key] = size
        return size
    }

    func clear() { cache.removeAll() }

    static func lineHeight(_ fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        return ceil(font.ascender - font.descender + font.leading)
    }
}

// MARK: - Controller

@MainActor
final class InlineOverlayController {
    static let fastTrackInterval: Duration = .milliseconds(16)
    /// Fast tracking stops this long after the last scroll event / anchor movement.
    static let fastTrackQuiet: Duration = .milliseconds(150)
    /// After AXRowCountChanged, follow KakaoTalk's own auto-scroll animation for this long.
    static let rowChangeBurst: Duration = .milliseconds(300)
    /// A resize re-reads the transcript once the window size has been stable this long.
    static let resizeSettle: Duration = .milliseconds(250)

    let state = InlineOverlayState()
    private let model: SidebarViewModel
    private let tracker: WindowTracker
    private let diagnostics: Diagnostics
    private let window = InlineOverlayWindow()
    private let container = InlineContainerView()
    private let hosting: NSHostingView<InlineOverlayView>
    private let measurer = TextMeasurer()

    // Geometry of the last read (AX coordinates).
    private var anchors: [InlineLayout.Anchor] = []
    private var viewportAtRead: CGRect?
    private var windowAtRead: CGRect?
    private var insets: ViewportInsets?
    private var scrollAnchor: ScrollAnchor?
    private var anchorGeneration = 0
    /// Viewport-local placement at read time (scroll offset 0).
    private var placed: [InlineLayout.Placed] = []
    private var translatedIDs: Set<MessageID> = []
    /// Content is laid out this far below the hosting view's top so rows above the viewport can be drawn.
    private var margin: CGFloat = 0
    private var scrollDelta: CGFloat = 0
    /// Scroll offset the current `placed` / labels were laid out for. Once the live offset drifts more than
    /// half a margin from it, the layout is rebased so rows that scrolled into the band get labels.
    private var baseDelta: CGFloat = 0
    private var viewportAX: CGRect?
    /// Offset of the hosting view relative to the laid-out content.
    private var shift: CGFloat { scrollDelta - baseDelta }

    // Occlusion (see WindowOcclusion): covered rects in AX global and in viewport-local coordinates.
    private var occludersAX: [CGRect] = []
    private var occludersLocal: [CGRect] = []
    private var maskedSize: CGSize = .zero
    private let maskLayer = CAShapeLayer()

    private(set) var active = false
    private var optionHeld = false
    private var resizing = false
    private var hoveredID: MessageID?
    private var lastMouse: NSPoint?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var fastTask: Task<Void, Never>?
    private var lastChangeAt = ContinuousClock.now
    private var burstUntil: ContinuousClock.Instant?
    private var movedSinceRead = false
    private var resizeTask: Task<Void, Never>?

    init(model: SidebarViewModel, tracker: WindowTracker, diagnostics: Diagnostics) {
        self.model = model
        self.tracker = tracker
        self.diagnostics = diagnostics
        hosting = NSHostingView(rootView: InlineOverlayView(state: state))
        // The hosting view's size is driven by the viewport, never by SwiftUI's ideal size.
        hosting.sizingOptions = []
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.autoresizesSubviews = false
        window.contentView = container
        container.addSubview(hosting)
        observeRows()
    }

    // MARK: Inputs

    /// A full transcript read: re-anchor every label to fresh frames and reset the scroll offset.
    func ingest(_ read: ChatWindowRead, anchor: ScrollAnchor?) {
        guard let viewport = read.transcriptFrame, viewport.width > 0, viewport.height > 0 else {
            clearLayout()
            return
        }
        viewportAtRead = viewport
        windowAtRead = read.windowFrame
        insets = read.windowFrame.map { InlineLayout.insets(viewport: viewport, window: $0) }
        scrollAnchor = anchor
        anchorGeneration &+= 1
        anchors = read.snapshot.messages.compactMap { m in
            guard !m.isSystem, let body = m.frame?.cgRect else { return nil }
            return InlineLayout.Anchor(id: m.id, body: body, bubble: m.bubbleFrame?.cgRect, isMine: m.isMine)
        }
        margin = viewport.height
        scrollDelta = 0
        baseDelta = 0
        movedSinceRead = false
        resizing = false
        if active { diagnostics.recordOverlayReanchor() }
        updateViewport()
        rebuild()
        updateContentVisibility(animated: false)
    }

    /// Window moved / resized / (de)minimized.
    func geometryChanged(_ geometry: WindowTracker.Geometry) {
        updateViewport()
    }

    /// AXRowCountChanged on the followed transcript: follow KakaoTalk's auto-scroll for a moment.
    func transcriptRowsChanged() {
        guard active else { return }
        burstUntil = .now + Self.rowChangeBurst
        lastChangeAt = .now
        startFastTracking()
    }

    func screensChanged() {
        updateViewport()
    }

    /// Rects (AX global coordinates) of windows above the chat window. The overlay draws nothing there and
    /// hover ignores them.
    func setOccluders(_ rects: [CGRect]) {
        guard rects != occludersAX else { return }
        occludersAX = rects
        updateMask()
        guard active else { return }
        updateHover()
        // Same hovered message, but its card may now intersect (or no longer intersect) a covering window.
        if let hovered = hoveredID {
            let popover = makePopover(hovered)
            if state.popover != popover { state.popover = popover }
        }
    }

    /// Visible in inline mode while a tracked chat window is on screen (not minimized, not on another Space,
    /// not entirely covered) and translation is not paused — also when KakaoTalk is not frontmost; windows
    /// covering the chat window are masked out (`setOccluders`).
    func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        logger.debug("inline active=\(value, privacy: .public)")
        if value {
            installMonitors()
            optionHeld = NSEvent.modifierFlags.contains(.option)
            updateViewport()
            rebuild()
            window.level = .floating
            // Never activates TalkLens (non-activating panel) and never touches KakaoTalk.
            window.orderFrontRegardless()
            updateContentVisibility(animated: false)
        } else {
            removeMonitors()
            stopFastTracking()
            resizeTask?.cancel()
            resizeTask = nil
            window.orderOut(nil)
            setHover(nil)
            // Drop drawn translations and measured strings while hidden (rebuilt on the next activation).
            state.labels = []
            state.notes = []
            measurer.clear()
        }
    }

    func stop() {
        setActive(false)
        clearLayout()
    }

    // MARK: Layout

    private func clearLayout() {
        anchors = []
        placed = []
        translatedIDs = []
        viewportAtRead = nil
        windowAtRead = nil
        insets = nil
        scrollAnchor = nil
        anchorGeneration &+= 1
        scrollDelta = 0
        baseDelta = 0
        state.labels = []
        state.notes = []
        setHover(nil)
    }

    /// Follows the chat window: viewport = window frame + the viewport's edge distances at the last read.
    private func updateViewport() {
        let window = tracker.geometry.windowAX
        if let insets, let window {
            viewportAX = InlineLayout.viewport(window: window, insets: insets)
            let sizeChanged = windowAtRead.map { $0.size != window.size } ?? false
            if sizeChanged && active { windowResizing() }
        } else {
            viewportAX = viewportAtRead
        }
        placeWindow()
    }

    private func placeWindow() {
        guard let viewport = viewportAX, viewport.width > 0, viewport.height > 0,
              let primary = NSScreen.screens.first else { return }
        let frame = ScreenGeometry.axToCocoa(viewport, primaryMaxY: primary.frame.maxY)
        if window.frame != frame {
            window.setFrame(frame, display: active, animate: false)
            container.frame = CGRect(origin: .zero, size: frame.size)
        }
        updateMask()
        layoutHosting()
    }

    /// Masks the container with `viewport − union(occluders)`. Only rebuilt when the covered rects (viewport-
    /// local) or the viewport size change; scrolling moves the hosting view inside the fixed mask.
    private func updateMask() {
        guard let viewport = viewportAX, let layer = container.layer else { return }
        let bounds = CGRect(origin: .zero, size: viewport.size)
        let local: [CGRect] = occludersAX.compactMap { r in
            let l = CGRect(x: r.minX - viewport.minX, y: r.minY - viewport.minY, width: r.width, height: r.height)
                .intersection(bounds)
            return l.isNull || l.width <= 0 || l.height <= 0 ? nil : l
        }
        let maskInstalled = layer.mask != nil
        guard local != occludersLocal || bounds.size != maskedSize || local.isEmpty == maskInstalled else { return }
        occludersLocal = local
        maskedSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let first = local.first else {
            layer.mask = nil
            return
        }
        var covered = CGPath(rect: first, transform: nil)
        for r in local.dropFirst() { covered = covered.union(CGPath(rect: r, transform: nil)) }
        var visible = CGPath(rect: bounds, transform: nil).subtracting(covered)
        // The container is flipped (top-left origin) and AppKit flips its backing layer to match; handle the
        // unflipped case anyway.
        if !layer.isGeometryFlipped {
            var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
            visible = visible.copy(using: &flip) ?? visible
        }
        maskLayer.frame = bounds
        maskLayer.fillColor = NSColor.black.cgColor
        maskLayer.path = visible
        if layer.mask !== maskLayer { layer.mask = maskLayer }
    }

    /// Viewport-local point (top-left origin) under a window that covers the chat window.
    private func isOccluded(_ point: CGPoint) -> Bool {
        occludersLocal.contains { $0.contains(point) }
    }

    /// Global Cocoa point (bottom-left origin) under a window that covers the chat window.
    private func isOccluded(cocoa point: NSPoint) -> Bool {
        guard !occludersAX.isEmpty, let primary = NSScreen.screens.first else { return false }
        let ax = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        return occludersAX.contains { $0.contains(ax) }
    }

    private func layoutHosting() {
        let width = container.bounds.width
        let height = max(container.bounds.height, viewportAtRead?.height ?? 0) + 2 * margin
        let frame = CGRect(x: 0, y: -margin + shift, width: width, height: height)
        if hosting.frame.size != frame.size {
            hosting.frame = frame
        } else if hosting.frame.origin != frame.origin {
            hosting.setFrameOrigin(frame.origin)
        }
    }

    private func applyOffset() {
        hosting.setFrameOrigin(NSPoint(x: 0, y: -margin + shift))
    }

    private func windowResizing() {
        if !resizing {
            resizing = true
            updateContentVisibility(animated: false)
            setHover(nil)
        }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: InlineOverlayController.resizeSettle)
            guard !Task.isCancelled, let self else { return }
            self.resizeTask = nil
            // Bubbles reflow on resize: only a fresh read gives their frames.
            self.tracker.requestRead()
        }
    }

    /// Labels hide while ⌥ is held (KakaoTalk's original shows) and while the window is being resized.
    private func updateContentVisibility(animated: Bool) {
        let target: CGFloat = (optionHeld || resizing) ? 0 : 1
        guard hosting.alphaValue != target else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                hosting.animator().alphaValue = target
            }
        } else {
            hosting.alphaValue = target
        }
    }

    private func observeRows() {
        withObservationTracking {
            _ = model.rows
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.rebuild()
                self.observeRows()
            }
        }
    }

    /// Recomputes labels and notes from the last read's frames and the model's current translations.
    private func rebuild() {
        // Nothing to draw (and no text to measure) while the overlay is off, e.g. in sidebar mode.
        guard active, let viewport = viewportAtRead else {
            if !state.labels.isEmpty { state.labels = [] }
            if !state.notes.isEmpty { state.notes = [] }
            return
        }
        // Rows may hold every loaded message; only those within the viewport ± one viewport (at the layout's
        // scroll offset) are laid out. The container clips to the viewport.
        placed = InlineLayout.place(rows: anchors, viewportAX: viewport, scrollDelta: baseDelta, margin: margin)
        let lineHeight = TextMeasurer.lineHeight(InlineStyle.fontSize)
        let pad = InlineStyle.padding
        let bounds = CGRect(x: 0, y: -margin, width: viewport.width, height: viewport.height + 2 * margin)
        var labels: [InlineLabel] = []
        var notes: [InlineNote] = []
        var translated = Set<MessageID>()
        for (index, p) in placed.enumerated() {
            guard let row = model.row(p.id) else { continue }
            if case .done(let value) = row.translation, !value.isEmpty {
                let measurer = self.measurer
                let single = measurer.size(value, fontSize: InlineStyle.fontSize, width: TextMeasurer.unbounded).width
                    + 2 * pad.width
                let frame = InlineLayout.labelFrame(cover: p.cover, bubble: p.bubble, isMine: p.isMine,
                                                    singleLineWidth: single, minScale: InlineStyle.minScale,
                                                    lineHeight: lineHeight) { width in
                    measurer.size(value, fontSize: InlineStyle.fontSize, width: width - 2 * pad.width).height
                        + 2 * pad.height
                }
                let lines = InlineLayout.lineLimit(height: frame.rect.height - 2 * pad.height, lineHeight: lineHeight,
                                                   minScale: InlineStyle.minScale)
                labels.append(InlineLabel(id: p.id, rect: frame.rect.offsetBy(dx: 0, dy: margin), text: value,
                                          isMine: p.isMine, extended: frame.extended, lineLimit: lines,
                                          badge: !row.chips.isEmpty))
                translated.insert(p.id)
            } else if row.kind == .jamoOnly, let note = row.note, !note.isEmpty {
                let s = measurer.size(note, fontSize: InlineStyle.noteFontSize, width: TextMeasurer.unbounded)
                let size = CGSize(width: s.width + 8, height: s.height + 2)
                let nextTop = index + 1 < placed.count ? placed[index + 1].bubble.minY : nil
                if let r = InlineLayout.noteFrame(bubble: p.bubble, size: size, isMine: p.isMine, nextTop: nextTop,
                                                  bounds: bounds) {
                    notes.append(InlineNote(id: p.id, rect: r.offsetBy(dx: 0, dy: margin), text: note))
                }
            }
            // Pending / failed / other kinds: nothing is drawn, KakaoTalk's original stays visible.
        }
        translatedIDs = translated
        if state.labels != labels { state.labels = labels }
        if state.notes != notes { state.notes = notes }
        if let hovered = hoveredID {
            if translated.contains(hovered) {
                let popover = makePopover(hovered)
                if state.popover != popover { state.popover = popover }
            } else {
                setHover(nil)
            }
        }
    }

    // MARK: Hover

    private func updateHover() {
        guard active, !optionHeld, !resizing, let mouse = lastMouse else {
            setHover(nil)
            return
        }
        let f = window.frame
        let p = CGPoint(x: mouse.x - f.minX, y: f.maxY - mouse.y)
        guard p.x >= 0, p.y >= 0, p.x <= f.width, p.y <= f.height, !isOccluded(p) else {
            setHover(nil)
            return
        }
        let candidates = placed.filter { translatedIDs.contains($0.id) }
        setHover(InlineLayout.hit(p, in: candidates, scrollDelta: shift))
    }

    private func setHover(_ id: MessageID?) {
        guard id != hoveredID else { return }
        hoveredID = id
        state.hiddenID = id
        let popover = id.flatMap(makePopover)
        withAnimation(.easeOut(duration: 0.12)) { state.popover = popover }
    }

    private func makePopover(_ id: MessageID) -> InlinePopover? {
        guard let row = model.row(id), case .done(let value) = row.translation,
              let p = placed.first(where: { $0.id == id }) else { return nil }
        let size = container.bounds.size
        let pad = InlineStyle.popoverPadding
        let maxText = max(80, min(InlineStyle.popoverMaxWidth, size.width - 16) - 2 * pad.width)
        let textSize = measurer.size(value, fontSize: InlineStyle.popoverFontSize, width: maxText)
        let chips = row.chips.isEmpty ? nil : row.chips.map { "\($0.term) = \($0.gloss)" }.joined(separator: "  ·  ")
        let chipsSize = chips.map { measurer.size($0, fontSize: InlineStyle.popoverChipsFontSize, width: maxText) }
            ?? .zero
        let width = max(textSize.width, chipsSize.width) + 2 * pad.width + 2
        let height = textSize.height + (chips == nil ? 0 : chipsSize.height + 4) + 2 * pad.height + 2
        // Visible part of the content (content coordinates) at the current scroll offset.
        let bounds = CGRect(x: 4, y: margin - shift + 4, width: max(0, size.width - 8),
                            height: max(0, size.height - 8))
        let rect = InlineLayout.popoverFrame(bubble: p.bubble.offsetBy(dx: 0, dy: margin),
                                             size: CGSize(width: width, height: height), isMine: p.isMine,
                                             bounds: bounds)
        // Never show the card over (or partly under) a window that covers the chat window.
        let visibleRect = rect.offsetBy(dx: 0, dy: -margin + shift)
        if occludersLocal.contains(where: { $0.intersects(visibleRect) }) { return nil }
        return InlinePopover(id: id, rect: rect, text: value, chips: chips)
    }

    // MARK: Event monitors (observation only; nothing is posted)

    private func installMonitors() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.scrollWheel, .mouseMoved, .flagsChanged, .leftMouseDragged]
            ) {
                [weak self] event in
                let type = event.type
                let flags = event.modifierFlags
                MainActor.assumeIsolated { self?.observed(type, flags: flags) }
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
                let flags = event.modifierFlags
                MainActor.assumeIsolated { self?.observed(.flagsChanged, flags: flags) }
                return event
            }
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func observed(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags) {
        guard active else { return }
        switch type {
        case .flagsChanged:
            let held = flags.contains(.option)
            guard held != optionHeld else { return }
            optionHeld = held
            updateContentVisibility(animated: true)
            if held { setHover(nil) } else { updateHover() }
        case .scrollWheel:
            lastMouse = NSEvent.mouseLocation
            guard let windowAX = tracker.geometry.windowAX, let primary = NSScreen.screens.first else { return }
            let chat = ScreenGeometry.axToCocoa(windowAX, primaryMaxY: primary.frame.maxY)
            let mouse = NSEvent.mouseLocation
            // Scrolling a window that covers the chat window does not scroll KakaoTalk.
            guard chat.contains(mouse), !isOccluded(cocoa: mouse) else { return }
            lastChangeAt = .now
            startFastTracking()
        case .mouseMoved:
            lastMouse = NSEvent.mouseLocation
            updateHover()
        case .leftMouseDragged:
            // Dragging KakaoTalk's scroller (or a selection that auto-scrolls) inside the viewport. Drags
            // elsewhere (e.g. moving the window by its title bar) are handled by the window tracker.
            lastMouse = NSEvent.mouseLocation
            let mouse = NSEvent.mouseLocation
            guard window.frame.contains(mouse), !isOccluded(cocoa: mouse) else { return }
            lastChangeAt = .now
            startFastTracking()
        default:
            break
        }
    }

    // MARK: Fast tracking

    /// Reads only the scroll anchor's frame every ~16 ms and shifts all labels by the scroll offset, until
    /// nothing has moved for `fastTrackQuiet` (and any row-change burst is over); then re-reads once.
    private func startFastTracking() {
        guard active, fastTask == nil, scrollAnchor != nil else { return }
        fastTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let tickStart = ContinuousClock.now
                await self.fastTrackTick()
                let now = ContinuousClock.now
                let quiet = now - self.lastChangeAt > InlineOverlayController.fastTrackQuiet
                let burstOver = self.burstUntil.map { now >= $0 } ?? true
                if quiet && burstOver { break }
                try? await Task.sleep(until: tickStart + InlineOverlayController.fastTrackInterval,
                                      tolerance: .milliseconds(4), clock: .continuous)
            }
            guard let self, !Task.isCancelled else { return }
            self.fastTask = nil
            self.burstUntil = nil
            // Re-anchor: new rows may have scrolled in and frames are now known exactly.
            if self.movedSinceRead { self.tracker.requestRead() }
        }
    }

    private func stopFastTracking() {
        fastTask?.cancel()
        fastTask = nil
        burstUntil = nil
    }

    private func fastTrackTick() async {
        guard let anchor = scrollAnchor else { return }
        let generation = anchorGeneration
        let frame = await tracker.geometryReader.frame(of: anchor.element)
        diagnostics.recordOverlayFastTrackTick()
        // A newer read re-anchored meanwhile: this frame belongs to the old anchor.
        guard generation == anchorGeneration, let frame else { return }
        let delta = InlineLayout.scrollDelta(anchorNow: frame, windowNow: tracker.geometry.windowAX,
                                             anchorAtRead: anchor.frameAtRead, windowAtRead: windowAtRead)
        guard abs(delta - scrollDelta) >= 0.5 else { return }
        scrollDelta = delta
        lastChangeAt = .now
        movedSinceRead = true
        if abs(shift) > margin / 2 {
            // Re-place around the current offset so rows that scrolled into range get labels before the
            // re-read at the end of the scroll.
            baseDelta = scrollDelta
            rebuild()
        }
        applyOffset()
        updateHover()
    }
}
