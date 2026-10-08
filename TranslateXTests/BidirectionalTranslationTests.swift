import AppKit
import SwiftUI
import XCTest
@testable import TranslateX

@MainActor
final class BidirectionalTranslationTests: XCTestCase {
    func testRemoteServicesStillDetectUncertainAlphabeticInput() async throws {
        for text in ["今日仕事"] {
            let f = try fixture()
            defer { f.finish() }
            f.model.editingChanged(text, isComposing: false)
            await f.pauseAndStart()
            XCTAssertFalse(f.model.inputNeedsNoTranslation)
            XCTAssertFalse(f.model.needsSourceLanguage)
            XCTAssertEqual(f.provider.requests.first?.text, text)
            XCTAssertNil(f.provider.requests.first?.source)
            f.provider.complete(0, text: "Constructed translation", source: "en")
            await settle()
            XCTAssertEqual(f.model.detectedSource, "en")
            f.model.selectService(nil)
            f.model.submit()
            XCTAssertNil(f.model.request, "A cached remote language must not open Apple's system picker")
            XCTAssertNil(f.model.configuration)
            XCTAssertTrue(f.model.needsSourceLanguage)
        }
    }

    func testChineseDominantMixedTextReachesRemoteAutoDetectionInFull() async throws {
        let f = try fixture()
        defer { f.finish() }
        f.model.editingChanged("789哈哈", isComposing: false)
        XCTAssertEqual(f.model.translatedText, "789哈哈")
        XCTAssertTrue(f.provider.requests.isEmpty)
        let input = "这是一段用于构造回归测试的中文。请点击 Save 后继续。"
        f.model.editingChanged(input, isComposing: false)
        await f.pauseAndStart()
        XCTAssertEqual(f.provider.requests.count, 1)
        XCTAssertEqual(f.provider.requests.first?.text, input)
        XCTAssertNil(f.provider.requests.first?.source, "Remote detection keeps its original full context")
        XCTAssertEqual(f.provider.requests.first?.target, "zh-Hans")
        f.provider.complete(0, text: "这是一段用于构造回归测试的中文。请点击保存后继续。", source: "en")
        await settle()
        XCTAssertEqual(f.model.phase, .completed)
        XCTAssertTrue(f.model.translatedText.contains("保存"))
        XCTAssertEqual(f.clock.pendingCount, 0)
    }

    func testNumbersAndSameLanguageNeverReadCredentialsOrCallARemoteProvider() async throws {
        for side in [TranslationSide.source, .target] {
            for value in ["123\n456", "123\n哈哈"] {
                let f = try fixture()
                defer { f.finish() }
                let reads = f.credentials.reads
                f.model.source = value.contains("哈哈") ? "zh-Hans" : "auto"
                f.model.editingChanged(value, isComposing: false, side: side)
                await f.pauseAndStart()
                XCTAssertEqual(f.model.text(on: side.opposite), value)
                XCTAssertEqual(f.model.phase, .unchanged)
                XCTAssertEqual(f.credentials.reads, reads)
                XCTAssertTrue(f.provider.requests.isEmpty)
                XCTAssertEqual(f.clock.pendingCount, 0)
                XCTAssertNil(f.model.result)
            }
        }
    }

    func testLocalSyncRejectsLateRemoteChunksAndCompletion() async throws {
        let f = try fixture()
        defer { f.finish() }
        f.model.source = "en"
        f.model.editingChanged("A pending sentence.", isComposing: false)
        await f.pauseAndStart()
        f.provider.partial(0, "Unfinished")
        f.model.editingChanged("123", isComposing: false, side: .target)
        f.provider.partial(0, "Obsolete chunk")
        f.provider.complete(0, text: "Obsolete completion")
        await settle()
        XCTAssertEqual(f.model.text, "123")
        XCTAssertEqual(f.model.translatedText, "123")
        XCTAssertEqual(f.model.phase, .unchanged)
        XCTAssertNil(f.model.partialSide)
        XCTAssertNil(f.model.result)
        XCTAssertNil(f.model.request)
        XCTAssertEqual(f.provider.requests.count, 1)
    }

