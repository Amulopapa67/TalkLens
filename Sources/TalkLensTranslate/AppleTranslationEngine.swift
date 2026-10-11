// SPDX-License-Identifier: MIT
// Apple Translation engine (on-device). See docs/architecture.md §5.
//
// Routes:
//   - macOS 26+: UI-less `TranslationSession(installedSource:target:)` (requires installed languages);
//     on 26.4+ with `preferredStrategy: .lowLatency`. One session per (source, target) pair (several pairs
//     live side by side when the source is auto-detected), held in an actor.
//   - macOS 15–25: `TranslationHost` (hidden SwiftUI `.translationTask` host), only inside a running app.
// Never logs text; only counts, durations and error codes.

import AppKit
import Foundation
import os
import TalkLensCore
@preconcurrency import Translation

/// Language availability as reported by `LanguageAvailability`, decoupled from the framework type so the
/// mapping can be unit-tested without models installed.
public enum AppleLanguageState: Sendable, Equatable {
    case installed
    case supported
    case unsupported
}

/// How the Apple engine can obtain a `TranslationSession` in the current process.
public enum AppleSessionRoute: Sendable, Equatable {
    /// macOS 26+: UI-less session.
    case uiLess
    /// macOS 15–25 inside a running NSApplication: hidden SwiftUI host.
    case hosted
    /// macOS 15–25 without a running NSApplication (e.g. the CLI).
    case unavailable
}

public struct AppleTranslationEngine: TranslationEngine {
    public let id = "apple"
    /// Prefer `.lowLatency` on macOS 26.4+ (highFidelity uses Apple Intelligence and is slower).
    public let preferLowLatency: Bool
    private let store: AppleSessionStore

    public init(preferLowLatency: Bool = true) {
        self.preferLowLatency = preferLowLatency
        self.store = AppleSessionStore(preferLowLatency: preferLowLatency)
    }

    public static let hostRequiredReason = "requires the TalkLens app on macOS < 26"

    // MARK: - Pure mapping (unit-tested)

    /// Maps language availability plus session route to an `EngineStatus`.
    public static func mapStatus(_ state: AppleLanguageState, route: AppleSessionRoute,
                                 source: String, target: String) -> EngineStatus {
        switch state {
        case .unsupported:
            return .unsupported("language pair \(source)→\(target) is not supported by Apple Translation")
        case .supported:
            return .needsDownload
        case .installed:
            return route == .unavailable ? .unsupported(hostRequiredReason) : .ready
        }
    }

    // MARK: - TranslationEngine

    public func status(source: Locale.Language, target: Locale.Language) async -> EngineStatus {
        let state = await Self.languageState(source: source, target: target, preferLowLatency: preferLowLatency)
        let route = await Self.currentRoute()
        return Self.mapStatus(state, route: route, source: source.minimalIdentifier, target: target.minimalIdentifier)
    }

    public func translate(_ items: [TranslationItem], source: Locale.Language,
                          target: Locale.Language) async throws -> [TranslationResult] {
        if items.isEmpty { return [] }
        switch await Self.currentRoute() {
        case .uiLess:
            return try await store.translate(items, source: source, target: target)
        case .hosted:
            return try await TranslationHost.shared.translate(items, source: source, target: target)
        case .unavailable:
            throw TranslationEngineError.unsupported(Self.hostRequiredReason)
        }
    }

    // MARK: - Helpers

