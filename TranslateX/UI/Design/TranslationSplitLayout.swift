import SwiftUI

extension EnvironmentValues {
    @Entry var translationLayout: TranslationLayout = .sideBySide
}

/// The same three subviews stay mounted across layout changes, preserving the
/// native source editor's selection, marked text and undo history.
struct TranslationSplitLayout: Layout {
    let orientation: TranslationLayout

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let horizontal = orientation == .sideBySide
        let extent = horizontal ? bounds.width : bounds.height
        let divider = min(1, max(0, extent))
        let half = max(0, extent - divider) / 2
        let paneSize = horizontal ? CGSize(width: half, height: bounds.height) : CGSize(width: bounds.width, height: half)
        let dividerSize = horizontal ? CGSize(width: divider, height: bounds.height) : CGSize(width: bounds.width, height: divider)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(paneSize))
        subviews[1].place(at: CGPoint(x: bounds.minX + (horizontal ? half : 0), y: bounds.minY + (horizontal ? 0 : half)),
                          anchor: .topLeading, proposal: ProposedViewSize(dividerSize))
        subviews[2].place(at: CGPoint(x: bounds.minX + (horizontal ? half + divider : 0), y: bounds.minY + (horizontal ? 0 : half + divider)),
                          anchor: .topLeading, proposal: ProposedViewSize(paneSize))
    }
}