    func testBothHumanInputDirectionsAutomaticallyTranslateWithoutAFeedbackLoop() async throws {
        let f = try fixture()
        defer { f.finish() }
        f.model.source = "en"
        f.model.editingChanged("A clear sentence.", isComposing: false)
        await f.pauseAndStart()
        XCTAssertEqual(f.provider.requests.map(\.text), ["A clear sentence."])
        f.provider.complete(0, text: "一个清晰的句子。")
        await settle()
        XCTAssertEqual(f.model.translatedText, "一个清晰的句子。")
        XCTAssertEqual(f.clock.pendingCount, 0)
        XCTAssertEqual(f.provider.requests.count, 1)
        f.model.editingChanged("一个修改后的句子。", isComposing: false, side: .target)
        XCTAssertEqual(f.model.text, "A clear sentence.")
        await f.pauseAndStart()
        XCTAssertEqual(f.provider.requests[1].source, "zh-Hans")
        XCTAssertEqual(f.provider.requests[1].target, "en")
        f.provider.complete(1, text: "A revised sentence.")
        await settle()
        XCTAssertEqual(f.model.text, "A revised sentence.")
        XCTAssertEqual(f.model.translatedText, "一个修改后的句子。")
        XCTAssertEqual(f.provider.requests.count, 2)
        XCTAssertEqual(f.clock.pendingCount, 0)
        XCTAssertEqual(f.model.phase, .completed)
    }

    func testLastEditWinsOverOldChunksAndCompletionsInBothDirections() async throws {
        let f = try fixture()
        defer { f.finish() }
        f.model.source = "en"
        f.model.editingChanged("First source.", isComposing: false)
        await f.pauseAndStart()
        f.model.editingChanged("使用右侧的新输入。", isComposing: false, side: .target)
        await f.pauseAndStart()
        f.provider.partial(0, "Obsolete chunk")
        f.provider.complete(0, text: "Obsolete result")
        await settle()
        XCTAssertEqual(f.model.translatedText, "使用右侧的新输入。")
        XCTAssertEqual(f.model.text, "First source.")
        f.model.editingChanged("The newest left input.", isComposing: false)
        await f.pauseAndStart()
        f.provider.partial(1, "Late reverse chunk")
        f.provider.complete(1, text: "Late reverse result")
        await settle()
        XCTAssertEqual(f.model.text, "The newest left input.")
        f.provider.complete(2, text: "最新结果。")
        await settle()
        XCTAssertEqual(f.model.translatedText, "最新结果。")
    }

    func testStoppingRetainsPartialTextAndOnlyNewInputRestartsAutomaticTranslation() async throws {
        for side in [TranslationSide.source, .target] {
            let f = try fixture()
            defer { f.finish() }
            f.model.source = "en"
            f.model.editingChanged(side == .source ? "First source." : "右侧输入。", isComposing: false, side: side)
            await f.pauseAndStart()
            f.provider.partial(0, "Incomplete fixture")
            XCTAssertNil(f.model.result)
            f.model.cancel()
            XCTAssertEqual(f.model.text(on: side.opposite), "Incomplete fixture")
            XCTAssertEqual(f.model.partialSide, side.opposite)
            XCTAssertEqual(f.model.phase, .cancelled)
            XCTAssertTrue(f.model.usesAutomaticTranslation)
            XCTAssertTrue(f.model.workspaceFeedback.contains(L10n.string("Stopped · Incomplete text retained")))
            f.provider.partial(0, "Late fragment")
            f.provider.complete(0, text: "Late completion")
            await settle()
            XCTAssertNil(f.model.result)
            XCTAssertEqual(f.clock.pendingCount, 0)
            XCTAssertEqual(f.model.text(on: side.opposite), "Incomplete fixture")
            f.model.editingChanged(side == .source ? "Continue editing." : "继续输入。", isComposing: false, side: side)
            await f.pauseAndStart()
            f.provider.complete(1, text: "Completed fixture")
            await settle()
            XCTAssertEqual(f.model.text(on: side.opposite), "Completed fixture")
            XCTAssertNil(f.model.partialSide)
            XCTAssertNotNil(f.model.result)
        }
    }

