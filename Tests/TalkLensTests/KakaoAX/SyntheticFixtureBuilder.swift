// SPDX-License-Identifier: MIT
// Builds the synthetic chat-window fixtures in fixtures/snapshots (meta.source = "synthetic").
//
// STRUCTURE. Mirrors a redacted recording of a real KakaoTalk 26.8.0 chat window (roles and frames only):
//   AXWindow(AXStandardWindow, [566,197,380,640])
//     header: AXButton 40×40 (profile), AXStaticText (title), 3 × AXButton 32×32, AXSlider → AXValueIndicator
//     AXScrollArea(_NS:29, [566,285,380,432]) → AXTable(_NS:33) → AXRow(AXTableRow) → AXCell → content; + AXColumn
//     AXScrollArea(_NS:47, [576,728,370,65]) → AXTextArea(_NS:51, placeholder description, no value) = input
//     3 × AXButton 26×26 (help only), send AXButton(title, disabled), AXImage 6×6, close/minimize/full-screen
//   Message row (mine, observed): AXCell → [AXImage bubble background, AXTextArea body inset (5, 8)];
//   the last row of a same-minute group also has AXStaticText time (help = date) left of the bubble.
//   Date divider (observed): centered AXButton 200×28 with no text. Last row: empty 15 pt spacer.
// ASSUMPTIONS (not observed yet; verify in M0): others' rows (AXButton 40×40 avatar or AXImage 36×36 at the far
//   left, AXStaticText author above the bubble, time right of the bubble); text-bearing divider buttons;
//   notices as centered AXStaticText; photo / sticker / file / link-preview layouts; time label "오후 3:12"
//   and AXHelp "2026. 10. 10.".
// All names and texts are invented or taken from fixtures/test_messages_ko.txt.

import CoreGraphics
import Foundation
@testable import KakaoAX

struct SyntheticChat {
    enum Content {
        case text(String)
        case image(CGSize)
        case link(text: String, full: String)
        case file(name: String, info: String)
    }

    enum AvatarStyle { case button, image }
    enum DividerStyle { case emptyButton, titledButton, staticText }

    struct Options {
        var avatarStyle: AvatarStyle = .button
        /// Body text area wrapped in an AXScrollArea (as in the chat list).
        var nestedBody = false
        /// Search text field in the header (the locator must ignore it).
        var searchField = false
        /// Row index that ends at the bottom of the visible transcript; later rows are below it (scrolled up).
        var bottomAnchorRow: Int?
        /// Window height in points (the transcript gets height − 208).
        var windowHeight: Double = 640
        /// Empty 15 pt spacer row at the end of the table (observed).
        var spacerRow = true
    }

    private enum Sender: Equatable { case none, me, other(String?) }

    let title: String
    var options = Options()
    private var rows: [(height: Double, make: (Double) -> RecordedAXNode)] = []
    private var lastSender: Sender = .none

    static let tableX: Double = 566
    static let tableWidth: Double = 380
    static let mineRightEdge: Double = 936 // transcript maxX − 10 (observed)
    static let otherBubbleX: Double = 622 // after a 40 pt avatar column (assumption)

    init(title: String, options: Options = Options()) {
        self.title = title
        self.options = options
    }

    var window: CGRect { CGRect(x: 566, y: 197, width: 380, height: options.windowHeight) }
    var transcript: CGRect { CGRect(x: 566, y: 285, width: 380, height: options.windowHeight - 208) }

    // MARK: - Text metrics (rough, deterministic)

    static func lineWidth(_ s: Substring) -> Double {
        s.unicodeScalars.reduce(0) { $0 + ($1.isASCII ? 7 : 12.5) }
    }

