// Derived from kmsg (https://github.com/channprj/kmsg) @54cbff7 — MIT License, Copyright (c) 2026 Park Hee Chan. Modifications: row analysis of TranscriptReader.swift rewritten generic over AXNodeLike and deterministic (no Date(), explicit reference year); rows collected by one budgeted BFS and filtered to the visible transcript area; avatars may be AXImage or AXButton; author taken from the static text above the body; time/date resolved forward within a same-sender group before kmsg's per-side carry-over; system rows (centered notices, date dividers) kept with isSystem; image/file-only rows kept; truncated URLs replaced in place by the AXLink title; removed AXActionRunner logging, the text-area fallback scan and the message limit/dedup logic.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import TalkLensCore

public struct TranscriptParser: Sendable {
    /// Year used when a date divider omits it (defaults to the current year).
    public var referenceYear: Int
    /// Upper bound on rows analysed (most recent rows win).
    public var maxRows: Int
    /// Only rows whose frame intersects the transcript container's frame (what is on screen).
    /// KakaoTalk keeps off-screen rows in the AX tree; set false to analyse every row (bench worst case).
    public var visibleOnly: Bool

    public init(referenceYear: Int = Calendar(identifier: .gregorian).component(.year, from: Date()),
                maxRows: Int = 400, visibleOnly: Bool = true) {
        self.referenceYear = referenceYear
        self.maxRows = maxRows
        self.visibleOnly = visibleOnly
    }

    /// Node budget for collecting rows below the transcript root.
    public static let maxRowScanNodes = 8_000
    /// Node budget per row subtree.
    public static let maxNodesPerRow = 160

    /// Messages top-to-bottom. System rows (date dividers etc.) are included with isSystem = true.
    public func parse<Node: AXNodeLike>(transcriptRoot: Node, inputFrame: CGRect?) -> [ParsedMessage] {
        let transcriptFrame = transcriptRoot.frame
        let rows = collectRows(transcriptRoot: transcriptRoot, transcriptFrame: transcriptFrame, inputFrame: inputFrame)
        let analyses = rows.compactMap { analyzeRow($0.node, rowFrame: $0.frame, transcriptFrame: transcriptFrame) }
        return assemble(analyses)
    }

    /// Convenience: locate + parse a whole chat window subtree.
    public func parse<Node: AXNodeLike>(window: Node) -> [ParsedMessage]? {
        guard let loc = TranscriptLocator.locate(inWindow: window) else { return nil }
        return parse(transcriptRoot: loc.transcriptRoot, inputFrame: loc.inputFrame)
    }

    // MARK: - Rows

    /// Number of rows this parser would analyse (after the input / visibility filters and `maxRows`).
    public func collectRowCount<Node: AXNodeLike>(transcriptRoot: Node, inputFrame: CGRect?) -> Int {
        collectRows(transcriptRoot: transcriptRoot, transcriptFrame: transcriptRoot.frame, inputFrame: inputFrame).count
    }

    /// AXRow descendants of the root (rows are not descended into), above the input, sorted by y then x.
    func collectRows<Node: AXNodeLike>(transcriptRoot: Node, transcriptFrame: CGRect?,
                                       inputFrame: CGRect?) -> [(node: Node, frame: CGRect?)] {
        var rows: [(node: Node, frame: CGRect?, order: Int)] = []
        var queue = [transcriptRoot]
        var index = 0
        var visited = 0
        while index < queue.count, visited < TranscriptParser.maxRowScanNodes {
            let node = queue[index]
            index += 1
            visited += 1
            if index > 1, node.role == AXRole.row {
                rows.append((node, node.frame, rows.count))
                continue
            }
            // Table columns reference the same cells as the rows; scanning them would only duplicate work.
            if node.role == AXRole.column { continue }
            queue.append(contentsOf: node.children)
        }
        var filtered = rows
        if let inputFrame {
            filtered = filtered.filter { r in r.frame.map { $0.maxY <= inputFrame.minY + 20 } ?? true }
        }
        if visibleOnly, let tf = transcriptFrame {
            filtered = filtered.filter { r in
                guard let f = r.frame else { return true }
                return f.intersection(tf).height >= min(4, f.height)
            }
        }
        filtered.sort { a, b in
            let ay = a.frame?.minY ?? .greatestFiniteMagnitude, by = b.frame?.minY ?? .greatestFiniteMagnitude
            if ay != by { return ay < by }
            let ax = a.frame?.minX ?? .greatestFiniteMagnitude, bx = b.frame?.minX ?? .greatestFiniteMagnitude
            if ax != bx { return ax < bx }
            return a.order < b.order
        }
        return filtered.suffix(maxRows).map { ($0.node, $0.frame) }
    }

