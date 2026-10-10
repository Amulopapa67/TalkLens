// SPDX-License-Identifier: MIT
// Thin wrapper around AXObserver. Observing is read-only: it only subscribes to notifications that KakaoTalk
// already posts. The C callback does no work beyond forwarding the notification name to the main actor.

import ApplicationServices
import Foundation
import os

private let logger = Logger.talkLens("ax-observer")

/// Receives AX notification names (and the element that posted them) on the main actor.
@MainActor
protocol AXEventSink: AnyObject {
    func axEventReceived(_ name: String, element: AXElementRef)
}

/// Token → sink registry. The AX refcon carries only an integer token, so a late callback after teardown
/// can never dereference freed memory.
@MainActor
enum AXEventRouter {
    private struct WeakSink { weak var sink: AXEventSink? }
    private static var sinks: [Int: WeakSink] = [:]
    private static var nextToken = 1

    static func register(_ sink: AXEventSink) -> Int {
        let token = nextToken
        nextToken += 1
        sinks[token] = WeakSink(sink: sink)
        return token
    }

    static func unregister(_ token: Int) {
        sinks[token] = nil
    }

    static func deliver(token: Int, name: String, element: AXElementRef) {
        sinks[token]?.sink?.axEventReceived(name, element: element)
    }
}

/// C callback: forwards (token, name) to the main actor. The observer's run-loop source is on the main run
/// loop, so this normally already runs on the main thread.
private func talkLensAXCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                                _ refcon: UnsafeMutableRawPointer?) {
    let token = Int(bitPattern: refcon)
    let name = notification as String
    let ref = AXElementRef(element: element)
    if Thread.isMainThread {
        MainActor.assumeIsolated { AXEventRouter.deliver(token: token, name: name, element: ref) }
    } else {
        Task { @MainActor in AXEventRouter.deliver(token: token, name: name, element: ref) }
    }
}

/// One AXObserver for one process, with bookkeeping so every registration and the run-loop source are
/// removed on `invalidate()`.
@MainActor
final class AXObservation {
    let pid: pid_t
    private let observer: AXObserver
    private let source: CFRunLoopSource
    private let token: Int
    private var registrations: [(element: AXUIElement, name: String)] = []
    private(set) var isValid = true

    struct AddResult {
        var registered = 0
        var unsupported = 0
        var permissionDenied = false
        var invalidElement = false
        var otherErrors = 0
        /// Names not attempted because the registration time budget ran out.
        var skipped = 0
    }

    private init(pid: pid_t, observer: AXObserver, token: Int) {
        self.pid = pid
        self.observer = observer
        self.token = token
        self.source = AXObserverGetRunLoopSource(observer)
        // Common modes so events keep flowing while a menu is open or a window is being resized.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    /// Returns the observation, or nil plus the AX error code.
    static func make(pid: pid_t, token: Int) -> (observation: AXObservation?, error: AXError) {
        var created: AXObserver?
        let err = AXObserverCreate(pid, talkLensAXCallback, &created)
        guard err == .success, let created else {
            logger.error("AXObserverCreate failed code=\(err.rawValue, privacy: .public)")
            return (nil, err)
        }
        return (AXObservation(pid: pid, observer: created, token: token), .success)
    }

    /// Registers `names` on `element`. Each registration is a synchronous IPC to KakaoTalk on the main
    /// thread, so the caller passes a deadline: once it has passed, the remaining names are skipped
    /// (reported in `skipped`) instead of stalling the UI behind a busy KakaoTalk.
    @discardableResult
    func add(_ names: [String], to element: AXUIElement, deadline: ContinuousClock.Instant? = nil) -> AddResult {
        var result = AddResult()
        guard isValid else { return result }
        let refcon = UnsafeMutableRawPointer(bitPattern: token)
        for (index, name) in names.enumerated() {
            if let deadline, ContinuousClock.now >= deadline {
                result.skipped = names.count - index
                break
            }
            let err = AXObserverAddNotification(observer, element, name as CFString, refcon)
            switch err {
            case .success, .notificationAlreadyRegistered:
                registrations.append((element, name))
                result.registered += 1
            case .notificationUnsupported, .actionUnsupported, .attributeUnsupported:
                result.unsupported += 1
            case .apiDisabled:
                result.permissionDenied = true
            case .invalidUIElement, .invalidUIElementObserver:
                result.invalidElement = true
            default:
                result.otherErrors += 1
            }
        }
        return result
    }

    /// Removes every registration on `element`.
    func removeAll(for element: AXUIElement) {
        var kept: [(element: AXUIElement, name: String)] = []
        for reg in registrations {
            if CFEqual(reg.element, element) {
                _ = AXObserverRemoveNotification(observer, reg.element, reg.name as CFString)
            } else {
                kept.append(reg)
            }
        }
        registrations = kept
    }

    func invalidate() {
        guard isValid else { return }
        isValid = false
        for reg in registrations {
            _ = AXObserverRemoveNotification(observer, reg.element, reg.name as CFString)
        }
        registrations.removeAll()
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }

    var registrationCount: Int { registrations.count }

    /// Safety net: an observation dropped without `invalidate()` must not leave its run-loop source (and
    /// registrations) behind on the main run loop.
    isolated deinit {
        if isValid {
            logger.fault("AXObservation released without invalidate()")
            invalidate()
        }
    }
}