    func testFailurePreservesFragmentWithoutCertifyingItOrAutomaticallyRetrying() async throws {
        let f = try fixture()
        defer { f.finish() }
        f.model.editingChanged("A clear sentence.", isComposing: false)
        await f.pauseAndStart()
        f.provider.partial(0, "Half of the answer")
        f.provider.complete(0, error: RemoteTranslationError.incompleteResponse)
        await settle()
        XCTAssertTrue(f.model.hasTranslationFailure)
        XCTAssertEqual(f.model.translatedText, "Half of the answer")
        XCTAssertEqual(f.model.partialSide, .target)
        XCTAssertNil(f.model.result)
        XCTAssertNil(f.model.makeHandoff()?.completedResult)
        XCTAssertEqual(f.provider.requests.count, 1)
        XCTAssertEqual(f.clock.pendingCount, 0)
    }

    func testUnknownReverseLanguageWaitsForAChoiceThenContinuesAutomatically() async throws {
        let f = try fixture()
        defer { f.finish() }
        f.model.editingChanged("我从右侧开始输入。", isComposing: false, side: .target)
        await settle()
        XCTAssertTrue(f.model.needsReverseLanguage)
        XCTAssertTrue(f.provider.requests.isEmpty)
        XCTAssertEqual(f.clock.pendingCount, 0)
        f.model.submit()
        XCTAssertNil(f.model.request)
        f.model.source = "en"
        await f.pauseAndStart()
        XCTAssertEqual(f.provider.requests.first?.text, "我从右侧开始输入。")
        XCTAssertEqual(f.provider.requests.first?.target, "en")
    }

    func testTurningOffCancelsBothWaitingAndActiveRequestsAndEnablingDoesNotResend() async throws {
        let f = try fixture()
        defer { f.finish() }
        f.model.editingChanged("Waiting input.", isComposing: false)
        await settle()
        f.model.setAutomaticTranslation(false)
        f.clock.releaseAll()
        await settle()
        XCTAssertTrue(f.provider.requests.isEmpty)
        f.model.setAutomaticTranslation(true)
        await settle()
        XCTAssertEqual(f.clock.pendingCount, 0)
        f.model.editingChanged("Active input.", isComposing: false)
        await f.pauseAndStart()
        f.model.setAutomaticTranslation(false)
        f.provider.complete(0, text: "Must not arrive")
        await settle()
        XCTAssertTrue(f.model.translatedText.isEmpty)
        XCTAssertNil(f.model.result)
        f.model.editingChanged("Manual right input.", isComposing: false, side: .target)
        await settle()
        XCTAssertEqual(f.provider.requests.count, 1)
        f.model.source = "en"
        f.model.submit()
        await settle()
        XCTAssertEqual(f.provider.requests.last?.text, "Manual right input.")
    }

    func testCompositionOnEitherSideCancelsOldIntentAndCommitsOnlyOnce() async throws {
        for side in [TranslationSide.source, .target] {
            let f = try fixture()
            defer { f.finish() }
            f.model.source = "en"
            f.model.editingChanged("ni", isComposing: true, side: side)
            f.model.submit()
            f.model.setAutomaticTranslation(false)
            await settle()
            XCTAssertEqual(f.model.phase, .composing)
            XCTAssertTrue(f.model.usesAutomaticTranslation)
            XCTAssertFalse(f.model.canTranslate)
            XCTAssertEqual(f.clock.pendingCount, 0)
            f.model.editingChanged("你好，世界。", isComposing: false, side: side)
            await f.pauseAndStart()
            XCTAssertEqual(f.provider.requests.map(\.text), ["你好，世界。"])
        }
    }

