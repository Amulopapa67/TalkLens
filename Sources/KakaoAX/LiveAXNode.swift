// Derived from kmsg (https://github.com/channprj/kmsg) @54cbff7 — MIT License, Copyright (c) 2026 Park Hee Chan. Modifications: UIElement.swift reduced to read-only attribute access; attributes batch-fetched with AXUIElementCopyMultipleAttributeValues and cached under a lock; uncached geometry reads added; children cached; conforms to AXNodeLike; removed setAttribute, setPosition/setSize/setFrame, performAction, press, focus and element(at:).
// SPDX-License-Identifier: MIT

import ApplicationServices
import CoreGraphics
import Foundation

/// AXNodeLike over a live AXUIElement. Read-only: only AX copy/get calls are made.
///
/// Attributes are fetched lazily in one IPC round-trip (`AXUIElementCopyMultipleAttributeValues`) on first
/// access and cached until `invalidate()`; children are fetched lazily and cached too. A node is a
/// point-in-time view: create fresh nodes (from the app element) for every transcript read. Window geometry
/// that must track live moves/resizes is read with the uncached `currentFrame()` / `currentIsMinimized()` /
/// `currentGeometry()` instead of `frame` / `isMinimized`'s cached snapshot.
///
/// Concurrency contract (`@unchecked Sendable`): an instance may be handed between isolation domains (e.g.
/// from the app's AX reader actor to the main actor and back), but is only *used* by one domain at a time.
/// Even so, the lazy caches are guarded by a lock: each cache is filled at most once per fetch (first writer
/// wins, later readers see the stored value) and `invalidate()` clears both under the same lock, so a
/// concurrent misuse can at worst cost a redundant AX round-trip, never a data race. The wrapped
/// `AXUIElement` is an immutable CF reference; AX calls on it are thread-safe.
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

    /// Guards `cachedAttributes` and `cachedChildren`. Never held across an AX call.
    private let cacheLock = NSLock()
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
        if let cached = cacheLock.withLock({ cachedChildren }) { return cached }
        let fetched = elements(AXAttr.children).map(LiveAXNode.init)
        return cacheLock.withLock {
            if let existing = cachedChildren { return existing }
            cachedChildren = fetched
            return fetched
        }
    }

    /// At most `limit` children (uses the ranged copy call; not cached).
    public func children(limit: Int) -> [LiveAXNode] {
        if let cached = cacheLock.withLock({ cachedChildren }) { return Array(cached.prefix(limit)) }
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

    /// Discards the cached attributes and children so the next access re-reads them over AX.
    ///
    /// Use it when the same node must reflect a change (e.g. after an AXValueChanged / AXUIElementDestroyed
    /// notification). Child nodes handed out earlier keep their own caches; they are not invalidated.
    /// For geometry that changes continuously (window drags) prefer the uncached `current…()` reads.
    public func invalidate() {
        cacheLock.withLock {
            cachedAttributes = nil
            cachedChildren = nil
        }
    }

    // MARK: - Uncached geometry

    /// Current frame and minimized state of a window element.
    public struct Geometry: Sendable, Equatable {
        /// AX global coordinates (top-left origin of the primary screen); nil when unavailable.
        public var frame: CGRect?
        public var isMinimized: Bool
        public init(frame: CGRect?, isMinimized: Bool) {
            self.frame = frame
            self.isMinimized = isMinimized
        }
    }

    static let geometryAttributeNames: [String] = [AXAttr.position, AXAttr.size, AXAttr.minimized]

    /// Position, size and AXMinimized in one `AXUIElementCopyMultipleAttributeValues` call. Never cached and
    /// never touches the attribute cache, so it always reflects the window's live geometry.
    public func currentGeometry() -> Geometry {
        let values = copyMultiple(LiveAXNode.geometryAttributeNames)
        guard let values else { return Geometry(frame: nil, isMinimized: false) }
        var frame: CGRect?
        if let p = LiveAXNode.pointValue(values[0]), let s = LiveAXNode.sizeValue(values[1]) {
            frame = CGRect(origin: p, size: s)
        }
        return Geometry(frame: frame, isMinimized: LiveAXNode.boolValue(values[2]) ?? false)
    }

    /// Live frame (AX coordinates): position and size in one `AXUIElementCopyMultipleAttributeValues` call,
    /// not cached.
    public func currentFrame() -> CGRect? {
        guard let values = copyMultiple([AXAttr.position, AXAttr.size]),
              let p = LiveAXNode.pointValue(values[0]), let s = LiveAXNode.sizeValue(values[1]) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Live AXMinimized (one `AXUIElementCopyMultipleAttributeValues` call, not cached); false when unavailable.
    public func currentIsMinimized() -> Bool {
        guard let values = copyMultiple([AXAttr.minimized]) else { return false }
        return LiveAXNode.boolValue(values[0]) ?? false
    }

    // MARK: - Raw reads

    private var attributes: Attributes {
        if let cached = cacheLock.withLock({ cachedAttributes }) { return cached }
        let fetched = fetchAttributes()
        return cacheLock.withLock {
            if let existing = cachedAttributes { return existing }
            cachedAttributes = fetched
            return fetched
        }
    }

    /// One batched copy; nil unless every requested slot came back (missing attributes are AXValue errors).
    private func copyMultiple(_ names: [String]) -> [AnyObject]? {
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard err == .success, let array = values as? [AnyObject], array.count == names.count else { return nil }
        return array
    }

    private func fetchAttributes() -> Attributes {
        var out = Attributes()
        guard let array = copyMultiple(LiveAXNode.batchAttributeNames) else { return out }
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
