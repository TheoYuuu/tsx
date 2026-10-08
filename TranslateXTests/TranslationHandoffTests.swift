import AppKit
import XCTest
@testable import TranslateX

@MainActor
final class TranslationHandoffTests: XCTestCase {
    func testCompletedPassageKeepsTextAndLanguagesWithoutTransferringARequest() async throws {
        let quick = passage(source: "en", target: "zh-Hans", text: "  A quiet morning.\n")
        let translated = TranslationResult(text: "安静的早晨。", source: "en", target: "zh-Hans")
        await quick.run(try XCTUnwrap(quick.request), provider: HandoffProvider(result: translated))
        let snapshot = try XCTUnwrap(quick.makeHandoff())
        quick.cancel() // The panel closes before the receiving workspace uses its snapshot.

        let input = passage(source: "ja", target: "en", text: "以前の文章")
        input.acceptHandoff(snapshot)
        XCTAssertEqual(input.text, "  A quiet morning.\n")
        XCTAssertEqual(input.source, "en")
        XCTAssertEqual(input.target, "zh-Hans")
        XCTAssertEqual(input.result, translated)
        XCTAssertEqual(input.phase, .completed)
        XCTAssertNil(input.request)
        XCTAssertNil(input.configuration)
    }

    func testAutomaticSourceRemainsAutomaticWhileKeepingDetectedResultLanguage() async throws {
        let quick = passage(source: "auto", target: "zh-Hans", text: "The bright morning sun shines through the window.")
        let request = try XCTUnwrap(quick.request)
        let translated = TranslationResult(text: "明亮的晨光照进窗户。", source: "en", target: "zh-Hans")
        await quick.run(request, provider: HandoffProvider(result: translated))
        let input = TranslationModel()
        input.acceptHandoff(quick.makeHandoff())
        XCTAssertEqual(input.source, "auto")
        XCTAssertEqual(input.result, translated)
        XCTAssertTrue(input.canSwapLanguages)
        XCTAssertNil(input.configuration)
    }

    func testPendingPassageMovesItsLanguagePairWithoutResubmitting() throws {
        let quick = passage(source: "en", target: "fr", text: "A quiet morning.")
        let snapshot = try XCTUnwrap(quick.makeHandoff())
        XCTAssertNil(snapshot.completedResult)
        quick.cancel()
        let input = passage(source: "ja", target: "en", text: "以前の文章")
        input.acceptHandoff(snapshot)
        XCTAssertNil(input.request)
        XCTAssertEqual(input.text, "A quiet morning.")
        XCTAssertEqual(input.source, "en")
        XCTAssertEqual(input.target, "fr")
        XCTAssertEqual(input.phase, .cancelled)
        XCTAssertNil(input.result)
    }

    func testEditedContentCannotCarryAnEarlierCompletedResult() async throws {
        let quick = passage(source: "en", target: "fr", text: "First passage.")
        await quick.run(try XCTUnwrap(quick.request), provider: HandoffProvider(
            result: TranslationResult(text: "Premier passage.", source: "en", target: "fr")
        ))
        quick.text = "Different passage."
        let snapshot = try XCTUnwrap(quick.makeHandoff())
        XCTAssertNil(snapshot.completedResult)
        let input = TranslationModel()
        input.acceptHandoff(snapshot)
        XCTAssertEqual(input.text, "Different passage.")
        XCTAssertNil(input.request)
        XCTAssertNil(input.result)
    }

    func testChangedLanguageCannotCarryAnEarlierCompletedResult() async throws {
        let quick = passage(source: "en", target: "fr", text: "A quiet morning.")
        await quick.run(try XCTUnwrap(quick.request), provider: HandoffProvider(
            result: TranslationResult(text: "Un matin calme.", source: "en", target: "fr")
        ))
        quick.target = "de"
        let snapshot = try XCTUnwrap(quick.makeHandoff())
        XCTAssertNil(snapshot.completedResult)
        let input = TranslationModel()
        input.acceptHandoff(snapshot)
        XCTAssertEqual(input.target, "de")
        XCTAssertNil(input.request)
        XCTAssertNil(input.result)
    }

