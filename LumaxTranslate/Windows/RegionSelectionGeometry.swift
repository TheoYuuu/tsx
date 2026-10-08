import CoreGraphics

struct SelectedRegion: Sendable {
    /// Global AppKit coordinates: points, with the primary display's origin at bottom left.
    let bounds: CGRect
    let referenceTop: CGFloat
    let excludingWindowIDs: [CGWindowID]
}

enum RegionSelectionError: Error, Equatable {
    case busy
    case noScreens
    case screenConfigurationChanged
}

struct RegionSelectionGeometry {
    let desktopBounds: CGRect
    private(set) var start: CGPoint?
    private(set) var selection: CGRect?

    init(screenFrames: [CGRect]) {
        desktopBounds = screenFrames.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
            .reduce(CGRect.null) { $0.union($1) }
    }

    mutating func begin(at point: CGPoint) {
        guard !desktopBounds.isNull, point.x.isFinite, point.y.isFinite else { return }
        start = clamped(point)
        selection = CGRect(origin: clamped(point), size: .zero)
    }

    mutating func update(to point: CGPoint) {
        guard let start, point.x.isFinite, point.y.isFinite else { return }
        let end = clamped(point)
        selection = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
    }

    /// A click or a very thin drag is not a screenshot; leave the overlay ready to try again.
    mutating func finish(at point: CGPoint) -> CGRect? {
        guard start != nil else { return nil }
        update(to: point)
        defer { start = nil }
        guard let selection, selection.width >= 4, selection.height >= 4 else {
            self.selection = nil
            return nil
        }
        return selection
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, desktopBounds.minX), desktopBounds.maxX),
            y: min(max(point.y, desktopBounds.minY), desktopBounds.maxY)
        )
    }
}