    /// Size of the text area (16 pt per line, wrapped at 279 pt).
    static func textSize(_ text: String) -> CGSize {
        var lines = 0
        var maxW = 0.0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let w = lineWidth(line)
            lines += max(1, Int((w / 279).rounded(.up)))
            maxW = max(maxW, min(279, w))
        }
        return CGSize(width: max(12, maxW.rounded()), height: Double(lines * 16))
    }

    /// Bubble background around a text area (observed insets: 5 left, 8 right, 8 top, 7 bottom).
    static func bubbleSize(_ text: String) -> CGSize {
        let t = textSize(text)
        return CGSize(width: t.width + 13, height: t.height + 15)
    }

    static func contentSize(_ c: Content) -> CGSize {
        switch c {
        case .text(let t): return bubbleSize(t)
        case .image(let s): return s
        case .link(let text, _):
            let b = bubbleSize(text)
            return CGSize(width: max(b.width, 220), height: b.height + 4 + 56)
        case .file: return CGSize(width: 220, height: 64)
        }
    }

    // MARK: - Element factories

    static func text(_ role: String, _ value: String, _ r: CGRect, help: String? = nil, id: String? = nil) -> RecordedAXNode {
        RecordedAXNode(role: role, identifier: id, value: value, help: help, frame: r)
    }

    func bubbleNodes(_ text: String, origin: CGPoint) -> [RecordedAXNode] {
        let b = Self.bubbleSize(text), t = Self.textSize(text)
        let x = Double(origin.x), y = Double(origin.y)
        let bubble = RecordedAXNode(role: AXRole.image, frame: CGRect(x: x, y: y, width: b.width, height: b.height))
        let r = CGRect(x: x + 5, y: y + 8, width: t.width, height: t.height)
        let area = Self.text(AXRole.textArea, text, r)
        return [bubble, options.nestedBody ? RecordedAXNode(role: AXRole.scrollArea, frame: r, children: [area]) : area]
    }

    /// `origin` is the top-left of the content block.
    func contentNodes(_ c: Content, origin: CGPoint) -> [RecordedAXNode] {
        let x = Double(origin.x), y = Double(origin.y)
        switch c {
        case .text(let t):
            return bubbleNodes(t, origin: origin)
        case .image(let s):
            return [RecordedAXNode(role: AXRole.image, nodeDescription: "이미지", frame: CGRect(x: x, y: y, width: s.width, height: s.height))]
        case .link(let text, let full):
            var nodes = bubbleNodes(text, origin: origin)
            let b = Self.bubbleSize(text)
            nodes.append(RecordedAXNode(role: AXRole.link, title: full, frame: CGRect(x: x + 5, y: y + 8, width: b.width - 13, height: b.height - 15)))
            let py = y + b.height + 4
            nodes.append(RecordedAXNode(role: AXRole.group, frame: CGRect(x: x, y: py, width: 220, height: 56), children: [
                Self.text(AXRole.staticText, "학과 공지사항", CGRect(x: x + 8, y: py + 6, width: 180, height: 16)),
                Self.text(AXRole.staticText, "example.com", CGRect(x: x + 8, y: py + 30, width: 120, height: 14)),
            ]))
            return nodes
        case .file(let name, let info):
            return [RecordedAXNode(role: AXRole.group, frame: CGRect(x: x, y: y, width: 220, height: 64), children: [
                Self.text(AXRole.staticText, name, CGRect(x: x + 12, y: y + 10, width: 180, height: 16)),
                Self.text(AXRole.staticText, info, CGRect(x: x + 12, y: y + 30, width: 150, height: 14)),
                RecordedAXNode(role: AXRole.button, title: "저장", frame: CGRect(x: x + 164, y: y + 36, width: 48, height: 20)),
            ])]
        }
    }

    static func row(top: Double, height: Double, _ children: [RecordedAXNode]) -> RecordedAXNode {
        let r = CGRect(x: tableX, y: top, width: tableWidth, height: height)
        return RecordedAXNode(role: AXRole.row, subrole: "AXTableRow", frame: r,
                              children: [RecordedAXNode(role: AXRole.cell, frame: r, children: children)])
    }

    // MARK: - Rows

    /// A message from someone else. `author != nil` → first of a group (avatar + name shown).
    mutating func other(_ author: String?, _ content: Content, time: String? = nil, help: String? = nil) {
        let size = Self.contentSize(content)
        let continuing: Bool
        if case .other = lastSender { continuing = author == nil } else { continuing = false }
        let pad: Double = continuing ? 5 : 10
        lastSender = .other(author)
        let header: Double = author == nil ? 0 : 20
        let height = pad + header + Double(size.height)
        let opts = options
        let me = self
        rows.append((height, { top in
            var kids: [RecordedAXNode] = []
            if let author {
                switch opts.avatarStyle {
                case .button:
                    kids.append(RecordedAXNode(role: AXRole.button, nodeDescription: author,
                                               frame: CGRect(x: 576, y: top + pad, width: 40, height: 40)))
                case .image:
                    kids.append(RecordedAXNode(role: AXRole.image, frame: CGRect(x: 578, y: top + pad, width: 36, height: 36)))
                }
                kids.append(Self.text(AXRole.staticText, author,
                                      CGRect(x: 626, y: top + pad, width: Self.lineWidth(Substring(author)).rounded(), height: 16)))
            }
            let cy = top + pad + header
            kids += me.contentNodes(content, origin: CGPoint(x: Self.otherBubbleX, y: cy))
            if let time {
                kids.append(Self.text(AXRole.staticText, time,
                                      CGRect(x: Self.otherBubbleX + Double(size.width) + 4, y: cy + Double(size.height) - 15, width: 43, height: 16),
                                      help: help))
            }
            return Self.row(top: top, height: height, kids)
        }))
    }

    /// A message of mine (right side, no avatar or name; time label left of the bubble).
    mutating func mine(_ content: Content, time: String? = nil, help: String? = nil, unread: Int? = nil) {
        let size = Self.contentSize(content)
        let pad: Double = lastSender == .me ? 5 : 10
        lastSender = .me
        let height = pad + Double(size.height)
        let me = self
        rows.append((height, { top in
            let x = Self.mineRightEdge - Double(size.width)
            var kids: [RecordedAXNode] = []
            let timeY = top + pad + Double(size.height) - 15
            if let time {
                kids.append(Self.text(AXRole.staticText, time, CGRect(x: x - 47, y: timeY, width: 43, height: 16), help: help))
            }
            if let unread {
                kids.append(Self.text(AXRole.staticText, String(unread), CGRect(x: x - 14, y: timeY - 14, width: 10, height: 12), id: "Count Label"))
            }
            kids += me.contentNodes(content, origin: CGPoint(x: x, y: top + pad))
            return Self.row(top: top, height: height, kids)
        }))
    }

    /// Date divider row (observed: a centered 200×28 AXButton with no text).
    mutating func divider(_ text: String?, style: DividerStyle = .titledButton) {
        lastSender = .none
        rows.append((36, { top in
            switch style {
            case .emptyButton, .titledButton:
                let label = style == .emptyButton ? "" : (text ?? "")
                return Self.row(top: top, height: 36, [RecordedAXNode(role: AXRole.button, title: label, nodeDescription: "",
                                                                    frame: CGRect(x: 656, y: top + 9, width: 200, height: 28))])
            case .staticText:
                let t = text ?? ""
                let w = Self.lineWidth(Substring(t)).rounded()
                let x = (Self.tableX + (Self.tableWidth - w) / 2).rounded()
                return Self.row(top: top, height: 36, [Self.text(AXRole.staticText, t, CGRect(x: x, y: top + 10, width: w, height: 16))])
            }
        }))
    }

    /// Centered notice ("박서연님이 들어왔습니다.") as a static text (assumption).
    mutating func notice(_ text: String) {
        divider(text, style: .staticText)
    }

    // MARK: - Window

    func build(note: String) -> AXSnapshotFile {
        let w = window, t = transcript
        var allRows = rows
        if options.spacerRow {
            allRows.append((15, { top in
                RecordedAXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: Self.tableX, y: top, width: Self.tableWidth, height: 15),
                               children: [RecordedAXNode(role: AXRole.cell, frame: CGRect(x: Self.tableX, y: top, width: Self.tableWidth, height: 15))])
            }))
        }
        let anchor = options.bottomAnchorRow ?? (allRows.count - 1)
        let aboveHeight = allRows.prefix(anchor + 1).reduce(0) { $0 + $1.height }
        var top = Double(t.maxY) - aboveHeight
        let tableTop = top
        var rowNodes: [RecordedAXNode] = []
        for (i, r) in allRows.enumerated() {
            rowNodes.append(r.make(top))
            top += r.height
            if i == anchor { top = max(top, Double(t.maxY) + 30) } // later rows start below the visible area
        }
        let tableHeight = max(Double(t.height), top - tableTop)
        let column = RecordedAXNode(role: AXRole.column, identifier: "AutomaticTableColumnIdentifier.0", frame: t)
        let table = RecordedAXNode(role: AXRole.table, identifier: "_NS:33",
                                   frame: CGRect(x: 565, y: tableTop - 1, width: 382, height: tableHeight + 2),
                                   children: rowNodes + [column])
        let transcriptNode = RecordedAXNode(role: AXRole.scrollArea, identifier: "_NS:29", frame: t, children: [table])

        let bottom = Double(w.maxY)
        var children: [RecordedAXNode] = [
            transcriptNode,
            RecordedAXNode(role: AXRole.button, identifier: "_NS:164", nodeDescription: "프로필 보기", frame: CGRect(x: 580, y: 235, width: 40, height: 40)),
            RecordedAXNode(role: AXRole.staticText, identifier: "_NS:144", value: title, help: title,
                           frame: CGRect(x: 631, y: 244.5, width: Self.lineWidth(Substring(title)).rounded(), height: 21)),
            RecordedAXNode(role: AXRole.button, identifier: "_NS:10", title: "", nodeDescription: "검색", help: "대화 내용 검색",
                           frame: CGRect(x: 849, y: 240, width: 32, height: 32)),
            RecordedAXNode(role: AXRole.button, identifier: "_NS:54", title: "", nodeDescription: "톡서랍", frame: CGRect(x: 879, y: 240, width: 32, height: 32)),
            RecordedAXNode(role: AXRole.button, identifier: "_NS:78", title: "", nodeDescription: "메뉴", frame: CGRect(x: 909, y: 240, width: 32, height: 32)),
            RecordedAXNode(role: "AXSlider", identifier: "_NS:182", value: "1", frame: CGRect(x: 875, y: 202, width: 62, height: 18), children: [
                RecordedAXNode(role: "AXValueIndicator", frame: CGRect(x: 920, y: 203, width: 16, height: 16)),
            ]),
        ]
        if options.searchField {
            children.append(RecordedAXNode(role: AXRole.textField, value: "", nodeDescription: "검색",
                                           frame: CGRect(x: 640, y: 242, width: 200, height: 26)))
        }
        children += [
            RecordedAXNode(role: AXRole.scrollArea, identifier: "_NS:47", frame: CGRect(x: 576, y: t.maxY + 11, width: 370, height: 65), children: [
                RecordedAXNode(role: AXRole.textArea, identifier: "_NS:51", nodeDescription: "메시지 입력",
                               frame: CGRect(x: 576, y: t.maxY + 11, width: 370, height: 65)),
            ]),
            RecordedAXNode(role: AXRole.button, title: "", nodeDescription: "", help: "이모티콘", frame: CGRect(x: 575, y: bottom - 35, width: 26, height: 26)),
            RecordedAXNode(role: AXRole.button, title: "", nodeDescription: "", help: "파일 전송", frame: CGRect(x: 607, y: bottom - 35, width: 26, height: 26)),
            RecordedAXNode(role: AXRole.button, title: "", nodeDescription: "", help: "더보기", frame: CGRect(x: 639, y: bottom - 35, width: 26, height: 26)),
            RecordedAXNode(role: AXRole.button, title: "전송", frame: CGRect(x: 877, y: bottom - 39, width: 62, height: 32), enabled: false),
            RecordedAXNode(role: AXRole.image, nodeDescription: "새 기능 알림", frame: CGRect(x: 627, y: bottom - 33, width: 6, height: 6)),
            RecordedAXNode(role: AXRole.button, subrole: "AXCloseButton", frame: CGRect(x: 574, y: 205, width: 16, height: 16)),
            RecordedAXNode(role: AXRole.button, subrole: "AXFullScreenButton", help: "전체 화면으로 전환", frame: CGRect(x: 620, y: 205, width: 16, height: 16)),
            RecordedAXNode(role: AXRole.button, subrole: "AXMinimizeButton", frame: CGRect(x: 597, y: 205, width: 16, height: 16)),
        ]
        let root = RecordedAXNode(role: AXRole.window, subrole: "AXStandardWindow", identifier: "_NS:443", title: title,
                                  frame: w, children: children)
        return AXSnapshotFile(
            meta: .init(source: "synthetic", kakaoVersion: nil, macOS: nil, recordedAt: "2026-10-10T12:00:00Z",
                        note: "Hand-built (Tests/TalkLensTests/KakaoAX/SyntheticFixtureBuilder.swift); window geometry mirrors a redacted KakaoTalk 26.8.0 chat window, others' rows are assumptions. " + note),
            window: .init(title: title, frame: AXRectArray(w)),
            root: root)
    }
}

