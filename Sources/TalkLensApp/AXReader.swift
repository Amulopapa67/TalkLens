// SPDX-License-Identifier: MIT
// Off-main AX reads on dedicated serial executors (one for snapshots, one for cheap geometry reads so that a
// window drag is never queued behind a transcript parse).

import CoreGraphics
import Dispatch
import Foundation
import KakaoAX
import TalkLensCore

struct WindowGeometry: Sendable {
    var frame: CGRect?
    var minimized: Bool
}

enum ReadOutcome: Sendable {
    /// Full transcript read of the current chat window.
    case read(ChatWindowRead, window: LiveAXNode)
    /// Window resolved without reading the transcript (used while paused).
    case windowOnly(LiveAXNode, WindowGeometry)
    case failure(KakaoReadError, window: LiveAXNode?)
}

actor AXReader {
    private let queue = DispatchSerialQueue(label: "dev.lipper.TalkLens.ax-reader", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let parser: TranscriptParser
    private var lastStartedAt: ContinuousClock.Instant?
    private var lastOutcome: ReadOutcome?
    private(set) var coalescedCount = 0

    init(parser: TranscriptParser = TranscriptParser()) {
        self.parser = parser
    }

    /// Reads the current chat window. Requests made before an already-started read began (i.e. queued
    /// behind it) are answered with that read's result instead of reading again.
    func read(requestedAt: ContinuousClock.Instant) -> ReadOutcome {
        if let started = lastStartedAt, started >= requestedAt, let cached = lastOutcome {
            coalescedCount += 1
            return cached
        }
        let started = ContinuousClock.now
        let outcome = Self.performRead(parser: parser)
        lastStartedAt = started
        lastOutcome = outcome
        return outcome
    }

    /// Resolves the current chat window and its geometry without touching the transcript.
    func resolveWindow() -> ReadOutcome {
        guard KakaoProcess.isAccessibilityTrusted else { return .failure(.notTrusted, window: nil) }
        guard let app = KakaoProcess.applicationNode() else { return .failure(.notRunning, window: nil) }
        guard let window = KakaoChatReader.currentChatWindow(app: app) else {
            return .failure(.noChatWindow, window: nil)
        }
        return .windowOnly(window, WindowGeometry(frame: window.frame, minimized: window.isMinimized))
    }

    /// Drops the cached outcome (it holds chat content in memory).
    func clear() {
        lastOutcome = nil
        lastStartedAt = nil
    }

    private static func performRead(parser: TranscriptParser) -> ReadOutcome {
        guard KakaoProcess.isAccessibilityTrusted else { return .failure(.notTrusted, window: nil) }
        guard let app = KakaoProcess.applicationNode() else { return .failure(.notRunning, window: nil) }
        guard let window = KakaoChatReader.currentChatWindow(app: app) else {
            return .failure(.noChatWindow, window: nil)
        }
        do {
            return .read(try KakaoChatReader.read(window: window, parser: parser), window: window)
        } catch let error as KakaoReadError {
            return .failure(error, window: window)
        } catch {
            return .failure(.transcriptNotFound, window: window)
        }
    }
}

actor WindowGeometryReader {
    private let queue = DispatchSerialQueue(label: "dev.lipper.TalkLens.ax-geometry", qos: .userInteractive)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init() {}

    func geometry(of window: LiveAXNode) -> WindowGeometry {
        WindowGeometry(frame: window.frame, minimized: window.isMinimized)
    }
}