    func testMismatchedResultLanguagesAreNotReused() async throws {
        for result in [
            TranslationResult(text: "Different target", source: "en", target: "de"),
            TranslationResult(text: "Different source", source: "ja", target: "fr")
        ] {
            let quick = passage(source: "en", target: "fr", text: "A quiet morning.")
            await quick.run(try XCTUnwrap(quick.request), provider: HandoffProvider(result: result))
            let snapshot = try XCTUnwrap(quick.makeHandoff())
            XCTAssertNil(snapshot.completedResult)
            let input = TranslationModel()
            input.acceptHandoff(snapshot)
            XCTAssertEqual(input.phase, .empty)
            XCTAssertNil(input.result)
        }
    }

    func testEquivalentCanonicalResultLanguagesCanBeReused() async throws {
        let quick = passage(source: "en", target: "zh-Hans", text: "A quiet morning.")
        let translated = TranslationResult(text: "安静的早晨。", source: "en-US", target: "zh-CN")
        await quick.run(try XCTUnwrap(quick.request), provider: HandoffProvider(result: translated))
        XCTAssertEqual(quick.makeHandoff()?.completedResult, translated)
    }

    func testCancellingAfterCompletionKeepsTheVerifiedSnapshotReusable() async throws {
        let quick = passage(source: "en", target: "fr", text: "A quiet morning.")
        await quick.run(try XCTUnwrap(quick.request), provider: HandoffProvider(
            result: TranslationResult(text: "Un matin calme.", source: "en", target: "fr")
        ))
        quick.cancel()
        XCTAssertNotNil(quick.result)
        XCTAssertEqual(try XCTUnwrap(quick.makeHandoff()).completedResult, quick.result)
    }

    func testSameLanguagePassageKeepsBothSyncedSidesAfterTransfer() {
        let quick = passage(source: "en", target: "en", text: "A quiet morning.")
        let input = TranslationModel()
        input.acceptHandoff(quick.makeHandoff())
        XCTAssertEqual(input.source, "en")
        XCTAssertEqual(input.target, "en")
        XCTAssertEqual(input.phase, .unchanged)
        XCTAssertEqual(input.text, "A quiet morning.")
        XCTAssertEqual(input.translatedText, input.text)
        XCTAssertNil(input.request)
        XCTAssertNil(input.result)
    }

    func testEmptyPermissionOrRecognitionPanelLeavesExistingInputUntouched() async throws {
        let input = passage(source: "ja", target: "en", text: "以前の文章")
        let request = try XCTUnwrap(input.request)
        let translated = TranslationResult(text: "Previous passage", source: "ja", target: "en")
        await input.run(request, provider: HandoffProvider(result: translated))
        let configuration = input.configuration
        let empty = TranslationModel()
        for text in ["", " \n\t "] {
            empty.text = text
            XCTAssertNil(empty.makeHandoff())
            input.acceptHandoff(empty.makeHandoff())
        }
        empty.beginRecognition()
        input.acceptHandoff(empty.makeHandoff())
        XCTAssertEqual(input.text, "以前の文章")
        XCTAssertEqual(input.source, "ja")
        XCTAssertEqual(input.target, "en")
        XCTAssertEqual(input.result, translated)
        XCTAssertEqual(input.request, request)
        XCTAssertEqual(input.configuration, configuration)
    }

