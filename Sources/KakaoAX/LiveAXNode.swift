// SPDX-License-Identifier: MIT
// AXNodeLike over a live AXUIElement. Read-only: only Copy* AX calls.
// STUB — core-dev: batch attribute fetch with AXUIElementCopyMultipleAttributeValues, messaging timeout.

import ApplicationServices
import CoreGraphics
import Foundation

public final class LiveAXNode: AXNodeLike, @unchecked Sendable {
    public let element: AXUIElement

    public init(_ element: AXUIElement) {
        self.element = element
    }

    public static func application(pid: pid_t) -> LiveAXNode {
        LiveAXNode(AXUIElementCreateApplication(pid))
    }

    private func string(_ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &v) == .success else { return nil }
        return v as? String
    }

    public var role: String? { string(kAXRoleAttribute) }
    public var subrole: String? { string(kAXSubroleAttribute) }
    public var identifier: String? { string(kAXIdentifierAttribute) }
    public var title: String? { string(kAXTitleAttribute) }
    public var value: String? { string(kAXValueAttribute) }
    public var nodeDescription: String? { string(kAXDescriptionAttribute) }
    public var help: String? { string(kAXHelpAttribute) }
    public var frame: CGRect? { nil }
    public var isEnabled: Bool { true }
    public var children: [LiveAXNode] { [] }

    /// AXWindows of an application element.
    public var windows: [LiveAXNode] { [] }
    public var focusedWindow: LiveAXNode? { nil }
    public var mainWindow: LiveAXNode? { nil }
    public var isMinimized: Bool { false }
}
