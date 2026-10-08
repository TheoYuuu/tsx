import XCTest
@testable import LumaxTranslate

@MainActor
final class TranslationServiceRoutingTests: XCTestCase {
    func testStatisticsAndWebsiteEditsDoNotInterruptActiveTranslation() async throws {
        let services = try store(), recorder = RoutingRecorder()
        let model = TranslationModel(services: services, remoteProvider: recorder.make)
        model.source = "en"
        model.target = "zh-Hans"
        model.text = "A constructed sentence for the active translation."
        model.submit()
        await settle()
        let request = try XCTUnwrap(model.request), revision = services.revision
        var config = try XCTUnwrap(services.selectedConfiguration)
        config.website = "https://example.com/console"
        try services.save(config, apiKey: nil)
        services.usage.clearAll()
        services.usage.setEnabled(false)
        services.usage.setEnabled(true)
        _ = services.usage.records(for: config.id, days: 30)
        await settle()
        XCTAssertEqual(services.revision, revision)
        XCTAssertEqual(model.request, request)
        XCTAssertEqual(model.phase, .translating)
        XCTAssertEqual(recorder.requests.count, 1)
        recorder.finishAll()
        await settle()
        XCTAssertEqual(model.phase, .completed)
        XCTAssertEqual(model.result?.text, "构造译文")
        XCTAssertTrue(services.usage.records.isEmpty, "Cleared in-flight records cannot reappear.")
    }

    func testCompletedTranslationRecordsWithoutChangingRoutingOrBody() async throws {
        let services = try store(), recorder = RoutingRecorder()
        let model = TranslationModel(services: services, remoteProvider: recorder.make)
        model.source = "en"; model.target = "zh-Hans"
        model.text = "A constructed sentence for usage."
        let revision = services.revision
        model.submit()
        await settle()
        recorder.finishAll()
        await settle()
        XCTAssertEqual(model.phase, .completed)
        XCTAssertEqual(services.revision, revision)
        XCTAssertEqual(services.usage.records.count, 1)
        XCTAssertEqual(services.usage.records.first?.configurationID, services.selectedID)
        XCTAssertEqual(services.usage.records.first?.purpose, .translation)
        XCTAssertNil(services.usage.records.first?.usage)
        XCTAssertEqual(recorder.requests.first?.text, "A constructed sentence for usage.")
        let handoff = model.makeHandoff()
        var config = try XCTUnwrap(services.selectedConfiguration)
        config.website = "https://example.com/new-console"
        try services.save(config, apiKey: nil)
        let destination = TranslationModel(services: services, remoteProvider: recorder.make)
        destination.acceptHandoff(handoff)
        XCTAssertEqual(destination.phase, .completed)
        XCTAssertEqual(destination.result, model.result)
        XCTAssertEqual(recorder.requests.count, 1, "Website metadata cannot invalidate handoff or resend text.")
    }

