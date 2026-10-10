// SPDX-License-Identifier: MIT
// Incremental diff between two snapshots' id lists (docs/architecture.md §4.3).
// STUB — core-dev: implement the suffix/prefix overlap algorithm and test it.

import Foundation

public struct TranscriptDiff: Sendable, Equatable {
    public var appended: [MessageID]
    public var prepended: [MessageID]
    public var removed: [MessageID]
    public var unchanged: [MessageID]
    /// No overlap between old and new (chat switched, or jumped far): treat everything as new.
    public var isReset: Bool

    public init(appended: [MessageID] = [], prepended: [MessageID] = [], removed: [MessageID] = [],
                unchanged: [MessageID] = [], isReset: Bool = false) {
        self.appended = appended
        self.prepended = prepended
        self.removed = removed
        self.unchanged = unchanged
        self.isReset = isReset
    }

    public var hasChanges: Bool { !appended.isEmpty || !prepended.isEmpty || !removed.isEmpty || isReset }
}

public enum TranscriptDiffer {
    public static func diff(old: [MessageID], new: [MessageID]) -> TranscriptDiff {
        if old == new { return TranscriptDiff(unchanged: new) }
        return TranscriptDiff(appended: new, removed: old, isReset: true)
    }
}