    static func languageState(source: Locale.Language, target: Locale.Language,
                              preferLowLatency: Bool) async -> AppleLanguageState {
        var availability = LanguageAvailability()
        // macOS 26.4 SDK API (Swift 6.3+ toolchains); older SDKs build without it.
        #if compiler(>=6.3)
        if #available(macOS 26.4, *), preferLowLatency {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        }
        #endif
        switch await availability.status(from: source, to: target) {
        case .installed: return .installed
        case .supported: return .supported
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Catalog ids that Apple Translation supports on this Mac (`LanguageAvailability().supportedLanguages`),
    /// or nil when the list is empty (callers fall back to the static catalog).
    public static func supportedCatalogLanguages() async -> Set<String>? {
        let languages = await LanguageAvailability().supportedLanguages
        let ids = Set(languages.compactMap(LanguageCatalog.canonicalID))
        return ids.isEmpty ? nil : ids
    }

    /// Public wrapper of the availability check for UI (settings) — no session is created.
    public static func pairState(source: String, target: String) async -> AppleLanguageState {
        await languageState(source: Locale.Language(identifier: source), target: Locale.Language(identifier: target),
                            preferLowLatency: true)
    }

    static func currentRoute() async -> AppleSessionRoute {
        // UI-less sessions need the macOS 26 SDK (Swift 6.2+ toolchains) at build time.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return .uiLess }
        #endif
        let appRunning = await MainActor.run { NSApp != nil && NSApp.isRunning }
        return appRunning ? .hosted : .unavailable
    }

    /// Maps a framework error to `TranslationEngineError` without including any text (domain + code only).
    static func mapError(_ error: any Error) -> TranslationEngineError {
        if let e = error as? TranslationEngineError { return e }
        if error is CancellationError { return .cancelled }
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if TranslationError.notInstalled ~= error { return .notInstalled }
            if TranslationError.alreadyCancelled ~= error { return .cancelled }
        }
        #endif
        if TranslationError.unsupportedLanguagePairing ~= error
            || TranslationError.unsupportedSourceLanguage ~= error
            || TranslationError.unsupportedTargetLanguage ~= error {
            return .unsupported("language pair not supported")
        }
        if TranslationError.nothingToTranslate ~= error { return .failed("nothingToTranslate") }
        if TranslationError.unableToIdentifyLanguage ~= error { return .failed("unableToIdentifyLanguage") }
        let ns = error as NSError
        return .failed("\(ns.domain)#\(ns.code)")
    }

    /// Matches responses to items by `clientIdentifier`, falling back to position.
    static func matchResults(items: [TranslationItem],
                             responses: [(clientIdentifier: String?, text: String)]) throws -> [TranslationResult] {
        var byID: [String: String] = [:]
        for r in responses { if let cid = r.clientIdentifier { byID[cid] = r.text } }
        var out: [TranslationResult] = []
        out.reserveCapacity(items.count)
        for (i, item) in items.enumerated() {
            if let t = byID[item.id] {
                out.append(TranslationResult(id: item.id, text: t))
            } else if byID.isEmpty, i < responses.count {
                out.append(TranslationResult(id: item.id, text: responses[i].text))
            } else {
                throw TranslationEngineError.failed("missing result")
            }
        }
        return out
    }
}

/// Holds the macOS 26+ UI-less sessions, one per (source, target) pair — with auto-detected sources several
/// pairs are used side by side (D-023). At most `maxSessions` are kept (least recently used is dropped); a
/// session is recreated after a cancellation or a not-installed error.
actor AppleSessionStore {
    static let maxSessions = 4
    private let preferLowLatency: Bool
    private var sessions: [String: TranslationSession] = [:]
    /// Pair keys, least recently used first.
    private var usage: [String] = []
    private let logger = Logger(subsystem: TranslateLog.subsystem, category: "apple-engine")

    init(preferLowLatency: Bool) {
        self.preferLowLatency = preferLowLatency
    }

    /// Number of live sessions (tests / diagnostics).
    var sessionCount: Int { sessions.count }

    func translate(_ items: [TranslationItem], source: Locale.Language,
                   target: Locale.Language) async throws -> [TranslationResult] {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *) else {
            throw TranslationEngineError.unsupported(AppleTranslationEngine.hostRequiredReason)
        }
        let key = source.maximalIdentifier + "|" + target.maximalIdentifier
        let current: TranslationSession
        if let s = sessions[key] {
            current = s
        } else {
            current = makeSession(source: source, target: target)
            sessions[key] = current
            if sessions.count > Self.maxSessions, let oldest = usage.first(where: { $0 != key }) {
                sessions[oldest] = nil
                usage.removeAll { $0 == oldest }
            }
        }
        usage.removeAll { $0 == key }
        usage.append(key)
        let requests = items.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
        let watch = DispatchTime.now().uptimeNanoseconds
        do {
            let responses = try await current.translations(from: requests)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - watch) / 1e6
            logger.debug("batch items=\(items.count, privacy: .public) ms=\(ms, privacy: .public)")
            return try AppleTranslationEngine.matchResults(
                items: items, responses: responses.map { ($0.clientIdentifier, $0.targetText) })
        } catch {
            let mapped = AppleTranslationEngine.mapError(error)
            logger.debug("batch failed items=\(items.count, privacy: .public)")
            if mapped == .cancelled || mapped == .notInstalled {
                // A cancelled session cannot be reused; a not-installed one is retried after download.
                sessions[key] = nil
                usage.removeAll { $0 == key }
            }
            throw mapped
        }
        #else
        throw TranslationEngineError.unsupported(AppleTranslationEngine.hostRequiredReason)
        #endif
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private func makeSession(source: Locale.Language, target: Locale.Language) -> TranslationSession {
        #if compiler(>=6.3)
        if #available(macOS 26.4, *), preferLowLatency {
            return TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
        }
        #endif
        return TranslationSession(installedSource: source, target: target)
    }
    #endif
}
