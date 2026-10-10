// SPDX-License-Identifier: MIT
// `tlctl probe [--summary]` — live, read-only, redacted. Never prompts for permission.

import Foundation
import KakaoAX
import TalkLensCore

func runProbe(arguments: [String]) -> Int32 {
    guard let args = parseArguments(arguments, command: "probe", values: [], flags: ["--summary"]) else { return ExitCode.fail }
    let summaryOnly = args.has("--summary")

    if let reason = livePreconditionSkipReason() {
        print("probe: SKIP \(reason)")
        return ExitCode.skip
    }
    guard let app = KakaoProcess.applicationNode() else {
        print("probe: SKIP KakaoTalk is not running")
        return ExitCode.skip
    }
    let version = KakaoProcess.version ?? "?"
    let windows = app.windows
    var chatWindows = 0
    for (i, w) in windows.enumerated() {
        let isMain = KakaoChatReader.isMainWindow(w)
        let isChat = !isMain && !w.isMinimized && KakaoChatReader.isChatWindow(w)
        if isChat { chatWindows += 1 }
        if !summaryOnly {
            print("window[\(i)]: role=\(w.role ?? "?") title=\(Redactor.redactTitle(w.title ?? "")) main=\(isMain) chat=\(isChat) minimized=\(w.isMinimized)")
        }
    }
    print("windows: total=\(windows.count) chat=\(chatWindows)")

    guard let window = KakaoChatReader.currentChatWindow(app: app) else {
        print("probe: SKIP no open chat window (open a chat in KakaoTalk; windows=\(windows.count))")
        return ExitCode.skip
    }

    let watch = Stopwatch()
    guard let loc = TranscriptLocator.locate(inWindow: window) else {
        print("probe: FAIL chat window found but transcript area not located (kakao=\(version))")
        return ExitCode.fail
    }
    let locateMs = watch.elapsedMilliseconds
    let parser = TranscriptParser()
    let rowsTotal = AXTree.findAll(in: loc.transcriptRoot, maxNodes: 8_000, descend: { $0.role != AXRole.row }) { $0.role == AXRole.row }.count
    let parseWatch = Stopwatch()
    let parsed = parser.parse(transcriptRoot: loc.transcriptRoot, inputFrame: loc.inputFrame)
    let parseMs = parseWatch.elapsedMilliseconds
    let title = window.title ?? ""
    let key = MessageIdentity.chatKey(forTitle: title)
    let messages = MessageIdentity.assign(parsed, chatKey: key)

    let mine = messages.filter { $0.isMine }.count
    let system = messages.filter { $0.isSystem }.count
    let others = messages.count - mine - system
    print("chat: title=\(Redactor.redactTitle(title)) key=\(Redactor.shortHash(key)) rows=\(rowsTotal) transcript=\(loc.transcriptRoot.role ?? "?")")
    if !summaryOnly {
        for m in messages {
            let side = m.isSystem ? "system" : (m.isMine ? "mine" : "other")
            let author = m.author.map { "author#" + Redactor.shortHash($0) } ?? "-"
            print("  \(side) \(author) time=\(m.timeRaw ?? "-") date=\(m.date ?? "-") body=\(Redactor.redact(m.body)) img=\(m.attachments.images) link=\(m.attachments.links) file=\(m.attachments.files)")
        }
    }
    print("messages: total=\(messages.count) mine=\(mine) others=\(others) system=\(system) locate=\(formatMs(locateMs))ms parse=\(formatMs(parseMs))ms")
    print("probe: OK kakao=\(version) windows=\(windows.count) chat=\(chatWindows) rows=\(rowsTotal) messages=\(messages.count) parse=\(formatMs(parseMs))ms")
    return ExitCode.ok
}
