// SPDX-License-Identifier: MIT
// Order in which loaded messages are submitted for translation (pre-translation of everything loaded).

import Foundation

public enum TranslationPriority {
    /// Default upper bound on messages submitted per chat.
    public static let defaultCap = 300

    /// `ids` top-to-bottom. Visible messages first (newest-first), then the others ordered by their distance
    /// (in rows) from the visible range, nearest first; on equal distance the newer (below) one wins. With no
    /// visible message everything is newest-first. `include` filters (e.g. "still needs a translation") before
    /// the cap is applied, so the cap counts submitted messages only.
    public static func order(_ ids: [MessageID], visible: Set<MessageID>, cap: Int = defaultCap,
                             include: (MessageID) -> Bool = { _ in true }) -> [MessageID] {
        guard cap > 0, !ids.isEmpty else { return [] }
        let visibleIndices = ids.indices.filter { visible.contains(ids[$0]) }
        var ranked: [(id: MessageID, group: Int, distance: Int, index: Int)] = []
        ranked.reserveCapacity(ids.count)
        if let lo = visibleIndices.first, let hi = visibleIndices.last {
            for (i, id) in ids.enumerated() {
                if visible.contains(id) {
                    ranked.append((id, 0, 0, i))
                } else {
                    let d = i < lo ? lo - i : (i > hi ? i - hi : 0)
                    ranked.append((id, 1, d, i))
                }
            }
        } else {
            for (i, id) in ids.enumerated() { ranked.append((id, 1, 0, i)) }
        }
        ranked.sort { a, b in
            if a.group != b.group { return a.group < b.group }
            if a.distance != b.distance { return a.distance < b.distance }
            return a.index > b.index
        }
        var out: [MessageID] = []
        out.reserveCapacity(min(cap, ranked.count))
        var seen = Set<MessageID>()
        for r in ranked where out.count < cap {
            guard seen.insert(r.id).inserted, include(r.id) else { continue }
            out.append(r.id)
        }
        return out
    }
}
