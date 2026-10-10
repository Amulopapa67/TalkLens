// SPDX-License-Identifier: MIT
// Message identity (docs/architecture.md §4.2). KakaoTalk exposes no message id, so ids are derived from
// what is visible: chat, author, date, time label, row kind and normalized body.

import CryptoKit
import Foundation

public enum MessageIdentity {
    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    /// Lowercase hex of SHA-256(`text` as UTF-8).
    public static func sha256Hex(_ text: String) -> String {
        hex(SHA256.hash(data: Data(text.utf8)), maxBytes: 32)
    }

    /// Chat key derived from the window title (hash; used only in memory).
    public static func chatKey(forTitle title: String) -> String {
        String(sha256Hex("chat\u{1F}" + title).prefix(16))
    }

    /// Base key (16 hex chars) for one parsed message, without the duplicate suffix:
    /// sha256(chatKey ‖ author ‖ date ‖ timeRaw ‖ rowKind ‖ normalizedBody), fields joined by U+001F.
    /// `rowKind` distinguishes "me" / system / others so identical texts in different roles differ.
    public static func baseKey(for p: ParsedMessage, chatKey: String) -> String {
        let rowKind = p.isSystem ? "s" : (p.isMine ? "m" : "o")
        let material = [chatKey, p.author ?? "", p.date ?? "", p.timeRaw ?? "", rowKind,
                        ChatPreprocessor.normalize(p.body)].joined(separator: "\u{1F}")
        return hex(SHA256.hash(data: Data(material.utf8)), maxBytes: 8)
    }

    /// Assign ids top-to-bottom: the base key, with a "#k" suffix (k = 1, 2, …) for the k-th repeat of the
    /// same base key within this snapshot.
    public static func assign(_ parsed: [ParsedMessage], chatKey: String) -> [ChatMessage] {
        var seen: [String: Int] = [:]
        seen.reserveCapacity(parsed.count)
        return parsed.map { p in
            let base = baseKey(for: p, chatKey: chatKey)
            let k = seen[base, default: 0]
            seen[base] = k + 1
            return ChatMessage(id: MessageID(k == 0 ? base : "\(base)#\(k)"), parsed: p)
        }
    }

    private static func hex<D: Sequence>(_ digest: D, maxBytes: Int) -> String where D.Element == UInt8 {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(maxBytes * 2)
        for b in digest.prefix(maxBytes) {
            bytes.append(hexDigits[Int(b >> 4)])
            bytes.append(hexDigits[Int(b & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