    func testPairUndoAndRedoRestoreOnlyTheLastReplacementWithoutSendingRequests() async throws {
        let f = try fixture()
        defer { f.finish() }
        f.model.source = "en"
        f.model.text = "Original text."
        f.model.editingChanged("人工译文。", isComposing: false, side: .target)
        await f.pauseAndStart()
        f.provider.complete(0, text: "Revised original.")
        await settle()
        XCTAssertTrue(f.model.undoWorkspaceChange())
        XCTAssertEqual(f.model.text, "Original text.")
        XCTAssertEqual(f.model.translatedText, "人工译文。")
        XCTAssertTrue(f.model.redoWorkspaceChange())
        XCTAssertEqual(f.model.text, "Revised original.")
        XCTAssertEqual(f.clock.pendingCount, 0)
        XCTAssertEqual(f.provider.requests.count, 1)
        f.model.clear()
        XCTAssertTrue(f.model.text.isEmpty && f.model.translatedText.isEmpty)
        XCTAssertTrue(f.model.undoWorkspaceChange())
        XCTAssertEqual(f.model.text, "Revised original.")
        XCTAssertEqual(f.model.translatedText, "人工译文。")
        f.model.swapLanguages()
        XCTAssertEqual(f.model.text, "人工译文。")
        XCTAssertEqual(f.model.translatedText, "Revised original.")
        XCTAssertTrue(f.model.undoWorkspaceChange())
        XCTAssertEqual(f.model.source, "en")
        XCTAssertEqual(f.model.target, "zh-Hans")
        f.model.editingChanged("A newer edit.", isComposing: false)
        XCTAssertFalse(f.model.undoWorkspaceChange(), "Old pair undo must never discard newer human edits")
    }

    func testHandoffPreservesBothSidesDirectionAndPartialStateWithoutResubmitting() async throws {
        let f = try fixture()
        defer { f.finish() }
        f.model.source = "en"
        f.model.text = "Original source."
        f.model.editingChanged("右侧草稿。", isComposing: false, side: .target)
        await f.pauseAndStart()
        f.provider.partial(0, "Unfinished reverse")
        let handoff = try XCTUnwrap(f.model.makeHandoff())
        f.model.cancel()
        let input = TranslationModel(automaticallyTranslates: true, services: f.store, remoteProvider: f.provider.make)
        input.acceptHandoff(handoff)
        await settle()
        XCTAssertEqual(input.text, "Unfinished reverse")
        XCTAssertEqual(input.translatedText, "右侧草稿。")
        XCTAssertEqual(input.inputSide, .target)
        XCTAssertEqual(input.partialSide, .source)
        XCTAssertEqual(input.phase, .cancelled)
        XCTAssertNil(input.result)
        XCTAssertNil(input.request)
        XCTAssertEqual(f.provider.requests.count, 1)
    }

    func testPreferenceIsSharedAcrossWindowsAndPersistsWithoutReadingSecrets() async throws {
        let f = try fixture()
        defer { f.finish() }
        let second = TranslationModel(automaticallyTranslates: true, services: f.store, remoteProvider: f.provider.make)
        let reads = f.credentials.reads
        let revision = f.store.revision
        f.model.setAutomaticTranslation(false)
        await settle()
        XCTAssertFalse(second.usesAutomaticTranslation)
        XCTAssertEqual(f.credentials.reads, reads)
        XCTAssertEqual(f.store.revision, revision)
        XCTAssertFalse(try XCTUnwrap(f.store.selectedConfiguration).automaticallyTranslates)
        let reopened = TranslationServiceStore(defaults: f.defaults, credentials: f.credentials)
        XCTAssertFalse(try XCTUnwrap(reopened.selectedConfiguration).automaticallyTranslates)
        try f.store.select(nil)
        await settle()
        XCTAssertTrue(second.usesAutomaticTranslation)
        second.setAutomaticTranslation(false)
        await settle()
        XCTAssertFalse(f.model.usesAutomaticTranslation)
        XCTAssertFalse(TranslationServiceStore(defaults: f.defaults, credentials: f.credentials).appleAutomaticallyTranslates)
    }

    func testChangingAutomaticPreferenceInAnotherWindowDoesNotCancelRecognition() async throws {
        let f = try fixture()
        defer { f.finish() }
        f.model.beginRecognition()
        try f.store.setAutomaticTranslation(false, for: f.store.selectedID)
        await settle()
        XCTAssertEqual(f.model.phase, .recognizing)
        XCTAssertFalse(f.model.usesAutomaticTranslation)
        XCTAssertTrue(f.provider.requests.isEmpty)
    }

    func testNewServicesDefaultOnWhileSavedManualServicesKeepTheirPreference() throws {
        for kind in TranslationServiceKind.allCases {
            let new = TranslationServiceConfiguration(kind: kind)
            XCTAssertTrue(new.automaticallyTranslates)
            var old = new
            old.automaticallyTranslates = false
            XCTAssertFalse(try JSONDecoder().decode(TranslationServiceConfiguration.self, from: JSONEncoder().encode(old)).automaticallyTranslates)
        }
    }

