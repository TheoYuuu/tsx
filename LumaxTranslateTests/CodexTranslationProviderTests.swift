import XCTest
@testable import LumaxTranslate

@MainActor
final class CodexTranslationProviderTests: XCTestCase {
    func testMissingControllerOrGenerationCannotCreateAReplacementAccount() async {
        let fixture = CodexControllerSessionFixture(); let controller = fixture.controller()
        for provider in [CodexTranslationProvider(controller: nil, model: fixture.model.id, generation: fixture.generation),
                         .init(controller: controller, model: fixture.model.id, generation: nil)] {
            do { _ = try await provider.translate(fixture.translation()); XCTFail("Missing binding must fail.") }
            catch { XCTAssertNotNil(error as? CodexAccountError) }
        }
        XCTAssertEqual(fixture.created, 0)
    }

    func testUnknownStateUsesSavedBindingAndPreservesUnknownSource() async throws {
        let fixture = CodexControllerSessionFixture(); let controller = fixture.controller()
        let provider = CodexTranslationProvider(controller: controller, model: fixture.model.id, generation: fixture.generation)
        let request = fixture.translation("  source\n")
        let task = Task { try await provider.translate(request) }
        try await fixture.waitForRequests(1)
        XCTAssertEqual(fixture.requests[0].expectedGeneration, fixture.generation)
        XCTAssertEqual(fixture.requests[0].text, request.text)
        XCTAssertEqual(fixture.requests[0].model, fixture.model.id)
        try fixture.finish(0, status: "ok", text: "  译文\n")
        let result = try await task.value
        XCTAssertNil(result.source)
        XCTAssertEqual(result.text, "  译文\n")
        XCTAssertEqual(result.target, request.target)
    }

    func testMultibyteInputAboveByteLimitFailsBeforeStartingAccountRequest() async {
        let fixture = CodexControllerSessionFixture(); let controller = fixture.controller()
        let provider = CodexTranslationProvider(controller: controller, model: fixture.model.id, generation: fixture.generation)
        let text = String(repeating: "中", count: 22_000)
        XCTAssertLessThan(text.count, SelectionText.maximumLength)
        XCTAssertGreaterThan(text.utf8.count, 65_536)
        do { _ = try await provider.translate(fixture.translation(text)); XCTFail("Oversized input must fail.") }
        catch { XCTAssertEqual(error as? RemoteTranslationError, .inputTooLarge) }
        XCTAssertEqual(fixture.created, 0)
        XCTAssertFalse(controller.hasActiveOperation)
    }

    func testWhitespaceAndInvalidModelsRetainConfigurationErrorBeforeSizeCheck() async {
        let fixture = CodexControllerSessionFixture(); let controller = fixture.controller()
        let text = String(repeating: "中", count: 22_000)
        let whitespace = String(repeating: "　", count: 22_000)
        for (model, input) in [(fixture.model.id, whitespace), (" ", text),
                               (String(repeating: "m", count: 257), text), ("invalid\nmodel", text)] {
            let provider = CodexTranslationProvider(controller: controller, model: model, generation: fixture.generation)
            do { _ = try await provider.translate(fixture.translation(input)); XCTFail("Invalid input must fail.") }
            catch { XCTAssertEqual(error as? CodexAccountError, .invalidConfiguration) }
        }
        XCTAssertEqual(fixture.created, 0)
    }

    func testKnownDifferentGenerationRejectsWithoutSendingSource() async throws {
        let fixture = CodexControllerSessionFixture(); let controller = fixture.controller()
        try await fixture.signInStatus(controller)
        let provider = CodexTranslationProvider(controller: controller, model: fixture.model.id, generation: fixture.otherGeneration)
        do { _ = try await provider.translate(fixture.translation()); XCTFail("Stale account must fail.") }
        catch { XCTAssertEqual(error as? CodexAccountError, .accountChanged) }
        XCTAssertEqual(fixture.requests.map(\.operation), [.status])
    }

    func testTaskCancellationReapsItsOwnTranslationAndDiscardsLateText() async throws {
        let fixture = CodexControllerSessionFixture(); let controller = fixture.controller()
        let provider = CodexTranslationProvider(controller: controller, model: fixture.model.id, generation: fixture.generation)
        let task = Task { try await provider.translate(fixture.translation(source: "en")) }
        try await fixture.waitForRequests(1)
        task.cancel()
        await fixture.waitForCancellation()
        XCTAssertTrue(controller.hasActiveOperation)
        try fixture.finish(0, status: "ok", text: "late result")
        do { _ = try await task.value; XCTFail("Cancelled result must not escape.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(controller.hasActiveOperation)
    }
}
