// SPDX-License-Identifier: MIT
// Incremental diff between two snapshots' id lists (docs/architecture.md §4.3).

import Foundation

public struct TranscriptDiff: Sendable, Equatable {
    public var appended: [MessageID]
    public var prepended: [MessageID]
    public var removed: [MessageID]
    public var unchanged: [MessageID]
    /// No overlap between old and new (chat switched, or jumped far): treat everything as new.
    public var isReset: Bool
    /// Ids present in both snapshots appear in a different relative order.
    public var isReordered: Bool

    public init(appended: [MessageID] = [], prepended: [MessageID] = [], removed: [MessageID] = [],
                unchanged: [MessageID] = [], isReset: Bool = false, isReordered: Bool = false) {
        self.appended = appended
        self.prepended = prepended
        self.removed = removed
        self.unchanged = unchanged
        self.isReset = isReset
        self.isReordered = isReordered
    }

    public var hasChanges: Bool {
        !appended.isEmpty || !prepended.isEmpty || !removed.isEmpty || isReset || isReordered
    }
}

public enum TranscriptDiffer {
    /// Diff of two top-to-bottom id lists. Ids are unique within a snapshot (MessageIdentity adds "#k").
    ///
    /// Because ids are unique, the "suffix of old = prefix of new" (scroll down / new messages),
    /// "prefix of old = suffix of new" (scroll up), "new inside old" and "old inside new" cases all reduce to
    /// one O(n) pass with a hash set:
    /// - `unchanged`: ids present in both, in `new` order;
    /// - `prepended`: new-only ids above the first common id;
    /// - `appended`: new-only ids below the first common id (for a clean scroll these are exactly the rows
    ///   after the overlap; an edited/deleted row in the middle also lands here instead of forcing a reset);
    /// - `removed`: old-only ids, in `old` order;
    /// - `isReordered`: the common ids are not in the same relative order in both lists.
    /// No common id at all → `isReset` (appended = all new, removed = all old). Both empty → no changes.
    public static func diff(old: [MessageID], new: [MessageID]) -> TranscriptDiff {
        if old == new { return TranscriptDiff(unchanged: new) }
        if old.isEmpty { return TranscriptDiff(appended: new, isReset: true) }
        if new.isEmpty { return TranscriptDiff(removed: old, isReset: true) }

        let oldSet = Set(old)
        var prepended: [MessageID] = []
        var appended: [MessageID] = []
        var unchanged: [MessageID] = []
        unchanged.reserveCapacity(min(old.count, new.count))
        var newSet = Set<MessageID>(minimumCapacity: new.count)
        var seenCommon = false
        for id in new {
            newSet.insert(id)
            if oldSet.contains(id) {
                seenCommon = true
                unchanged.append(id)
            } else if seenCommon {
                appended.append(id)
            } else {
                prepended.append(id)
            }
        }
        guard seenCommon else {
            return TranscriptDiff(appended: new, removed: old, isReset: true)
        }
        var removed: [MessageID] = []
        // Common ids in `old` order must match `unchanged` (common ids in `new` order), else rows moved.
        var reordered = false
        var u = 0
        for id in old {
            if newSet.contains(id) {
                if !reordered && (u >= unchanged.count || unchanged[u] != id) { reordered = true }
                u += 1
            } else {
                removed.append(id)
            }
        }
        return TranscriptDiff(appended: appended, prepended: prepended, removed: removed, unchanged: unchanged,
                              isReordered: reordered)
    }
}