    func testCodexAccountFailureRemainsVisibleWithoutLeakingToAnotherService() async throws {
        for status in ["account_changed", "authentication_failed", "invalid_account_storage"] {
            for switchToApple in [false, true] {
                let fixture = CodexControllerSessionFixture()
                let domain = "Lumax.codex-account-error.\(UUID().uuidString)"
                addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: domain) }
                let services = TranslationServiceStore(defaults: try XCTUnwrap(UserDefaults(suiteName: domain)),
                    credentials: RoutingCredentials(), codex: fixture.controller())
                var profile = TranslationServiceConfiguration(kind: .codex)
                profile.model = fixture.model.id
                profile.codexAccountGeneration = fixture.generation
                try services.save(profile, apiKey: nil)
                try services.select(profile.id)
                let model = TranslationModel(services: services)
                model.text = "constructed source"
                model.submit()
                try await fixture.waitForRequests(1)
                if switchToApple { try services.select(nil) }
                try fixture.finish(0, status: status)
                await settle()
                XCTAssertNil(model.result)
                XCTAssertNil(model.configuration)
                XCTAssertEqual(fixture.requests.count, 1)
                if switchToApple {
                    XCTAssertEqual(model.phase, .empty)
                    XCTAssertTrue(model.usesAppleTranslation)
                } else {
                    let error = try XCTUnwrap(services.codex.error)
                    XCTAssertEqual(model.phase, .failed(error.localizedDescription), status)
                    XCTAssertFalse(model.usesAppleTranslation)
                }
            }
        }
    }

    func testCodexMainSelectionAndOCRTextUseSharedAccountThroughProductionFactory() async throws {
        let fixture = CodexControllerSessionFixture()
        let domain = "Lumax.codex-routing-tests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let services = TranslationServiceStore(defaults: try XCTUnwrap(UserDefaults(suiteName: domain)),
            credentials: RoutingCredentials(), codex: fixture.controller())
        var profile = TranslationServiceConfiguration(kind: .codex)
        profile.model = fixture.model.id
        profile.codexAccountGeneration = fixture.generation
        try services.save(profile, apiKey: nil)
        try services.select(profile.id)
        let input = TranslationModel(services: services)
        let quick = TranslationModel(services: services)
        for (index, text) in ["typed fixture", "selection fixture", "OCR fixture"].enumerated() {
            let model = index == 0 ? input : quick
            model.source = "en"
            model.target = "zh-Hans"
            if index == 0 {
                model.text = text
                model.submit()
            } else {
                let revision = model.captureServiceIntent()
                if index == 2 { model.beginRecognition() }
                model.submitCapturedText(text, serviceRevision: revision)
            }
            try await fixture.waitForRequests(index + 1)
            let request = fixture.requests[index]
            XCTAssertEqual(request.operation, .translate)
            XCTAssertEqual(request.expectedGeneration, fixture.generation)
            XCTAssertEqual(request.model, fixture.model.id)
            XCTAssertEqual(request.text, text)
            XCTAssertNil(model.configuration, "A Codex request must not start Apple translation.")
            try fixture.finish(index, status: "ok", text: "constructed result \(index)")
            await settle()
            XCTAssertEqual(model.result?.text, "constructed result \(index)")
            XCTAssertEqual(model.phase, .completed)
            XCTAssertTrue(model.partialText.isEmpty)
        }
        XCTAssertEqual(fixture.created, 3, "All entry points share one account controller without status probes or fallback.")
    }

    private func store(automatic: Bool = false, kind: TranslationServiceKind = .openAICompatible) throws -> TranslationServiceStore {
        let domain = "Lumax.routing-tests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let store = TranslationServiceStore(defaults: try XCTUnwrap(UserDefaults(suiteName: domain)),
                                            credentials: RoutingCredentials())
        let profile = TranslationServiceConfiguration(name: "Fixture", kind: kind,
                                                       endpoint: kind == .codex ? kind.defaultEndpoint : "http://localhost:8181/v1",
                                                       model: kind == .codex ? "fixture" : kind.requiresModel && !kind.allowsCustomModel ? kind.defaultModel : (kind.requiresModel ? "fixture" : ""),
                                                       automaticallyTranslates: automatic,
                                                       codexAccountGeneration: kind == .codex ? UUID().uuidString.lowercased() : nil)
        try store.save(profile, apiKey: kind.requiresAPIKey ? "fixture-key" : nil)
        try store.select(profile.id)
        return store
    }

    private func settle() async { for _ in 0..<100 { await Task.yield() } }

    func testExternalProviderRequestsPreserveWhitespaceWhileAppleKeepsTrimming() async throws {
        let passage = "\n  Hello 🌍\n\nSecond paragraph.\t \n"
        for kind in TranslationServiceKind.allCases {
            let services = try store(kind: kind)
            let recorder = RoutingRecorder()
            let model = TranslationModel(services: services, remoteProvider: recorder.make)
            model.text = passage
            model.submit()
            await settle()
            XCTAssertEqual(recorder.requests.map(\.text), [passage], kind.rawValue)
            XCTAssertEqual(model.request?.text, passage)
            recorder.partial?("Current translation")
            XCTAssertEqual(model.partialText, "Current translation")
            recorder.finishAll()
            await settle()
            XCTAssertEqual(model.phase, .completed)
            XCTAssertNotNil(model.result)
        }
        let apple = TranslationModel()
        apple.source = "en"
        apple.text = passage
        apple.submit()
        XCTAssertEqual(apple.request?.text, "Hello 🌍\n\nSecond paragraph.")
        XCTAssertNotNil(apple.configuration)
    }

    func testWhitespaceOnlyRemoteInputDoesNotSubmitOrProduceHandoff() async throws {
        let services = try store()
        let recorder = RoutingRecorder()
        let model = TranslationModel(services: services, remoteProvider: recorder.make)
        model.text = " \n\t "
        XCTAssertFalse(model.canTranslate)
        XCTAssertNil(model.makeHandoff())
        model.submit()
        await settle()
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertNil(model.request)
        XCTAssertEqual(model.phase, .empty)
    }

    func testSavedManualCloudPreferenceDoesNotSubmitTypingLanguageChangesOrComposition() async throws {
        let services = try store()
        let recorder = RoutingRecorder()
        let model = TranslationModel(automaticallyTranslates: true, services: services, remoteProvider: recorder.make)
        model.editingChanged("A private draft.", isComposing: false)
        model.target = "fr"
        model.editingChanged("Unfinished composition", isComposing: true)
        model.submit()
        await settle()
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertNil(model.configuration)
        XCTAssertFalse(model.usesAutomaticTranslation)
        model.editingChanged("A committed passage.", isComposing: false)
        model.submit()
        await settle()
        XCTAssertEqual(recorder.requests.map(\.text), ["A committed passage."])
        XCTAssertNil(recorder.requests.first?.source)
        recorder.finishAll()
        await settle()
        XCTAssertNil(model.result?.source)
        XCTAssertEqual(model.resolvedSource, "en", "Confident on-device detection is separate from an unknown provider response source")
    }

    func testSwitchingServiceDoesNotResendAndRejectsLateDeltasAndCompletion() async throws {
        let services = try store()
        let recorder = RoutingRecorder()
        let model = TranslationModel(services: services, remoteProvider: recorder.make)
        model.text = "Translate this passage."
        model.submit()
        await settle()
        XCTAssertEqual(recorder.requests.count, 1)
        recorder.partial?("部分译文")
        XCTAssertEqual(model.partialText, "部分译文")
        XCTAssertNil(model.result)
        try services.select(nil)
        // Before the observation callback runs, old callbacks already fail closed.
        recorder.partial?("late text")
        recorder.finishAll()
        await settle()
        XCTAssertTrue(model.usesAppleTranslation)
        XCTAssertNil(model.result)
        XCTAssertTrue(model.partialText.isEmpty)
        XCTAssertNil(model.request)
        XCTAssertNil(model.configuration)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(model.text, "Translate this passage.")
    }

    func testConfigurationEditInvalidatesResultWithoutSendingText() async throws {
        let services = try store()
        let recorder = RoutingRecorder()
        let model = TranslationModel(services: services, remoteProvider: recorder.make)
        model.text = "A simple passage."
        model.submit()
        await settle()
        recorder.finishAll()
        await settle()
        XCTAssertNotNil(model.result)
        var profile = try XCTUnwrap(services.selectedConfiguration)
        profile.model = "another-model"
        try services.save(profile, apiKey: nil)
        await settle()
        XCTAssertNil(model.result)
        XCTAssertNil(model.request)
        XCTAssertEqual(model.serviceModelName, "another-model")
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testCancelAndManualEditDropIncompleteOutputAndNeverAllowCopy() async throws {
        for cancel in [true, false] {
            let services = try store()
            let recorder = RoutingRecorder()
            let model = TranslationModel(services: services, remoteProvider: recorder.make)
            model.text = "A simple passage."
            model.submit()
            await settle()
            recorder.partial?("Partial")
            XCTAssertNil(model.result)
            if cancel { model.cancel() } else { model.editingChanged("New passage", isComposing: false) }
            recorder.partial?("Stale")
            recorder.finishAll()
            await settle()
            XCTAssertTrue(model.partialText.isEmpty)
            XCTAssertNil(model.result)
            XCTAssertNil(model.request)
        }
    }

    func testIncompleteRemoteResponseDoesNotBecomeSuccessfulResult() async throws {
        let services = try store()
        let recorder = RoutingRecorder()
        let model = TranslationModel(services: services, remoteProvider: recorder.make)
        model.text = "A simple passage."
        model.submit()
        await settle()
        recorder.partial?("Half a translation")
        recorder.finishAll(error: RemoteTranslationError.incompleteResponse)
        await settle()
        XCTAssertNil(model.result)
        XCTAssertEqual(model.translatedText, "Half a translation")
        XCTAssertEqual(model.partialSide, .target)
        XCTAssertEqual(model.phase, .failed(RemoteTranslationError.incompleteResponse.errorDescription!))
        XCTAssertNil(model.configuration)
    }

    func testCompletedRemoteHandoffReusesSameServiceWithoutChargingAgain() async throws {
        let services = try store()
        let recorder = RoutingRecorder()
        let quick = TranslationModel(services: services, remoteProvider: recorder.make)
        quick.text = "\n  A simple passage.\t \n"
        quick.submit()
        await settle()
        recorder.finishAll()
        await settle()
        let snapshot = try XCTUnwrap(quick.makeHandoff())
        XCTAssertEqual(recorder.requests.first?.text, quick.text)
        XCTAssertNotNil(snapshot.completedResult)
        let input = TranslationModel(automaticallyTranslates: true, services: services, remoteProvider: recorder.make)
        input.acceptHandoff(snapshot)
        await settle()
        XCTAssertEqual(input.text, "\n  A simple passage.\t \n")
        XCTAssertEqual(input.result, quick.result)
        XCTAssertEqual(input.phase, .completed)
        XCTAssertNil(input.request)
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testPendingRemoteHandoffRequiresManualResubmitAndChangedServiceCannotReuse() async throws {
        let services = try store()
        let recorder = RoutingRecorder()
        let quick = TranslationModel(services: services, remoteProvider: recorder.make)
        quick.text = "A simple passage."
        quick.submit()
        await settle()
        let input = TranslationModel(services: services, remoteProvider: recorder.make)
        input.acceptHandoff(quick.makeHandoff())
        await settle()
        XCTAssertEqual(input.phase, .cancelled)
        XCTAssertNil(input.request)
        XCTAssertEqual(recorder.requests.count, 1)
        recorder.finishAll()
        await settle()
        let completed = quick.makeHandoff()
        try services.select(nil)
        input.acceptHandoff(completed)
        XCTAssertNil(input.result)
        XCTAssertNil(input.configuration)
        XCTAssertEqual(input.text, quick.text)
    }

    func testCloudAutoTranslationRestartsPauseAndNeverUsesAppleSession() async throws {
        let services = try store(automatic: true)
        let recorder = RoutingRecorder()
        let sleeper = RoutingSleeper()
        defer { sleeper.releaseAll(); recorder.finishAll() }
        let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep,
                                     services: services, remoteProvider: recorder.make)
        model.editingChanged("First", isComposing: false)
        await settle()
        model.editingChanged("Latest", isComposing: false)
        await settle()
        XCTAssertEqual(sleeper.delays, [.milliseconds(650), .milliseconds(650)])
        sleeper.releaseFirst()
        await settle()
        XCTAssertTrue(recorder.requests.isEmpty)
        sleeper.releaseFirst()
        await settle()
        XCTAssertEqual(recorder.requests.map(\.text), ["Latest"])
        XCTAssertNil(model.configuration)
    }

    func testTrailingWhitespaceEditRejectsStaleOutputAndQueuesLatestAutomaticSnapshot() async throws {
        // Both an old completion and an old failure must advance the new input.
        for completionError in [nil, RemoteTranslationError.timedOut] {
            let services = try store(automatic: true)
            let recorder = RoutingRecorder()
            let sleeper = RoutingSleeper()
            let model = TranslationModel(automaticallyTranslates: true, sleep: sleeper.sleep,
                                         services: services, remoteProvider: recorder.make)
            defer { model.cancel(); sleeper.releaseAll(); recorder.finishAll() }
            let first = "  First paragraph.\n\nSecond paragraph."
            let latest = first + " \n"
            model.editingChanged(first, isComposing: false)
            await settle()
            sleeper.releaseFirst()
            await settle()
            XCTAssertEqual(recorder.requests.map(\.text), [first])
            recorder.partial?("Old partial")
            XCTAssertEqual(model.partialText, "Old partial")

            model.editingChanged(latest, isComposing: false)
            recorder.partial?("Stale partial")
            XCTAssertTrue(model.partialText.isEmpty)
            XCTAssertNil(model.makeHandoff()?.completedResult)
            recorder.finishAll(error: completionError)
            await settle()
            XCTAssertNil(model.result)
            XCTAssertEqual(model.phase, .waiting)
            XCTAssertNil(model.makeHandoff()?.completedResult)

            sleeper.releaseFirst()
            await settle()
            XCTAssertEqual(recorder.requests.map(\.text), [first, latest])
            recorder.partial?("Current partial")
            XCTAssertEqual(model.partialText, "Current partial")
            recorder.finishAll()
            await settle()
            XCTAssertEqual(model.phase, .completed)
            XCTAssertNotNil(model.result)
            XCTAssertNotNil(model.makeHandoff()?.completedResult)
        }
    }

    func testServiceChangeDuringRecognitionKeepsBusyAndNeverSendsCapturedText() async throws {
        let services = try store()
        try services.select(nil)
        let recorder = RoutingRecorder()
        let model = TranslationModel(services: services, remoteProvider: recorder.make)
        let intent = model.captureServiceIntent()
        model.beginRecognition()
        try services.select(services.configurations[0].id)
        await settle()
        XCTAssertEqual(model.phase, .recognizing)
        XCTAssertTrue(model.isBusy)
        model.submitCapturedText("Text recognized on device.", serviceRevision: intent)
        await settle()
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertNil(model.configuration)
        XCTAssertEqual(model.text, "Text recognized on device.")
        guard case .failed = model.phase else { return XCTFail("A changed capture destination must require a new intent") }
    }

    func testCapturedIntentRejectsChangeBeforeObservationAndUnchangedIntentSubmits() async throws {
        let services = try store()
        let recorder = RoutingRecorder()
        let model = TranslationModel(services: services, remoteProvider: recorder.make)
        let oldIntent = model.captureServiceIntent()
        try services.select(nil)
        model.submitCapturedText("Selected text", serviceRevision: oldIntent)
        XCTAssertNil(model.configuration)
        XCTAssertNil(model.request)
        try services.select(services.configurations[0].id)
        let newIntent = model.captureServiceIntent()
        model.submitCapturedText("Selected text", serviceRevision: newIntent)
        await settle()
        XCTAssertEqual(recorder.requests.map(\.text), ["Selected text"])
        recorder.finishAll()
        await settle()
    }

    func testPendingHandoffClearsExistingResultEvenWhenContentIsIdentical() async throws {
        let services = try store()
        let recorder = RoutingRecorder()
        let input = TranslationModel(services: services, remoteProvider: recorder.make)
        input.text = "The same passage."
        input.submit()
        await settle()
        recorder.finishAll()
        await settle()
        XCTAssertNotNil(input.result)
        let quick = TranslationModel(services: services, remoteProvider: recorder.make)
        quick.text = input.text
        input.acceptHandoff(quick.makeHandoff())
        XCTAssertNil(input.result)
        XCTAssertNil(input.displayedResult)
        XCTAssertNil(input.request)
        XCTAssertEqual(input.phase, .empty)
    }

    func testModelLanguageChoicesDoNotDependOnDownloadedAppleLanguages() throws {
        let catalog = LanguageCatalog()
        XCTAssertTrue(catalog.languages.isEmpty)
        XCTAssertTrue(catalog.languages(for: nil).isEmpty)
        XCTAssertTrue(catalog.languages(for: try store().selectedConfiguration).contains { $0.id == "hi" })
    }

    func testRegionalAndScriptConversionsAreNotSuppressedAsSameLanguage() async throws {
        let services = try store()
        let recorder = RoutingRecorder()
        let model = TranslationModel(services: services, remoteProvider: recorder.make)
        for (source, target) in [("en", "en-GB"), ("pt", "pt-PT"), ("zh-Hans", "zh-Hant")] {
            model.source = source
            model.target = target
            model.text = "A generated regional-language fixture."
            model.submit()
            await settle()
            XCTAssertEqual(recorder.requests.last?.source, source)
            XCTAssertEqual(recorder.requests.last?.target, target)
            XCTAssertEqual(model.phase, .translating)
            recorder.finishAll()
            await settle()
        }
        XCTAssertEqual(recorder.requests.count, 3)
        XCTAssertTrue(TranslationModel.isSameLanguage("en-US", "en"))
        XCTAssertTrue(TranslationModel.isSameLanguage("zh-CN", "zh-Hans"))
    }

    func testDedicatedLanguagePickersOnlyExposeMappedChoicesForTheirDirection() {
        let catalog = LanguageCatalog()
        for kind in [TranslationServiceKind.deepL, .azureTranslator] {
            let profile = TranslationServiceConfiguration(kind: kind)
            for asTarget in [false, true] {
                let choices = catalog.languages(for: profile, asTarget: asTarget)
                XCTAssertFalse(choices.isEmpty)
                for choice in choices {
                    XCTAssertNotNil(DedicatedTranslationLanguages.code(for: choice.id, kind: kind, asTarget: asTarget))
                }
                XCTAssertTrue(choices.contains { $0.id == "zh-Hans" })
                XCTAssertTrue(choices.contains { $0.id == "zh-Hant" })
            }
        }
    }

    func testNewDedicatedLanguagePickersKeepTheirVerifiedLanguageSubsets() {
        let catalog = LanguageCatalog()
        for asTarget in [false, true] {
            let qwen = catalog.languages(for: .init(kind: .qwenMT), asTarget: asTarget)
            XCTAssertEqual(qwen.count, 52)
            XCTAssertFalse(qwen.contains { $0.id == "ga" || $0.id == "pt-PT" })
            for choice in qwen {
                XCTAssertNotNil(QwenMTTranslationLanguages.code(for: choice.id, asTarget: asTarget))
            }
            let google = catalog.languages(for: .init(kind: .googleCloud), asTarget: asTarget)
            XCTAssertEqual(google.count, 53)
            XCTAssertFalse(google.contains { $0.id == "nb" })
            XCTAssertTrue(google.contains { $0.id == "pt-PT" })
            for choice in google {
                XCTAssertNotNil(GoogleTranslationLanguages.code(for: choice.id, asTarget: asTarget))
            }
            for choices in [qwen, google] {
                XCTAssertTrue(choices.contains { $0.id == "zh-Hans" })
                XCTAssertTrue(choices.contains { $0.id == "zh-Hant" })
            }
        }
        XCTAssertEqual(catalog.languages(for: .init(kind: .claude)).count, 54)
    }

    func testTencentLanguagePickerPreservesScriptsWithoutInventingRegionalSupport() {
        let catalog = LanguageCatalog()
        for asTarget in [false, true] {
            let choices = catalog.languages(for: .init(kind: .tencentTranslation), asTarget: asTarget)
            XCTAssertEqual(choices.count, 29)
            XCTAssertTrue(choices.contains { $0.id == "zh-Hans" })
            XCTAssertTrue(choices.contains { $0.id == "zh-Hant" })
            XCTAssertFalse(choices.contains { $0.id == "pt-PT" || $0.id == "nb" || $0.id == "auto" })
            for choice in choices {
                XCTAssertNotNil(TencentTranslationLanguages.code(for: choice.id, asTarget: asTarget))
            }
        }
        XCTAssertEqual(TencentTranslationLanguages.code(for: "zh-Hant"), "zh-TR")
        XCTAssertEqual(TencentTranslationLanguages.detectedSourceIdentifier(from: "zh-TR"), "zh-Hant")
    }
}