    // MARK: - Row analysis

    enum Side: String { case left, right, unknown }

    struct RowAnalysis {
        var rowFrame: CGRect?
        var body: String
        var bodyFrame: CGRect?
        var contentFrame: CGRect?
        var explicitAuthor: String?
        var timeRaw: String?
        var helpDate: String?
        var images = 0
        var links = 0
        var files = 0
        var side: Side = .unknown
        var isSystem = false
        var dividerDate: String?
    }

    private struct TextItem {
        let text: String
        let frame: CGRect?
    }

    /// nil = nothing displayable in this row (spacer, empty row).
    func analyzeRow<Node: AXNodeLike>(_ row: Node, rowFrame: CGRect?, transcriptFrame: CGRect?) -> RowAnalysis? {
        var textAreas: [Node] = []
        var staticTexts: [Node] = []
        var images: [Node] = []
        var buttons: [Node] = []
        var links: [Node] = []

        // Bounded BFS over the row; text areas and links are leaves for our purposes.
        var queue = row.children
        var index = 0
        while index < queue.count, index < TranscriptParser.maxNodesPerRow {
            let n = queue[index]
            index += 1
            switch n.role ?? "" {
            case AXRole.textArea: textAreas.append(n); continue
            case AXRole.staticText: staticTexts.append(n); continue
            case AXRole.image: images.append(n)
            case AXRole.button: buttons.append(n)
            case AXRole.link: links.append(n); continue
            default: break
            }
            queue.append(contentsOf: n.children)
        }

        var a = RowAnalysis(rowFrame: rowFrame, body: "")
        var urlCount = 0

        // Body: longest/best text area value, with truncated-link promotion.
        var bestBody: (text: String, frame: CGRect?, score: Int)?
        for ta in textAreas {
            var text = KakaoText.normalizeBodyText(ta.value ?? ta.title)
            guard !text.isEmpty else { continue }
            urlCount += KakaoText.countURLTokens(in: text)
            if KakaoText.shouldPromoteLinkTitle(for: text), let full = bestLinkTitle(links) {
                text = promoteLink(text, fullLink: full)
            }
            let score = KakaoText.scoreBodyCandidate(text)
            if bestBody == nil || score > bestBody!.score { bestBody = (text, ta.frame, score) }
        }
        if bestBody == nil, let linkOnly = bestLinkTitle(links) {
            bestBody = (linkOnly, links.first?.frame, 0)
        }
        a.links = links.count

        // Bubble backgrounds: KakaoTalk 26.8.0 draws each text bubble as an AXImage enclosing the AXTextArea
        // (observed). They are neither attachments nor avatars, but they give the bubble's true edges.
        let textFrames = (textAreas + links).compactMap(\.frame)
        let imageFrames = images.compactMap(\.frame)
        let bubbleFrames = imageFrames.filter { img in textFrames.contains { isBubble(img, enclosing: $0) } }

        // Avatar vs message images.
        let avatarFrames = (images + buttons).compactMap { n -> CGRect? in
            guard let f = n.frame, !bubbleFrames.contains(f),
                  isAvatarFrame(f, bodyFrame: bestBody?.frame, transcriptFrame: transcriptFrame) else { return nil }
            return f
        }
        let messageImageFrames = imageFrames.filter { f in
            f.width >= 48 && f.height >= 48 && f.width * f.height >= 2_304
                && !avatarFrames.contains(f) && !bubbleFrames.contains(f)
                && (rowFrame.map { $0.intersects(f) } ?? true)
        }
        a.images = messageImageFrames.count

        // Static texts: time, AXHelp date, author candidates, attachment metadata, dividers/notices.
        var authorCandidates: [TextItem] = []
        var plainTexts: [TextItem] = [] // non-time, non-count texts (system-row candidates)
        var fileNameItems: [TextItem] = []
        var hasAttachmentMetadata = false
        for st in staticTexts {
            if a.helpDate == nil, let help = st.help, let d = KakaoText.parseHelpDate(help, referenceYear: referenceYear) { a.helpDate = d }
            let full = KakaoText.normalizeBodyText(st.value ?? st.title)
            guard !full.isEmpty else { continue }
            urlCount += KakaoText.countURLTokens(in: full)
            var nonMeta = false
            for token in KakaoText.metadataTokens(from: full) {
                // Time labels are short ("오후 3:12"); longer texts that merely contain a time are not labels.
                if token.count <= 16, let t = KakaoText.extractTimeToken(from: token) {
                    if a.timeRaw == nil { a.timeRaw = t }
                    continue
                }
                if KakaoText.isCountToken(token) { continue }
                if KakaoText.isFileNameToken(token) {
                    fileNameItems.append(TextItem(text: token, frame: st.frame))
                    hasAttachmentMetadata = true
                    continue
                }
                if KakaoText.isAttachmentMetadataToken(token) { hasAttachmentMetadata = true; continue }
                if KakaoText.isSystemMetadataToken(token) { nonMeta = true; continue }
                authorCandidates.append(TextItem(text: token, frame: st.frame))
                nonMeta = true
            }
            if nonMeta { plainTexts.append(TextItem(text: full, frame: st.frame)) }
        }
        var hasSaveButton = false
        for b in buttons {
            let title = KakaoText.normalizeBodyText(b.title)
            guard !title.isEmpty else { continue }
            urlCount += KakaoText.countURLTokens(in: title)
            if KakaoText.isAttachmentButtonTitle(title) { hasSaveButton = true }
        }
        // Wide text-bearing buttons (e.g. a date divider drawn as a button) are system-row candidates.
        // The observed 26.8.0 divider button exposes no text at all; such rows are skipped below.
        for b in buttons {
            guard let f = b.frame, f.width >= 100 else { continue }
            let text = KakaoText.normalizeBodyText(nonEmpty(b.title) ?? nonEmpty(b.value) ?? b.nodeDescription)
            guard !text.isEmpty, !KakaoText.isAttachmentButtonTitle(text) else { continue }
            plainTexts.append(TextItem(text: text, frame: f))
        }
        a.files = fileNameItems.count
        if a.files == 0, hasAttachmentMetadata || hasSaveButton, bestBody == nil || hasSaveButton {
            a.files = 1
        }
        a.links = max(a.links, urlCount)

        // System rows. (1) centered static-text-only rows: notices and date dividers.
        if bestBody == nil, a.images == 0, a.files == 0, avatarFrames.isEmpty, !plainTexts.isEmpty,
           plainTexts.allSatisfy({ isCentered($0.frame, in: transcriptFrame, tolerance: 0.12) }) {
            let text = plainTexts.map(\.text).joined(separator: "\n")
            a.isSystem = true
            a.body = text
            a.dividerDate = KakaoText.parseDividerDate(text, referenceYear: referenceYear)
            a.contentFrame = plainTexts.first?.frame
            return a
        }
        // (2) a centered text area whose whole text is a date, without avatar/author/time.
        if let b = bestBody, avatarFrames.isEmpty, authorCandidates.isEmpty, a.timeRaw == nil,
           isCentered(b.frame, in: transcriptFrame, tolerance: 0.1),
           let d = KakaoText.parseDividerDate(b.text, referenceYear: referenceYear) {
            a.isSystem = true
            a.body = b.text
            a.dividerDate = d
            a.links = 0
            a.contentFrame = b.frame
            return a
        }

        guard bestBody != nil || a.images > 0 || a.files > 0 else { return nil }
        a.body = bestBody?.text ?? ""
        a.bodyFrame = bestBody?.frame
        a.contentFrame = bestBody?.frame ?? messageImageFrames.first ?? fileNameItems.first?.frame
        // Bubble edges (background image) are more reliable than the inset text area for side detection.
        let bubble = bestBody?.frame.flatMap { body in bubbleFrames.first { isBubble($0, enclosing: body) } }

        // Author: the topmost non-metadata static text above the content.
        if let content = a.contentFrame {
            a.explicitAuthor = authorCandidates
                .filter { item in item.frame.map { $0.maxY <= content.minY + 4 } ?? false }
                .min { ($0.frame?.minY ?? 0) < ($1.frame?.minY ?? 0) }?.text
        } else {
            a.explicitAuthor = authorCandidates.first?.text
        }

        a.side = inferSide(avatarFound: !avatarFrames.isEmpty, reference: bubble ?? a.contentFrame ?? rowFrame,
                           transcriptFrame: transcriptFrame)
        return a
    }

