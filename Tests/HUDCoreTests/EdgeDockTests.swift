import Foundation
import CoreGraphics
import HUDCore

func testDockingUsesCurrentScreenAndRestoresReadableFrame() {
    let screen = CGRect(x: -1440, y: 23, width: 1440, height: 877)
    expectEqual(EdgeDocking.edge(for: CGRect(x: -1428, y: 300, width: 340, height: 310), in: screen), .left)
    expectEqual(EdgeDocking.edge(for: CGRect(x: -350, y: 300, width: 340, height: 310), in: screen), .right)
    expectEqual(EdgeDocking.edge(for: CGRect(x: -900, y: 300, width: 340, height: 310), in: screen), nil)
    expectEqual(EdgeDocking.edge(for: CGRect(x: -1470, y: 300, width: 340, height: 310), in: screen), .left)
    let original = CGRect(x: -350, y: 300, width: 340, height: 310)
    let tab = EdgeDocking.collapsedFrame(edge: .right, expanded: original, in: screen)
    expectEqual(tab, CGRect(x: -36, y: 401, width: 36, height: 108))
    let restored = EdgeDocking.expandedFrame(edge: .right, previous: original, size: CGSize(width: 340, height: 650), in: screen)
    expectEqual(restored.minX, -340)
    expectEqual(restored.minY, 31)
    expectEqual(restored.height, 650)
    let dual = EdgeDocking.collapsedFrame(edge: .right, expanded: original, in: screen, layout: .dual)
    expectEqual(dual.minX, screen.maxX - EdgeTabLayout.dual.size.width)
    expectEqual(dual.size, EdgeTabLayout.dual.size)
    let left = EdgeDocking.collapsedFrame(edge: .left, expanded: original, in: screen, layout: .dual)
    expectEqual(left.minX, screen.minX)
    let high = EdgeDocking.collapsedFrame(edge: .left, expanded: CGRect(x: -1440, y: 1000, width: 340, height: 400), in: screen, layout: .dual)
    expectEqual(high.maxY, screen.maxY - 8)
    let low = EdgeDocking.collapsedFrame(edge: .right, expanded: CGRect(x: -340, y: -1000, width: 340, height: 400), in: screen, layout: .dual)
    expectEqual(low.minY, screen.minY + 8)
}
