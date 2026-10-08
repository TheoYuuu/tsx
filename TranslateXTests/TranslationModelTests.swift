import XCTest
@testable import TranslateX

@MainActor
final class TranslationModelTests: XCTestCase {
    func testAppleTranslationRetainsOriginalLineAndParagraphBreaks() {
        for separator in ["\n", "\r\n", "\r", "\u{0085}", "\u{2028}", "\u{2029}"] {
            let source = "First.\(separator)123\(separator)\(separator)Last."
            let response = "第一句。\n\n123\n\n最后一句。"
            XCTAssertEqual(AppleLocalTranslationProvider.preservingLineBreaks(in: response, from: source),
                           "第一句。\(separator)123\(separator)\(separator)最后一句。")
        }
        XCTAssertEqual(AppleLocalTranslationProvider.preservingLineBreaks(in: "第一句。\n\n第二句。", from: "First.\n \t\nSecond."),
                       "第一句。\n \t\n第二句。", "An intentionally empty paragraph is preserved")
    }

    func testAppleLineBreakRepairLeavesUnmatchedParagraphsAndContentUntouched() {
        for (source, response) in [
            ("First. Second.", "第一句。\n\n第二句。"),
            ("First.\nSecond.\nThird.", "第一句和第二句。\n第三句。"),
            ("First.\nSecond.", "第一句。\n第二句。\n其他内容。"),
            ("\nFirst.\nSecond.", "第一句。\n第二句。\n"),
            ("First.\nSecond.", "\n第一句和第二句。")
        ] {
            XCTAssertEqual(AppleLocalTranslationProvider.preservingLineBreaks(in: response, from: source), response)
        }
    }

    func testRecognitionClearsPreviousResultAndCanBeCancelledBeforeTranslation() async {
        let model = TranslationModel()
        model.text = "An earlier passage."
        model.submit()
        await model.run(model.request!, provider: ImmediateProvider(text: "Earlier result"))
        model.beginRecognition()
        XCTAssertEqual(model.phase, .recognizing)
        XCTAssertTrue(model.isBusy)
        XCTAssertTrue(model.text.isEmpty)
        XCTAssertNil(model.result)
        XCTAssertNil(model.request)
        model.cancel()
        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertFalse(model.isBusy)
    }

    func testOldResponseCannotReplaceNewRequest() async {
        let model = TranslationModel()
        model.text = "First sentence"
        model.submit()
        let first = model.request!
        let provider = SuspendedProvider()
        let task = Task { await model.run(first, provider: provider) }
        while provider.continuation == nil { await Task.yield() }
        model.text = "Second sentence"
        model.submit()
        provider.continuation?.resume(returning: TranslationResult(text: "old", source: "en", target: "zh-Hans"))
        await task.value
        XCTAssertNil(model.result)
        XCTAssertEqual(model.phase, .translating)
        XCTAssertEqual(model.request?.text, "Second sentence")
    }

    func testCancelInvalidatesInFlightResult() async {
        let model = TranslationModel()
        model.text = "A clear sentence."
        model.submit()
        let request = model.request!
        let provider = SuspendedProvider()
        let task = Task { await model.run(request, provider: provider) }
        while provider.continuation == nil { await Task.yield() }
        model.cancel()
        provider.continuation?.resume(returning: TranslationResult(text: "late", source: "en", target: "zh-Hans"))
        await task.value
        XCTAssertNil(model.result)
        XCTAssertEqual(model.phase, .cancelled)
    }

    func testWhitespaceDoesNotStartTranslation() {
        let model = TranslationModel()
        model.text = " \n\t "
        model.submit()
        XCTAssertNil(model.request)
        XCTAssertNil(model.configuration)
        XCTAssertEqual(model.phase, .empty)
    }

    func testRepeatedLanguagePairInvalidatesConfiguration() {
        let model = TranslationModel()
        model.source = "en"
        model.text = "Hello"
        model.submit()
        let original = model.configuration
        model.text = "A different phrase"
        model.submit()
        XCTAssertNotEqual(original, model.configuration)
        XCTAssertEqual(original?.source, model.configuration?.source)
    }

