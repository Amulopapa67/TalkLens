// SPDX-License-Identifier: MIT
// Non-activating floating sidebar panel. It never becomes key or main, so clicking it does not take focus
// away from KakaoTalk.

import AppKit
import os
import SwiftUI
import TalkLensCore

private let logger = Logger.talkLens("panel")

final class OverlayPanel: NSPanel {
    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
                  styleMask: [.nonactivatingPanel, .borderless],
                  backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // canJoinAllSpaces: the panel exists on whichever Space is active, so it is already there when the
        // user switches to the Space (or full-screen Space, via fullScreenAuxiliary) that holds the chat
        // window; it is hidden whenever KakaoTalk is not frontmost, so it does not linger on other Spaces.
        // (moveToActiveSpace is mutually exclusive with canJoinAllSpaces and would re-home the panel only on
        // the next orderFront, which caused a visible lag in the same situation.)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that reacts to the first click even though the panel is never key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PanelController {
    let panel: OverlayPanel
    private let settings: AppSettings
    private let effectView: NSVisualEffectView
    private(set) var lastEdge: PanelEdge?
    private(set) var isShown = false

    init<Content: View>(rootView: Content, settings: AppSettings) {
        self.settings = settings
        panel = OverlayPanel()

        effectView = NSVisualEffectView()
        effectView.material = .popover          // adapts to light/dark
        effectView.blendingMode = .behindWindow
        effectView.state = .active              // our app is never active; keep the material vivid
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true

        panel.contentView = effectView
        let hosting = FirstMouseHostingView(rootView: rootView)
        // Fill the effect view; autoresizing keeps it sized with the panel.
        hosting.frame = effectView.bounds
        hosting.autoresizingMask = [.width, .height]
        // The panel size is driven by the chat window, not by SwiftUI's ideal size.
        hosting.sizingOptions = []
        effectView.addSubview(hosting)
        panel.alphaValue = CGFloat(settings.opacity)
    }

    func applyOpacity() {
        panel.alphaValue = CGFloat(settings.opacity)
    }

    /// Positions the panel for a chat window (AX coordinates); without a window, docks at the right edge of
    /// the main screen so status messages are still visible.
    func place(windowAX: CGRect?, inputAX: CGRect?) {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        let primaryMaxY = primary.frame.maxY
        let width = CGFloat(settings.panelWidth)
        var frame: CGRect
        if let windowAX, windowAX.width > 0, windowAX.height > 0 {
            let window = ScreenGeometry.axToCocoa(windowAX, primaryMaxY: primaryMaxY)
            let input = inputAX.map { ScreenGeometry.axToCocoa($0, primaryMaxY: primaryMaxY) }
            let placed = PanelPlacement.place(window: window, panelWidth: width,
                                              screens: screens.map(\.visibleFrame),
                                              preferred: settings.edge, inputFrame: input, gap: 6)
            frame = placed.frame
            if lastEdge != placed.edge {
                lastEdge = placed.edge
                logger.debug("edge=\(placed.edge.rawValue, privacy: .public)")
            }
        } else {
            let visible = (NSScreen.main ?? primary).visibleFrame
            let height = min(520, max(200, visible.height - 80))
            frame = CGRect(x: visible.maxX - width - 12, y: visible.midY - height / 2, width: width, height: height)
            lastEdge = nil
        }
        frame = frame.integral
        if frame.width < 120 || frame.height < 120 { return }
        if panel.frame != frame {
            panel.setFrame(frame, display: isShown, animate: false)
        }
    }

    /// Shows or hides the panel. `kakaoFrontmost` selects .floating vs .normal level.
    func setVisible(_ visible: Bool, kakaoFrontmost: Bool) {
        if visible {
            let level: NSWindow.Level = kakaoFrontmost ? .floating : .normal
            let levelChanged = panel.level != level
            if levelChanged { panel.level = level }
            if !isShown || (levelChanged && kakaoFrontmost) {
                // Never activates our app (non-activating panel); never touches KakaoTalk.
                panel.orderFrontRegardless()
            }
            isShown = true
        } else if isShown {
            panel.orderOut(nil)
            isShown = false
        }
    }
}
