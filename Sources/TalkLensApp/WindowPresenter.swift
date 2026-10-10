// SPDX-License-Identifier: MIT
// Opens our own auxiliary windows (settings, onboarding, about). Activating is limited to this app:
// NSApp.activate() is the only activation call in TalkLens.

import AppKit
import SwiftUI

@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    private var closeHandlers: [String: () -> Void] = [:]

    func isOpen(_ id: String) -> Bool { windows[id] != nil }

    func show<Content: View>(id: String, title: String, size: CGSize, onClose: (() -> Void)? = nil,
                             content: () -> Content) {
        if let existing = windows[id] {
            NSApp.activate()
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: content())
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[id] = window
        closeHandlers[id] = onClose
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ id: String) {
        windows[id]?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        windows[id] = nil
        let handler = closeHandlers.removeValue(forKey: id)
        // Drop the SwiftUI hierarchy once the window is gone.
        window.contentViewController = nil
        handler?()
    }
}
