// SPDX-License-Identifier: MIT
// Fallback for macOS 15–25, where no UI-less TranslationSession exists: a hidden, non-activating 1×1 panel
// hosts a SwiftUI view with `.translationTask(configuration)`. The session lives only inside the action
// closure, which loops over a job stream (`for await job in jobs`) for as long as the host exists.
// Results return through CheckedContinuations. Only works inside a running NSApplication.

import AppKit
import Foundation
import SwiftUI
@preconcurrency import Translation

/// One batch handed to the hosted session.
struct HostJob: Sendable {
    let id: UInt64
    let items: [TranslationItem]
}

/// Never becomes key or main; never activates the app; invisible and click-through.
final class TranslationHostPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class TranslationHost {
    static let shared = TranslationHost()

    private final class Host {
        let source: Locale.Language
        let target: Locale.Language
        let panel: TranslationHostPanel
        let continuation: AsyncStream<HostJob>.Continuation
        init(source: Locale.Language, target: Locale.Language, panel: TranslationHostPanel,
             continuation: AsyncStream<HostJob>.Continuation) {
            self.source = source
            self.target = target
            self.panel = panel
            self.continuation = continuation
        }
    }

    private var host: Host?
    private var hostGeneration: UInt64 = 0
    private var pending: [UInt64: CheckedContinuation<[TranslationResult], any Error>] = [:]
    private var nextJobID: UInt64 = 0

    private init() {}

    func translate(_ items: [TranslationItem], source: Locale.Language,
                   target: Locale.Language) async throws -> [TranslationResult] {
        guard NSApp != nil, NSApp.isRunning else {
            throw TranslationEngineError.unsupported(AppleTranslationEngine.hostRequiredReason)
        }
        let current = ensureHost(source: source, target: target)
        nextJobID &+= 1
        let jobID = nextJobID
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[TranslationResult], any Error>) in
            pending[jobID] = cont
            if case .terminated = current.continuation.yield(HostJob(id: jobID, items: items)) {
                complete(jobID, .failure(.cancelled))
            }
        }
    }

    /// Called from the hosted action closure when a job finishes.
    func complete(_ jobID: UInt64, _ result: Result<[TranslationResult], TranslationEngineError>) {
        guard let cont = pending.removeValue(forKey: jobID) else { return }
        switch result {
        case .success(let r): cont.resume(returning: r)
        case .failure(let e): cont.resume(throwing: e)
        }
    }

    /// Removes the hidden panel and fails every outstanding job with `.cancelled`.
    func tearDown() {
        if let h = host {
            h.continuation.finish()
            h.panel.orderOut(nil)
            h.panel.contentView = nil
        }
        host = nil
        let outstanding = pending
        pending = [:]
        for cont in outstanding.values { cont.resume(throwing: TranslationEngineError.cancelled) }
    }

    private func ensureHost(source: Locale.Language, target: Locale.Language) -> Host {
        if let h = host, h.source == source, h.target == target { return h }
        tearDown()
        hostGeneration &+= 1
        let generation = hostGeneration
        let (jobs, continuation) = AsyncStream.makeStream(of: HostJob.self)
        continuation.onTermination = { _ in
            // The stream ends when the action task is cancelled (e.g. the view went away); start fresh next time.
            Task { @MainActor in TranslationHost.shared.streamTerminated(generation: generation) }
        }
        let panel = TranslationHostPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                                         styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let configuration = TranslationSession.Configuration(source: source, target: target)
        panel.contentView = NSHostingView(rootView: TranslationHostView(configuration: configuration, jobs: jobs))
        panel.orderFrontRegardless()
        let h = Host(source: source, target: target, panel: panel, continuation: continuation)
        host = h
        return h
    }

    private func streamTerminated(generation: UInt64) {
        guard generation == hostGeneration, host != nil else { return }
        tearDown()
    }
}

/// Invisible view that owns the session through `.translationTask`.
struct TranslationHostView: View {
    let configuration: TranslationSession.Configuration
    let jobs: AsyncStream<HostJob>

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { @Sendable session in
                // The session never leaves this closure. Nonisolated so the session's calls do not cross actors.
                for await job in jobs {
                    let result: Result<[TranslationResult], TranslationEngineError>
                    do {
                        let requests = job.items.map {
                            TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
                        }
                        let responses = try await session.translations(from: requests)
                        result = .success(try AppleTranslationEngine.matchResults(
                            items: job.items, responses: responses.map { ($0.clientIdentifier, $0.targetText) }))
                    } catch {
                        result = .failure(AppleTranslationEngine.mapError(error))
                    }
                    await TranslationHost.shared.complete(job.id, result)
                }
            }
    }
}
