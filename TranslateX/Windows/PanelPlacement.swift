import Foundation

enum PanelPlacement {
    /// Resize around the existing top-left corner, moving it only where necessary
    /// to keep the entire panel in the current display's usable area.
    static func resizingFrame(current: CGRect, size: CGSize, visibleFrame: CGRect) -> CGRect {
        let width = min(max(0, size.width), max(0, visibleFrame.width))
        let height = min(max(0, size.height), max(0, visibleFrame.height))
        let x = min(max(current.minX, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(current.maxY - height, visibleFrame.minY), visibleFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func frame(size: CGSize, anchor: CGPoint, visibleFrame: CGRect) -> CGRect {
        let margin: CGFloat = 12
        let width = min(size.width, max(0, visibleFrame.width - 2 * margin))
        let height = min(size.height, max(0, visibleFrame.height - 2 * margin))
        let x = min(max(anchor.x + 16, visibleFrame.minX + margin), visibleFrame.maxX - width - margin)
        let below = anchor.y - height - 16
        let y = min(max(below, visibleFrame.minY + margin), visibleFrame.maxY - height - margin)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
