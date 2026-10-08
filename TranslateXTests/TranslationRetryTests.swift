import XCTest
@testable import TranslateX

@MainActor
final class TranslationRetryTests: XCTestCase {
    func testCancelledInputCanRetryItsOriginalTextAndLanguages() throws {
        let model = translatingModel()
        let cancelled = try XCTUnwrap(model.request)
        model.cancel()
        let view = TranslationResultView(model: model)
        view.retryTranslation()
        let restarted = try XCTUnwrap(model.request)
        XCTAssertNotEqual(restarted.id, cancelled.id)
        XCTAssertEqual(restarted.text, cancelled.text)
        XCTAssertEqual(restarted.source, cancelled.source)
        XCTAssertEqual(restarted.target, cancelled.target)
        XCTAssertEqual(model.phase, .translating)
    }

    func testCancelledQuickResultUsesItsSuppliedRetryRoute() throws {
        let model = translatingModel()
        let previous = try XCTUnwrap(model.request)
        model.cancel()
        var retries = 0
        let view = TranslationResultView(model: model, retry: {
            retries += 1
            model.submit()
        })
        view.retryTranslation()
        XCTAssertEqual(retries, 1)
        XCTAssertNotEqual(model.request?.id, previous.id)
        XCTAssertEqual(model.request?.text, previous.text)
    }

    func testCancelledRecognitionWithNoTextCallsScreenshotRetryRoute() {
        let model = TranslationModel()
        model.beginRecognition()
        model.cancel()
        XCTAssertFalse(model.canTranslate)
        var screenshotRetries = 0
        let view = TranslationResultView(model: model, retry: {
            screenshotRetries += 1
        })
        view.retryTranslation()
        XCTAssertEqual(screenshotRetries, 1)
        XCTAssertNil(model.request, "Empty OCR content must not submit a translation instead of retrying its entry")
    }

    func testFailedTranslationKeepsItsExistingRetryBehavior() {
        let model = translatingModel()
        model.fail("A synthetic recoverable error")
        let view = TranslationResultView(model: model)
        view.retryTranslation()
        XCTAssertEqual(model.request?.text, "A quiet morning.")
        XCTAssertEqual(model.phase, .translating)
    }

    func testCancelledLanguagePreparationCanRestartWithoutEditingThePassage() async throws {
        let model = translatingModel()
        let original = try XCTUnwrap(model.request)
        model.markPreparing(original)
        await model.run(original, provider: CancelledPreparationProvider())
        XCTAssertEqual(model.phase, .cancelled)
        TranslationResultView(model: model).retryTranslation()
        XCTAssertNotEqual(model.request?.id, original.id)
        XCTAssertEqual(model.request?.text, original.text)
        XCTAssertEqual(model.phase, .translating)
    }

    func testLateCancelledSuccessOrFailureCannotOverwriteRetriedCompletion() async throws {
        let lateOutcomes: [Result<TranslationResult, any Error>] = [
            .success(TranslationResult(text: "Outdated response", source: "en", target: "fr")),
            .failure(URLError(.notConnectedToInternet))
        ]
        for lateOutcome in lateOutcomes {
            let model = translatingModel()
            let original = try XCTUnwrap(model.request)
            let deferred = DeferredRetryProvider()
            let oldTask = Task { await model.run(original, provider: deferred) }
            await deferred.waitUntilStarted()
            model.cancel()
            TranslationResultView(model: model).retryTranslation()
            let replacement = try XCTUnwrap(model.request)
            let currentResult = TranslationResult(text: "Un matin calme.", source: "en", target: "fr")
            await model.run(replacement, provider: CompletedRetryProvider(result: currentResult))
            deferred.finish(lateOutcome)
            await oldTask.value
            XCTAssertNotEqual(replacement.id, original.id)
            XCTAssertEqual(model.request?.id, replacement.id)
            XCTAssertEqual(model.result, currentResult)
            XCTAssertEqual(model.phase, .completed)
        }
    }

    private func translatingModel() -> TranslationModel {
        let model = TranslationModel()
        model.source = "en"
        model.target = "fr"
        model.text = "A quiet morning."
        model.submit()
        return model
    }
}

@MainActor
private struct CancelledPreparationProvider: TranslationProvider {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        throw CocoaError(.userCancelled)
    }
}

@MainActor
private struct CompletedRetryProvider: TranslationProvider {
    let result: TranslationResult
    func translate(_ request: TranslationRequest) async throws -> TranslationResult { result }
}

@MainActor
private final class DeferredRetryProvider: TranslationProvider {
    private var continuation: CheckedContinuation<TranslationResult, any Error>?

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        for _ in 0..<500 {
            if continuation != nil { return }
            await Task.yield()
        }
        XCTFail("Provider did not start")
    }

    func finish(_ result: Result<TranslationResult, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