@MainActor
private final class RoutingCredentials: TranslationCredentialStore {
    private var values: [UUID: TranslationServiceCredential] = [:]
    func credential(for id: UUID) throws -> TranslationServiceCredential? { values[id] }
    func setCredential(_ credential: TranslationServiceCredential, for id: UUID) throws { values[id] = credential }
    func removeCredential(for id: UUID) throws { values.removeValue(forKey: id) }
}

@MainActor
private final class RoutingRecorder: TranslationProvider {
    var requests: [TranslationRequest] = []
    var partial: (@MainActor @Sendable (String) -> Void)?
    private var pending: [(TranslationRequest, CheckedContinuation<TranslationResult, any Error>)] = []

    func make(_ configuration: TranslationServiceConfiguration, _ key: String?,
              _ callback: @escaping @MainActor @Sendable (String) -> Void) -> any TranslationProvider {
        partial = callback
        return self
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        requests.append(request)
        // Deliberately ignore cancellation to exercise the model's stale guards.
        return try await withCheckedThrowingContinuation { pending.append((request, $0)) }
    }

    func finishAll(error: (any Error)? = nil) {
        let work = pending
        pending = []
        for (request, continuation) in work {
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: .init(text: "构造译文", source: request.source, target: request.target)) }
        }
    }
}

@MainActor
private final class RoutingSleeper {
    var delays: [Duration] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func sleep(_ duration: Duration) async throws {
        delays.append(duration)
        await withCheckedContinuation { continuations.append($0) }
        try Task.checkCancellation()
    }
    func releaseFirst() { if !continuations.isEmpty { continuations.removeFirst().resume() } }
    func releaseAll() { while !continuations.isEmpty { releaseFirst() } }
}