    func testFooterPreferenceUpdatesAnOpenSettingsDraftWithoutLosingOtherEdits() async throws {
        let f = try fixture()
        defer { f.finish() }
        let editor = TranslationServiceEditor(configuration: try XCTUnwrap(f.store.selectedConfiguration), services: f.store)
        f.model.setAutomaticTranslation(false)
        await settle()
        XCTAssertFalse(editor.configuration.automaticallyTranslates)
        XCTAssertFalse(editor.isDirty)
        editor.configuration.name = "Renamed draft"
        f.model.setAutomaticTranslation(true)
        // Save before the observation task runs: a stale draft cannot undo the footer.
        XCTAssertTrue(editor.save())
        XCTAssertTrue(try XCTUnwrap(f.store.selectedConfiguration).automaticallyTranslates)
        XCTAssertEqual(f.store.selectedConfiguration?.name, "Renamed draft")
        XCTAssertTrue(f.provider.requests.isEmpty)
    }

    func testModeChangeDuringSampleTestKeepsItsResultAssociatedWithSavedService() async throws {
        let f = try fixture()
        defer { f.finish() }
        let editor = TranslationServiceEditor(configuration: try XCTUnwrap(f.store.selectedConfiguration), services: f.store)
        editor.test(using: f.provider)
        await settle()
        XCTAssertTrue(editor.isTesting)
        f.model.setAutomaticTranslation(false)
        await settle()
        XCTAssertTrue(editor.isTesting)
        XCTAssertFalse(editor.configuration.automaticallyTranslates)
        f.provider.complete(0, text: "一个清晰的句子。")
        await settle()
        XCTAssertEqual(editor.testState, .succeeded)
        XCTAssertEqual(f.store.sampleTestOutcome(for: try XCTUnwrap(f.store.selectedConfiguration)), .succeeded)
    }

    func testAutoPreferenceDoesNotEraseSampleFeedbackOrRequestCredentials() throws {
        let f = try fixture()
        defer { f.finish() }
        let configuration = try XCTUnwrap(f.store.selectedConfiguration)
        f.store.recordSampleTest(.succeeded, for: configuration, revision: f.store.configurationRevision(for: configuration.id))
        let reads = f.credentials.reads
        try f.store.setAutomaticTranslation(false, for: configuration.id)
        XCTAssertEqual(f.store.sampleTestOutcome(for: try XCTUnwrap(f.store.selectedConfiguration)), .succeeded)
        XCTAssertEqual(f.credentials.reads, reads)
    }

    func testSettingsSaveUpdatesTheSameAutomaticPreferenceWithoutSendingText() async throws {
        let f = try fixture()
        defer { f.finish() }
        f.model.editingChanged("A waiting draft.", isComposing: false)
        await settle()
        var profile = try XCTUnwrap(f.store.selectedConfiguration)
        profile.automaticallyTranslates = false
        try f.store.save(profile, apiKey: nil)
        f.clock.releaseAll()
        await settle()
        XCTAssertFalse(f.model.usesAutomaticTranslation)
        XCTAssertTrue(f.provider.requests.isEmpty)
        XCTAssertEqual(f.model.text, "A waiting draft.")
    }

    func testReverseRemoteRequestPreservesWhitespaceAndRegionalTarget() async throws {
        let f = try fixture()
        defer { f.finish() }
        f.model.source = "pt-PT"
        f.model.target = "en"
        f.model.editingChanged("  A regional translation.\n\n", isComposing: false, side: .target)
        await f.pauseAndStart()
        XCTAssertEqual(f.provider.requests.first?.text, "  A regional translation.\n\n")
        XCTAssertEqual(f.provider.requests.first?.source, "en")
        XCTAssertEqual(f.provider.requests.first?.target, "pt-PT")
    }