// MARK: - Fixture definitions

enum SyntheticFixtures {
    static let names = ["synthetic_group_basic", "synthetic_mine_continuation", "synthetic_dividers_system",
                        "synthetic_attachments_links", "synthetic_multiline_long", "synthetic_nested_offscreen",
                        "synthetic_200rows"]

    static func make(_ name: String) -> AXSnapshotFile {
        switch name {
        case "synthetic_group_basic": return groupBasic()
        case "synthetic_mine_continuation": return mineContinuation()
        case "synthetic_dividers_system": return dividersSystem()
        case "synthetic_attachments_links": return attachmentsLinks()
        case "synthetic_multiline_long": return multilineLong()
        case "synthetic_nested_offscreen": return nestedOffscreen()
        case "synthetic_200rows": return rows200()
        default: fatalError("unknown fixture \(name)")
        }
    }

    static func groupBasic() -> AXSnapshotFile {
        var c = SyntheticChat(title: "합성 테스트방", options: .init(searchField: true, windowHeight: 760))
        c.divider(nil, style: .emptyButton) // as observed: no text exposed
        c.other("김민준", .text("내일 랩미팅은 오후 2시에서 4시로 변경되었습니다."))
        c.other(nil, .text("교수님께서 이번 주 금요일 세미나는 온라인으로 진행한다고 하셨어요."), time: "오후 3:12", help: "2026. 10. 10.")
        c.mine(.text("넵 알겠습니다!"), time: "오후 3:13", help: "2026. 10. 10.")
        c.other("박서연", .text("ㅋㅋㅋㅋ"), time: "오후 3:14", help: "2026. 10. 10.")
        c.other("이도윤", .text("ㅇㅋ ㄱㄱ"), time: "오후 3:14", help: "2026. 10. 10.")
        c.other(nil, .text("수고하셨습니다~"), time: "오후 3:15", help: "2026. 10. 10.")
        c.mine(.text("오늘 점심 학식 vs 배달?"), time: "오후 3:16", help: "2026. 10. 10.", unread: 2)
        return c.build(note: "Group chat basics: author groups, continuation, mine, empty divider button, header search field.")
    }

