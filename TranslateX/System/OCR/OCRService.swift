import CoreGraphics
import Vision

enum OCRError: Error, Equatable, Sendable {
    case noText
    case recognitionFailed
    case tooMuchText
}

/// Await Vision's Swift API so task cancellation reaches the system request and a
/// replacement does not queue behind synchronous work on this actor.
actor OCRService {
    private let recognition: @Sendable (CGImage) async throws -> [OCRTextBlock]

    init(recognition: @escaping @Sendable (CGImage) async throws -> [OCRTextBlock] = OCRService.performVisionRecognition) {
        self.recognition = recognition
    }

    func recognize(_ image: CGImage) async throws -> String {
        let text = try await recognizedBlocks(image).mapText(image: image)
        try Task.checkCancellation()
        return text
    }

    func recognizeDocument(_ image: CGImage) async throws -> ScreenshotDocument {
        let blocks = try await recognizedBlocks(image)
        let document = try ScreenshotDocument(image: image, blocks: blocks)
        try Task.checkCancellation()
        return document
    }

    private func recognizedBlocks(_ image: CGImage) async throws -> [OCRTextBlock] {
        try Task.checkCancellation()
        let blocks: [OCRTextBlock]
        do {
            blocks = try await recognition(image)
        } catch {
            try Task.checkCancellation()
            // Vision errors may describe the input. Keep those details out of UI and logs.
            throw OCRError.recognitionFailed
        }
        try Task.checkCancellation()
        return blocks
    }

    private static func performVisionRecognition(_ image: CGImage) async throws -> [OCRTextBlock] {
        var request = RecognizeTextRequest(.revision3)
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let observations = try await request.perform(on: image)
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRTextBlock(text: candidate.string, bounds: observation.boundingBox.cgRect, confidence: candidate.confidence)
        }
    }
}

private extension Array where Element == OCRTextBlock {
    func mapText(image: CGImage) throws -> String {
        try OCRReadingOrder.text(from: self, imageAspectRatio: CGFloat(image.width) / CGFloat(image.height))
    }
}