    func testNativeEditorPairUndoNeverPublishesProgrammaticInputAndIMEStaysIntact() async throws {
        let f = try fixture()
        defer { f.finish() }
        f.model.source = "en"
        f.model.text = "Original."
        let editor = TranslationTextEditor(text: Binding(get: { f.model.translatedText }, set: { _ in }),
            onEdit: { f.model.editingChanged($0, isComposing: $1, side: .target) }, onSubmit: { f.model.submit() },
            managesWorkspaceUndo: true, canUndoWorkspace: { f.model.canUndoWorkspaceChange },
            canRedoWorkspace: { f.model.canRedoWorkspaceChange }, undoWorkspace: { f.model.undoWorkspaceChange() },
            redoWorkspace: { f.model.redoWorkspaceChange() })
        let coordinator = editor.makeCoordinator()
        let native = TranslationInputTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        coordinator.connect(native)
        coordinator.synchronize(native)
        native.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.synchronize(native)
        XCTAssertTrue(native.hasMarkedText())
        XCTAssertTrue(f.model.isComposing)
        native.insertText("你好。", replacementRange: NSRange(location: NSNotFound, length: 0))
        await f.pauseAndStart()
        f.provider.complete(0, text: "Hello.")
        await settle()
        native.undo(nil)
        coordinator.synchronize(native)
        XCTAssertEqual(f.model.text, "Original.")
        XCTAssertEqual(native.string, "你好。")
        native.redo(nil)
        XCTAssertEqual(f.model.text, "Hello.")
        XCTAssertEqual(f.provider.requests.count, 1)
        XCTAssertEqual(f.clock.pendingCount, 0)
    }

    private func fixture() throws -> MutualFixture {
        let domain = "TranslateX.mutual-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let credentials = MutualCredentials()
        let store = TranslationServiceStore(defaults: defaults, credentials: credentials)
        let profile = TranslationServiceConfiguration(name: "Fixture", kind: .openAICompatible,
            endpoint: "http://localhost:8181/v1", model: "fixture")
        try store.save(profile, apiKey: nil)
        try store.select(profile.id)
        let clock = MutualClock(), provider = MutualProvider()
        let model = TranslationModel(automaticallyTranslates: true, sleep: clock.sleep, services: store, remoteProvider: provider.make)
        return MutualFixture(model: model, store: store, defaults: defaults, credentials: credentials, clock: clock, provider: provider)
    }
    private func settle() async { for _ in 0..<100 { await Task.yield() } }
}

@MainActor private struct MutualFixture {
    let model: TranslationModel
    let store: TranslationServiceStore
    let defaults: UserDefaults
    let credentials: MutualCredentials
    let clock: MutualClock
    let provider: MutualProvider
    func pauseAndStart() async {
        for _ in 0..<100 { await Task.yield() }
        clock.releaseAll()
        for _ in 0..<100 { await Task.yield() }
    }
    func finish() { model.cancel(); clock.releaseAll(); provider.finishAll() }
}
@MainActor private final class MutualCredentials: TranslationCredentialStore {
    var reads = 0
    func credential(for id: UUID) throws -> TranslationServiceCredential? { reads += 1; return nil }
    func setCredential(_ credential: TranslationServiceCredential, for id: UUID) throws { }
    func removeCredential(for id: UUID) throws { }
}
@MainActor private final class MutualClock {
    var pending: [CheckedContinuation<Void, Never>] = []
    var pendingCount: Int { pending.count }
    func sleep(_ delay: Duration) async throws {
        await withCheckedContinuation { pending.append($0) }
        try Task.checkCancellation()
    }
    func releaseAll() { let work = pending; pending = []; work.forEach { $0.resume() } }
}
@MainActor private final class MutualProvider: TranslationProvider {
    var requests: [TranslationRequest] = []
    private var callbacks: [(@MainActor @Sendable (String) -> Void)] = []
    private var continuations: [Int: CheckedContinuation<TranslationResult, any Error>] = [:]
    func make(_ profile: TranslationServiceConfiguration, _ key: String?, _ callback: @escaping @MainActor @Sendable (String) -> Void) -> any TranslationProvider {
        callbacks.append(callback)
        return self
    }
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }
    func partial(_ index: Int, _ text: String) { callbacks[index](text) }
    func complete(_ index: Int, text: String = "", source: String? = nil, error: (any Error)? = nil) {
        guard let continuation = continuations.removeValue(forKey: index) else { return }
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: .init(text: text, source: source ?? requests[index].source, target: requests[index].target)) }
    }
    func finishAll() { for index in Array(continuations.keys) { complete(index, error: CancellationError()) } }
}