    static func mineContinuation() -> AXSnapshotFile {
        var c = SyntheticChat(title: "합성 1:1 대화", options: .init(windowHeight: 760))
        c.other("박서연", .text("서버 GPU 2번은 제가 오늘 밤까지 쓸게요"), time: "오전 10:02", help: "2026. 10. 9.")
        c.mine(.text("아 그거 제가 착각했네요 ㅎㅎ 죄송합니다"))
        c.mine(.text("Deadline은 Friday까지예요"))
        c.mine(.text("好的，我知道了"), time: "오전 10:05", help: "2026. 10. 9.", unread: 1)
        c.other("박서연", .text("헐 대박 ㄷㄷ"), time: "오전 10:06", help: "2026. 10. 9.")
        c.other(nil, .text("😂😂"))
        c.other(nil, .text("12345"), time: "오전 10:07", help: "2026. 10. 9.")
        c.other(nil, .text("ㅋㅋㅋㅋ"))
        c.other(nil, .text("ㅋㅋㅋㅋ"), time: "오전 10:09", help: "2026. 10. 9.")
        c.mine(.text("넵 알겠습니다!"), time: "오전 10:10", help: "2026. 10. 9.")
        return c.build(note: "1:1 chat: my consecutive messages, partner continuation rows, duplicate bodies in one minute.")
    }

