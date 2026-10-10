// Derived from kmsg (https://github.com/channprj/kmsg) @54cbff7 — MIT License, Copyright (c) 2026 Park Hee Chan. Modifications: UIElement.swift reduced to read-only attribute access; attributes batch-fetched with AXUIElementCopyMultipleAttributeValues and cached; children cached; conforms to AXNodeLike; removed setAttribute, setPosition/setSize/setFrame, performAction, press, focus and element(at:).
// SPDX-License-Identifier: MIT

import ApplicationServices
import CoreGraphics
import Foundation

/// AXNodeLike over a live AXUIElement. Read-only: only AX copy/get calls are made.
///
/// Attributes are fetched lazily in one IPC round-trip (`AXUIElementCopyMultipleAttributeValues`) on first
/// access and cached for the lifetime of the node; children are fetched lazily and cached too. A node is a
/// point-in-time view: create fresh nodes (from the app element) for every read.
///
/// Concurrency: the lazily filled caches are not synchronized. A node graph is only ever used from one
/// isolation domain at a time (the `AXReader` actor, or tlctl's main thread), hence `@unchecked Sendable`.
public final class LiveAXNode: AXNodeLike, @unchecked Sendable {
    public let element: AXUIElement

    private struct Attributes {
        var role: String?
        var subrole: String?
        var identifier: String?
        var title: String?
        var value: String?
        var description: String?
        var help: String?
        var position: CGPoint?
        var size: CGSize?
        var enabled: Bool?
    }

    private var cachedAttributes: Attributes?
    private var cachedChildren: [LiveAXNode]?

    /// Messaging timeout (seconds) applied to application elements so a hung KakaoTalk cannot block us.
    public static let messagingTimeout: Float = 0.25

    static let batchAttributeNames: [String] = [
        AXAttr.role, AXAttr.subrole, AXAttr.identifier, AXAttr.title, AXAttr.value,
        AXAttr.description, AXAttr.help, AXAttr.position, AXAttr.size, AXAttr.enabled,
    ]

    public init(_ element: AXUIElement) {
        self.element = element
    }

    /// Application element for `pid` with a bounded messaging timeout.
    public static func application(pid: pid_t) -> LiveAXNode {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return LiveAXNode(app)
    }

    // MARK: - AXNodeLike

    public var role: String? { attributes.role }
    public var subrole: String? { attributes.subrole }
    public var identifier: String? { attributes.identifier }
    public var title: String? { attributes.title }
    public var value: String? { attributes.value }
    public var nodeDescription: String? { attributes.description }
    public var help: String? { attributes.help }
    public var isEnabled: Bool { attributes.enabled ?? true }

    public var frame: CGRect? {
        let a = attributes
        guard let p = a.position, let s = a.size else { return nil }
        return CGRect(origin: p, size: s)
    }

    public var children: [LiveAXNode] {
        if let cachedChildren { return cachedChildren }
        let result = elements(AXAttr.children).map(LiveAXNode.init)
        cachedChildren = result
        return result
    }

    /// At most `limit` children (uses the ranged copy call; not cached).
    public func children(limit: Int) -> [LiveAXNode] {
        if let cachedChildren { return Array(cachedChildren.prefix(limit)) }
        var values: CFArray?
        let err = AXUIElementCopyAttributeValues(element, AXAttr.children as CFString, 0, max(0, limit), &values)
        guard err == .success, let array = values as? [AXUIElement] else { return [] }
        return array.map(LiveAXNode.init)
    }

    // MARK: - Application / window helpers

    /// AXWindows of an application element.
    public var windows: [LiveAXNode] { elements(AXAttr.windows).map(LiveAXNode.init) }
    public var focusedWindow: LiveAXNode? { element(AXAttr.focusedWindow).map(LiveAXNode.init) }
    public var mainWindow: LiveAXNode? { element(AXAttr.mainWindow).map(LiveAXNode.init) }
    public var isMinimized: Bool { bool(AXAttr.minimized) ?? false }

    /// Same underlying accessibility element (CFEqual).
    public func isSameElement(as other: LiveAXNode) -> Bool {
        CFEqual(element, other.element)
    }

    /// Discards cached attributes and children (e.g. after a change notification).
    public func invalidate() {
        cachedAttributes = nil
        cachedChildren = nil
    }

    // MARK: - Raw reads

    private var attributes: Attributes {
        if let cachedAttributes { return cachedAttributes }
        let fetched = fetchAttributes()
        cachedAttributes = fetched
        return fetched
    }

    private func fetchAttributes() -> Attributes {
        var out = Attributes()
        var values: CFArray?
        let names = LiveAXNode.batchAttributeNames as CFArray
        let err = AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard err == .success, let array = values as? [AnyObject], array.count == LiveAXNode.batchAttributeNames.count else {
            return out
        }
        out.role = LiveAXNode.stringValue(array[0])
        out.subrole = LiveAXNode.stringValue(array[1])
        out.identifier = LiveAXNode.stringValue(array[2])
        out.title = LiveAXNode.stringValue(array[3])
        out.value = LiveAXNode.stringValue(array[4])
        out.description = LiveAXNode.stringValue(array[5])
        out.help = LiveAXNode.stringValue(array[6])
        out.position = LiveAXNode.pointValue(array[7])
        out.size = LiveAXNode.sizeValue(array[8])
        out.enabled = LiveAXNode.boolValue(array[9])
        return out
    }

    /// Missing attributes come back as an AXValue of type `.axError`; anything that is not a CFString → nil.
    static func stringValue(_ v: AnyObject) -> String? {
        guard CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
        return v as? String
    }

    static func boolValue(_ v: AnyObject) -> Bool? {
        guard CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((v as! CFBoolean))
    }

    static func pointValue(_ v: AnyObject) -> CGPoint? {
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let ax = v as! AXValue
        guard AXValueGetType(ax) == .cgPoint else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(ax, .cgPoint, &p) ? p : nil
    }

    static func sizeValue(_ v: AnyObject) -> CGSize? {
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let ax = v as! AXValue
        guard AXValueGetType(ax) == .cgSize else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(ax, .cgSize, &s) ? s : nil
    }

    private func copyValue(_ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &v) == .success else { return nil }
        return v
    }

    private func elements(_ name: String) -> [AXUIElement] {
        guard let v = copyValue(name), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    private func element(_ name: String) -> AXUIElement? {
        guard let v = copyValue(name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private func bool(_ name: String) -> Bool? {
        guard let v = copyValue(name) else { return nil }
        return LiveAXNode.boolValue(v)
    }
}
