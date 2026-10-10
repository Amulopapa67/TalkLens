// SPDX-License-Identifier: MIT
// Hashable identity of a live accessibility element (CFEqual / CFHash), used to key cached row analyses.

import ApplicationServices
import Foundation

/// `@unchecked Sendable`: an AXUIElement is an immutable CF reference (pid + opaque element token) with no
/// client-side mutable state; equality and hashing only call CFEqual / CFHash, which are thread-safe.
public struct AXElementKey: Hashable, @unchecked Sendable {
    public let element: AXUIElement

    public init(_ element: AXUIElement) {
        self.element = element
    }

    public static func == (lhs: AXElementKey, rhs: AXElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

extension LiveAXNode: IncrementalAXNode {
    public var elementIdentity: AXElementKey { AXElementKey(element) }

    /// A new node for the same element: attributes and children are fetched again on first access.
    public func refreshed() -> LiveAXNode { LiveAXNode(element) }
}
