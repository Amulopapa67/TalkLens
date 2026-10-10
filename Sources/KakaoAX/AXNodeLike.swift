// SPDX-License-Identifier: MIT
// Read-only view of an accessibility node. The transcript parser is generic over this protocol so that
// it runs identically on the live AX tree (LiveAXNode) and on recorded .axjson fixtures (RecordedAXNode).
//
// CONTRACT FILE: see Sources/TalkLensCore/Models.swift.

import CoreGraphics
import Foundation

public protocol AXNodeLike {
    var role: String? { get }
    var subrole: String? { get }
    var identifier: String? { get }
    var title: String? { get }
    /// AXValue when it is a string.
    var value: String? { get }
    var nodeDescription: String? { get }
    var help: String? { get }
    /// AX global coordinates: origin at the top-left of the primary screen, y grows downward.
    var frame: CGRect? { get }
    var isEnabled: Bool { get }
    var children: [Self] { get }
}