    static func dividersSystem() -> AXSnapshotFile {
        var c = SyntheticChat(title: "합성 공지방", options: .init(windowHeight: 760))
        c.divider("2026년 10월 9일 목요일")
        c.other("김민준", .text("오늘 3교시 휴강입니다. 보강 일정은 추후 공지하겠습니다."), time: "오후 9:40")
        c.notice("박서연님이 들어왔습니다.")
        c.other("박서연", .text("조교입니다. 질문은 수업 게시판에 올려주시면 답변드리겠습니다."), time: "오후 11:58")
        c.divider("2026년 10월 10일 금요일", style: .staticText)
        c.other("이도윤", .text("출석 체크는 KLMS에서 해주세요."), time: "오전 9:01", help: "10월 10일")
        c.notice("이도윤님이 나갔습니다.")
        c.mine(.text("10/15 (수) 연구실 대청소 있습니다"), time: "오전 9:30", help: "2026. 10. 10.")
        c.divider("10월 11일 토요일")
        c.other("김민준", .text("중간고사 범위는 1장부터 6장까지입니다."), time: "오후 1:00")
        return c.build(note: "Text-bearing date dividers (button and static text; with and without year), join/leave notices, dates without AXHelp, year-less AXHelp.")
    }

    static func attachmentsLinks() -> AXSnapshotFile {
        var c = SyntheticChat(title: "합성 자료방", options: .init(windowHeight: 1000))
        c.other("김민준", .image(CGSize(width: 160, height: 120)))
        c.other(nil, .link(text: "https://example.com/notice/123", full: "https://example.com/notice/123"),
                time: "오후 2:01", help: "2026. 10. 10.")
        c.mine(.text("학회 포스터 초안 공유드립니다. 피드백 부탁드려요 🙏"))
        c.mine(.image(CGSize(width: 160, height: 120)), time: "오후 2:03", help: "2026. 10. 10.")
        c.other("박서연", .file(name: "과제2_보고서.pdf", info: "유효기간 ~ 2026. 10. 24. · 용량 1.2MB"),
                time: "오후 2:05", help: "2026. 10. 10.")
        c.other(nil, .link(text: "자료는 여기 있어요 https://example.com/files/share/2026/fall/...",
                           full: "https://example.com/files/share/2026/fall/lab-seminar-schedule"),
                time: "오후 2:05", help: "2026. 10. 10.")
        c.other("이도윤", .image(CGSize(width: 100, height: 100)), time: "오후 2:06", help: "2026. 10. 10.")
        c.mine(.link(text: "https://example.com/notice/123", full: "https://example.com/notice/123"),
               time: "오후 2:07", help: "2026. 10. 10.")
        return c.build(note: "Image, sticker, file and link messages (with previews and a truncated URL).")
    }

