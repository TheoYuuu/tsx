import CoreGraphics
import Foundation

struct ScreenshotRegion: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable { case paragraph, heading, listItem, price }
    let id: UUID
    var text: String
    /// Vision coordinates, normalized to the original image, bottom-left origin.
    let bounds: CGRect
    let confidence: Float
    let role: Role
    let separator: String
    /// Individual visual lines, kept even when OCR wraps are joined into a paragraph.
    var lineBounds: [CGRect] = []
}

/// Pixels stay in memory. Region IDs, not output line counts or text guesses,
/// connect a translated paragraph to its original image position.
struct ScreenshotDocument: Equatable, Sendable {
    let id: UUID
    let image: CGImage
    var regions: [ScreenshotRegion]
    var translations: [UUID: String] = [:]

    init(image: CGImage, regions: [ScreenshotRegion] = []) {
        id = UUID()
        self.image = image
        self.regions = regions
    }

    init(image: CGImage, blocks: [OCRTextBlock]) throws {
        let rows = try OCRReadingOrder.rows(from: blocks, imageAspectRatio: CGFloat(image.width) / CGFloat(image.height))
        let heights = rows.map(\.bounds.height).sorted()
        let bodyHeight = heights[heights.count / 2]
        var regions: [ScreenshotRegion] = []
        var previousRow: OCRReadingOrder.Row?
        for row in rows {
            let fragments = row.blocks.sorted { $0.bounds.minX < $1.bounds.minX }
            if fragments.count > 1, let price = fragments.last, price.isPrice,
               fragments.dropLast().contains(where: { !$0.isPrice }) {
                let label = fragments.dropLast()
                regions.append(ScreenshotRegion(id: UUID(), text: label.map(\.text).joined(separator: " "),
                    bounds: label.reduce(CGRect.null) { $0.union($1.bounds) }, confidence: label.map(\.confidence).min() ?? 0,
                    role: .paragraph, separator: regions.isEmpty ? "" : "\n\n", lineBounds: [row.bounds]))
                regions.append(ScreenshotRegion(id: UUID(), text: price.text, bounds: price.bounds,
                    confidence: price.confidence, role: .price, separator: "\t", lineBounds: [price.bounds]))
                previousRow = nil
                continue
            }
            let text = OCRReadingOrder.rowText(row)
            let isList = text.range(of: #"^(?:(?:[•●▪◦‣–-]|\d+[.)])\s+|>\s*)"#, options: .regularExpression) != nil
            let role: ScreenshotRegion.Role = isList ? .listItem : rows.count >= 3 && row.bounds.height > bodyHeight * 1.3 ? .heading : .paragraph
            let confidence = row.blocks.map(\.confidence).min() ?? 0
            // Join visual wraps only with positive geometric evidence: same
            // indentation and font height, nearby, no list or multiple columns.
            let joinsPrevious: Bool
            if let previousRow, let previous = regions.last {
                joinsPrevious = role == .paragraph && (previous.role == .paragraph || previous.role == .listItem) && row.separator == "\n"
                    && abs(previousRow.bounds.minX - row.bounds.minX) < 0.018
                    && abs(previousRow.bounds.height - row.bounds.height) < bodyHeight * 0.25
                    && previousRow.blocks.count == 1 && row.blocks.count == 1
            } else { joinsPrevious = false }
            if joinsPrevious, let previous = regions.popLast() {
                let join = Self.wrapSeparator(previous.text, text)
                regions.append(ScreenshotRegion(id: previous.id, text: previous.text + join + text,
                    bounds: previous.bounds.union(row.bounds), confidence: min(previous.confidence, confidence),
                    role: previous.role, separator: previous.separator, lineBounds: previous.lineBounds + [row.bounds]))
            } else {
                regions.append(ScreenshotRegion(id: UUID(), text: text, bounds: row.bounds, confidence: confidence,
                    role: role, separator: regions.isEmpty ? "" : role == .listItem && regions.last?.role == .listItem ? "\n" : "\n\n", lineBounds: [row.bounds]))
            }
            previousRow = row
        }
        self.init(image: image, regions: regions)
        guard sourceText.count <= SelectionText.maximumLength else { throw OCRError.tooMuchText }
    }

    struct ReadingGroup: Identifiable {
        let id: UUID
        var regions: [ScreenshotRegion]
    }
    var readingGroups: [ReadingGroup] {
        var groups: [ReadingGroup] = []
        for region in regions {
            if region.role == .price, !groups.isEmpty { groups[groups.count - 1].regions.append(region) }
            else { groups.append(ReadingGroup(id: region.id, regions: [region])) }
        }
        return groups
    }

    var sourceText: String { regions.map { $0.separator + $0.text }.joined() }
    var translatedText: String { regions.map { $0.separator + (translations[$0.id] ?? "") }.joined() }
    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.regions == rhs.regions && lhs.translations == rhs.translations
    }

    /// The image itself never reflows. All regions use this same fitted scale.
    static func fittedSize(image: CGSize, available: CGSize, zoom: CGFloat = 1) -> CGSize {
        guard image.width > 0, image.height > 0, available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / image.width, available.height / image.height) * zoom
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
    static func displayBounds(_ bounds: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: bounds.minX * size.width, y: (1 - bounds.maxY) * size.height,
               width: bounds.width * size.width, height: bounds.height * size.height)
    }
    private static func wrapSeparator(_ first: String, _ second: String) -> String {
        if let last = first.unicodeScalars.last, let next = second.unicodeScalars.first,
           (0x3400...0x9fff).contains(last.value), (0x3400...0x9fff).contains(next.value) { return "" }
        return " "
    }
}
