// SPDX-License-Identifier: MIT
// Parses transcript rows into ParsedMessage values. Generic over AXNodeLike.
// STUB — core-dev: port kmsg TranscriptReader row analysis (with attribution header) and test.

import CoreGraphics
import Foundation
import TalkLensCore

public struct TranscriptParser: Sendable {
    /// Year used when a date divider omits it (defaults to the current year).
    public var referenceYear: Int
    /// Upper bound on rows analysed (most recent rows win).
    public var maxRows: Int

    public init(referenceYear: Int = Calendar(identifier: .gregorian).component(.year, from: Date()), maxRows: Int = 400) {
        self.referenceYear = referenceYear
        self.maxRows = maxRows
    }

    /// Messages top-to-bottom. System rows (date dividers etc.) are included with isSystem = true.
    public func parse<Node: AXNodeLike>(transcriptRoot: Node, inputFrame: CGRect?) -> [ParsedMessage] {
        []
    }

    /// Convenience: locate + parse a whole chat window subtree.
    public func parse<Node: AXNodeLike>(window: Node) -> [ParsedMessage]? {
        guard let loc = TranscriptLocator.locate(inWindow: window) else { return nil }
        return parse(transcriptRoot: loc.transcriptRoot, inputFrame: loc.inputFrame)
    }
}
