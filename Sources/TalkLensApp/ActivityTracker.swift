// SPDX-License-Identifier: MIT
// "TalkLens is working" indicator for the menu bar icon: on while a slow AX read or a translation is in
// flight. Debounced so that the many short reads (a few ms each) never make the icon flicker: the badge shows
// once something has been busy for `showDelay` and stays for `hold` after the last work ended.

import Foundation

@MainActor
final class ActivityTracker {
    static let showDelay: Duration = .milliseconds(150)
    static let hold: Duration = .milliseconds(400)

    /// Busy sources ("read", "mt-<channel>", ...).
    private var busy: Set<String> = []
    private(set) var shown = false
    private var transitionTask: Task<Void, Never>?
    var onChange: (@MainActor (Bool) -> Void)?

    var isBusy: Bool { !busy.isEmpty }

    func set(_ source: String, busy value: Bool) {
        let wasBusy = isBusy
        if value { busy.insert(source) } else { busy.remove(source) }
        guard isBusy != wasBusy else { return }
        transitionTask?.cancel()
        let target = isBusy
        guard target != shown else {
            transitionTask = nil
            return
        }
        let delay = target ? Self.showDelay : Self.hold
        transitionTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.isBusy == target, self.shown != target else { return }
            self.transitionTask = nil
            self.shown = target
            self.onChange?(target)
        }
    }

    func reset() {
        busy.removeAll()
        transitionTask?.cancel()
        transitionTask = nil
        if shown {
            shown = false
            onChange?(false)
        }
    }
}
