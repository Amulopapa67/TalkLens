// SPDX-License-Identifier: MIT
// Launch at login via SMAppService.mainApp.

import Foundation
import Observation
import os
import ServiceManagement
import TalkLensCore

private let logger = Logger.talkLens("login-item")

@MainActor
@Observable
final class LoginItemController {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var lastError: String?

    init() {
        refresh()
    }

    var isEnabled: Bool { status == .enabled }

    var statusDescription: String {
        switch status {
        case .enabled: return tr(.loginEnabled)
        case .notRegistered: return tr(.loginNotRegistered)
        case .requiresApproval: return tr(.loginRequiresApproval)
        case .notFound: return tr(.loginNotFound)
        @unknown default: return tr(.unknownState)
        }
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let ns = error as NSError
            lastError = ns.localizedDescription
            logger.error("login item change failed code=\(ns.code, privacy: .public)")
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
