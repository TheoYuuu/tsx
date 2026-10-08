import AppKit

/// Original sample pixels built in memory, then processed by shipping Vision OCR.
/// No user image or text is loaded, saved or sent to an API.
@MainActor
enum ScreenshotReviewFixture {
    static func document(menu: Bool = false, dense: Bool = false) async throws -> ScreenshotDocument {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 1100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedWhite: menu ? 0.97 : 1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 900, height: 1100).fill()
        func line(_ text: String, y: CGFloat, size: CGFloat = 28, x: CGFloat = 65) {
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor(calibratedWhite: 0.14, alpha: 1)])
        }
        if menu {
            line("QUIET CAFE", y: 970, size: 48)
            line("COFFEE", y: 840, size: 36)
            line("Espresso", y: 770); line("$3.00", y: 770, x: 690)
            line("Flat White", y: 690); line("$4.50", y: 690, x: 690)
            line("A smooth coffee with warm steamed milk", y: 620, size: 24)
            line("TEA", y: 470, size: 36)
            line("Jasmine Tea", y: 390); line("$3.50", y: 390, x: 690)
            line("Fresh citrus and fragrant green tea", y: 320, size: 24)
            line("Ask about today's selection.", y: 140, size: 24)
        } else if dense {
            line("Reading a long passage", y: 990, size: 40)
            for (index, text) in ["A long passage should keep its original rhythm.",
                "Each wrapped line belongs to the same paragraph.", "The translated font follows the source line size.",
                "Extra words use the space inside that paragraph.", "No artificial two-line limit leaves a large gap.",
                "The complete translation remains available to edit."].enumerated() {
                line(text, y: 865 - CGFloat(index) * 42)
            }
            line("> Keep each quotation on its own line.", y: 530)
            line("Its continuation belongs to the same item.", y: 488)
            line("> A second item keeps its own boundary.", y: 446)
            line("Readable spacing supports careful comparison.", y: 290)
            line("Return to this result whenever you need it.", y: 160)
        } else {
            line("Make room for words", y: 960, size: 46)
            line("A note on reading and design", y: 890, size: 24)
            line("Good design keeps useful tools close.", y: 760)
            line("It leaves more space for the conversation.", y: 715)
            line("A calmer workspace", y: 575, size: 36)
            line("• Keep the original image", y: 500)
            line("• Edit a translated paragraph", y: 450)
            line("• Compare words in their context", y: 400)
            line("Small details make reading easier.", y: 225)
        }
        NSGraphicsContext.restoreGraphicsState()
        return try await OCRService().recognizeDocument(bitmap.cgImage!)
    }
}

@MainActor
struct ScreenshotReviewProvider: TranslationProvider {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let translations = [
            "Reading a long": "阅读一段较长的文字",
            "A long passage": "较长的文字也应该保留原有的阅读节奏。自动换行仍属于同一个段落，译文字号依据截图中每一行文字的实际高度计算。较长的中文内容会使用段落内现有的空间，不会因为固定只显示两行而留下大片空白。完整的译文依然可以打开查看和修改，每个段落的位置也保持稳定，方便读者对照原文，继续阅读并调整用词。",
            "Keep each quotation": "> 每段引用保持各自的换行，续行仍属于同一个引用条目。",
            "A second item": "> 第二个条目保留独立边界。",
            "Readable spacing": "自然的行距，让逐段对照更轻松。",
            "Return to this": "需要时，可以再次打开这份翻译结果。",
            "Make room": "给文字更多空间", "A note": "阅读与设计札记", "Good design": "好的设计让常用工具触手可及，也为交流留下更多空间。",
            "A calmer": "更从容的工作区", "Keep the original": "• 保留截图原图", "Edit a translated": "• 修改段落译文", "Compare words": "• 在原来的位置对照文字",
            "Small details": "细微的调整，让阅读更轻松。", "QUIET": "宁静咖啡馆", "COFFEE": "咖啡", "Espresso": "浓缩咖啡", "Flat White": "馥芮白",
            "A smooth": "温热的蒸汽牛奶与醇厚咖啡融合，口感细腻柔滑。这条较长的译文用于检查原图覆盖区域的省略与完整详情。",
            "TEA": "茶饮", "Jasmine": "茉莉花茶", "Fresh citrus": "清新的柑橘与芬芳的绿茶", "Ask about": "欢迎询问今日精选。"
        ]
        let output = translations.first(where: { request.text.contains($0.key) })?.value ?? request.text
        return TranslationResult(text: output, source: request.source, target: request.target)
    }
}
