import CoreGraphics

public enum HUDLayout {
    /// No forced minimum: a small screen must never overflow just to preserve a detail pane.
    public static func detailHeight(available: CGFloat, chrome: CGFloat) -> CGFloat { min(274, max(0, available - chrome)) }
}
