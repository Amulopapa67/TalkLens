// SPDX-License-Identifier: MIT
// Finds the message input and the transcript container inside a chat window (background-safe path only).
// STUB — core-dev: port kmsg MessageContextResolver scoring (with attribution header) and test.

import CoreGraphics
import Foundation

public struct TranscriptLocation<Node: AXNodeLike> {
    public let transcriptRoot: Node
    public let inputFrame: CGRect?
    public let windowFrame: CGRect?
    public init(transcriptRoot: Node, inputFrame: CGRect?, windowFrame: CGRect?) {
        self.transcriptRoot = transcriptRoot
        self.inputFrame = inputFrame
        self.windowFrame = windowFrame
    }
}

public enum TranscriptLocator {
    public static func locate<Node: AXNodeLike>(inWindow window: Node) -> TranscriptLocation<Node>? {
        nil
    }
}
