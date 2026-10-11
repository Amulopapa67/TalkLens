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
    private let pauseItem = NSMenuItem(title: "", action: #selector(togglePaused), keyEquivalent: "p")
    private let sidebarItem = NSMenuItem(title: "", action: #selector(toggleSidebar), keyEquivalent: "")
    private let pinItem = NSMenuItem(title: "", action: #selector(togglePinned), keyEquivalent: "")
    private let inlineModeItem = NSMenuItem(title: "", action: #selector(selectInlineMode), keyEquivalent: "")
    private let sidebarModeItem = NSMenuItem(title: "", action: #selector(selectSidebarMode), keyEquivalent: "")
    /// Source / target / UI language submenus for quick switching (D-023, D-024).
    private let sourceLanguageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var sourceLanguageItems: [NSMenuItem] = []
    private let targetLanguageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var targetLanguageItems: [NSMenuItem] = []
    private let uiLanguageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var uiLanguageItems: [NSMenuItem] = []
    /// Shown only while some auto-detected pair needs a download.
    private let downloadItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AppController()
        self.controller = controller
        setUpStatusItem()
        controller.onUILanguageChange = { [weak self] in self?.rebuildMenu() }
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
        statusItem = item
        rebuildMenu()
    }

    /// Builds the status menu in the current UI language; called at launch and after every language change.
    private func rebuildMenu() {
        guard let statusItem else { return }
        // The reused items may belong to only one menu at a time: detach them from the previous one first.
        statusItem.menu?.removeAllItems()
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
        pinItem.title = tr(.menuPinned)
        menu.addItem(.separator())
        let modeHeader = NSMenuItem(title: tr(.displayMode), action: nil, keyEquivalent: "")
        modeHeader.isEnabled = false
        menu.addItem(modeHeader)
        inlineModeItem.title = tr(AppSettings.DisplayMode.inline.nameKey)
        sidebarModeItem.title = tr(AppSettings.DisplayMode.sidebar.nameKey)
        for entry in [inlineModeItem, sidebarModeItem] {
            entry.target = self
            entry.indentationLevel = 1
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let language = uiLanguage
        let sourceIDs = [LanguageCatalog.autoID] + LanguageCatalog.all.map(\.id)
        sourceLanguageItems = makeSubmenu(sourceLanguageItem, ids: sourceIDs, action: #selector(selectSourceLanguage(_:))) {
            UIStrings.languageOptionLabel($0, language)
        }
        menu.addItem(sourceLanguageItem)
        targetLanguageItems = makeSubmenu(targetLanguageItem, ids: LanguageCatalog.all.map(\.id),
                                          action: #selector(selectTargetLanguage(_:))) {
            UIStrings.languageOptionLabel($0, language)
        }
        menu.addItem(targetLanguageItem)
        downloadItem.title = tr(.menuDownloadMissing)
        downloadItem.submenu = NSMenu()
        downloadItem.isHidden = true
        menu.addItem(downloadItem)
        menu.addItem(.separator())
        let uiIDs = UILanguageSetting.allCases.map(\.rawValue)
        uiLanguageItems = makeSubmenu(uiLanguageItem, ids: uiIDs, action: #selector(selectUILanguage(_:))) { id in
            Self.uiLanguageLabel(UILanguageSetting(rawValue: id) ?? .system, language)
        }
        menu.addItem(uiLanguageItem)
        menu.addItem(makeItem(tr(.menuSettings), #selector(openSettings), key: ","))
        menu.addItem(makeItem(tr(.menuOnboarding), #selector(openOnboarding)))
        menu.addItem(makeItem(tr(.menuAbout), #selector(openAbout)))
        menu.addItem(.separator())
        menu.addItem(makeItem(tr(.menuQuit), #selector(quit), key: "q"))
        statusItem.menu = menu
        updateDynamicItems()
    }

    /// "跟随系统（简体中文）" / "한국어 (Korean)": the follow-system entry names the language it resolves to.
    static func uiLanguageLabel(_ setting: UILanguageSetting, _ language: UILanguage) -> String {
        guard let fixed = setting.fixedLanguage else {
            return UIStrings.text(.uiLanguageSystemResolved, language, UILanguage.system.nativeName)
        }
        return UIStrings.uiLanguageOptionLabel(fixed, language)
    }

    private func makeSubmenu(_ parent: NSMenuItem, ids: [String], action: Selector,
                             label: (String) -> String) -> [NSMenuItem] {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let items = ids.map { id in
            let entry = NSMenuItem(title: label(id), action: action, keyEquivalent: "")
            entry.target = self
            entry.representedObject = id
            submenu.addItem(entry)
            return entry
        }
        parent.submenu = submenu
        return items
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateDynamicItems()
    }

    /// Titles and check marks that depend on the current state.
    private func updateDynamicItems() {
        guard let controller else { return }
        let settings = controller.settings
        let language = uiLanguage
        statusLineItem.title = controller.menuStatusLine
        pauseItem.title = tr(settings.paused ? .menuResume : .menuPause)
        let inline = settings.displayMode == .inline
        if inline {
            sidebarItem.title = tr(settings.sidebarVisible ? .menuHideOverlay : .menuShowOverlay)
        } else {
            sidebarItem.title = tr(settings.sidebarVisible ? .menuHideSidebar : .menuShowSidebar)
        }
        pinItem.state = settings.pinned ? .on : .off
        // "Pinned" keeps the sidebar visible without KakaoTalk in front; the overlay only shows over it.
        pinItem.isEnabled = !inline
        inlineModeItem.state = inline ? .on : .off
        sidebarModeItem.state = inline ? .off : .on
        for entry in sourceLanguageItems {
            entry.state = (entry.representedObject as? String) == settings.sourceLanguage ? .on : .off
        }
        sourceLanguageItem.title = tr(.menuSourceLanguage,
                                      UIStrings.languageOptionLabel(settings.sourceLanguage, language))
        for entry in targetLanguageItems {
            entry.state = (entry.representedObject as? String) == settings.targetLanguage ? .on : .off
        }
        targetLanguageItem.title = tr(.menuTargetLanguage, UIStrings.languageName(settings.targetLanguage, language))
        for entry in uiLanguageItems {
            entry.state = (entry.representedObject as? String) == settings.uiLanguage.rawValue ? .on : .off
        }
        uiLanguageItem.title = tr(.menuUILanguage, Self.uiLanguageLabel(settings.uiLanguage, language))
        let missing = controller.missingPairs
        downloadItem.isHidden = missing.isEmpty
        downloadItem.submenu?.removeAllItems()
        for pair in missing {
            let entry = NSMenuItem(title: UIStrings.pairName(pair, language) + "…", action: #selector(downloadPair(_:)),
                                   keyEquivalent: "")
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

    @objc private func selectSourceLanguage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let settings = controller?.settings,
              settings.sourceLanguage != id else { return }
        settings.sourceLanguage = id
    }

    @objc private func selectUILanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let value = UILanguageSetting(rawValue: raw),
              let settings = controller?.settings, settings.uiLanguage != value else { return }
        settings.uiLanguage = value
    }

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