    func testLateSourceResponseDoesNotReachTransferredRequest() async throws {
        let quick = passage(source: "en", target: "fr", text: "A quiet morning.")
        let original = try XCTUnwrap(quick.request)
        let provider = SuspendedHandoffProvider()
        let task = Task { await quick.run(original, provider: provider) }
        await provider.waitUntilStarted()
        let snapshot = try XCTUnwrap(quick.makeHandoff())
        quick.cancel()
        let input = TranslationModel()
        input.acceptHandoff(snapshot)
        let restarted = input.request
        provider.finish(TranslationResult(text: "Late old response", source: "en", target: "fr"))
        await task.value
        XCTAssertNil(quick.result)
        XCTAssertNil(input.result)
        XCTAssertEqual(input.request, restarted)
    }

    func testLateDestinationResponseCannotReplaceTransferredCompletion() async throws {
        let input = passage(source: "ja", target: "en", text: "以前の文章")
        let provider = SuspendedHandoffProvider()
        let oldRequest = try XCTUnwrap(input.request)
        let task = Task { await input.run(oldRequest, provider: provider) }
        await provider.waitUntilStarted()
        let quick = passage(source: "en", target: "fr", text: "A quiet morning.")
        let translated = TranslationResult(text: "Un matin calme.", source: "en", target: "fr")
        await quick.run(try XCTUnwrap(quick.request), provider: HandoffProvider(result: translated))
        input.acceptHandoff(quick.makeHandoff())
        provider.finish(TranslationResult(text: "Late old response", source: "ja", target: "en"))
        await task.value
        XCTAssertEqual(input.result, translated)
        XCTAssertEqual(input.phase, .completed)
        XCTAssertNil(input.request)
        XCTAssertNil(input.configuration)
    }

    func testCompletedHandoffDoesNotScheduleIntermediateLanguageChanges() async throws {
        var sleepCount = 0
        let input = TranslationModel(automaticallyTranslates: true, sleep: { _ in sleepCount += 1 })
        input.text = "Previously edited text."
        let quick = passage(source: "en", target: "fr", text: "A quiet morning.")
        let translated = TranslationResult(text: "Un matin calme.", source: "en", target: "fr")
        await quick.run(try XCTUnwrap(quick.request), provider: HandoffProvider(result: translated))
        input.acceptHandoff(quick.makeHandoff())
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(sleepCount, 0)
        XCTAssertEqual(input.result, translated)
        XCTAssertNil(input.request)
    }

    func testExplicitHandoffEndsCompositionAndTextReplacementRemainsUndoable() async throws {
        _ = NSApplication.shared
        let input = TranslationModel()
        let editor = TranslationInputTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        input.text = "Existing "
        editor.applyExternalText(input.text)
        editor.onEdit = { input.editingChanged($0, isComposing: $1) }
        editor.setMarkedText("ni hao", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: 9, length: 0))
        XCTAssertTrue(input.isComposing)
        XCTAssertNil(input.makeHandoff())
        editor.finishCompositionForReplacement()
        let committed = editor.string
        let undo = try XCTUnwrap(editor.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        let quick = passage(source: "en", target: "fr", text: "A new passage.")
        undo.beginUndoGrouping()
        input.acceptHandoff(quick.makeHandoff())
        editor.applyExternalText(input.text)
        undo.endUndoGrouping()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertFalse(input.isComposing)
        XCTAssertEqual(editor.string, "A new passage.")
        XCTAssertEqual(input.target, "fr")
        XCTAssertNil(input.request)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(editor.string, committed)
        XCTAssertEqual(input.text, committed)
        XCTAssertNil(input.result)
        undo.redo()
        XCTAssertEqual(editor.string, "A new passage.")
        XCTAssertEqual(input.text, "A new passage.")
    }

    private func passage(source: String, target: String, text: String) -> TranslationModel {
        let model = TranslationModel()
        model.source = source
        model.target = target
        model.text = text
        model.submit()
        return model
    }
}

@MainActor
private struct HandoffProvider: TranslationProvider {
    let result: TranslationResult
    func translate(_ request: TranslationRequest) async throws -> TranslationResult { result }
}

@MainActor
private final class SuspendedHandoffProvider: TranslationProvider {
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

    func finish(_ result: TranslationResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
