// SPDX-License-Identifier: MIT
// Menu bar app lifecycle (LSUIElement) with an NSStatusItem menu (F1).

import AppKit
import os
import TalkLensCore

private let logger = Logger.talkLens("app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: AppController?
    private var statusItem: NSStatusItem?

    private let statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "暂停翻译", action: #selector(togglePaused), keyEquivalent: "p")
    private let sidebarItem = NSMenuItem(title: "隐藏侧栏", action: #selector(toggleSidebar), keyEquivalent: "")
    private let pinItem = NSMenuItem(title: "常驻显示", action: #selector(togglePinned), keyEquivalent: "")
    private let inlineModeItem = NSMenuItem(title: AppSettings.DisplayMode.inline.name,
                                            action: #selector(selectInlineMode), keyEquivalent: "")
    private let sidebarModeItem = NSMenuItem(title: AppSettings.DisplayMode.sidebar.name,
                                             action: #selector(selectSidebarMode), keyEquivalent: "")
    /// "目标语言" submenu for quick switching (D-023).
    private let targetLanguageItem = NSMenuItem(title: "目标语言", action: nil, keyEquivalent: "")
    private var targetLanguageItems: [NSMenuItem] = []
    /// Shown only while some auto-detected pair needs a download.
    private let downloadItem = NSMenuItem(title: "下载缺少的翻译语言", action: nil, keyEquivalent: "")

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
        let modeHeader = NSMenuItem(title: "显示方式", action: nil, keyEquivalent: "")
        modeHeader.isEnabled = false
        menu.addItem(modeHeader)
        for entry in [inlineModeItem, sidebarModeItem] {
            entry.target = self
            entry.indentationLevel = 1
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let targetMenu = NSMenu()
        targetMenu.autoenablesItems = false
        targetLanguageItems = LanguageCatalog.all.map { option in
            let entry = NSMenuItem(title: option.name, action: #selector(selectTargetLanguage(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = option.id
            targetMenu.addItem(entry)
            return entry
        }
        targetLanguageItem.submenu = targetMenu
        menu.addItem(targetLanguageItem)
        downloadItem.submenu = NSMenu()
        downloadItem.isHidden = true
        menu.addItem(downloadItem)
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
        let inline = settings.displayMode == .inline
        if inline {
            sidebarItem.title = settings.sidebarVisible ? "隐藏译文覆盖" : "显示译文覆盖"
        } else {
            sidebarItem.title = settings.sidebarVisible ? "隐藏侧栏" : "显示侧栏"
        }
        pinItem.state = settings.pinned ? .on : .off
        // "Pinned" keeps the sidebar visible without KakaoTalk in front; the overlay only shows over it.
        pinItem.isEnabled = !inline
        inlineModeItem.state = inline ? .on : .off
        sidebarModeItem.state = inline ? .off : .on
        for entry in targetLanguageItems {
            entry.state = (entry.representedObject as? String) == settings.targetLanguage ? .on : .off
        }
        targetLanguageItem.title = "目标语言：" + LanguageCatalog.displayName(settings.targetLanguage)
        let missing = controller.missingPairs
        downloadItem.isHidden = missing.isEmpty
        downloadItem.submenu?.removeAllItems()
        for pair in missing {
            let entry = NSMenuItem(title: pair.displayName + "…", action: #selector(downloadPair(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = [pair.source, pair.target]
            downloadItem.submenu?.addItem(entry)
        }
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

    @objc private func selectInlineMode() { controller?.settings.displayMode = .inline }
    @objc private func selectSidebarMode() { controller?.settings.displayMode = .sidebar }

    @objc private func selectTargetLanguage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let settings = controller?.settings,
              settings.targetLanguage != id else { return }
        settings.targetLanguage = id
    }

    @objc private func downloadPair(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [String], ids.count == 2 else { return }
        controller?.showLanguageDownload(LanguagePair(source: ids[0], target: ids[1]))
    }

    @objc private func openSettings() { controller?.showSettings() }
    @objc private func openOnboarding() { controller?.showOnboarding() }
    @objc private func openAbout() { controller?.showAbout() }

    @objc private func quit() {
        logger.info("quit requested")
        NSApp.terminate(nil)
    }
}
