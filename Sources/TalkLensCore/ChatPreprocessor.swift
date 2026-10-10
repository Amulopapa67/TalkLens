// SPDX-License-Identifier: MIT
// Normalization, classification, segmentation and glossary annotation (docs/architecture.md §4.4).
// STUB — core-dev: implement and test.

import Foundation

public struct ChatPreprocessor: Sendable {
    public let glossary: Glossary
    /// BCP-47 target language, e.g. "zh-Hans", "en", "ja".
    public let targetLanguage: String
    public let glossaryEnabled: Bool
    /// Max characters per `translate` segment.
    public let maxSegmentLength: Int

    public init(glossary: Glossary, targetLanguage: String = "zh-Hans", glossaryEnabled: Bool = true,
                maxSegmentLength: Int = 1000) {
        self.glossary = glossary
        self.targetLanguage = targetLanguage
        self.glossaryEnabled = glossaryEnabled
        self.maxSegmentLength = maxSegmentLength
    }

    public func process(_ message: ChatMessage) -> PreprocessedMessage {
        if message.isSystem {
            return PreprocessedMessage(message: message, kind: .system, textForMT: nil, segments: [], chips: [], note: nil)
        }
        let text = message.body
        return PreprocessedMessage(message: message, kind: .translate, textForMT: text,
                                   segments: [.translate(text)], chips: [], note: nil)
    }

    /// Zero-width characters removed, runs of spaces collapsed, line breaks kept.
    public static func normalize(_ text: String) -> String { text }
}
