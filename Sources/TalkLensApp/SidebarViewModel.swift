// SPDX-License-Identifier: MIT
// Snapshot → diff → preprocess → rows → translation. All chat content lives only in memory here; nothing is
// written to disk and nothing but counts/durations is logged.
//
// `rows` covers every loaded message of the chat (not only the ones on screen), so the inline overlay can draw
// whatever scrolls into view at once, and everything loaded is pre-translated: visible messages first (newest
// first), then the rest by distance from the viewport. `visibleIDs` marks the rows on screen; the sidebar list
// shows only those (`visibleRows`).

import Foundation
import Observation
import os
import SwiftUI
import TalkLensCore
import TalkLensTranslate

private let logger = Logger.talkLens("pipeline")

enum RowTranslation: Equatable, Sendable {
    /// Kind is not machine-translated (system, emoji, jamo, url, number, already target language).
    case notNeeded
    case pending
    case done(String)
    case failed(String)
}

struct SidebarRow: Identifiable, Equatable {
    let id: MessageID
    let author: String?
    let timeRaw: String?
    let original: String
    let isMine: Bool
    let isSystem: Bool
    let kind: MessageKind
    let chips: [GlossaryChip]
    let note: String?
    let attachments: AttachmentSummary
    var translation: RowTranslation

    var copyableTranslation: String? {
        if case .done(let t) = translation { return t }
        return nil
    }
}

@MainActor
@Observable
final class SidebarViewModel {
    enum Status: Equatable {
        case starting, active, paused, noPermission, kakaoNotRunning, noChatWindow, transcriptNotFound
    }

    struct Counts: Equatable {
        var rows = 0
        var needsMT = 0
        var done = 0
        var pending = 0
        var failed = 0
    }

    /// Every loaded message of the current chat, top to bottom (on screen or not).
    private(set) var rows: [SidebarRow] = []
    /// Ids of the rows currently on screen in KakaoTalk (a subset of the ids in `rows`).
    private(set) var visibleIDs: Set<MessageID> = []
    private(set) var status: Status = .starting
    private(set) var engineStatus: EngineStatus?
    /// Shown in the sidebar header only (local UI); never logged.
    private(set) var chatTitle: String?
    /// Incremented when rows the sidebar shows are appended at the bottom of the same chat (drives
    /// auto-scroll / pill).
    private(set) var appendedTick = 0
    private(set) var lastAppendedCount = 0
    /// Incremented when the row list is replaced (chat switch / first load / reprocess).
    private(set) var resetTick = 0
    /// Rows whose original-text visibility is flipped relative to the global setting.
    var toggledOriginals: Set<MessageID> = []

    /// Upper bound on messages submitted for translation per chat (visible ones always come first).
    static let translationCap = TranslationPriority.defaultCap

    @ObservationIgnored let service: TranslationService
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let diagnostics: Diagnostics
    @ObservationIgnored private var glossary: Glossary
    @ObservationIgnored private var preprocessor: ChatPreprocessor
    @ObservationIgnored private var trackerStatus: Status = .starting
    @ObservationIgnored private var paused = false

