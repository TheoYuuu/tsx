import Foundation

struct OCRTextBlock: Equatable, Sendable {
    let text: String
    /// Vision's normalized image coordinates: origin at the bottom left.
    let bounds: CGRect
    var confidence: Float = 1
    var isPrice: Bool {
        text.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
            && !text.unicodeScalars.contains(where: CharacterSet.letters.contains)
    }
}

/// Conservative geometric ordering for left-to-right horizontal layouts. Clear column gutters are
/// read column by column; otherwise lines remain top-to-bottom with their breaks.
/// This is not document-layout analysis for tables, vertical text or complex pages.
enum OCRReadingOrder {
    static func text(from blocks: [OCRTextBlock], imageAspectRatio: CGFloat = 1) throws -> String {
        try rows(from: blocks, imageAspectRatio: imageAspectRatio).map { $0.separator + rowText($0) }.joined()
    }

    static func rows(from blocks: [OCRTextBlock], imageAspectRatio: CGFloat = 1) throws -> [Row] {
        let valid = blocks.compactMap { block -> OCRTextBlock? in
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let box = block.bounds
            guard !text.isEmpty, box.minX.isFinite, box.minY.isFinite,
                  box.width.isFinite, box.height.isFinite,
                  box.width > 0, box.height > 0 else { return nil }
            let clipped = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !clipped.isNull, !clipped.isEmpty else { return nil }
            return OCRTextBlock(text: text, bounds: clipped, confidence: block.confidence)
        }
        guard !valid.isEmpty else { throw OCRError.noText }
        var characterCount = 0
        for block in valid {
            characterCount += block.text.count
            guard characterCount <= SelectionText.maximumLength else { throw OCRError.tooMuchText }
        }
        let aspect = imageAspectRatio.isFinite && imageAspectRatio > 0 ? imageAspectRatio : 1
        let result = arrange(valid, aspect: aspect, depth: 0)
        guard result.map({ $0.separator + rowText($0) }).joined().count <= SelectionText.maximumLength else { throw OCRError.tooMuchText }
        return result
    }

    private static func arrange(_ blocks: [OCRTextBlock], aspect: CGFloat, depth: Int) -> [Row] {
        let rows = makeRows(blocks)
        if depth < 8 {
            if let columns = splitColumns(blocks, aspect: aspect) {
                return arrange(columns.left, aspect: aspect, depth: depth + 1)
                    + separated(arrange(columns.right, aspect: aspect, depth: depth + 1))
            }
            // A full-width heading/footer must not make two clear body columns interleave.
            if rows.count > 2 {
                let width = bounds(of: blocks).width
                if rows.count > 3, let first = rows.first, let last = rows.last,
                   first.blocks.count == 1, first.bounds.width >= width * 0.7,
                   last.blocks.count == 1, last.bounds.width >= width * 0.7 {
                    let body = rows.dropFirst().dropLast().flatMap(\.blocks)
                    if splitColumns(body, aspect: aspect) != nil {
                        return [first] + separated(arrange(body, aspect: aspect, depth: depth + 1)) + separated([last])
                    }
                }
                if let first = rows.first, first.blocks.count == 1, first.bounds.width >= width * 0.7 {
                    let rest = rows.dropFirst().flatMap(\.blocks)
                    if splitColumns(rest, aspect: aspect) != nil {
                        return [first] + separated(arrange(rest, aspect: aspect, depth: depth + 1))
                    }
                }
                if let last = rows.last, last.blocks.count == 1, last.bounds.width >= width * 0.7 {
                    let rest = rows.dropLast().flatMap(\.blocks)
                    if splitColumns(rest, aspect: aspect) != nil {
                        return arrange(rest, aspect: aspect, depth: depth + 1) + separated([last])
                    }
                }
            }
        }
        var result: [Row] = []
        for (index, originalRow) in rows.enumerated() {
            var row = originalRow
            if index > 0 {
                let previous = rows[index - 1]
                let gap = previous.bounds.minY - row.bounds.maxY
                let lineHeight = max(previous.bounds.height, row.bounds.height)
                row.separator = gap > lineHeight * 0.9 ? "\n\n" : "\n"
            }
            result.append(row)
        }
        return result
    }

    private static func separated(_ rows: [Row]) -> [Row] {
        var value = rows
        if !value.isEmpty { value[0].separator = "\n\n" }
        return value
    }

    struct Row {
        var separator = ""
        var blocks: [OCRTextBlock]
        var bounds: CGRect
    }

    private static func makeRows(_ blocks: [OCRTextBlock]) -> [Row] {
        let sorted = blocks.sorted {
            if $0.bounds.maxY != $1.bounds.maxY { return $0.bounds.maxY > $1.bounds.maxY }
            if $0.bounds.minX != $1.bounds.minX { return $0.bounds.minX < $1.bounds.minX }
            return $0.text < $1.text
        }
        var rows: [Row] = []
        for block in sorted {
            if let last = rows.last {
                let overlap = min(last.bounds.maxY, block.bounds.maxY) - max(last.bounds.minY, block.bounds.minY)
                if overlap >= min(last.bounds.height, block.bounds.height) * 0.6 {
                    rows[rows.count - 1].blocks.append(block)
                    rows[rows.count - 1].bounds = last.bounds.union(block.bounds)
                    continue
                }
            }
            rows.append(Row(blocks: [block], bounds: block.bounds))
        }
        return rows
    }

    static func rowText(_ row: Row) -> String {
        row.blocks.sorted {
            if $0.bounds.minX != $1.bounds.minX { return $0.bounds.minX < $1.bounds.minX }
            return $0.text < $1.text
        }.map(\.text).joined(separator: " ")
    }

    private static func splitColumns(
        _ blocks: [OCRTextBlock], aspect: CGFloat
    ) -> (left: [OCRTextBlock], right: [OCRTextBlock])? {
        guard blocks.count >= 4 else { return nil }
        let sorted = blocks.sorted { $0.bounds.minX < $1.bounds.minX }
        let heights = blocks.map(\.bounds.height).sorted()
        // Convert a horizontal normalized gap into image-height units before comparing.
        let minimumGap = max(0.025, heights[heights.count / 2] * 1.5 / aspect)
        var rightEdge = sorted[0].bounds.maxX
        var best: (index: Int, gap: CGFloat)?
        for index in 1..<sorted.count {
            let block = sorted[index]
            let gap = block.bounds.minX - rightEdge
            if gap >= minimumGap, gap > (best?.gap ?? 0) {
                let left = Array(sorted[..<index])
                let right = Array(sorted[index...])
                let leftBounds = bounds(of: left)
                let rightBounds = bounds(of: right)
                let overlap = min(leftBounds.maxY, rightBounds.maxY) - max(leftBounds.minY, rightBounds.minY)
                // Two separated pieces of one line are fragments, not columns.
                if !right.allSatisfy(\.isPrice), makeRows(left).count >= 2, makeRows(right).count >= 2,
                   overlap >= min(leftBounds.height, rightBounds.height) * 0.5 {
                    best = (index, gap)
                }
            }
            rightEdge = max(rightEdge, block.bounds.maxX)
        }
        guard let best else { return nil }
        return (Array(sorted[..<best.index]), Array(sorted[best.index...]))
    }

    private static func bounds(of blocks: [OCRTextBlock]) -> CGRect {
        blocks.reduce(CGRect.null) { $0.union($1.bounds) }
    }
}
