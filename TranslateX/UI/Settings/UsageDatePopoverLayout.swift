import Foundation
import CoreGraphics

/// The date selector uses the existing settings anchor-overlay mechanism.
/// These bounds are in the owning page's coordinate space, not screen space.
nonisolated enum UsageDatePopoverLayout {
    static let preferredWidth: CGFloat = 520
    static let endpointWidth: CGFloat = 224
    static let columnGap: CGFloat = 14
    static let yearWidth: CGFloat = 68
    static let monthDayWidth: CGFloat = 54
    // NSPopUpButton draws 5pt beyond its SwiftUI alignment rect. A 13pt
    // layout gap leaves an actual 8pt gap between the painted menu borders.
    static let componentGap: CGFloat = 13
    static let endpointPadding: CGFloat = 10
    static let endpointGap: CGFloat = 12
    static let outerPadding: CGFloat = 14
    static let calendarHeaderHeight: CGFloat = 27
    static let weekdayHeight: CGFloat = 21
    static let dayHeight: CGFloat = 29
    static let calendarRowGap: CGFloat = 3
    static let calendarSectionGap: CGFloat = 10

    static func calendarHeight(weeks: Int) -> CGFloat {
        endpointPadding * 2 + calendarHeaderHeight + calendarSectionGap + weekdayHeight
            + CGFloat(weeks) * (dayHeight + calendarRowGap)
    }

    static var endpointContentWidth: CGFloat {
        endpointWidth - endpointPadding * 2
    }

    static func frame(anchor: CGRect, contentSize: CGSize, containerSize: CGSize) -> CGRect {
        let margin: CGFloat = 12, gap: CGFloat = 8
        let width = min(contentSize.width, max(0, containerSize.width - margin * 2))
        let height = min(contentSize.height, max(0, containerSize.height - margin * 2))
        let left = max(margin, min(anchor.maxX - width, containerSize.width - width - margin))
        let below = anchor.maxY + gap
        let above = anchor.minY - gap - height
        let top: CGFloat
        if below + height <= containerSize.height - margin { top = max(margin, below) }
        else if above >= margin { top = above }
        else { top = max(margin, min(below, containerSize.height - height - margin)) }
        return CGRect(x: left, y: top, width: width, height: height)
    }
}
