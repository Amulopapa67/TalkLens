// SPDX-License-Identifier: MIT
// LiveAXNode without a live KakaoTalk: uncached geometry reads and the locked lazy caches.
// Only read-only AX copy calls are made, against an application element that has no windows.

import CoreGraphics
import Foundation
import Testing
@testable import KakaoAX

@Suite("LiveAXNodeTests")
struct LiveAXNodeTests {
    /// An application element for a pid that (almost certainly) does not exist; application elements never
    /// expose a position, size or AXMinimized either way.
    private func node() -> LiveAXNode { LiveAXNode.application(pid: 99_991) }

    @Test("uncached geometry reads degrade to nil / false on failure")
    func uncachedGeometry() {
        let n = node()
        #expect(n.currentFrame() == nil)
        #expect(n.currentIsMinimized() == false)
        let g = n.currentGeometry()
        #expect(g.frame == nil && g.isMinimized == false)
        #expect(LiveAXNode.geometryAttributeNames == [AXAttr.position, AXAttr.size, AXAttr.minimized])
    }

    @Test("lazy caches tolerate concurrent use and invalidate()")
    func concurrentCacheAccess() async {
        let n = node()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<16 {
                group.addTask {
                    for _ in 0..<20 {
                        _ = n.role
                        _ = n.frame
                        _ = n.children.count
                        if i % 4 == 0 { n.invalidate() }
                    }
                }
            }
        }
        #expect(n.role == nil)
        #expect(n.children.isEmpty)
    }
}
