import CoreGraphics

public enum HUDDockEdge: String, Equatable { case left, right }

/// Geometry in the current screen's global coordinates, including negative origins.
public enum EdgeDocking {
    public static func edge(for frame: CGRect, in screen: CGRect, threshold: CGFloat = 16) -> HUDDockEdge? {
        let left = frame.minX - screen.minX, right = screen.maxX - frame.maxX
        if left <= threshold && left <= right { return .left }
        if right <= threshold { return .right }
        return nil
    }
    public static func collapsedFrame(edge: HUDDockEdge, expanded: CGRect, in screen: CGRect) -> CGRect {
        let size = CGSize(width: 36, height: 108)
        let y = min(max(expanded.midY - size.height / 2, screen.minY + 8), screen.maxY - size.height - 8)
        return CGRect(x: edge == .left ? screen.minX : screen.maxX - size.width, y: y, width: size.width, height: size.height)
    }
    public static func expandedFrame(edge: HUDDockEdge?, previous: CGRect, size: CGSize, in screen: CGRect) -> CGRect {
        let width = min(size.width, screen.width - 16), height = min(size.height, screen.height - 16)
        let top = min(max(previous.maxY, screen.minY + height + 8), screen.maxY - 8)
        let x: CGFloat
        switch edge {
        case .left: x = screen.minX
        case .right: x = screen.maxX - width
        case nil: x = min(max(previous.minX, screen.minX + 8), screen.maxX - width - 8)
        }
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}
