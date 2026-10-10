// SPDX-License-Identifier: MIT
// Menu bar app lifecycle (LSUIElement) with an NSStatusItem menu (F1).

import AppKit
import os

private let logger = Logger.talkLens("app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: AppController?
    private var statusItem: NSStatusItem?

    private let statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "暂停翻译", action: #selector(togglePaused), keyEquivalent: "p")
    private let sidebarItem = NSMenuItem(title: "隐藏侧栏", action: #selector(toggleSidebar), keyEquivalent: "")
    private let pinItem = NSMenuItem(title: "常驻显示", action: #selector(togglePinned), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AppController()
        self.controller = controller
        setUpStatusItem()
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "TalkLens")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "TalkLens"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)
        menu.addItem(.separator())
        for entry in [pauseItem, sidebarItem, pinItem] {
            entry.target = self
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("设置…", #selector(openSettings), key: ","))
        menu.addItem(makeItem("权限与语言引导…", #selector(openOnboarding)))
        menu.addItem(makeItem("关于 TalkLens", #selector(openAbout)))
        menu.addItem(.separator())
        menu.addItem(makeItem("退出 TalkLens", #selector(quit), key: "q"))
        item.menu = menu
        statusItem = item
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let controller else { return }
        let settings = controller.settings
        statusLineItem.title = controller.menuStatusLine
        pauseItem.title = settings.paused ? "启用翻译" : "暂停翻译"
        sidebarItem.title = settings.sidebarVisible ? "隐藏侧栏" : "显示侧栏"
        pinItem.state = settings.pinned ? .on : .off
    }

    // MARK: - Actions

    @objc private func togglePaused() {
        guard let settings = controller?.settings else { return }
        settings.paused.toggle()
    }

    @objc private func toggleSidebar() {
        guard let settings = controller?.settings else { return }
        settings.sidebarVisible.toggle()
    }

    @objc private func togglePinned() {
        guard let settings = controller?.settings else { return }
        settings.pinned.toggle()
    }

    @objc private func openSettings() { controller?.showSettings() }
    @objc private func openOnboarding() { controller?.showOnboarding() }
    @objc private func openAbout() { controller?.showAbout() }

    @objc private func quit() {
        logger.info("quit requested")
        NSApp.terminate(nil)
    }
}
