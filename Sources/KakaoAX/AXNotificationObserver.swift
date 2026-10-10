// SPDX-License-Identifier: MIT
// Thin wrapper over AXObserver: subscribes to notifications (read-only; nothing is posted or performed) and
// delivers them on the run loop it was scheduled on (the main run loop by default).

import ApplicationServices
import Foundation

public final class AXNotificationObserver {
    public typealias Handler = (_ notification: String, _ element: AXUIElement) -> Void

    private let observer: AXObserver
    private let handler: Handler
    private var registrations: [(element: AXUIElement, name: String)] = []
    private let runLoop: CFRunLoop

    /// nil when the observer cannot be created (e.g. not trusted or the process is gone).
    public init?(pid: pid_t, runLoop: CFRunLoop = CFRunLoopGetMain(), handler: @escaping Handler) {
        var created: AXObserver?
        let err = AXObserverCreate(pid, { _, element, notification, refcon in
            guard let refcon else { return }
            let me = Unmanaged<AXNotificationObserver>.fromOpaque(refcon).takeUnretainedValue()
            me.handler(notification as String, element)
        }, &created)
        guard err == .success, let created else { return nil }
        self.observer = created
        self.handler = handler
        self.runLoop = runLoop
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(created), .defaultMode)
    }

    deinit {
        removeAll()
        CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    /// Subscribes `element` to `names`; returns the AXError raw value per notification that failed.
    @discardableResult
    public func add(_ names: [String], to element: AXUIElement) -> [String: Int32] {
        var failures: [String: Int32] = [:]
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in names {
            let err = AXObserverAddNotification(observer, element, name as CFString, refcon)
            if err == .success || err == .notificationAlreadyRegistered {
                registrations.append((element, name))
            } else {
                failures[name] = err.rawValue
            }
        }
        return failures
    }

    /// Unsubscribes every notification registered on `element`.
    public func remove(element: AXUIElement) {
        registrations.removeAll { reg in
            guard CFEqual(reg.element, element) else { return false }
            _ = AXObserverRemoveNotification(observer, reg.element, reg.name as CFString)
            return true
        }
    }

    public func removeAll() {
        for reg in registrations {
            _ = AXObserverRemoveNotification(observer, reg.element, reg.name as CFString)
        }
        registrations.removeAll()
    }
}
