// SPDX-License-Identifier: MIT

import Testing
import TalkLensCore

@Suite("Core.TranslationPriority")
struct TranslationPriorityTests {
    static func ids(_ n: Int) -> [MessageID] { (0..<n).map { MessageID("m\($0)") } }

    @Test("visible newest-first, then the rest nearest-first (below before above on ties)")
    func ordering() {
        let all = Self.ids(10)
        let visible: Set<MessageID> = [all[4], all[5], all[6]]
        let order = TranslationPriority.order(all, visible: visible, cap: 100)
        #expect(order.map(\.rawValue) == ["m6", "m5", "m4", "m7", "m3", "m8", "m2", "m9", "m1", "m0"])
    }

    @Test("cap and include filter apply after ordering; visible messages always come first")
    func capAndFilter() {
        let all = Self.ids(10)
        let visible: Set<MessageID> = [all[8], all[9]]
        let done: Set<MessageID> = [all[9], all[7]]
        let order = TranslationPriority.order(all, visible: visible, cap: 3) { !done.contains($0) }
        #expect(order.map(\.rawValue) == ["m8", "m6", "m5"])
    }

    @Test("no visible information: newest-first")
    func noVisible() {
        let all = Self.ids(4)
        #expect(TranslationPriority.order(all, visible: [], cap: 10).map(\.rawValue) == ["m3", "m2", "m1", "m0"])
        #expect(TranslationPriority.order([], visible: [], cap: 10).isEmpty)
    }
}
