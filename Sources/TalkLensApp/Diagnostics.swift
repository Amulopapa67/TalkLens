// SPDX-License-Identifier: MIT
// In-memory timing samples (milliseconds) and counters. Never persisted; shown as numbers in the About window.

import Foundation
import os
import TalkLensCore

private let logger = Logger.talkLens("diagnostics")

@MainActor
final class Diagnostics {
    static let sampleCap = 500

    /// AX move/resize event → panel setFrame.
    private(set) var followSamples: [Double] = []
    /// New message seen → translation displayed (only truly new messages, D-027).
    private(set) var translationSamples: [Double] = []
    /// Breakdown of each translation sample: first content event → read start (debounce + queue wait).
    private(set) var eventToReadSamples: [Double] = []
    /// … → read result on the main actor.
    private(set) var stageReadSamples: [Double] = []
    /// … submit to the translation service → outcome applied.
    private(set) var translateSamples: [Double] = []
    /// … outcome applied → overlay labels / sidebar rows updated.
    private(set) var displaySamples: [Double] = []
    /// One KakaoChatReader.read call.
    private(set) var readSamples: [Double] = []
    /// TranscriptDiffer.diff + preprocessing of new rows.
    private(set) var ingestSamples: [Double] = []
    /// Rows whose subtree one incremental read analysed (0 = everything came from the row cache).
    private(set) var rowsAnalyzedSamples: [Double] = []
    /// Loaded rows of the transcript table at the last read.
    private(set) var lastRowsTotal = 0

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
    /// Chat windows currently followed (one session each).
    private(set) var sessionCount = 0

    /// "Busy" indicator of the menu bar icon (state only; nothing is recorded).
    let activity = ActivityTracker()

    /// Launch timeline (ms since launch), each milestone logged once.
    enum StartupMilestone: String, CaseIterable {
        case firstEnumeration, firstSession, firstReadStarted, firstRead, firstIngest, warmUp, firstTranslation,
             firstDisplay
    }
    private let launchedAt = ContinuousClock.now
    private(set) var startup: [StartupMilestone: Double] = [:]

    func recordFollow(_ ms: Double) { append(&followSamples, ms) }
    func recordTranslation(_ ms: Double) { append(&translationSamples, ms) }

    /// One "new message → translation displayed" sample with its breakdown.
    func recordTranslation(_ b: LatencyTrace.Breakdown) {
        append(&translationSamples, b.total)
        append(&eventToReadSamples, b.eventToRead)
        append(&stageReadSamples, b.read)
        append(&translateSamples, b.translate)
        append(&displaySamples, b.display)
    }

    /// Records a launch milestone the first time it is reached (numbers only).
    func markStartup(_ milestone: StartupMilestone) {
        guard startup[milestone] == nil else { return }
        let ms = LatencyTrace.ms(ContinuousClock.now - launchedAt)
        startup[milestone] = ms
        logger.info("startup \(milestone.rawValue, privacy: .public) ms=\(Int(ms), privacy: .public)")
    }
    func recordIngest(_ ms: Double) { append(&ingestSamples, ms) }

    func recordRead(_ ms: Double?) {
        readCount += 1
        if let ms { append(&readSamples, ms) } else { readFailureCount += 1 }
    }

    /// Successful read: duration plus how much of it was incremental.
    func recordRead(_ ms: Double, rowsAnalyzed: Int, rowsTotal: Int) {
        recordRead(ms)
        append(&rowsAnalyzedSamples, Double(rowsAnalyzed))
        lastRowsTotal = rowsTotal
    }

    func recordAXEvent() { axEventCount += 1 }
    func recordPollRead() { pollReadCount += 1 }
    func recordCheapPollCheck() { cheapPollCheckCount += 1 }
    func recordSkippedHiddenRead() { skippedHiddenReadCount += 1 }
    func recordOverlayFastTrackTick() { overlayFastTrackTicks += 1 }
    func recordOverlayReanchor() { overlayReanchors += 1 }
    func setSessionCount(_ count: Int) { sessionCount = count }

    var followStats: LatencyStats { LatencyStats(followSamples) }
    var translationStats: LatencyStats { LatencyStats(translationSamples) }
    var readStats: LatencyStats { LatencyStats(readSamples) }
    var ingestStats: LatencyStats { LatencyStats(ingestSamples) }
    var rowsAnalyzedStats: LatencyStats { LatencyStats(rowsAnalyzedSamples) }
    var eventToReadStats: LatencyStats { LatencyStats(eventToReadSamples) }
    var stageReadStats: LatencyStats { LatencyStats(stageReadSamples) }
    var translateStats: LatencyStats { LatencyStats(translateSamples) }
    var displayStats: LatencyStats { LatencyStats(displaySamples) }

    /// Launch milestones in order, e.g. "firstRead=812 firstTranslation=1430".
    var startupLine: String {
        StartupMilestone.allCases.compactMap { m in startup[m].map { "\(m.rawValue)=\(Int($0))" } }
            .joined(separator: " ")
    }

    /// One numbers-only line for `log show` (durations in ms and counts; no content).
    var summaryLine: String {
        func f(_ s: LatencyStats) -> String { String(format: "n=%d p50=%.1f p95=%.1f", s.count, s.p50, s.p95) }
        return "stats translation[\(f(translationStats))] eventToRead[\(f(eventToReadStats))] "
            + "readStage[\(f(stageReadStats))] translate[\(f(translateStats))] display[\(f(displayStats))] "
            + "follow[\(f(followStats))] read[\(f(readStats))] "
            + "ingest[\(f(ingestStats))] rowsAnalyzed[\(f(rowsAnalyzedStats))] rowsTotal=\(lastRowsTotal) "
            + "reads=\(readCount) readFailures=\(readFailureCount) "
            + "axEvents=\(axEventCount) pollReads=\(pollReadCount) cheapPollChecks=\(cheapPollCheckCount) "
            + "skippedHiddenReads=\(skippedHiddenReadCount) overlayFastTrackTicks=\(overlayFastTrackTicks) "
            + "overlayReanchors=\(overlayReanchors) sessions=\(sessionCount) startup[\(startupLine)]"
    }

    private func append(_ samples: inout [Double], _ value: Double) {
        samples.append(value)
        if samples.count > Diagnostics.sampleCap {
            samples.removeFirst(samples.count - Diagnostics.sampleCap)
        }
    }
}