    /// Small square image/button at the far left of the transcript (or left of the body).
    func isAvatarFrame(_ f: CGRect, bodyFrame: CGRect?, transcriptFrame: CGRect?) -> Bool {
        guard f.width >= 24, f.width <= 72, f.height >= 24, f.height <= 72, abs(f.width - f.height) <= 8 else { return false }
        if let b = bodyFrame, f.maxX + 4 <= b.minX, f.midX + 10 < b.minX {
            if let t = transcriptFrame { return f.minX - t.minX < t.width * 0.25 }
            return true
        }
        if let t = transcriptFrame { return f.minX - t.minX < t.width * 0.15 }
        return false
    }

    func isCentered(_ f: CGRect?, in transcript: CGRect?, tolerance: Double) -> Bool {
        guard let f, let t = transcript, t.width > 0 else { return false }
        return abs(Double(f.midX - t.midX)) / Double(t.width) <= tolerance
    }

    /// Side of a message: avatar → left; else edge alignment (mine bubbles end ~10 pt from the transcript's
    /// right edge, others' start right after the avatar column); else kmsg's midX ratio.
    func inferSide(avatarFound: Bool, reference: CGRect?, transcriptFrame: CGRect?) -> Side {
        if avatarFound { return .left }
        guard let r = reference, let t = transcriptFrame else { return .unknown }
        let leftGap = r.minX - t.minX
        let rightGap = t.maxX - r.maxX
        if rightGap <= 30, leftGap > 60 { return .right }
        if leftGap <= 60, rightGap > 30 { return .left }
        let ratio = (r.midX - t.minX) / max(t.width, 1)
        if ratio <= 0.56 { return .left }
        if ratio >= 0.62 { return .right }
        return .unknown
    }

