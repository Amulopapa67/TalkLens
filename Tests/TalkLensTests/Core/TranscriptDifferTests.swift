// SPDX-License-Identifier: MIT

import Testing
@testable import TalkLensCore

@Suite struct TranscriptDifferTests {
    private func ids(_ s: String) -> [MessageID] {
        s.split(separator: " ").map { MessageID(String($0)) }
    }

    @Test func identicalListsHaveNoChanges() {
        let d = TranscriptDiffer.diff(old: ids("a b c"), new: ids("a b c"))
        #expect(d == TranscriptDiff(unchanged: ids("a b c")))
        #expect(!d.hasChanges)
    }

    @Test func bothEmptyHasNoChanges() {
        let d = TranscriptDiffer.diff(old: [], new: [])
        #expect(!d.hasChanges)
        #expect(d.unchanged.isEmpty)
    }

    @Test func firstSnapshotIsResetWithEverythingAppended() {
        let d = TranscriptDiffer.diff(old: [], new: ids("a b"))
        #expect(d.isReset)
        #expect(d.appended == ids("a b"))
        #expect(d.removed.isEmpty)
    }

    @Test func emptyNewSnapshotRemovesEverything() {
        let d = TranscriptDiffer.diff(old: ids("a b"), new: [])
        #expect(d.removed == ids("a b"))
        #expect(d.appended.isEmpty)
        #expect(d.unchanged.isEmpty)
        #expect(d.hasChanges)
    }

    @Test func newMessagesAtBottomAreAppended() {
        let d = TranscriptDiffer.diff(old: ids("a b c"), new: ids("a b c d e"))
        #expect(d.appended == ids("d e"))
        #expect(d.prepended.isEmpty)
        #expect(d.removed.isEmpty)
        #expect(d.unchanged == ids("a b c"))
        #expect(!d.isReset)
    }

    @Test func scrollDownSuffixPrefixOverlap() {
        let d = TranscriptDiffer.diff(old: ids("a b c d"), new: ids("c d e f"))
        #expect(d.appended == ids("e f"))
        #expect(d.removed == ids("a b"))
        #expect(d.unchanged == ids("c d"))
        #expect(d.prepended.isEmpty)
        #expect(!d.isReset)
    }

    @Test func scrollUpPrefixSuffixOverlap() {
        let d = TranscriptDiffer.diff(old: ids("c d e f"), new: ids("a b c d"))
        #expect(d.prepended == ids("a b"))
        #expect(d.removed == ids("e f"))
        #expect(d.unchanged == ids("c d"))
        #expect(d.appended.isEmpty)
        #expect(!d.isReset)
    }

    @Test func newWindowInsideOldRemovesBothEnds() {
        let d = TranscriptDiffer.diff(old: ids("a b c d e"), new: ids("b c d"))
        #expect(d.removed == ids("a e"))
        #expect(d.unchanged == ids("b c d"))
        #expect(d.appended.isEmpty && d.prepended.isEmpty && !d.isReset)
    }

    @Test func oldInsideNewGrowsBothEnds() {
        let d = TranscriptDiffer.diff(old: ids("c d"), new: ids("a b c d e"))
        #expect(d.prepended == ids("a b"))
        #expect(d.appended == ids("e"))
        #expect(d.unchanged == ids("c d"))
        #expect(d.removed.isEmpty)
    }

    @Test func noOverlapIsReset() {
        let d = TranscriptDiffer.diff(old: ids("a b c"), new: ids("x y"))
        #expect(d.isReset)
        #expect(d.appended == ids("x y"))
        #expect(d.removed == ids("a b c"))
        #expect(d.unchanged.isEmpty)
        #expect(d.prepended.isEmpty)
    }

    @Test func editedMessageInTheMiddleIsNotAReset() {
        // An edited/deleted message changes its id; the rest of the window still overlaps.
        let d = TranscriptDiffer.diff(old: ids("a b c d"), new: ids("a b x d e"))
        #expect(!d.isReset)
        #expect(d.removed == ids("c"))
        #expect(d.appended == ids("x e"))
        #expect(d.unchanged == ids("a b d"))
    }

    @Test func singleElementOverlap() {
        let d = TranscriptDiffer.diff(old: ids("a b c"), new: ids("c d"))
        #expect(d.unchanged == ids("c"))
        #expect(d.appended == ids("d"))
        #expect(d.removed == ids("a b"))
    }

    @Test func diffOf200IdsIsFast() {
        let old = (0..<200).map { MessageID("id\($0)") }
        let new = (3..<203).map { MessageID("id\($0)") }
        var samples: [Double] = []
        for _ in 0..<200 {
            let sw = Stopwatch()
            let d = TranscriptDiffer.diff(old: old, new: new)
            samples.append(sw.elapsedMilliseconds)
            #expect(d.appended.count == 3)
        }
        let stats = LatencyStats(samples)
        #expect(stats.p95 < 5, "diff p95 \(stats.summary)")
    }
}