    @ObservationIgnored private var chatKey: String?
    @ObservationIgnored private var lastIDs: [MessageID] = []
    @ObservationIgnored private var messages: [ChatMessage] = []
    @ObservationIgnored private var prepared: [MessageID: PreprocessedMessage] = [:]
    @ObservationIgnored private var rowIndex: [MessageID: Int] = [:]
    @ObservationIgnored private var seenAt: [MessageID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var translateTask: Task<Void, Never>?
    /// Ids of the current submission without an outcome yet, in submission (priority) order.
    @ObservationIgnored private var outstanding: [MessageID] = []

    init(service: TranslationService, glossary: Glossary, settings: AppSettings, diagnostics: Diagnostics) {
        self.service = service
        self.settings = settings
        self.diagnostics = diagnostics
        self.glossary = glossary
        self.preprocessor = ChatPreprocessor(glossary: glossary, targetLanguage: settings.targetLanguage,
                                             glossaryEnabled: settings.glossaryEnabled)
    }

    /// Counts over every loaded row (not only the visible ones).
    var counts: Counts {
        var c = Counts(rows: rows.count)
        for row in rows {
            switch row.translation {
            case .notNeeded: break
            case .pending: c.needsMT += 1; c.pending += 1
            case .done: c.needsMT += 1; c.done += 1
            case .failed: c.needsMT += 1; c.failed += 1
            }
        }
        return c
    }

    /// Row for a message id (reads `rows`, so SwiftUI / observation tracking see translation updates).
    func row(_ id: MessageID) -> SidebarRow? {
        let all = rows
        guard let idx = rowIndex[id], idx < all.count, all[idx].id == id else { return nil }
        return all[idx]
    }

    /// Whether the message is on screen in KakaoTalk.
    func isVisible(_ id: MessageID) -> Bool { visibleIDs.contains(id) }

    /// Rows on screen in KakaoTalk, top to bottom (what the sidebar list shows).
    var visibleRows: [SidebarRow] {
        let visible = visibleIDs
        return rows.filter { visible.contains($0.id) }
    }

    func isOriginalVisible(_ id: MessageID) -> Bool {
        settings.showOriginal != toggledOriginals.contains(id)
    }

    func toggleOriginal(_ id: MessageID) {
        if toggledOriginals.contains(id) { toggledOriginals.remove(id) } else { toggledOriginals.insert(id) }
    }

    // MARK: - Status

    func setTrackerStatus(_ status: Status) {
        trackerStatus = status
        refreshStatus()
        // Without a readable chat window, drop the rows (and the chat content they hold).
        if status != .active && status != .starting && status != .paused && chatKey != nil {
            resetChat(nil)
        }
    }

    func setPaused(_ value: Bool) {
        paused = value
        refreshStatus()
        if value {
            cancelTranslations()
        } else {
            scheduleTranslation(force: true)
        }
    }

    private func refreshStatus() {
        status = paused ? .paused : trackerStatus
    }

    func refreshEngineStatus() async {
        engineStatus = await service.status()
    }

    // MARK: - Ingest

    /// - triggeredAt: when the AX content event (or poll) that led to this read happened; the
    ///   "new message seen → translation displayed" latency is measured from there.
    func ingest(_ read: ChatWindowReadLike, triggeredAt: ContinuousClock.Instant? = nil) {
        ingest(snapshot: read.snapshot, title: read.title, animate: true, triggeredAt: triggeredAt,
               viewport: read.transcriptFrame, visibleIDs: read.visibleIDs)
    }

    /// - viewport: transcript viewport (AX); tells the visible rows apart when `visibleIDs` is nil.
    /// - visibleIDs: messages on screen. nil = derive them from `viewport` and the frames, or (no viewport)
    ///   treat every message as visible.
    func ingest(snapshot: TranscriptSnapshot, title: String?, animate: Bool,
                triggeredAt: ContinuousClock.Instant? = nil, viewport: CGRect? = nil,
                visibleIDs: Set<MessageID>? = nil) {
        guard !paused else { return }
        let seenInstant = triggeredAt ?? .now
        let stopwatch = Stopwatch()
        if snapshot.chatKey != chatKey { resetChat(snapshot.chatKey) }
        if chatTitle != title { chatTitle = title }

        let newIDs = snapshot.messages.map(\.id)
        let newVisible = visibleIDs ?? Self.visible(snapshot.messages, viewport: viewport)
        let diff = TranscriptDiffer.diff(old: lastIDs, new: newIDs)
        let hadRows = !lastIDs.isEmpty
        // Order-only changes (same ids, different order) also rebuild the rows.
        guard diff.hasChanges || newIDs != lastIDs || (rows.isEmpty && !newIDs.isEmpty) else {
            // Same messages, e.g. the user scrolled: only the visible set (and so the priority) changes.
            if newVisible != self.visibleIDs {
                self.visibleIDs = newVisible
                scheduleTranslation()
            }
            return
        }
        let isIncremental = hadRows && !diff.isReset
        // "Appended" = only rows below the last row that was already loaded. A row replaced in the middle
        // (edited / deleted message) is just an updated row: no pill, no auto-scroll, no latency sample.
        let appendedIDs = isIncremental ? Self.tailAfterLastCommon(old: lastIDs, new: newIDs) : []
        // The sidebar only shows visible rows: its pill / auto-scroll only count those.
        let visibleAppended = appendedIDs.filter { newVisible.contains($0) }

        lastIDs = newIDs
        messages = snapshot.messages
        let present = Set(newIDs)
        for message in messages where prepared[message.id] == nil {
            prepared[message.id] = preprocessor.process(message)
        }
        prepared = prepared.filter { present.contains($0.key) }
        seenAt = seenAt.filter { present.contains($0.key) }
        toggledOriginals = toggledOriginals.filter { present.contains($0) }
        outstanding = outstanding.filter { present.contains($0) }

        var previous: [MessageID: RowTranslation] = [:]
        for row in rows { previous[row.id] = row.translation }
        let newRows = messages.compactMap { m in prepared[m.id].map { makeRow($0, translation: previous[m.id]) } }

        if isIncremental {
            for id in appendedIDs where prepared[id]?.kind.needsTranslation == true && seenAt[id] == nil {
                seenAt[id] = seenInstant
            }
        }
        if isIncremental && animate && !visibleAppended.isEmpty {
            withAnimation(.easeOut(duration: 0.25)) {
                setRows(newRows)
                self.visibleIDs = newVisible
            }
        } else {
            setRows(newRows)
            self.visibleIDs = newVisible
        }
        if isIncremental {
            if !visibleAppended.isEmpty {
                lastAppendedCount = visibleAppended.count
                appendedTick &+= 1
            }
        } else {
            resetTick &+= 1
        }
        diagnostics.recordIngest(stopwatch.elapsedMilliseconds)
        logger.debug("ingest rows=\(newRows.count) visible=\(newVisible.count) appended=\(appendedIDs.count) prepended=\(diff.prepended.count) reset=\(diff.isReset)")

        scheduleTranslation()
    }

    /// Ids of `new` below the last id that also exists in `old` (empty when there is no overlap).
    static func tailAfterLastCommon(old: [MessageID], new: [MessageID]) -> [MessageID] {
        let oldSet = Set(old)
        guard let last = new.lastIndex(where: { oldSet.contains($0) }) else { return [] }
        return Array(new[(last + 1)...])
    }

    /// Messages whose frame intersects `viewport` (a message without a frame counts as visible); every
    /// message when there is no viewport.
    static func visible(_ messages: [ChatMessage], viewport: CGRect?) -> Set<MessageID> {
        guard let viewport else { return Set(messages.map(\.id)) }
        return Set(messages.filter { m in m.frame.map { $0.cgRect.intersects(viewport) } ?? true }.map(\.id))
    }

    // MARK: - Settings changes

    /// Target language changed: retarget the service, re-preprocess and re-translate the loaded set.
    func retarget(_ languageID: String) {
        let previous = translateTask
        previous?.cancel()
        outstanding = []
        let service = self.service
        translateTask = Task { [weak self] in
            await previous?.value
            await service.setTarget(Locale.Language(identifier: languageID))
            let status = await service.status()
            guard let self else { return }
            self.engineStatus = status
            self.rebuildPreprocessor()
        }
    }

    /// Glossary contents or the glossary switch changed.
    func updateGlossary(_ glossary: Glossary) {
        self.glossary = glossary
        rebuildPreprocessor()
    }

    private func rebuildPreprocessor() {
        preprocessor = ChatPreprocessor(glossary: glossary, targetLanguage: settings.targetLanguage,
                                        glossaryEnabled: settings.glossaryEnabled)
        prepared = [:]
        seenAt = [:]
        for message in messages { prepared[message.id] = preprocessor.process(message) }
        setRows(messages.compactMap { m in prepared[m.id].map { makeRow($0, translation: nil) } })
        resetTick &+= 1
        scheduleTranslation(force: true)
    }

    // MARK: - Rows

    private func makeRow(_ p: PreprocessedMessage, translation: RowTranslation?) -> SidebarRow {
        let state: RowTranslation
        if p.kind.needsTranslation {
            state = translation.flatMap { $0 == .notNeeded ? nil : $0 } ?? .pending
        } else {
            state = .notNeeded
        }
        let m = p.message
        return SidebarRow(id: m.id, author: m.author, timeRaw: m.timeRaw, original: m.body, isMine: m.isMine,
                          isSystem: m.isSystem || p.kind == .system, kind: p.kind, chips: p.chips, note: p.note,
                          attachments: m.attachments, translation: state)
    }

    private func setRows(_ newRows: [SidebarRow]) {
        rows = newRows
        var index: [MessageID: Int] = [:]
        for (i, row) in newRows.enumerated() { index[row.id] = i }
        rowIndex = index
    }

    private func resetChat(_ newKey: String?) {
        cancelTranslations()
        chatKey = newKey
        lastIDs = []
        messages = []
        prepared = [:]
        seenAt = [:]
        toggledOriginals = []
        visibleIDs = []
        setRows([])
        if newKey == nil { chatTitle = nil }
        resetTick &+= 1
    }

    // MARK: - Translation

    private func cancelTranslations() {
        outstanding = []
        let previous = translateTask
        previous?.cancel()
        let service = self.service
        translateTask = Task {
            await previous?.value
            await service.cancelAll()
        }
    }

    /// Submits every loaded message that still needs a translation, in priority order (visible newest-first,
    /// then the rest by distance from the viewport, nearest first), at most `translationCap` per chat.
    /// Messages already translated (or failed) are never submitted again. When the outstanding submission
    /// already covers exactly the same messages in the same order nothing is re-submitted, so work in flight
    /// is not restarted; on a re-prioritisation the service keeps texts already in flight running (their
    /// results reach the new submission through its cache / in-flight set).
    private func scheduleTranslation(force: Bool = false) {
        guard !paused else { return }
        let order = TranslationPriority.order(messages.map(\.id), visible: visibleIDs, cap: Self.translationCap) { id in
            guard let idx = self.rowIndex[id], idx < self.rows.count else { return false }
            return self.rows[idx].translation == .pending && self.prepared[id] != nil
        }
        if !force, order == outstanding, translateTask != nil { return }
        let batch = order.compactMap { prepared[$0] }
        outstanding = order
        let previous = translateTask
        previous?.cancel()
        let service = self.service
        translateTask = Task { [weak self] in
            // Serialize with the previous task so an older submit can never cancel a newer one.
            await previous?.value
            guard !Task.isCancelled else { return }
            if batch.isEmpty {
                await service.cancelAll()
                return
            }
            var hits: [(MessageID, String)] = []
            var misses: [PreprocessedMessage] = []
            for p in batch {
                if let cached = await service.cachedTranslation(for: p) {
                    hits.append((p.message.id, cached))
                } else {
                    misses.append(p)
                }
            }
            guard !Task.isCancelled else { return }
            self?.applyCached(hits)
            guard !misses.isEmpty else { return }
            let stream = await service.submit(misses)
            for await outcome in stream {
                guard !Task.isCancelled else { break }
                self?.apply(outcome)
            }
            // The stream ended without being superseded: anything still outstanding got no outcome and must
            // be submittable again.
            if !Task.isCancelled { self?.outstanding = [] }
        }
    }

    private func applyCached(_ hits: [(MessageID, String)]) {
        guard !hits.isEmpty else { return }
        var updated = rows
        var finished = Set<MessageID>()
        for (id, value) in hits {
            guard let idx = rowIndex[id] else { continue }
            updated[idx].translation = .done(value)
            finished.insert(id)
            recordLatency(id)
        }
        rows = updated
        outstanding.removeAll { finished.contains($0) }
    }

    private func apply(_ outcome: TranslationOutcome) {
        if outcome.error == .cancelled {
            outstanding = [] // the submission was cut short; allow a re-submit
        } else if let i = outstanding.firstIndex(of: outcome.id) {
            outstanding.remove(at: i)
        }
        guard let idx = rowIndex[outcome.id], idx < rows.count, rows[idx].id == outcome.id else { return }
        if let value = outcome.text {
            rows[idx].translation = .done(value)
            recordLatency(outcome.id)
        } else if let error = outcome.error {
            if error == .cancelled { return }
            rows[idx].translation = .failed(Self.describe(error))
            seenAt[outcome.id] = nil
            if error == .notInstalled { engineStatus = .needsDownload }
            logger.info("mt error code=\(Self.errorCode(error))")
        }
    }

    /// Latency samples exist only for appended messages (see `ingest`): prefetched history is not "new".
    private func recordLatency(_ id: MessageID) {
        if let seen = seenAt.removeValue(forKey: id) {
            let d = ContinuousClock.now - seen
            diagnostics.recordTranslation(Double(d.components.seconds) * 1000
                                          + Double(d.components.attoseconds) / 1e15)
        }
    }

    static func describe(_ error: TranslationEngineError) -> String {
        if error == .notInstalled { return "翻译语言未安装" }
        if case .unsupported = error { return "当前系统不支持此语言对" }
        return "翻译失败"
    }

    /// Numeric code for logs (engine error strings are never logged).
    static func errorCode(_ error: TranslationEngineError) -> Int {
        if error == .notInstalled { return 1 }
        if case .unsupported = error { return 2 }
        if error == .cancelled { return 3 }
        return 4
    }

    /// Waits until the current translation task (if any) has finished. Used by --self-check.
    func waitForTranslations() async {
        while let task = translateTask {
            await task.value
            if translateTask == task { break }
        }
    }
}

/// The parts of KakaoAX.ChatWindowRead the view model needs (keeps the model testable without KakaoAX).
protocol ChatWindowReadLike {
    var title: String { get }
    /// Every loaded message, top to bottom.
    var snapshot: TranscriptSnapshot { get }
    /// Transcript viewport (AX coordinates), when known.
    var transcriptFrame: CGRect? { get }
    /// Messages of `snapshot` on screen.
    var visibleIDs: Set<MessageID> { get }
}
