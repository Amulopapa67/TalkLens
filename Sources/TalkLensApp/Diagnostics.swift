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

    func recordFollow(_ ms: Double) { append(&followSamples, ms) }
    func recordTranslation(_ ms: Double) { append(&translationSamples, ms) }
    func recordIngest(_ ms: Double) { append(&ingestSamples, ms) }

    func recordRead(_ ms: Double?) {
        readCount += 1
        if let ms { append(&readSamples, ms) } else { readFailureCount += 1 }
    }

    func recordAXEvent() { axEventCount += 1 }
    func recordPollRead() { pollReadCount += 1 }

    var followStats: LatencyStats { LatencyStats(followSamples) }
    var translationStats: LatencyStats { LatencyStats(translationSamples) }
    var readStats: LatencyStats { LatencyStats(readSamples) }
    var ingestStats: LatencyStats { LatencyStats(ingestSamples) }

    private func append(_ samples: inout [Double], _ value: Double) {
        samples.append(value)
        if samples.count > Diagnostics.sampleCap {
            samples.removeFirst(samples.count - Diagnostics.sampleCap)
        }
    }
}
