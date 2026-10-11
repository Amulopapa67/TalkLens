// SPDX-License-Identifier: MIT
// Supported languages and per-pair install status for the settings window (D-023). Status checks only ask
// LanguageAvailability (through the engine); no text is involved.

import Foundation
import Observation
import TalkLensCore
import TalkLensTranslate

@MainActor
@Observable
final class LanguageStatusModel {
    /// Catalog ids Apple Translation supports here; nil = unknown (pickers show the static catalog).
    private(set) var supported: Set<String>?
    /// Status per source id for the current target (fixed source: one entry; auto: every catalog source).
    private(set) var statuses: [String: EngineStatus] = [:]
    private(set) var checking = false

    @ObservationIgnored private let service: TranslationService
    @ObservationIgnored private var loadedSupported = false

    init(service: TranslationService) {
        self.service = service
    }

    func refresh(source: String, target: String) async {
        if !loadedSupported {
            loadedSupported = true
            if await service.engine.id == "apple" {
                supported = await AppleTranslationEngine.supportedCatalogLanguages()
            }
        }
        checking = true
        let sources: [String]
        if source == LanguageCatalog.autoID {
            sources = LanguageCatalog.targetOptions(supported: supported).map(\.id)
                .filter { !LanguageCatalog.sameFamily($0, target) }
        } else {
            sources = LanguageCatalog.sameFamily(source, target) ? [] : [source]
        }
        let targetLanguage = Locale.Language(identifier: target)
        var out: [String: EngineStatus] = [:]
        for s in sources {
            out[s] = await service.status(source: Locale.Language(identifier: s), target: targetLanguage)
        }
        statuses = out
        checking = false
    }

    /// Sources whose pair with the target still needs a download.
    var needsDownload: [String] {
        statuses.filter { $0.value == .needsDownload }.map(\.key).sorted(by: Self.catalogOrder)
    }

    var installed: [String] {
        statuses.filter { $0.value == .ready }.map(\.key).sorted(by: Self.catalogOrder)
    }

    var unsupported: [String] {
        statuses.filter { if case .unsupported = $0.value { return true } else { return false } }.map(\.key)
            .sorted(by: Self.catalogOrder)
    }

    static func catalogOrder(_ a: String, _ b: String) -> Bool {
        let ia = LanguageCatalog.all.firstIndex { $0.id == a } ?? Int.max
        let ib = LanguageCatalog.all.firstIndex { $0.id == b } ?? Int.max
        return ia < ib
    }

    static func statusText(_ status: EngineStatus?) -> String {
        switch status {
        case .ready?: return "已安装"
        case .needsDownload?: return "需要下载"
        case .unsupported?: return "不支持"
        case nil: return "检测中…"
        }
    }
}
