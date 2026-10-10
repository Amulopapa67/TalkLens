// SPDX-License-Identifier: MIT
// Message identity (docs/architecture.md §4.2).
// STUB — core-dev: finish and test.

import CryptoKit
import Foundation

public enum MessageIdentity {
    public static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Chat key derived from the window title (hash; used only in memory).
    public static func chatKey(forTitle title: String) -> String {
        String(sha256Hex("chat\u{1F}" + title).prefix(16))
    }

    /// Assign ids top-to-bottom: baseKey = sha256(chatKey ‖ author ‖ date ‖ timeRaw ‖ normalizedBody)[0..<16],
    /// with "#k" suffix for duplicates within the same snapshot.
    public static func assign(_ parsed: [ParsedMessage], chatKey: String) -> [ChatMessage] {
        var seen: [String: Int] = [:]
        return parsed.map { p in
            let base = String(sha256Hex([chatKey, p.author ?? "", p.date ?? "", p.timeRaw ?? "", p.body]
                .joined(separator: "\u{1F}")).prefix(16))
            let k = seen[base, default: 0]
            seen[base] = k + 1
            return ChatMessage(id: MessageID(k == 0 ? base : "\(base)#\(k)"), parsed: p)
        }
    }
}
