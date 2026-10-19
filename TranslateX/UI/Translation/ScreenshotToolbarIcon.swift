import AppKit
import SwiftUI

/// Lucide 1.17.0 vectors. See Resources/ScreenshotIconNotices.txt for provenance and licenses.
/// Kept separate from system symbols so screenshot controls do not change other app icons.
enum ScreenshotToolbarIcon: CaseIterable, Sendable {
    case chevronDown, arrowRight, retranslate, image, fileText, copy, save, more, stop, images, clipboardText, edit, capture

    private var paths: (outline: Path, fill: Path) {
        var outline = Path(), fill = Path()
        switch self {
        case .chevronDown:
            outline.move(to: CGPoint(x: 6, y: 9))
            outline.addLine(to: CGPoint(x: 12, y: 15))
            outline.addLine(to: CGPoint(x: 18, y: 9))
        case .arrowRight:
            outline.move(to: CGPoint(x: 5, y: 12))
            outline.addLine(to: CGPoint(x: 19, y: 12))
            outline.move(to: CGPoint(x: 12, y: 5))
            outline.addLine(to: CGPoint(x: 19, y: 12))
            outline.addLine(to: CGPoint(x: 12, y: 19))
        case .retranslate:
            outline.move(to: CGPoint(x: 2, y: 9))
            outline.addLine(to: CGPoint(x: 5, y: 6))
            outline.addLine(to: CGPoint(x: 8, y: 9))
            outline.move(to: CGPoint(x: 13, y: 18))
            outline.addLine(to: CGPoint(x: 7, y: 18))
            outline.addCurve(to: CGPoint(x: 5, y: 16), control1: CGPoint(x: 5.895431, y: 18), control2: CGPoint(x: 5, y: 17.104569))
            outline.addLine(to: CGPoint(x: 5, y: 6))
            outline.move(to: CGPoint(x: 22, y: 15))
            outline.addLine(to: CGPoint(x: 19, y: 18))
            outline.addLine(to: CGPoint(x: 16, y: 15))
            outline.move(to: CGPoint(x: 11, y: 6))
            outline.addLine(to: CGPoint(x: 17, y: 6))
            outline.addCurve(to: CGPoint(x: 19, y: 8), control1: CGPoint(x: 18.104569, y: 6), control2: CGPoint(x: 19, y: 6.895431))
            outline.addLine(to: CGPoint(x: 19, y: 18))
        case .image:
            outline.addRoundedRect(in: CGRect(x: 3, y: 3, width: 18, height: 18), cornerSize: CGSize(width: 2, height: 2))
            outline.addEllipse(in: CGRect(x: 7, y: 7, width: 4, height: 4))
            outline.move(to: CGPoint(x: 21, y: 15))
            outline.addLine(to: CGPoint(x: 17.914, y: 11.914))
            outline.addCurve(to: CGPoint(x: 15.086, y: 11.914), control1: CGPoint(x: 17.133, y: 11.133236), control2: CGPoint(x: 15.867, y: 11.133236))
            outline.addLine(to: CGPoint(x: 6, y: 21))
        case .fileText:
            outline.move(to: CGPoint(x: 6, y: 22))
            outline.addCurve(to: CGPoint(x: 4, y: 20), control1: CGPoint(x: 4.895431, y: 22), control2: CGPoint(x: 4, y: 21.104569))
            outline.addLine(to: CGPoint(x: 4, y: 4))
            outline.addCurve(to: CGPoint(x: 6, y: 2), control1: CGPoint(x: 4, y: 2.895431), control2: CGPoint(x: 4.895431, y: 2))
            outline.addLine(to: CGPoint(x: 14, y: 2))
            outline.addCurve(to: CGPoint(x: 15.704, y: 2.706), control1: CGPoint(x: 14.639365, y: 1.998964), control2: CGPoint(x: 15.252715, y: 2.253086))
            outline.addLine(to: CGPoint(x: 19.292, y: 6.294))
            outline.addCurve(to: CGPoint(x: 20, y: 8), control1: CGPoint(x: 19.74614, y: 6.745444), control2: CGPoint(x: 20.00104, y: 7.359653))
            outline.addLine(to: CGPoint(x: 20, y: 20))
            outline.addCurve(to: CGPoint(x: 18, y: 22), control1: CGPoint(x: 20, y: 21.104569), control2: CGPoint(x: 19.104569, y: 22))
            outline.addLine(to: CGPoint(x: 6, y: 22))
            outline.closeSubpath()
            outline.move(to: CGPoint(x: 14, y: 2))
            outline.addLine(to: CGPoint(x: 14, y: 7))
            outline.addCurve(to: CGPoint(x: 15, y: 8), control1: CGPoint(x: 14, y: 7.552285), control2: CGPoint(x: 14.447715, y: 8))
            outline.addLine(to: CGPoint(x: 20, y: 8))
            outline.move(to: CGPoint(x: 10, y: 9))
            outline.addLine(to: CGPoint(x: 8, y: 9))
            outline.move(to: CGPoint(x: 16, y: 13))
            outline.addLine(to: CGPoint(x: 8, y: 13))
            outline.move(to: CGPoint(x: 16, y: 17))
            outline.addLine(to: CGPoint(x: 8, y: 17))
        case .copy:
            outline.addRoundedRect(in: CGRect(x: 8, y: 8, width: 14, height: 14), cornerSize: CGSize(width: 2, height: 2))
            outline.move(to: CGPoint(x: 4, y: 16))
            outline.addCurve(to: CGPoint(x: 2, y: 14), control1: CGPoint(x: 2.9, y: 16), control2: CGPoint(x: 2, y: 15.1))
            outline.addLine(to: CGPoint(x: 2, y: 4))
            outline.addCurve(to: CGPoint(x: 4, y: 2), control1: CGPoint(x: 2, y: 2.9), control2: CGPoint(x: 2.9, y: 2))
            outline.addLine(to: CGPoint(x: 14, y: 2))
            outline.addCurve(to: CGPoint(x: 16, y: 4), control1: CGPoint(x: 15.1, y: 2), control2: CGPoint(x: 16, y: 2.9))
        case .save:
            outline.move(to: CGPoint(x: 15.2, y: 3))
            outline.addCurve(to: CGPoint(x: 16.6, y: 3.6), control1: CGPoint(x: 15.727539, y: 3.007514), control2: CGPoint(x: 16.230739, y: 3.223171))
            outline.addLine(to: CGPoint(x: 20.4, y: 7.4))
            outline.addCurve(to: CGPoint(x: 21, y: 8.8), control1: CGPoint(x: 20.776829, y: 7.769261), control2: CGPoint(x: 20.992486, y: 8.272461))
            outline.addLine(to: CGPoint(x: 21, y: 19))
            outline.addCurve(to: CGPoint(x: 19, y: 21), control1: CGPoint(x: 21, y: 20.104569), control2: CGPoint(x: 20.104569, y: 21))
            outline.addLine(to: CGPoint(x: 5, y: 21))
            outline.addCurve(to: CGPoint(x: 3, y: 19), control1: CGPoint(x: 3.895431, y: 21), control2: CGPoint(x: 3, y: 20.104569))
            outline.addLine(to: CGPoint(x: 3, y: 5))
            outline.addCurve(to: CGPoint(x: 5, y: 3), control1: CGPoint(x: 3, y: 3.895431), control2: CGPoint(x: 3.895431, y: 3))
            outline.addLine(to: CGPoint(x: 15.2, y: 3))
            outline.closeSubpath()
            outline.move(to: CGPoint(x: 17, y: 21))
            outline.addLine(to: CGPoint(x: 17, y: 14))
            outline.addCurve(to: CGPoint(x: 16, y: 13), control1: CGPoint(x: 17, y: 13.447715), control2: CGPoint(x: 16.552285, y: 13))
            outline.addLine(to: CGPoint(x: 8, y: 13))
            outline.addCurve(to: CGPoint(x: 7, y: 14), control1: CGPoint(x: 7.447715, y: 13), control2: CGPoint(x: 7, y: 13.447715))
            outline.addLine(to: CGPoint(x: 7, y: 21))
            outline.move(to: CGPoint(x: 7, y: 3))
            outline.addLine(to: CGPoint(x: 7, y: 7))
            outline.addCurve(to: CGPoint(x: 8, y: 8), control1: CGPoint(x: 7, y: 7.552285), control2: CGPoint(x: 7.447715, y: 8))
            outline.addLine(to: CGPoint(x: 15, y: 8))
        case .more:
            outline.addEllipse(in: CGRect(x: 11, y: 11, width: 2, height: 2))
            outline.addEllipse(in: CGRect(x: 18, y: 11, width: 2, height: 2))
            outline.addEllipse(in: CGRect(x: 4, y: 11, width: 2, height: 2))
        case .stop:
            outline.addRoundedRect(in: CGRect(x: 3, y: 3, width: 18, height: 18), cornerSize: CGSize(width: 2, height: 2))
        case .images:
            outline.move(to: CGPoint(x: 22, y: 11))
            outline.addLine(to: CGPoint(x: 20.704, y: 9.704))
            outline.addCurve(to: CGPoint(x: 19, y: 8.994084), control1: CGPoint(x: 20.25336, y: 9.24965), control2: CGPoint(x: 19.63993, y: 8.994084))
            outline.addCurve(to: CGPoint(x: 17.296, y: 9.704), control1: CGPoint(x: 18.36007, y: 8.994084), control2: CGPoint(x: 17.74664, y: 9.24965))
            outline.addLine(to: CGPoint(x: 11, y: 16))
            outline.move(to: CGPoint(x: 4, y: 8))
            outline.addCurve(to: CGPoint(x: 2, y: 10), control1: CGPoint(x: 2.895431, y: 8), control2: CGPoint(x: 2, y: 8.895431))
            outline.addLine(to: CGPoint(x: 2, y: 20))
            outline.addCurve(to: CGPoint(x: 4, y: 22), control1: CGPoint(x: 2, y: 21.104569), control2: CGPoint(x: 2.895431, y: 22))
            outline.addLine(to: CGPoint(x: 14, y: 22))
            outline.addCurve(to: CGPoint(x: 16, y: 20), control1: CGPoint(x: 15.104569, y: 22), control2: CGPoint(x: 16, y: 21.104569))
            fill.addEllipse(in: CGRect(x: 12, y: 6, width: 2, height: 2))
            outline.addRoundedRect(in: CGRect(x: 8, y: 2, width: 14, height: 14), cornerSize: CGSize(width: 2, height: 2))
        case .clipboardText:
            outline.addRoundedRect(in: CGRect(x: 8, y: 2, width: 8, height: 4), cornerSize: CGSize(width: 1, height: 1))
            outline.move(to: CGPoint(x: 16, y: 4))
            outline.addLine(to: CGPoint(x: 18, y: 4))
            outline.addCurve(to: CGPoint(x: 20, y: 6), control1: CGPoint(x: 19.104569, y: 4), control2: CGPoint(x: 20, y: 4.895431))
            outline.addLine(to: CGPoint(x: 20, y: 20))
            outline.addCurve(to: CGPoint(x: 18, y: 22), control1: CGPoint(x: 20, y: 21.104569), control2: CGPoint(x: 19.104569, y: 22))
            outline.addLine(to: CGPoint(x: 6, y: 22))
            outline.addCurve(to: CGPoint(x: 4, y: 20), control1: CGPoint(x: 4.895431, y: 22), control2: CGPoint(x: 4, y: 21.104569))
            outline.addLine(to: CGPoint(x: 4, y: 6))
            outline.addCurve(to: CGPoint(x: 6, y: 4), control1: CGPoint(x: 4, y: 4.895431), control2: CGPoint(x: 4.895431, y: 4))
            outline.addLine(to: CGPoint(x: 8, y: 4))
            outline.move(to: CGPoint(x: 9, y: 12))
            outline.addLine(to: CGPoint(x: 9, y: 11))
            outline.addLine(to: CGPoint(x: 15, y: 11))
            outline.addLine(to: CGPoint(x: 15, y: 12))
            outline.move(to: CGPoint(x: 11, y: 17))
            outline.addLine(to: CGPoint(x: 13, y: 17))
            outline.move(to: CGPoint(x: 12, y: 11))
            outline.addLine(to: CGPoint(x: 12, y: 17))
        case .edit:
            outline.move(to: CGPoint(x: 12, y: 3))
            outline.addLine(to: CGPoint(x: 5, y: 3))
            outline.addCurve(to: CGPoint(x: 3, y: 5), control1: CGPoint(x: 3.895431, y: 3), control2: CGPoint(x: 3, y: 3.895431))
            outline.addLine(to: CGPoint(x: 3, y: 19))
            outline.addCurve(to: CGPoint(x: 5, y: 21), control1: CGPoint(x: 3, y: 20.104569), control2: CGPoint(x: 3.895431, y: 21))
            outline.addLine(to: CGPoint(x: 19, y: 21))
            outline.addCurve(to: CGPoint(x: 21, y: 19), control1: CGPoint(x: 20.104569, y: 21), control2: CGPoint(x: 21, y: 20.104569))
            outline.addLine(to: CGPoint(x: 21, y: 12))
            outline.move(to: CGPoint(x: 18.375, y: 2.625))
            outline.addCurve(to: CGPoint(x: 21.375, y: 2.625), control1: CGPoint(x: 19.203427, y: 1.796573), control2: CGPoint(x: 20.546573, y: 1.796573))
            outline.addCurve(to: CGPoint(x: 21.375, y: 5.625), control1: CGPoint(x: 22.203427, y: 3.453427), control2: CGPoint(x: 22.203427, y: 4.796573))
            outline.addLine(to: CGPoint(x: 12.362, y: 14.639))
            outline.addCurve(to: CGPoint(x: 11.509, y: 15.144), control1: CGPoint(x: 12.124549, y: 14.876246), control2: CGPoint(x: 11.831206, y: 15.049914))
            outline.addLine(to: CGPoint(x: 8.636, y: 15.984))
            outline.addCurve(to: CGPoint(x: 8.142447, y: 15.857553), control1: CGPoint(x: 8.460735, y: 16.035119), control2: CGPoint(x: 8.271541, y: 15.986648))
            outline.addCurve(to: CGPoint(x: 8.016, y: 15.364), control1: CGPoint(x: 8.013352, y: 15.728459), control2: CGPoint(x: 7.964881, y: 15.539265))
            outline.addLine(to: CGPoint(x: 8.856, y: 12.491))
            outline.addCurve(to: CGPoint(x: 9.362, y: 11.639), control1: CGPoint(x: 8.950526, y: 12.169051), control2: CGPoint(x: 9.124534, y: 11.876058))
            outline.addLine(to: CGPoint(x: 18.375, y: 2.625))
            outline.closeSubpath()
        case .capture:
            outline.move(to: CGPoint(x: 3, y: 7))
            outline.addLine(to: CGPoint(x: 3, y: 5))
            outline.addCurve(to: CGPoint(x: 5, y: 3), control1: CGPoint(x: 3, y: 3.895431), control2: CGPoint(x: 3.895431, y: 3))
            outline.addLine(to: CGPoint(x: 7, y: 3))
            outline.move(to: CGPoint(x: 17, y: 3))
            outline.addLine(to: CGPoint(x: 19, y: 3))
            outline.addCurve(to: CGPoint(x: 21, y: 5), control1: CGPoint(x: 20.104569, y: 3), control2: CGPoint(x: 21, y: 3.895431))
            outline.addLine(to: CGPoint(x: 21, y: 7))
            outline.move(to: CGPoint(x: 21, y: 17))
            outline.addLine(to: CGPoint(x: 21, y: 19))
            outline.addCurve(to: CGPoint(x: 19, y: 21), control1: CGPoint(x: 21, y: 20.104569), control2: CGPoint(x: 20.104569, y: 21))
            outline.addLine(to: CGPoint(x: 17, y: 21))
            outline.move(to: CGPoint(x: 7, y: 21))
            outline.addLine(to: CGPoint(x: 5, y: 21))
            outline.addCurve(to: CGPoint(x: 3, y: 19), control1: CGPoint(x: 3.895431, y: 21), control2: CGPoint(x: 3, y: 20.104569))
            outline.addLine(to: CGPoint(x: 3, y: 17))
            outline.move(to: CGPoint(x: 7, y: 12))
            outline.addLine(to: CGPoint(x: 17, y: 12))
        }
        return (outline, fill)
    }

    func image(size: CGFloat = 16, color: NSColor? = nil) -> NSImage {
        let paths = paths
        let viewport = CGRect(x: 0, y: 0, width: 24, height: 24)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / viewport.width, y: rect.height / viewport.height)
            context.translateBy(x: -viewport.minX, y: -viewport.minY)
            context.setStrokeColor((color ?? .black).cgColor)
            context.setFillColor((color ?? .black).cgColor)
            context.setLineWidth(1.7)
            context.setLineCap(.round); context.setLineJoin(.round)
            context.addPath(paths.outline.cgPath); context.strokePath()
            context.addPath(paths.fill.cgPath); context.fillPath()
            context.restoreGState()
            return true
        }
        image.isTemplate = color == nil
        return image
    }
}

struct ScreenshotToolbarSymbol: View {
    let icon: ScreenshotToolbarIcon
    private var size: CGFloat { icon == .stop ? 11.6 : 18 }
    var body: some View {
        Image(nsImage: icon.image(size: size)).renderingMode(.template).frame(width: size, height: size).accessibilityHidden(true)
    }
}
