// SPDX-License-Identifier: MIT
// Launch at login via SMAppService.mainApp.

import Foundation
import Observation
import os
import ServiceManagement

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
        case .enabled: return "已启用"
        case .notRegistered: return "未启用"
        case .requiresApproval: return "需要在 系统设置 → 通用 → 登录项 中批准"
        case .notFound: return "未找到（请从 .app 运行）"
        @unknown default: return "未知状态"
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