    /// An image that encloses a text frame (allowing a few points of slack) is that text's bubble background.
    func isBubble(_ image: CGRect, enclosing text: CGRect) -> Bool {
        guard text.width > 0, text.height > 0 else { return false }
        if image.insetBy(dx: -2, dy: -2).contains(text) { return true }
        let i = image.intersection(text)
        return !i.isNull && i.width * i.height >= 0.8 * text.width * text.height
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private func bestLinkTitle<Node: AXNodeLike>(_ links: [Node]) -> String? {
        links.map { KakaoText.normalizeBodyText($0.title ?? $0.value) }
            .filter { !$0.isEmpty }
            .max { $0.count < $1.count }
    }

    /// Replaces a truncated URL token ("https://a.b/c...") with the full link when it is a prefix of it;
    /// otherwise appends the full link on a new line (kmsg behaviour).
    func promoteLink(_ text: String, fullLink: String) -> String {
        if KakaoText.isURLOnlyText(text) { return fullLink }
        if text.contains(fullLink) { return text }
        for token in KakaoText.urlTokens(in: text) {
            var stem = token
            for suffix in ["...", "…"] where stem.hasSuffix(suffix) { stem.removeLast(suffix.count) }
            if stem != token, fullLink.hasPrefix(stem) {
                return text.replacingOccurrences(of: token, with: fullLink)
            }
        }
        return "\(text)\n\(fullLink)"
    }

    // MARK: - Assembly

    func assemble(_ rows: [RowAnalysis]) -> [ParsedMessage] {
        let n = rows.count
        // Same-sender groups: KakaoTalk shows the time label (and its AXHelp date) only on the last message
        // of a same-minute group, so earlier rows take the time of the next labelled row in their group.
        var groupTime = [String?](repeating: nil, count: n)
        var groupDate = [String?](repeating: nil, count: n)
        var nextTime: String?
        var nextDate: String?
        for i in stride(from: n - 1, through: 0, by: -1) {
            let r = rows[i]
            if r.isSystem {
                nextTime = nil; nextDate = nil
                continue
            }
            if i + 1 < n {
                let next = rows[i + 1]
                let boundary = next.isSystem || next.side != r.side || (next.side == .left && next.explicitAuthor != nil)
                if boundary { nextTime = nil; nextDate = nil }
            } else {
                nextTime = nil; nextDate = nil
            }
            if r.timeRaw == nil {
                groupTime[i] = nextTime
                groupDate[i] = r.helpDate == nil ? nextDate : nil
            } else {
                nextTime = r.timeRaw
                nextDate = r.helpDate
            }
        }

        var out: [ParsedMessage] = []
        out.reserveCapacity(n)
        var leftAnchorAuthor: String?
        var leftAnchorTime: String?
        var lastTimeBySide: [Side: String] = [:]
        var lastKnownTime: String?
        var lastKnownDate: String?

        for (i, r) in rows.enumerated() {
            if r.isSystem {
                leftAnchorAuthor = nil
                leftAnchorTime = nil
                if let d = r.dividerDate ?? r.helpDate { lastKnownDate = d }
                out.append(ParsedMessage(author: nil, isMine: false, isSystem: true, timeRaw: r.timeRaw,
                                         date: r.dividerDate ?? r.helpDate ?? lastKnownDate, body: r.body,
                                         attachments: .none, frame: (r.contentFrame ?? r.rowFrame).map(AXRect.init)))
                continue
            }

            if r.side != .left {
                leftAnchorAuthor = nil
                leftAnchorTime = nil
            } else if let explicit = r.explicitAuthor {
                leftAnchorAuthor = explicit
                leftAnchorTime = r.timeRaw
            }

            let author: String?
            switch r.side {
            case .right:
                author = nil
            case .left:
                if let explicit = r.explicitAuthor {
                    author = explicit
                } else if let anchor = leftAnchorAuthor, isForwardTimeProgress(anchor: leftAnchorTime, candidate: r.timeRaw) {
                    author = anchor
                } else {
                    author = nil
                }
            case .unknown:
                author = r.explicitAuthor
            }

            let time: String?
            if let explicit = r.timeRaw {
                time = explicit
                lastKnownTime = explicit
                if r.side != .unknown { lastTimeBySide[r.side] = explicit }
            } else if let g = groupTime[i] {
                time = g
            } else if r.side != .unknown, let sideTime = lastTimeBySide[r.side] {
                time = sideTime
            } else {
                time = lastKnownTime
            }

            if let d = r.helpDate { lastKnownDate = d }
            let date = r.helpDate ?? groupDate[i] ?? lastKnownDate

            out.append(ParsedMessage(author: author, isMine: r.side == .right, isSystem: false, timeRaw: time,
                                     date: date, body: r.body,
                                     attachments: AttachmentSummary(images: r.images, links: r.links, files: r.files),
                                     frame: (r.bodyFrame ?? r.contentFrame ?? r.rowFrame).map(AXRect.init)))
        }
        return out
    }

    private func isForwardTimeProgress(anchor: String?, candidate: String?) -> Bool {
        guard let a = KakaoText.minuteOfDay(anchor), let c = KakaoText.minuteOfDay(candidate) else { return true }
        return c >= a
    }
}
