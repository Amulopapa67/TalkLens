// SPDX-License-Identifier: MIT
// .lens-dev.json loader: the self-chat title allowlist that gates showing/recording raw text in tlctl.

import Foundation

public struct DevConfig: Sendable, Equatable {
    public let allowedTextChats: [String]

    public init(allowedTextChats: [String]) {
        self.allowedTextChats = allowedTextChats
    }

    public static let empty = DevConfig(allowedTextChats: [])

    public static func load(from data: Data) throws -> DevConfig {
        struct File: Decodable { let allowed_text_chats: [String]? }
        let f = try JSONDecoder().decode(File.self, from: data)
        return DevConfig(allowedTextChats: (f.allowed_text_chats ?? []).filter { !$0.isEmpty && !$0.hasPrefix("<") })
    }

    /// Loads `<dir>/.lens-dev.json`; `.empty` when missing or invalid.
    public static func load(inDirectory dir: URL) -> DevConfig {
        let url = dir.appendingPathComponent(".lens-dev.json")
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return (try? load(from: data)) ?? .empty
    }

    /// Raw text may be shown only when the window title exactly equals the requested title AND
    /// that title is in the allowlist.
    public func allowsText(windowTitle: String, requested: String?) -> Bool {
        guard let requested, !requested.isEmpty else { return false }
        return windowTitle == requested && allowedTextChats.contains(requested)
    }
}
