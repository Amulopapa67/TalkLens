// SPDX-License-Identifier: MIT
// In-memory timing samples (milliseconds) and counters. Never persisted; shown as numbers in the About window.

import Foundation
import TalkLensCore

@MainActor
final class Diagnostics {
    static let sampleCap = 500

    /// AX move/resize event → panel setFrame.
    private(set) var followSamples: [Double] = []
    /// New message seen → translation displayed.
    private(set) var translationSamples: [Double] = []
    /// One KakaoChatReader.read call.
    private(set) var readSamples: [Double] = []
    /// TranscriptDiffer.diff + preprocessing of new rows.
    private(set) var ingestSamples: [Double] = []

    private(set) var readCount = 0
    private(set) var readFailureCount = 0
    private(set) var axEventCount = 0
    private(set) var pollReadCount = 0
    /// Cheap change probes (row count + last row frame + window size) done instead of full reads.
    private(set) var cheapPollCheckCount = 0
    /// Read requests dropped (marked dirty) because the panel was not visible.
    private(set) var skippedHiddenReadCount = 0
    /// Inline overlay: scroll-anchor frame reads while following a scroll (one IPC each).
    private(set) var overlayFastTrackTicks = 0
    /// Inline overlay: full reads applied to the overlay (re-anchoring labels to fresh frames).
    private(set) var overlayReanchors = 0

    func recordFollow(_ ms: Double) { append(&followSamples, ms) }
    func recordTranslation(_ ms: Double) { append(&translationSamples, ms) }
    func recordIngest(_ ms: Double) { append(&ingestSamples, ms) }

    func recordRead(_ ms: Double?) {
        readCount += 1
        if let ms { append(&readSamples, ms) } else { readFailureCount += 1 }
    }

    func recordAXEvent() { axEventCount += 1 }
    func recordPollRead() { pollReadCount += 1 }
    func recordCheapPollCheck() { cheapPollCheckCount += 1 }
    func recordSkippedHiddenRead() { skippedHiddenReadCount += 1 }
    func recordOverlayFastTrackTick() { overlayFastTrackTicks += 1 }
    func recordOverlayReanchor() { overlayReanchors += 1 }

    var followStats: LatencyStats { LatencyStats(followSamples) }
    var translationStats: LatencyStats { LatencyStats(translationSamples) }
    var readStats: LatencyStats { LatencyStats(readSamples) }
    var ingestStats: LatencyStats { LatencyStats(ingestSamples) }

    /// One numbers-only line for `log show` (durations in ms and counts; no content).
    var summaryLine: String {
        func f(_ s: LatencyStats) -> String { String(format: "n=%d p50=%.1f p95=%.1f", s.count, s.p50, s.p95) }
        return "stats translation[\(f(translationStats))] follow[\(f(followStats))] read[\(f(readStats))] "
            + "ingest[\(f(ingestStats))] reads=\(readCount) readFailures=\(readFailureCount) "
            + "axEvents=\(axEventCount) pollReads=\(pollReadCount) cheapPollChecks=\(cheapPollCheckCount) "
            + "skippedHiddenReads=\(skippedHiddenReadCount) overlayFastTrackTicks=\(overlayFastTrackTicks) "
            + "overlayReanchors=\(overlayReanchors)"
    }

    private func append(_ samples: inout [Double], _ value: Double) {
        samples.append(value)
        if samples.count > Diagnostics.sampleCap {
            samples.removeFirst(samples.count - Diagnostics.sampleCap)
        }
    }
}