    static let longParagraph: String = {
        let sentences = [
            "이번 학기 연구실 세미나 일정과 발표 순서를 정리해서 공유드립니다.",
            "발표자는 발표 하루 전까지 슬라이드를 공유 폴더에 올려 주세요.",
            "질문은 발표가 끝난 뒤에 한꺼번에 받겠습니다.",
            "장소는 E3-1 1501호이고, 온라인 참석자는 회의 링크를 이용해 주세요.",
        ]
        var lines: [String] = []
        for i in 0..<30 { lines.append("\(i + 1). " + sentences[i % sentences.count]) }
        return lines.joined(separator: "\n")
    }()

    static func multilineLong() -> AXSnapshotFile {
        var c = SyntheticChat(title: "합성 연구실", options: .init(avatarStyle: .image))
        // The long message is the top row and only partly visible; it is still read in full.
        c.other("박서연", .text(longParagraph), time: "오후 4:15", help: "2026. 10. 10.")
        c.other("김민준", .text("안녕하세요 여러분,\n다음 주 월요일부터 실험실 출입 카드가 새로 발급됩니다.\n기존 카드는 금요일까지 행정실에 반납해 주세요.\n문의는 저에게 개인 톡 주세요."),
                time: "오후 4:20", help: "2026. 10. 10.")
        c.mine(.text("논문 리비전 마감이 다음 주라서 이번 주는 다들 화이팅!"), time: "오후 4:21", help: "2026. 10. 10.")
        c.mine(.text("네 확인했습니다.\n카드는 목요일에 반납할게요."), time: "오후 4:26", help: "2026. 10. 10.")
        c.other("이도윤", .text("@린루이 혹시 오늘 저녁 회식 참석 가능하세요?"))
        c.other(nil, .text("내일 오전 10시 30분에 E3-1 1501호에서 뵙겠습니다."), time: "오후 4:30", help: "2026. 10. 10.")
        return c.build(note: "Multi-line and long (> 1000 characters) messages, @mention, AXImage avatars.")
    }