    func testContinuousEditsRestartThePauseAndSubmitOnlyTheLatestText() async {
        let sleeper = ControlledSleeper()
        defer { sleeper.releaseAll() }
        let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep)
        model.source = "en"
        model.editingChanged("First edit", isComposing: false)
        await sleeper.waitForCount(1)
        model.editingChanged("Final edit", isComposing: false)
        await sleeper.waitForCount(2)
        XCTAssertEqual(sleeper.durations, [.milliseconds(650), .milliseconds(650)])
        sleeper.releaseFirst()
        await settleTasks()
        XCTAssertNil(model.request, "The superseded typing deadline must not submit")
        sleeper.releaseFirst()
        await settleTasks()
        XCTAssertEqual(model.request?.text, "Final edit")
    }

    func testCompositionWaitsForCommitAndManualSubmitDoesNotBypassIt() async {
        let sleeper = ControlledSleeper()
        defer { sleeper.releaseAll() }
        let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep)
        model.source = "zh-Hans"
        model.target = "en"
        model.editingChanged("ni hao", isComposing: true)
        model.submit()
        await settleTasks()
        XCTAssertNil(model.request)
        XCTAssertTrue(sleeper.durations.isEmpty)
        XCTAssertFalse(model.canTranslate)
        XCTAssertEqual(model.phase, .composing)
        model.editingChanged("你好，世界。", isComposing: false)
        await sleeper.waitForCount(1)
        sleeper.releaseFirst()
        await settleTasks()
        XCTAssertEqual(model.request?.text, "你好，世界。")
    }

    func testNumericPrefixesDoNotScheduleUntilTranslatableTextArrives() async {
        let sleeper = ControlledSleeper()
        defer { sleeper.releaseAll() }
        let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep)
        model.editingChanged("1", isComposing: false)
        model.editingChanged("12", isComposing: false)
        await settleTasks()
        XCTAssertTrue(sleeper.durations.isEmpty)
        XCTAssertNil(model.request)
        model.editingChanged("Clear sentences are easy to understand.", isComposing: false)
        XCTAssertNil(model.request, "A changing source gets one interval to stabilize")
        await sleeper.waitForCount(1)
        model.editingChanged("Clear sentences are easy to understand. Keep reading.", isComposing: false)
        sleeper.releaseFirst()
        await settleTasks()
        XCTAssertNil(model.request)
        await sleeper.waitForCount(1)
        sleeper.releaseFirst()
        await settleTasks()
        XCTAssertEqual(model.request?.text, model.text)
        XCTAssertEqual(model.request?.source, "en")
    }

    func testNumericAndSymbolOnlyInputSynchronizesBothDirectionsWithoutAnAppleSession() async {
        let sleeper = ControlledSleeper()
        defer { sleeper.releaseAll() }
        for source in ["auto", "en"] {
            for side in [TranslationSide.source, .target] {
                for text in ["123123", "１２３", "١٢٣", "$12.50 + 25%", "…！?", "😀 🌷", "2026-09-29\n1️⃣"] {
                    let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep)
                    model.source = source
                    model.editingChanged(text, isComposing: false, side: side)
                    XCTAssertEqual(model.text(on: side.opposite), text, "Automatic mode copies neutral text immediately")
                    model.submit() // Repeating the action stays local.
                    XCTAssertEqual(model.text(on: side), text)
                    XCTAssertNil(model.request)
                    XCTAssertNil(model.configuration)
                    XCTAssertNil(model.result)
                    XCTAssertEqual(model.phase, .unchanged)
                    XCTAssertTrue(model.canTranslate)
                    XCTAssertFalse(model.needsSourceLanguage)
                    XCTAssertFalse(model.needsReverseLanguage)
                    XCTAssertEqual(model.workspaceFeedback, L10n.string("Synced · No translation needed"))
                }
            }
        }
        await settleTasks()
        XCTAssertTrue(sleeper.durations.isEmpty)
    }

    func testNumericEditInvalidatesInFlightResultAndTextEditingCanResume() async throws {
        let sleeper = ControlledSleeper()
        defer { sleeper.releaseAll() }
        let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep)
        model.text = "An earlier sentence."
        model.submit()
        let earlier = try XCTUnwrap(model.request)
        let provider = SuspendedProvider()
        let task = Task { await model.run(earlier, provider: provider) }
        while provider.continuation == nil { await Task.yield() }
        model.editingChanged("123123", isComposing: false)
        XCTAssertNil(model.request)
        XCTAssertNil(model.configuration)
        provider.continuation?.resume(returning: TranslationResult(text: "obsolete", source: "en", target: "zh-Hans"))
        await task.value
        XCTAssertEqual(model.text, "123123")
        XCTAssertEqual(model.translatedText, "123123")
        XCTAssertEqual(model.phase, .unchanged)
        model.editingChanged("Clear sentences are easy to understand.", isComposing: false)
        await sleeper.waitForCount(1)
        sleeper.releaseFirst()
        await settleTasks()
        let current = try XCTUnwrap(model.request)
        XCTAssertEqual(current.source, "en")
        XCTAssertEqual(current.text, model.text)
        XCTAssertNil(model.displayedResult)
        XCTAssertEqual(model.request?.id, current.id)
        await model.run(current, provider: ImmediateProvider(text: "清晰的句子很容易理解。"))
        XCTAssertEqual(model.phase, .completed)
    }

    func testUncertainSourceWaitsInlineAndLanguageChoiceResumesAutomaticTranslation() async {
        let sleeper = ControlledSleeper()
        defer { sleeper.releaseAll() }
        let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep)
        model.editingChanged("今日仕事", isComposing: false)
        model.submit()
        await settleTasks()
        XCTAssertTrue(model.needsSourceLanguage)
        XCTAssertNil(model.request)
        XCTAssertNil(model.configuration)
        XCTAssertTrue(sleeper.durations.isEmpty)
        XCTAssertEqual(model.workspaceFeedback, L10n.string("Language unclear · Choose the original language"))
        model.source = "ja"
        await sleeper.waitForCount(1)
        sleeper.releaseFirst()
        await settleTasks()
        XCTAssertEqual(model.request?.text, "今日仕事")
        XCTAssertEqual(model.request?.source, "ja")
        XCTAssertNotNil(model.configuration?.source)
    }

    func testManualLanguageChoiceDoesNotResendUntilExplicitSubmit() {
        let model = TranslationModel()
        model.text = "今日仕事"
        model.submit()
        XCTAssertTrue(model.needsSourceLanguage)
        model.source = "ja"
        XCTAssertFalse(model.needsSourceLanguage)
        XCTAssertNil(model.request)
        model.submit()
        XCTAssertEqual(model.request?.source, "ja")
        XCTAssertEqual(model.request?.text, "今日仕事")
    }

    func testAppendingEnglishAfterChineseAutomaticallyReplacesTheLocalCopy() async throws {
        let sleeper = ControlledSleeper()
        defer { sleeper.releaseAll() }
        let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep)
        model.editingChanged("789哈哈", isComposing: false)
        XCTAssertEqual(model.translatedText, "789哈哈")
        XCTAssertEqual(model.phase, .unchanged)
        for suffix in ["h", "he", "hel", "hell", "hello", "HelloKitty", "HelloKitty\nhello, where?"] {
            let input = "789哈哈\n" + suffix
            model.editingChanged(input, isComposing: false)
            XCTAssertEqual(model.phase, .waiting, suffix)
            XCTAssertFalse(model.needsSourceLanguage)
            await sleeper.waitForCount(1)
            sleeper.releaseFirst()
            await settleTasks()
            let request = try XCTUnwrap(model.request)
            XCTAssertEqual(request.text, input)
            XCTAssertEqual(request.source, "en", suffix)
            XCTAssertEqual(request.target, "zh-Hans")
            let output = "789哈哈\n构造译文：\(suffix)"
            await model.run(request, provider: ImmediateProvider(text: output))
            XCTAssertEqual(model.translatedText, output)
            XCTAssertEqual(model.phase, .completed)
            XCTAssertEqual(model.target, "zh-Hans")
        }
        model.editingChanged("789哈哈", isComposing: false)
        XCTAssertEqual(model.translatedText, "789哈哈")
        XCTAssertEqual(model.phase, .unchanged)
        XCTAssertNil(model.request)
    }

    func testMixedEditInvalidatesAnEarlierTranslationAndWaitsForIMECommit() async throws {
        let sleeper = ControlledSleeper()
        defer { sleeper.releaseAll() }
        let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep)
        model.text = "789哈哈\nHelloKitty"
        model.submit()
        let earlier = try XCTUnwrap(model.request)
        let provider = SuspendedProvider()
        let pending = Task { await model.run(earlier, provider: provider) }
        while provider.continuation == nil { await Task.yield() }
        model.editingChanged("789哈哈\nHelloKitty\nhello, where?", isComposing: true)
        provider.continuation?.resume(returning: .init(text: "Old result", source: "en", target: "zh-Hans"))
        await pending.value
        XCTAssertEqual(model.phase, .composing)
        XCTAssertNil(model.request)
        XCTAssertTrue(model.translatedText.isEmpty)
        XCTAssertTrue(sleeper.durations.isEmpty)
        model.editingChanged(model.text, isComposing: false)
        await sleeper.waitForCount(1)
        sleeper.releaseFirst()
        await settleTasks()
        XCTAssertEqual(model.request?.text, model.text)
        XCTAssertEqual(model.request?.source, "en")
    }

    func testNumericSynchronizationReplacesTheOppositePaneAndCanBeUndone() async throws {
        for side in [TranslationSide.source, .target] {
            let model = TranslationModel(automaticallyTranslates: true)
            model.text = "A clear sentence."
            model.submit()
            await model.run(try XCTUnwrap(model.request), provider: ImmediateProvider(text: "一个清晰的句子。"))
            let retained = model.text(on: side.opposite)
            model.editingChanged("123123", isComposing: false, side: side)
            XCTAssertEqual(model.text(on: side.opposite), "123123")
            XCTAssertNil(model.result)
            XCTAssertNil(model.makeHandoff()?.completedResult)
            XCTAssertNil(model.request)
            XCTAssertNil(model.configuration)
            XCTAssertTrue(model.undoWorkspaceChange())
            XCTAssertEqual(model.text(on: side.opposite), retained)
            XCTAssertEqual(model.text(on: side), "123123")
            XCTAssertTrue(model.redoWorkspaceChange())
            XCTAssertEqual(model.text(on: side.opposite), "123123")
        }
    }

    func testMixedNumbersAndSameLanguageSynchronizeImmediatelyAndRespectManualMode() async {
        let model = TranslationModel(automaticallyTranslates: true)
        model.editingChanged("123\n哈哈", isComposing: false)
        XCTAssertEqual(model.resolvedSource, "zh-Hans")
        XCTAssertEqual(model.translatedText, "123\n哈哈")
        XCTAssertEqual(model.phase, .unchanged)
        XCTAssertNil(model.request)
        XCTAssertFalse(model.needsSourceLanguage)
        model.setAutomaticTranslation(false)
        model.editingChanged("456\n哈哈", isComposing: false)
        XCTAssertEqual(model.translatedText, "123\n哈哈", "Manual mode does not silently update the other side")
        model.submit()
        XCTAssertEqual(model.translatedText, "456\n哈哈")
        XCTAssertEqual(model.phase, .unchanged)
        model.editingChanged("789\n哈哈", isComposing: false, side: .target)
        XCTAssertEqual(model.text, "456\n哈哈")
        model.submit()
        XCTAssertEqual(model.text, "789\n哈哈")
        XCTAssertEqual(model.phase, .unchanged)
        XCTAssertNil(model.configuration)
    }

    func testNeutralCopyPreservesWhitespaceAndWaitsForCompositionCommit() {
        let model = TranslationModel(automaticallyTranslates: true)
        for side in [TranslationSide.source, .target] {
            model.clear(keepingUndo: false)
            model.editingChanged(" 123\n\n 456 ", isComposing: true, side: side)
            model.submit()
            XCTAssertTrue(model.text(on: side.opposite).isEmpty)
            model.editingChanged(" 123\n\n 456 ", isComposing: false, side: side)
            XCTAssertEqual(model.text(on: side.opposite), " 123\n\n 456 ")
            XCTAssertNil(model.detectedSource, "Copying numbers must not invent a language")
            XCTAssertNil(model.request)
            XCTAssertNil(model.result)
            let received = TranslationModel(automaticallyTranslates: true)
            received.acceptHandoff(model.makeHandoff())
            XCTAssertEqual(received.text, " 123\n\n 456 ")
            XCTAssertEqual(received.translatedText, received.text)
            XCTAssertEqual(received.inputSide, side)
            XCTAssertEqual(received.phase, .unchanged)
            XCTAssertNil(received.request)
        }
    }

    func testChangedDetectedSourceSupersedesLanguagePreparation() async throws {
        let sleeper = ControlledSleeper()
        defer { sleeper.releaseAll() }
        let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep)
        model.text = "Dies ist ein deutscher Satz über einen ruhigen Morgen."
        model.submit()
        let german = try XCTUnwrap(model.request)
        XCTAssertEqual(german.source, "de")
        model.markPreparing(german)
        model.editingChanged("Clear sentences are easy to understand.", isComposing: false)
        XCTAssertNil(model.request)
        XCTAssertNil(model.configuration)
        await sleeper.waitForCount(1)
        sleeper.releaseFirst()
        await settleTasks()
        XCTAssertEqual(model.request?.source, "en")
        XCTAssertEqual(model.request?.text, model.text)
        model.markPreparing(german)
        XCTAssertEqual(model.phase, .translating, "Old setup callbacks must not affect the new request")
    }

    func testCancellingDebounceNeverStartsARequest() async {
        let sleeper = ControlledSleeper()
        defer { sleeper.releaseAll() }
        let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep)
        model.editingChanged("A quiet morning.", isComposing: false)
        await sleeper.waitForCount(1)
        model.cancel()
        sleeper.releaseFirst()
        await settleTasks()
        XCTAssertNil(model.request)
        XCTAssertEqual(model.phase, .cancelled)
    }

    func testManualSubmitSupersedesQueuedAutomaticRequest() async {
        let sleeper = ControlledSleeper()
        defer { sleeper.releaseAll() }
        let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep)
        model.source = "en"
        model.editingChanged("A quiet morning.", isComposing: false)
        await sleeper.waitForCount(1)
        model.submit()
        let requestID = model.request?.id
        XCTAssertNotNil(requestID)
        sleeper.releaseFirst()
        await settleTasks()
        XCTAssertEqual(model.request?.id, requestID)
    }

    func testEditClearsCompletedResultBeforeDebounce() async {
        let model = TranslationModel()
        model.source = "en"
        model.text = "A quiet morning."
        model.submit()
        await model.run(model.request!, provider: ImmediateProvider(text: "安静的早晨。"))
        XCTAssertNotNil(model.result)
        model.text = "An unfinished replacement"
        XCTAssertNil(model.result)
        XCTAssertNil(model.request)
    }

    func testLiveInsertDeleteAndReplaceKeepTheTranslationVisibleUntilReplacement() async throws {
        let sleeper = ControlledSleeper()
        defer { sleeper.releaseAll() }
        let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep)
        model.source = "en"
        model.text = "A quiet morning."
        model.submit()
        await model.run(try XCTUnwrap(model.request), provider: ImmediateProvider(text: "安静的早晨。"))

        for draft in ["A quiet morning outside.", "A quiet morning", "A bright afternoon."] {
            model.editingChanged(draft, isComposing: false)
            XCTAssertEqual(model.displayedResult?.text, "安静的早晨。")
            XCTAssertNil(model.result, "Previous text must not be exposed as the current Copy/Swap result")
            XCTAssertNil(model.makeHandoff()?.completedResult)
        }
        await sleeper.waitForCount(1)
        sleeper.releaseFirst()
        await settleTasks()
        XCTAssertEqual(model.request?.text, "A bright afternoon.")
        XCTAssertEqual(model.displayedResult?.text, "安静的早晨。")
        await model.run(try XCTUnwrap(model.request), provider: ImmediateProvider(text: "明媚的午后。"))
        XCTAssertEqual(model.displayedResult?.text, "明媚的午后。")
        XCTAssertEqual(model.result, model.displayedResult)
        XCTAssertEqual(model.phase, .completed)
    }

    func testTypingDuringSlowTranslationRejectsTheOldSnapshotAndWaitsForTheLatestPause() async throws {
        let sleeper = ControlledSleeper()
        defer { sleeper.releaseAll() }
        let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep)
        model.source = "en"
        model.text = "First snapshot."
        model.submit()
        let first = try XCTUnwrap(model.request)
        let provider = SuspendedProvider()
        let task = Task { await model.run(first, provider: provider) }
        while provider.continuation == nil { await Task.yield() }
        model.editingChanged("An intermediate draft.", isComposing: false)
        await sleeper.waitForCount(1)
        model.editingChanged("The newest draft.", isComposing: false)
        await sleeper.waitForCount(2)
        XCTAssertNil(model.request, "New input cancels the obsolete intent")
        provider.continuation?.resume(returning: TranslationResult(text: "第一份快照。", source: "en", target: "zh-Hans"))
        await task.value
        XCTAssertNil(model.result)
        XCTAssertTrue(model.translatedText.isEmpty, "Old completion must never overwrite the other editor")
        sleeper.releaseFirst()
        await settleTasks()
        XCTAssertNil(model.request)
        sleeper.releaseFirst()
        await settleTasks()
        let latest = try XCTUnwrap(model.request)
        XCTAssertEqual(latest.text, "The newest draft.")
        XCTAssertNotEqual(latest.id, first.id)
        await model.run(latest, provider: ImmediateProvider(text: "最新的草稿。"))
        XCTAssertEqual(model.result?.text, "最新的草稿。")
    }

    func testLiveCompositionPreservesReadingAndSubmitsOnlyCommittedCharacters() async throws {
        let sleeper = ControlledSleeper()
        defer { sleeper.releaseAll() }
        let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep)
        model.target = "en"
        model.text = "早晨很安静。"
        model.source = "zh-Hans"
        model.submit()
        await model.run(try XCTUnwrap(model.request), provider: ImmediateProvider(text: "A quiet morning."))
        model.editingChanged("早晨很安静。xia", isComposing: true)
        model.submit()
        await settleTasks()
        XCTAssertNil(model.request)
        XCTAssertEqual(model.displayedResult?.text, "A quiet morning.")
        XCTAssertEqual(model.phase, .composing)
        XCTAssertTrue(sleeper.durations.isEmpty)
        model.editingChanged("早晨很安静。下午也一样。", isComposing: false)
        await sleeper.waitForCount(1)
        sleeper.releaseFirst()
        await settleTasks()
        XCTAssertEqual(model.request?.text, "早晨很安静。下午也一样。")
        XCTAssertEqual(model.displayedResult?.text, "A quiet morning.")
    }

    func testDeletingSourceKeepsTheOtherEditorAndRejectsTheRunningResponse() async throws {
        let model = TranslationModel(automaticallyTranslates: true)
        model.source = "en"
        model.text = "Original passage."
        model.submit()
        await model.run(try XCTUnwrap(model.request), provider: ImmediateProvider(text: "原文。"))
        model.text = "Replacement passage."
        model.submit()
        let request = try XCTUnwrap(model.request)
        let provider = SuspendedProvider()
        let task = Task { await model.run(request, provider: provider) }
        while provider.continuation == nil { await Task.yield() }
        model.editingChanged(" \n ", isComposing: false)
        XCTAssertEqual(model.translatedText, "原文。")
        XCTAssertNil(model.result)
        XCTAssertEqual(model.phase, .empty)
        provider.continuation?.resume(returning: TranslationResult(text: "late", source: "en", target: "zh-Hans"))
        await task.value
        XCTAssertEqual(model.translatedText, "原文。")
        XCTAssertNil(model.result)
        XCTAssertNil(model.request)
    }

    func testLiveTargetChangeDropsThePreviewAndRejectsTheOldLanguageResponse() async throws {
        let sleeper = ControlledSleeper()
        defer { sleeper.releaseAll() }
        let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep)
        model.source = "en"
        model.text = "Original passage."
        model.submit()
        await model.run(try XCTUnwrap(model.request), provider: ImmediateProvider(text: "原文。"))
        model.text = "Replacement passage."
        model.submit()
        let request = try XCTUnwrap(model.request)
        let provider = SuspendedProvider()
        let task = Task { await model.run(request, provider: provider) }
        while provider.continuation == nil { await Task.yield() }
        model.target = "fr"
        XCTAssertNil(model.displayedResult)
        provider.continuation?.resume(returning: TranslationResult(text: "late Chinese", source: "en", target: "zh-Hans"))
        await task.value
        XCTAssertNil(model.displayedResult)
        await sleeper.waitForCount(1)
        sleeper.releaseFirst()
        await settleTasks()
        XCTAssertEqual(model.request?.target, "fr")
    }

    func testFailedEarlierSnapshotStillAdvancesToTheLatestInput() async throws {
        let sleeper = ControlledSleeper()
        defer { sleeper.releaseAll() }
        let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep)
        model.source = "en"
        model.text = "An earlier passage."
        model.submit()
        let request = try XCTUnwrap(model.request)
        let provider = SuspendedProvider()
        let task = Task { await model.run(request, provider: provider) }
        while provider.continuation == nil { await Task.yield() }
        model.editingChanged("The current passage.", isComposing: false)
        provider.continuation?.resume(throwing: URLError(.notConnectedToInternet))
        await task.value
        XCTAssertEqual(model.phase, .waiting)
        await sleeper.waitForCount(1)
        sleeper.releaseFirst()
        await settleTasks()
        XCTAssertEqual(model.request?.text, "The current passage.")
    }

    func testEarlierAvailabilityFailureDoesNotStopEditedInput() async throws {
        let sleeper = ControlledSleeper()
        defer { sleeper.releaseAll() }
        let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep)
        model.source = "en"
        model.text = "An earlier passage."
        model.submit()
        let request = try XCTUnwrap(model.request)
        model.editingChanged("The current passage.", isComposing: false)
        model.fail("Earlier pair unavailable", for: request)
        XCTAssertEqual(model.phase, .waiting)
        await sleeper.waitForCount(1)
        sleeper.releaseFirst()
        await settleTasks()
        let current = try XCTUnwrap(model.request)
        XCTAssertEqual(current.text, "The current passage.")
        model.fail("Late availability failure", for: request)
        XCTAssertEqual(model.request?.id, current.id)
        XCTAssertEqual(model.phase, .translating)
    }

    func testLiveCancellationKeepsPreviewButStopsAutomaticWorkAndLateResults() async throws {
        let sleeper = ControlledSleeper()
        defer { sleeper.releaseAll() }
        let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep)
        model.text = "A quiet morning."
        model.submit()
        await model.run(try XCTUnwrap(model.request), provider: ImmediateProvider(text: "安静的早晨。"))
        model.editingChanged("A quiet afternoon.", isComposing: false)
        await sleeper.waitForCount(1)
        XCTAssertEqual(model.resolvedSource, "en", "The new source has its own confident detection")
        model.cancel()
        sleeper.releaseFirst()
        await settleTasks()
        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertEqual(model.displayedResult?.text, "安静的早晨。")
        XCTAssertNil(model.result)
        XCTAssertNil(model.request)
    }

    func testFailedCurrentUpdateKeepsThePreviousTranslationReadable() async throws {
        let model = TranslationModel(automaticallyTranslates: true)
        model.source = "en"
        model.text = "A quiet morning."
        model.submit()
        await model.run(try XCTUnwrap(model.request), provider: ImmediateProvider(text: "安静的早晨。"))
        model.text = "A quiet afternoon."
        model.submit()
        let request = try XCTUnwrap(model.request)
        let provider = SuspendedProvider()
        let task = Task { await model.run(request, provider: provider) }
        while provider.continuation == nil { await Task.yield() }
        provider.continuation?.resume(throwing: URLError(.notConnectedToInternet))
        await task.value
        guard case .failed = model.phase else { return XCTFail("Expected an update error") }
        XCTAssertEqual(model.displayedResult?.text, "安静的早晨。")
        XCTAssertNil(model.result)
    }

    func testLanguageChangeInvalidatesInFlightResult() async {
        let model = TranslationModel()
        model.source = "en"
        model.text = "A quiet morning."
        model.submit()
        let request = model.request!
        let provider = SuspendedProvider()
        let task = Task { await model.run(request, provider: provider) }
        while provider.continuation == nil { await Task.yield() }
        model.target = "fr"
        provider.continuation?.resume(returning: TranslationResult(text: "old target", source: "en", target: "zh-Hans"))
        await task.value
        XCTAssertNil(model.result)
        XCTAssertNil(model.request)
    }

    func testSwapUsesDetectedLanguageAndCurrentTranslation() async {
        let model = TranslationModel()
        model.text = "A quiet morning."
        model.submit()
        await model.run(model.request!, provider: ImmediateProvider(text: "安静的早晨。"))
        model.swapLanguages()
        XCTAssertEqual(model.source, "zh-Hans")
        XCTAssertEqual(model.target, "en")
        XCTAssertEqual(model.text, "安静的早晨。")
        XCTAssertNil(model.request, "Swap does not submit a new request")
        XCTAssertEqual(model.translatedText, "A quiet morning.")
        XCTAssertNil(model.result)
    }

    func testUnknownAutomaticLanguageCannotBeSwapped() {
        let model = TranslationModel()
        XCTAssertFalse(model.canSwapLanguages)
        model.swapLanguages()
        XCTAssertEqual(model.source, "auto")
        XCTAssertEqual(model.target, "zh-Hans")
    }

    func testSameLanguageCopiesTheOriginalWithoutInventingAProviderResult() {
        let model = TranslationModel()
        model.source = "en"
        model.target = "en"
        model.text = "Hello there."
        model.submit()
        XCTAssertEqual(model.phase, .unchanged)
        XCTAssertEqual(model.translatedText, model.text)
        XCTAssertNil(model.result)
        XCTAssertNil(model.request)
        XCTAssertNil(model.configuration)
        XCTAssertFalse(TranslationModel.isSameLanguage("zh-Hans", "zh-Hant"))
    }

    func testOversizedInputHasNoTranslationRequest() {
        let model = TranslationModel()
        model.text = String(repeating: "a", count: SelectionText.maximumLength + 1)
        model.submit()
        XCTAssertNil(model.request)
        guard case .failed = model.phase else { return XCTFail("Expected a recoverable size explanation") }
    }

    private func settleTasks() async {
        for _ in 0..<30 { await Task.yield() }
    }
}

@MainActor
private final class SuspendedProvider: TranslationProvider {
    var continuation: CheckedContinuation<TranslationResult, any Error>?
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

@MainActor
private struct ImmediateProvider: TranslationProvider {
    let text: String
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        TranslationResult(text: text, source: "en", target: request.target)
    }
}

@MainActor
private final class ControlledSleeper {
    private var continuations: [CheckedContinuation<Void, any Error>] = []
    private(set) var durations: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func releaseFirst() { continuations.removeFirst().resume() }
    func releaseAll() {
        while !continuations.isEmpty { releaseFirst() }
    }

    func waitForCount(_ count: Int) async {
        for _ in 0..<500 {
            if continuations.count >= count { return }
            await Task.yield()
        }
        XCTFail("Debounce did not reach the controlled clock")
    }
}
