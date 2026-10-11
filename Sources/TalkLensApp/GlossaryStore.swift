// SPDX-License-Identifier: MIT
// Bundled starter glossary (Contents/Resources/glossary.ko-zh.json, copied by scripts/build_app.sh) merged
// with the user's vocabulary file at ~/Library/Application Support/TalkLens/glossary.json.

import AppKit
import Foundation
import Observation
import os
import TalkLensCore

private let logger = Logger.talkLens("glossary")

@MainActor
@Observable
final class GlossaryStore {
    private(set) var bundled: Glossary = .empty
    private(set) var user: Glossary = .empty
    private(set) var merged: Glossary = .empty
    /// Short, content-free error for the settings window (localized at display time).
    private(set) var lastError: UIKey?

    @ObservationIgnored private let bundle: Bundle
    @ObservationIgnored private let loadUser: Bool

    init(bundle: Bundle = .main, loadUser: Bool = true) {
        self.bundle = bundle
        self.loadUser = loadUser
        reload()
    }

    static var userGlossaryURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TalkLens", isDirectory: true)
            .appendingPathComponent("glossary.json")
    }

    func reload() {
        lastError = nil
        if let url = bundle.url(forResource: "glossary.ko-zh", withExtension: "json") {
            do {
                bundled = try Glossary.load(contentsOf: url)
            } catch {
                bundled = .empty
                lastError = .glossaryErrorBundled
                logger.error("bundled glossary parse failed")
            }
        } else {
            bundled = .empty
        }
        user = .empty
        if loadUser, let url = Self.userGlossaryURL, FileManager.default.fileExists(atPath: url.path) {
            do {
                user = try Glossary.load(contentsOf: url)
            } catch {
                lastError = .glossaryErrorUser
                logger.error("user glossary parse failed")
            }
        }
        merged = bundled.merged(with: user)
        logger.info("glossary loaded bundled=\(self.bundled.entries.count) user=\(self.user.entries.count)")
    }

    /// Creates the user glossary from a template when missing, then opens it in the default JSON editor.
    func openUserGlossary() {
        guard let url = Self.userGlossaryURL else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(Self.template.utf8).write(to: url, options: .atomic)
            } catch {
                lastError = .glossaryErrorCreate
                logger.error("user glossary create failed")
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    static let template = """
    {
      "_comment": "TalkLens user glossary. Entries override built-in entries with the same 'ko'. Fields: ko, zh (gloss shown as a chip), kind, pattern (NSRegularExpression), standalone_only (true = only when the whole message is this token), expand (replacement applied before machine translation). After editing, use Settings → Glossary → Reload.",
      "version": 1,
      "source": "ko",
      "target": "zh-Hans",
      "entries": [
        { "ko": "랩미팅", "zh": "组会", "kind": "lab" }
      ]
    }

    """
}
