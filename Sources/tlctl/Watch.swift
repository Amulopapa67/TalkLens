// SPDX-License-Identifier: MIT
// `tlctl watch --seconds N` — live, read-only. Subscribes to AX notifications (app, chat window, transcript),
// prints redacted events and, after content events (debounced 120 ms), re-reads and prints diff counts.

import ApplicationServices
import Foundation
import KakaoAX
import TalkLensCore

func runWatch(arguments: [String]) -> Int32 {
    guard let args = parseArguments(arguments, command: "watch", values: ["--seconds"], flags: []) else { return ExitCode.fail }
    guard let seconds = args.int("--seconds"), seconds > 0 else {
        print("watch: --seconds N (N > 0) is required (see `tlctl help`)")
        return ExitCode.fail
    }
    if let reason = livePreconditionSkipReason() {
        print("watch: SKIP \(reason)")
        return ExitCode.skip
    }
    guard let pid = KakaoProcess.processIdentifier, let app = KakaoProcess.applicationNode() else {
        print("watch: SKIP KakaoTalk is not running")
        return ExitCode.skip
    }

    let session = WatchSession(pid: pid, app: app)
    guard session.start() else {
        print("watch: FAIL could not create an AXObserver for KakaoTalk")
        return ExitCode.fail
    }
    session.run(seconds: Double(seconds))
    return ExitCode.ok
}

/// Lives on the main thread (observer callbacks are delivered on the main run loop).
final class WatchSession {
    let pid: pid_t
    let app: LiveAXNode
    var observer: AXNotificationObserver?
    var window: LiveAXNode?
    var transcript: LiveAXNode?
    var eventCounts: [String: Int] = [:]
    var pendingReadAt: Double?
    var previousIDs: [MessageID]?
    var previousKey: String?
    var reads = 0
    let clock = Stopwatch()
    let debounceMs = 120.0
    /// Per-run random HMAC key for the chat tag (not dictionary-reversible, not stable across runs).
    let tagger = RunScopedTagger()

    init(pid: pid_t, app: LiveAXNode) {
        self.pid = pid
        self.app = app
    }

    func start() -> Bool {
        observer = AXNotificationObserver(pid: pid) { [weak self] name, element in
            self?.handle(name, element: element)
        }
        guard let observer else { return false }
        let failed = observer.add(AXNotificationName.application, to: app.element)
        reportFailures("app", failed)
        attachToCurrentWindow()
        readAndDiff(reason: "initial")
        return true
    }

    func attachToCurrentWindow() {
        guard let observer else { return }
        let fresh = KakaoProcess.applicationNode() ?? app
        let current = KakaoChatReader.currentChatWindow(app: fresh)
        if let current, let window, current.isSameElement(as: window) { return }
        if let window { observer.remove(element: window.element) }
        if let transcript { observer.remove(element: transcript.element) }
        window = current
        transcript = nil
        guard let current else {
            print(stamp() + " watch: no chat window")
            return
        }
        reportFailures("window", observer.add(AXNotificationName.window, to: current.element))
        if let loc = TranscriptLocator.locate(inWindow: current) {
            transcript = loc.transcriptRoot
            reportFailures("transcript(\(loc.transcriptRoot.role ?? "?"))",
                           observer.add(AXNotificationName.transcript, to: loc.transcriptRoot.element))
            // The table inside the scroll area is usually what posts row notifications.
            if let table = loc.transcriptRoot.children.first(where: { $0.role == AXRole.table || $0.role == AXRole.outline }) {
                reportFailures("table", observer.add(AXNotificationName.transcript, to: table.element))
            }
        }
        print(stamp() + " watch: attached to chat window \(Redactor.redactTitle(current.title ?? ""))")
    }

    func reportFailures(_ target: String, _ failures: [String: Int32]) {
        guard !failures.isEmpty else { return }
        let list = failures.keys.sorted().map { "\($0)=\(AccessibilityError.axError(failures[$0]!).description)" }
        print(stamp() + " watch: \(target) unsupported: " + list.joined(separator: ", "))
    }

    func handle(_ name: String, element: AXUIElement) {
        eventCounts[name, default: 0] += 1
        let node = LiveAXNode(element)
        // Role only: never titles or values.
        print(stamp() + " event \(name) role=\(node.role ?? "?")")
        if [AXNotificationName.focusedWindowChanged, AXNotificationName.mainWindowChanged,
            AXNotificationName.windowCreated, AXNotificationName.uiElementDestroyed].contains(name) {
            attachToCurrentWindow()
        }
        if AXNotificationName.content.contains(name) {
            pendingReadAt = clock.elapsedMilliseconds + debounceMs
        }
    }

    func readAndDiff(reason: String) {
        reads += 1
        do {
            let read = try KakaoChatReader.readCurrentChat()
            let ids = read.snapshot.messages.map(\.id)
            var line = "read(\(reason)): messages=\(ids.count) chat=\(tagger.tag(read.snapshot.chatKey)) parse=\(formatMs(read.elapsedMilliseconds))ms"
            if let previousIDs, previousKey == read.snapshot.chatKey {
                let d = TranscriptDiffer.diff(old: previousIDs, new: ids)
                line += " diff appended=\(d.appended.count) prepended=\(d.prepended.count) removed=\(d.removed.count) unchanged=\(d.unchanged.count) reset=\(d.isReset) reordered=\(d.isReordered)"
            } else if previousIDs != nil {
                line += " diff chat-changed"
            }
            previousIDs = ids
            previousKey = read.snapshot.chatKey
            print(stamp() + " " + line)
        } catch {
            print(stamp() + " read(\(reason)): \(error)")
        }
    }

    func run(seconds: Double) {
        let endMs = seconds * 1000
        while clock.elapsedMilliseconds < endMs {
            _ = CFRunLoopRunInMode(.defaultMode, 0.02, false)
            if let due = pendingReadAt, clock.elapsedMilliseconds >= due {
                pendingReadAt = nil
                readAndDiff(reason: "event")
            }
        }
        observer?.removeAll()
        let total = eventCounts.values.reduce(0, +)
        let breakdown = eventCounts.keys.sorted().map { "\($0)=\(eventCounts[$0]!)" }.joined(separator: " ")
        print("watch: OK seconds=\(Int(seconds)) events=\(total) reads=\(reads)\(breakdown.isEmpty ? "" : " " + breakdown)")
    }

    func stamp() -> String { String(format: "+%.3fs", clock.elapsedMilliseconds / 1000) }
}