    static func nestedOffscreen() -> AXSnapshotFile {
        var c = SyntheticChat(title: "합성 스크롤방", options: .init(nestedBody: true, bottomAnchorRow: 11, spacerRow: false))
        // Rows 0–4 end up above the visible area (off-screen but present in the AX tree).
        c.divider(nil, style: .emptyButton)
        c.other("김민준", .text("과제 2 마감이 10월 20일 23:59까지로 연장되었습니다."), time: "오후 5:00", help: "2026. 10. 8.")
        c.mine(.text("넵 알겠습니다!"), time: "오후 5:01", help: "2026. 10. 8.")
        c.other("박서연", .text(SyntheticFixtures.longParagraph), time: "오후 5:10", help: "2026. 10. 8.")
        c.mine(.text("수고하셨습니다~"), time: "오후 5:11", help: "2026. 10. 8.")
        // Visible rows.
        c.divider("2026년 10월 9일 목요일")
        c.other("이도윤", .text("오늘 3교시 휴강입니다. 보강 일정은 추후 공지하겠습니다."))
        c.other(nil, .text("졸업 요건 관련해서는 학과 사무실에 문의해 보세요."), time: "오전 11:20", help: "2026. 10. 9.")
        c.mine(.text("ㅠㅠ 데이터셋 다운로드가 너무 느리네요"), time: "오전 11:21", help: "2026. 10. 9.", unread: 1)
        c.other("김민준", .text("서버 GPU 2번은 제가 오늘 밤까지 쓸게요"), time: "오전 11:25", help: "2026. 10. 9.")
        c.other("박서연", .text("헐 대박 ㄷㄷ"))
        c.other(nil, .text("아 그거 제가 착각했네요 ㅎㅎ 죄송합니다"), time: "오전 11:26", help: "2026. 10. 9.")
        // Below the visible area (the user scrolled up a little).
        c.mine(.text("오늘 점심 학식 vs 배달?"), time: "오전 11:40", help: "2026. 10. 9.")
        c.other("이도윤", .text("넵 알겠습니다!"), time: "오전 11:41", help: "2026. 10. 9.")
        return c.build(note: "Nested AXScrollArea→AXTextArea bodies, AXButton avatars, Count Label, off-screen rows above and below the visible area.")
    }

    static func rows200() -> AXSnapshotFile {
        let sentences = [
            "내일 랩미팅은 오후 2시에서 4시로 변경되었습니다.", "넵 알겠습니다!", "ㅋㅋㅋㅋ",
            "오늘 3교시 휴강입니다. 보강 일정은 추후 공지하겠습니다.", "과제 2 마감이 10월 20일 23:59까지로 연장되었습니다.",
            "중간고사 범위는 1장부터 6장까지입니다.", "수고하셨습니다~", "https://example.com/notice/123",
            "서버 GPU 2번은 제가 오늘 밤까지 쓸게요", "ㅠㅠ 데이터셋 다운로드가 너무 느리네요",
            "출석 체크는 KLMS에서 해주세요.", "아 그거 제가 착각했네요 ㅎㅎ 죄송합니다", "오늘 점심 학식 vs 배달?",
            "Deadline은 Friday까지예요", "헐 대박 ㄷㄷ",
        ]
        let authors = ["김민준", "박서연", "이도윤", "최지우"]
        var c = SyntheticChat(title: "합성 대용량방")
        var minute = 9 * 60
        var day = 7
        var previousSender = -2
        for i in 0..<200 {
            if i % 50 == 0 {
                c.divider("2026년 10월 \(day)일")
                previousSender = -2
            }
            let sender = (i * 7 / 3) % 5 - 1 // -1 = me, 0...3 = authors
            let text = sentences[(i * 5) % sentences.count] + (i % 9 == 0 ? "\n(\(i))" : "")
            minute += (i % 3 == 0) ? 1 : 0
            let showTime = i % 2 == 1 || i % 50 == 49
            let h = minute / 60, m = minute % 60
            let label = "\(h < 12 ? "오전" : "오후") \(h % 12 == 0 ? 12 : h % 12):\(String(format: "%02d", m))"
            let help = "2026. 10. \(day)."
            if sender < 0 {
                c.mine(.text(text), time: showTime ? label : nil, help: showTime ? help : nil)
            } else {
                c.other(sender == previousSender ? nil : authors[sender], .text(text),
                        time: showTime ? label : nil, help: showTime ? help : nil)
            }
            previousSender = sender
            if i % 50 == 49 { day += 1; minute = 9 * 60 }
        }
        return c.build(note: "200 message rows + 4 dividers for the parse/diff benchmark; most rows are off-screen.")
    }
}
