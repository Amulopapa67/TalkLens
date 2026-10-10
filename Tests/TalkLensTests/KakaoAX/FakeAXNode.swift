// SPDX-License-Identifier: MIT
// A mutable, identity-stable fake AX tree for incremental-read tests.
//
// Every node is identified by its child-index path from the window ("w", "w/0", "w/0/0/3", …), so two builds of
// the same synthetic chat share identities for rows at the same index — like live AXUIElements, which keep
// their identity while the user scrolls or new rows arrive. `refreshed()` returns the node currently loaded in
// the world for that identity (or a dead node when it is gone), which mirrors a fresh AX read. Attribute and
// children reads are counted per identity so tests can assert that cached rows are not walked again.

import CoreGraphics
import Foundation
@testable import KakaoAX

final class FakeWorld: @unchecked Sendable {
    private(set) var nodes: [String: FakeAXNode] = [:]
    /// Number of `children` reads per node identity.
    private(set) var childrenReads: [String: Int] = [:]

    func load(_ root: FakeAXNode) {
        var map: [String: FakeAXNode] = [:]
        var stack = [root]
        while let n = stack.popLast() {
            map[n.id] = n
            stack.append(contentsOf: n.storedChildren)
        }
        nodes = map
    }

    func resetCounters() { childrenReads = [:] }

    func noteChildrenRead(_ id: String) { childrenReads[id, default: 0] += 1 }

    /// Children reads below (and including) the given identity prefix.
    func childrenReads(under prefix: String) -> Int {
        childrenReads.filter { $0.key == prefix || $0.key.hasPrefix(prefix + "/") }.values.reduce(0, +)
    }
}

final class FakeAXNode: IncrementalAXNode {
    let id: String
    let world: FakeWorld
    var role: String?
    var subrole: String?
    var identifier: String?
    var title: String?
    var value: String?
    var nodeDescription: String?
    var help: String?
    var frame: CGRect?
    var isEnabled: Bool
    var storedChildren: [FakeAXNode]

    init(id: String, world: FakeWorld, recorded r: RecordedAXNode?) {
        self.id = id
        self.world = world
        role = r?.role
        subrole = r?.subrole
        identifier = r?.identifier
        title = r?.title
        value = r?.value
        nodeDescription = r?.nodeDescription
        help = r?.help
        frame = r?.frame
        isEnabled = r?.isEnabled ?? true
        storedChildren = []
        if let r {
            // Columns get their own namespace so a row appended at the column's old index is a new element.
            storedChildren = r.children.enumerated().map { i, c in
                FakeAXNode(id: c.role == AXRole.column ? "\(id)/col\(i)" : "\(id)/\(i)", world: world, recorded: c)
            }
        }
    }

    var children: [FakeAXNode] {
        world.noteChildrenRead(id)
        return storedChildren
    }

    var elementIdentity: String { id }

    func refreshed() -> FakeAXNode {
        world.nodes[id] ?? FakeAXNode(id: id, world: world, recorded: nil)
    }

    /// Builds the fake tree for a recorded window and loads it into `world`.
    @discardableResult
    static func load(_ window: RecordedAXNode, into world: FakeWorld) -> FakeAXNode {
        let root = FakeAXNode(id: "w", world: world, recorded: window)
        world.load(root)
        return root
    }
}

extension RecordedAXNode {
    /// Copy with every frame in the subtree moved by (dx, dy).
    func shifted(dx: Double, dy: Double) -> RecordedAXNode {
        var copy = self
        if let f = frame { copy.rect = AXRectArray(f.offsetBy(dx: dx, dy: dy)) }
        copy.children = children.map { $0.shifted(dx: dx, dy: dy) }
        return copy
    }

    /// Applies `transform` to the first node (depth-first) with `role`, returning the modified tree.
    func modifyingFirst(role target: String, _ transform: (RecordedAXNode) -> RecordedAXNode) -> RecordedAXNode {
        var done = false
        func visit(_ n: RecordedAXNode) -> RecordedAXNode {
            if done { return n }
            if n.role == target {
                done = true
                return transform(n)
            }
            var copy = n
            copy.children = n.children.map(visit)
            return copy
        }
        return visit(self)
    }
}
