import XCTest
@testable import LumaxTranslate

@MainActor
final class TranslationServiceEditorTests: XCTestCase {
    func testSavedUntestedServicePublishesSuccessBeforeReturningWithoutSaving() async throws {
        try await withStore { store, credentials in
            let configuration = TranslationServiceConfiguration(kind: .deepSeek)
            try store.save(configuration, apiKey: "fixture-key")
            XCTAssertNil(store.sampleTestOutcome(for: configuration))
            let session = TranslationServiceDraftSession(services: store, configuration: configuration)
            let revision = store.revision
            let provider = EditorTestProvider()
            session.editor.test(using: provider)
            await waitUntil { provider.request != nil }
            provider.finish(text: "构造的样例译文")
            await waitUntil { session.editor.testState == .succeeded }
            XCTAssertEqual(store.sampleTestOutcome(for: configuration), .succeeded)
            XCTAssertFalse(session.hasUnsavedChanges)
            XCTAssertFalse(session.editor.canSave, "Testing alone does not require saving configuration")
            let reads = credentials.reads
            session.close() // Same teardown used by Back, Cancel and settings closure.
            XCTAssertEqual(store.sampleTestOutcome(for: configuration), .succeeded)
            XCTAssertEqual(store.revision, revision, "Feedback must not restart translation")
            XCTAssertEqual(credentials.reads, reads, "Displaying feedback must not reveal a key")
            XCTAssertNil(store.selectedID)
        }
    }

    func testTestingUnsavedModelDoesNotCertifyTheSavedServiceWhenDiscarded() async throws {
        try await withStore { store, _ in
            let configuration = TranslationServiceConfiguration(kind: .deepSeek)
            try store.save(configuration, apiKey: "fixture-key")
            let editor = TranslationServiceEditor(configuration: configuration, services: store)
            editor.configuration.model = "draft-model"
            let provider = EditorTestProvider()
            editor.test(using: provider)
            await waitUntil { provider.request != nil }
            provider.finish(text: "构造的草稿译文")
            await waitUntil { editor.testState == .succeeded }
            XCTAssertNil(store.sampleTestOutcome(for: configuration))
            editor.close()
            XCTAssertEqual(store.configurations, [configuration])
            XCTAssertNil(store.sampleTestOutcome(for: configuration))
        }
    }

    func testTestedNewServiceCarriesItsResultOnlyAfterSave() async throws {
        try await withStore { store, _ in
            var configuration = TranslationServiceConfiguration(kind: .deepSeek)
            configuration.name = "  My translation  "
            let editor = TranslationServiceEditor(configuration: configuration, services: store)
            editor.replacementKey = "fixture-new-key"
            let provider = EditorTestProvider()
            editor.test(using: provider)
            await waitUntil { provider.request != nil }
            provider.finish(text: "构造的样例译文")
            await waitUntil { editor.testState == .succeeded }
            XCTAssertTrue(store.configurations.isEmpty)
            XCTAssertNil(store.sampleTestOutcome(for: configuration))
            let finishedAt = Date()
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertTrue(editor.save())
            XCTAssertLessThanOrEqual(try XCTUnwrap(store.sampleTestRecord(for: configuration.id)).completedAt, finishedAt,
                                     "Saving later must retain the actual test completion time")
            let saved = try XCTUnwrap(store.configurations.first)
            XCTAssertEqual(saved.name, "My translation")
            XCTAssertEqual(store.sampleTestOutcome(for: saved), .succeeded)
            editor.close()
            XCTAssertEqual(store.sampleTestOutcome(for: saved), .succeeded)
        }
    }

    func testTestedReplacementKeyDoesNotCertifyOldKeyAndFollowsSuccessfulSave() async throws {
        try await withStore { store, credentials in
            let configuration = TranslationServiceConfiguration(kind: .deepSeek)
            try store.save(configuration, apiKey: "fixture-old-key")
            let editor = TranslationServiceEditor(configuration: configuration, services: store)
            editor.replacementKey = "fixture-replacement-key"
            let provider = EditorTestProvider()
            editor.test(using: provider)
            await waitUntil { provider.request != nil }
            provider.finish(text: "构造的样例译文")
            await waitUntil { editor.testState == .succeeded }
            XCTAssertNil(store.sampleTestOutcome(for: configuration))
            XCTAssertEqual(credentials.values[configuration.id]?.apiKey, "fixture-old-key")
            XCTAssertTrue(editor.save())
            XCTAssertEqual(store.sampleTestOutcome(for: configuration), .succeeded)
            XCTAssertEqual(credentials.values[configuration.id]?.apiKey, "fixture-replacement-key")
        }
    }

    func testKeySavedDuringTestRejectsLateStatusEvenWhenConfigurationIsIdentical() async throws {
        try await withStore { store, _ in
            let configuration = TranslationServiceConfiguration(kind: .deepSeek)
            try store.save(configuration, apiKey: "fixture-old-key")
            let editor = TranslationServiceEditor(configuration: configuration, services: store)
            let provider = EditorTestProvider()
            editor.test(using: provider)
            await waitUntil { provider.request != nil }
            try store.save(configuration, apiKey: "fixture-new-key")
            provider.finish(text: "来自旧密钥请求的构造译文")
            await waitUntil { editor.testState == .succeeded }
            XCTAssertNil(store.sampleTestOutcome(for: configuration))
            XCTAssertTrue(editor.save())
            XCTAssertNil(store.sampleTestOutcome(for: configuration), "Saving must not revive stale credential evidence")
            editor.close()
        }
    }

    func testCancelledOrClosedTestsCannotPublishLateSuccessToList() async throws {
        try await withStore { store, _ in
            let configuration = TranslationServiceConfiguration(kind: .deepSeek)
            try store.save(configuration, apiKey: "fixture-key")
            for close in [false, true] {
                let editor = TranslationServiceEditor(configuration: configuration, services: store)
                let provider = EditorTestProvider()
                editor.test(using: provider)
                await waitUntil { provider.request != nil }
                if close { editor.close() } else { editor.cancelTest() }
                provider.finish(text: "迟到的构造译文")
                await waitUntil { provider.sawCancellation }
                XCTAssertNil(store.sampleTestOutcome(for: configuration))
                editor.close()
            }
        }
    }

    func testCompletedFailureReplacesEarlierSuccessWithoutSaving() async throws {
        try await withStore { store, _ in
            let configuration = TranslationServiceConfiguration(kind: .deepSeek)
            try store.save(configuration, apiKey: "fixture-key")
            let editor = TranslationServiceEditor(configuration: configuration, services: store)
            let first = EditorTestProvider()
            editor.test(using: first)
            await waitUntil { first.request != nil }
            first.finish(text: "构造的样例译文")
            await waitUntil { editor.testState == .succeeded }
            XCTAssertEqual(store.sampleTestOutcome(for: configuration), .succeeded)
            let second = EditorTestProvider()
            editor.test(using: second)
            await waitUntil { second.request != nil }
            second.fail()
            await waitUntil { editor.testState == .failed }
            editor.close()
            XCTAssertEqual(store.sampleTestOutcome(for: configuration), .failed)
        }
    }

    func testEditingAfterSuccessAndFailedSaveDoNotAttachDraftResultToSavedService() async throws {
        try await withStore { store, credentials in
            let configuration = TranslationServiceConfiguration(kind: .deepSeek)
            try store.save(configuration, apiKey: "fixture-key")
            let editor = TranslationServiceEditor(configuration: configuration, services: store)
            editor.replacementKey = "fixture-other-key"
            let provider = EditorTestProvider()
            editor.test(using: provider)
            await waitUntil { provider.request != nil }
            provider.finish(text: "构造的样例译文")
            await waitUntil { editor.testState == .succeeded }
            credentials.failWrites = true
            XCTAssertFalse(editor.save())
            XCTAssertNil(store.sampleTestOutcome(for: configuration))
            credentials.failWrites = false
            editor.configuration.model = "another-model"
            XCTAssertTrue(editor.save())
            XCTAssertNil(store.sampleTestOutcome(for: try XCTUnwrap(store.configurations.first)))
        }
    }

    func testNewDraftsRequireExplicitModelChoiceWithoutChangingSavedConfigurations() async throws {
        try await withStore { store, _ in
            let saved = TranslationServiceConfiguration(kind: .openAI)
            try store.save(saved, apiKey: "fixture-key")
            let session = TranslationServiceDraftSession(services: store)
            defer { session.close() }
            for kind in [TranslationServiceKind.openAI, .deepSeek, .claude, .openAICompatible, .ollama] {
                session.selectKind(kind)
                XCTAssertEqual(session.editor.configuration.model, "", kind.rawValue)
                XCTAssertFalse(session.hasUnsavedChanges, "Choosing a provider alone should not create an unsaved edit")
            }
            session.selectKind(.qwenMT)
            XCTAssertEqual(session.editor.configuration.model, TranslationServiceKind.qwenMT.defaultModel)
            session.edit(saved)
            XCTAssertEqual(session.editor.configuration.model, saved.model)
            XCTAssertFalse(session.hasUnsavedChanges)
        }
    }

    func testModelReadinessFollowsCredentialsAndReceiverWithoutReadingSecrets() async throws {
        try await withStore { store, credentials in
            let session = TranslationServiceDraftSession(services: store)
            defer { session.close() }
            let editor = session.editor
            XCTAssertFalse(editor.canConfigureModel)
            XCTAssertFalse(editor.canTest)
            editor.replacementKey = "  "
            XCTAssertFalse(editor.canConfigureModel)
            editor.replacementKey = "fixture-key"
            XCTAssertTrue(editor.canConfigureModel)
            XCTAssertFalse(editor.canTest, "Choosing a model is an explicit setup step")
            editor.configuration.model = "custom-model"
            XCTAssertTrue(editor.canTest)
            editor.configuration.endpoint = "https://another.example/v1"
            XCTAssertFalse(editor.canConfigureModel)
            XCTAssertTrue(editor.replacementKey.isEmpty)
            editor.replacementKey = "fixture-new-key"
            XCTAssertTrue(editor.canConfigureModel)
            editor.configuration.endpoint = "not a URL"
            XCTAssertFalse(editor.canConfigureModel)
            session.selectKind(.ollama)
            XCTAssertTrue(session.editor.canConfigureModel, "Local anonymous servers do not need a key")
            session.selectKind(.openAICompatible)
            XCTAssertFalse(session.editor.canConfigureModel, "Custom services require an explicit endpoint")
            session.editor.configuration.endpoint = "https://custom.example/v1"
            XCTAssertTrue(session.editor.canConfigureModel)
            XCTAssertEqual(credentials.reads, 0)
        }
    }

    func testSavedCredentialEnablesModelConfigurationWithoutRevealingOrReplacingIt() async throws {
        try await withStore { store, credentials in
            let saved = TranslationServiceConfiguration(kind: .openAI)
            try store.save(saved, apiKey: "fixture-key")
            let editor = TranslationServiceEditor(configuration: saved, services: store)
            editor.refreshKeyState()
            XCTAssertTrue(editor.canConfigureModel)
            XCTAssertTrue(editor.keyFieldText.isEmpty)
            XCTAssertEqual(credentials.reads, 0)
            editor.configuration.endpoint = "https://another.example/v1"
            XCTAssertFalse(editor.canConfigureModel)
            editor.configuration.endpoint = saved.endpoint
            XCTAssertTrue(editor.canConfigureModel)
            XCTAssertEqual(credentials.reads, 0)
        }
    }

    func testDedicatedDraftSavesWithoutModelAndPreservesAzureRegion() async throws {
        try await withStore { store, _ in
            for kind in [TranslationServiceKind.deepL, .azureTranslator, .googleCloud] {
                let editor = TranslationServiceEditor(configuration: .init(kind: kind), services: store)
                editor.replacementKey = "fixture-dedicated-key"
                if kind == .azureTranslator { editor.configuration.region = " EastUS " }
                XCTAssertTrue(editor.save())
                let saved = try XCTUnwrap(store.configurations.last)
                XCTAssertEqual(saved.kind, kind)
                XCTAssertEqual(saved.model, "")
                XCTAssertEqual(saved.region, kind == .azureTranslator ? "eastus" : "")
                XCTAssertNil(store.selectedID)
            }
        }
    }

    func testQwenRegionChangeClearsTypedKeyAndCannotBorrowSavedKey() async throws {
        try await withStore { store, _ in
            let config = TranslationServiceConfiguration(kind: .qwenMT)
            try store.save(config, apiKey: "fixture-beijing-key")
            let editor = TranslationServiceEditor(configuration: config, services: store)
            editor.replacementKey = "fixture-key-for-old-region"
            editor.useQwenMTEndpoint(.singapore)
            XCTAssertEqual(editor.configuration.endpoint, QwenMTEndpoint.singapore.rawValue)
            XCTAssertTrue(editor.replacementKey.isEmpty)
            let provider = EditorTestProvider()
            editor.test(using: provider)
            await settleTasks()
            XCTAssertNil(provider.request)
            XCTAssertFalse(editor.save())
            XCTAssertEqual(editor.errorMessage, TranslationServiceConfigurationError.endpointChanged.localizedDescription)
            XCTAssertEqual(try store.apiKey(for: config.id), "fixture-beijing-key")
            editor.replacementKey = "fixture-singapore-key"
            editor.useQwenMTEndpoint(.singapore)
            XCTAssertEqual(editor.replacementKey, "fixture-singapore-key")
            XCTAssertTrue(editor.save())
            XCTAssertEqual(try store.apiKey(for: config.id), "fixture-singapore-key")
        }
    }

    func testClaudeOutputLimitEditCancelsOldTestAndPersistsNewLimit() async throws {
        try await withStore { store, _ in
            let editor = TranslationServiceEditor(configuration: .init(kind: .claude), services: store)
            editor.replacementKey = "fixture-claude-key"
            let provider = EditorTestProvider()
            editor.test(using: provider)
            await settleTasks()
            XCTAssertNotNil(provider.request)
            editor.configuration.maximumOutputTokens = 16_384
            provider.finish(text: "obsolete fixture")
            await settleTasks()
            XCTAssertTrue(provider.sawCancellation)
            XCTAssertTrue(editor.testResult.isEmpty)
            XCTAssertFalse(editor.isTesting)
            XCTAssertTrue(editor.save())
            XCTAssertEqual(store.configurations.first?.maximumOutputTokens, 16_384)
        }
    }

    func testTencentRegionChangeCannotReuseSavedOrTypedKey() async throws {
        try await withStore { store, _ in
            let config = TranslationServiceConfiguration(kind: .tencentTranslation)
            try store.save(config, apiKey: "fixture-guangzhou-key")
            let editor = TranslationServiceEditor(configuration: config, services: store)
            editor.replacementKey = "fixture-key-for-old-region"
            editor.useTencentEndpoint(.singapore)
            XCTAssertTrue(editor.replacementKey.isEmpty)
            let provider = EditorTestProvider()
            editor.test(using: provider)
            await settleTasks()
            XCTAssertNil(provider.request)
            XCTAssertFalse(editor.save())
            XCTAssertEqual(editor.errorMessage, TranslationServiceConfigurationError.endpointChanged.localizedDescription)
            XCTAssertEqual(try store.apiKey(for: config.id), "fixture-guangzhou-key")
            editor.replacementKey = "fixture-singapore-key"
            editor.useTencentEndpoint(.singapore)
            XCTAssertEqual(editor.replacementKey, "fixture-singapore-key")
            XCTAssertTrue(editor.save())
            XCTAssertEqual(store.configurations.first?.endpoint, TencentTranslationEndpoint.singapore.rawValue)
            XCTAssertEqual(try store.apiKey(for: config.id), "fixture-singapore-key")
        }
    }

    func testDeepLPlanChangeRequiresExplicitKeyReplacementAndDoesNotRetest() async throws {
        try await withStore { store, _ in
            let config = TranslationServiceConfiguration(kind: .deepL)
            try store.save(config, apiKey: "fixture-free-key")
            let editor = TranslationServiceEditor(configuration: config, services: store)
            editor.replacementKey = "fixture-typed-for-old-address"
            editor.useDeepLEndpoint(.pro)
            XCTAssertEqual(editor.configuration.endpoint, DeepLAPIEndpoint.pro.rawValue)
            XCTAssertTrue(editor.replacementKey.isEmpty)
            XCTAssertFalse(editor.isTesting)
            XCTAssertFalse(editor.save())
            XCTAssertEqual(editor.errorMessage, TranslationServiceConfigurationError.endpointChanged.localizedDescription)
            XCTAssertEqual(store.configurations.first?.endpoint, DeepLAPIEndpoint.free.rawValue)
            XCTAssertEqual(try store.apiKey(for: config.id), "fixture-free-key")
            editor.replacementKey = "fixture-pro-key"
            editor.useDeepLEndpoint(.pro)
            XCTAssertEqual(editor.replacementKey, "fixture-pro-key", "Selecting the current plan must not clear the entered key.")
            XCTAssertTrue(editor.save())
            XCTAssertEqual(store.configurations.first?.endpoint, DeepLAPIEndpoint.pro.rawValue)
            XCTAssertEqual(try store.apiKey(for: config.id), "fixture-pro-key")
        }
    }

    func testInvalidAzureRegionPreventsTestAndSaveWithoutChangingStoredService() async throws {
        try await withStore { store, _ in
            let config = TranslationServiceConfiguration(kind: .azureTranslator)
            try store.save(config, apiKey: "fixture-azure-key")
            let editor = TranslationServiceEditor(configuration: config, services: store)
            editor.configuration.region = "eastus\r\nmalformed"
            let provider = EditorTestProvider()
            editor.test(using: provider)
            await settleTasks()
            XCTAssertNil(provider.request)
            XCTAssertFalse(editor.isTesting)
            XCTAssertEqual(editor.errorMessage, TranslationServiceConfigurationError.invalidRegion.localizedDescription)
            XCTAssertFalse(editor.save())
            XCTAssertEqual(store.configurations.first?.region, "")
            XCTAssertEqual(try store.apiKey(for: config.id), "fixture-azure-key")
        }
    }

    func testAzureRegionEditCancelsAnActiveTestAndDiscardsItsResult() async throws {
        try await withStore { store, _ in
            let editor = TranslationServiceEditor(configuration: .init(kind: .azureTranslator), services: store)
            editor.replacementKey = "fixture-azure-key"
            let provider = EditorTestProvider()
            editor.test(using: provider)
            await settleTasks()
            XCTAssertNotNil(provider.request)
            editor.configuration.region = "eastus"
            provider.finish(text: "obsolete fixture translation")
            await settleTasks()
            XCTAssertTrue(provider.sawCancellation)
            XCTAssertFalse(editor.isTesting)
            XCTAssertTrue(editor.testResult.isEmpty)
            XCTAssertNil(editor.testDuration)
        }
    }

    func testOpeningExistingServiceDoesNotReadOrDisplayItsSavedKey() async throws {
        try await withStore { store, credentials in
            let configuration = TranslationServiceConfiguration(kind: .openAI)
            try store.save(configuration, apiKey: "test-private-key")
            let reads = credentials.reads
            let editor = TranslationServiceEditor(configuration: configuration, services: store)
            XCTAssertEqual(credentials.reads, reads)
            XCTAssertTrue(editor.replacementKey.isEmpty)
            XCTAssertFalse(editor.isNew)
            XCTAssertFalse(editor.isTesting)
            XCTAssertTrue(editor.testResult.isEmpty)
            XCTAssertNil(store.selectedID)
        }
    }

    func testExplicitTestUsesOnlyPublicSampleAndDoesNotSaveOrActivateTheDraft() async throws {
        try await withStore { store, _ in
            let editor = TranslationServiceEditor(configuration: .init(kind: .deepSeek), services: store)
            editor.replacementKey = "test-private-key"
            let provider = EditorTestProvider()
            editor.test(using: provider)
            await settleTasks()
            XCTAssertTrue(editor.isTesting)
            XCTAssertEqual(provider.request?.text, TranslationServiceEditor.testSample)
            XCTAssertEqual(provider.request?.source, "en")
            XCTAssertEqual(provider.request?.target, "zh-Hans")
            XCTAssertTrue(store.configurations.isEmpty)
            XCTAssertNil(store.selectedID)
            provider.finish(text: "清晰的句子很容易理解。")
            await settleTasks()
            XCTAssertFalse(editor.isTesting)
            XCTAssertEqual(editor.testResult, "清晰的句子很容易理解。")
            XCTAssertNotNil(editor.testDuration)
            XCTAssertNil(editor.errorMessage)
        }
    }

    func testEditingDraftCancelsTestAndDiscardsLateResponse() async throws {
        try await withStore { store, _ in
            let editor = TranslationServiceEditor(configuration: .init(kind: .openAI), services: store)
            editor.replacementKey = "test-private-key"
            let provider = EditorTestProvider()
            editor.test(using: provider)
            await settleTasks()
            XCTAssertNotNil(provider.request)
            editor.configuration.model = "another-model"
            XCTAssertTrue(editor.isTesting)
            XCTAssertEqual(editor.testState, .stopping)
            provider.finish(text: "obsolete translation")
            await waitUntil { !editor.isTesting }
            XCTAssertFalse(editor.isTesting)
            XCTAssertTrue(provider.sawCancellation)
            XCTAssertTrue(editor.testResult.isEmpty)
            XCTAssertNil(editor.testDuration)
            XCTAssertNil(editor.errorMessage)
        }
    }

    func testStopClearsOutputAndSuppressesLateError() async throws {
        try await withStore { store, _ in
            let editor = TranslationServiceEditor(configuration: .init(kind: .openAI), services: store)
            editor.replacementKey = "test-private-key"
            let provider = EditorTestProvider()
            editor.test(using: provider)
            await settleTasks()
            editor.cancelTest()
            let message = editor.errorMessage
            provider.fail()
            await settleTasks()
            XCTAssertTrue(provider.sawCancellation)
            XCTAssertEqual(editor.errorMessage, message)
            XCTAssertTrue(editor.testResult.isEmpty)
            XCTAssertFalse(editor.isTesting)
        }
    }

    func testClosingEditorClearsTypedKeyAndCancelsPendingTest() async throws {
        try await withStore { store, _ in
            let editor = TranslationServiceEditor(configuration: .init(kind: .openAI), services: store)
            editor.replacementKey = "test-private-key"
            let provider = EditorTestProvider()
            editor.test(using: provider)
            await settleTasks()
            editor.close()
            XCTAssertTrue(editor.replacementKey.isEmpty)
            XCTAssertFalse(editor.isTesting)
            provider.finish(text: "late")
            await settleTasks()
            XCTAssertTrue(provider.sawCancellation)
            XCTAssertTrue(editor.testResult.isEmpty)
            XCTAssertNil(editor.errorMessage)
        }
    }

    func testChangedEndpointCannotBorrowStoredKeyForUnsavedTest() async throws {
        try await withStore { store, _ in
            let configuration = TranslationServiceConfiguration(kind: .openAI)
            try store.save(configuration, apiKey: "test-private-key")
            let editor = TranslationServiceEditor(configuration: configuration, services: store)
            editor.configuration.endpoint = "https://other.example/v1"
            let provider = EditorTestProvider()
            editor.test(using: provider)
            await settleTasks()
            XCTAssertNil(provider.request)
            XCTAssertFalse(editor.isTesting)
            XCTAssertEqual(editor.errorMessage, TranslationServiceConfigurationError.endpointChanged.localizedDescription)
            XCTAssertEqual(try store.apiKey(for: configuration.id), "test-private-key")
            XCTAssertEqual(store.configurations.first?.endpoint, configuration.endpoint)
        }
    }

    func testSavePreservesHiddenKeyAndNeverChangesSelection() async throws {
        try await withStore { store, _ in
            let configuration = TranslationServiceConfiguration(kind: .openAI)
            try store.save(configuration, apiKey: "test-private-key")
            let editor = TranslationServiceEditor(configuration: configuration, services: store)
            editor.configuration.name = "Personal translations"
            XCTAssertTrue(editor.save())
            XCTAssertNil(store.selectedID)
            XCTAssertEqual(try store.apiKey(for: configuration.id), "test-private-key")
            editor.makeDefault = true
            XCTAssertTrue(editor.save())
            XCTAssertNil(store.selectedID)
            try store.select(configuration.id)
            editor.makeDefault = false
            editor.configuration.name = "Still selected"
            XCTAssertTrue(editor.save())
            XCTAssertEqual(store.selectedID, configuration.id)
        }
    }

    func testExplicitRemovalAllowsOptionalKeyToBeDeleted() async throws {
        try await withStore { store, _ in
            var configuration = TranslationServiceConfiguration(kind: .ollama)
            configuration.model = "local-test-model"
            try store.save(configuration, apiKey: "test-private-key")
            let editor = TranslationServiceEditor(configuration: configuration, services: store)
            editor.removeSavedKey = true
            XCTAssertTrue(editor.save())
            XCTAssertNil(try store.apiKey(for: configuration.id))
        }
    }

    func testUnknownProviderErrorNeverLeaksItsDescription() async throws {
        try await withStore { store, _ in
            let editor = TranslationServiceEditor(configuration: .init(kind: .openAI), services: store)
            editor.replacementKey = "test-private-key"
            let provider = EditorTestProvider()
            editor.test(using: provider)
            await settleTasks()
            provider.fail()
            await settleTasks()
            XCTAssertFalse(editor.isTesting)
            XCTAssertEqual(editor.errorMessage, L10n.string("Couldn’t update translation services. Please try again."))
            XCTAssertFalse(editor.errorMessage?.contains("secret") ?? true)
            XCTAssertTrue(editor.testResult.isEmpty)
        }
    }

    func testMetadataInspectionDoesNotReadKeyAndRevealDoesNotDirtyTheDraft() async throws {
        try await withStore { store, credentials in
            let config = TranslationServiceConfiguration(kind: .openAI)
            try store.save(config, apiKey: "fixture-secret")
            let editor = TranslationServiceEditor(configuration: config, services: store)
            let reads = credentials.reads
            XCTAssertEqual(editor.keyState, .unconfirmed)
            editor.refreshKeyState()
            XCTAssertEqual(editor.keyState, .stored)
            XCTAssertEqual(credentials.reads, reads)
            XCTAssertEqual(credentials.metadataReads, 1)
            editor.toggleKeyVisibility()
            XCTAssertEqual(credentials.reads, reads + 1)
            XCTAssertEqual(editor.keyFieldText, "fixture-secret")
            XCTAssertTrue(editor.isKeyVisible)
            XCTAssertTrue(editor.replacementKey.isEmpty)
            XCTAssertFalse(editor.isDirty)
            editor.hideKey()
            XCTAssertFalse(editor.isKeyVisible)
            XCTAssertTrue(editor.keyFieldText.isEmpty)
            XCTAssertFalse(editor.isDirty)
            editor.configuration.name = ""
            editor.configuration.model = ""
            editor.toggleKeyVisibility()
            XCTAssertEqual(editor.keyFieldText, "fixture-secret", "Reveal is bound to the saved identity, not unfinished name/model edits.")
            editor.close()
        }
    }

    func testKeyRevealTimerClearsStoredCopyButRetainsTypedReplacement() async throws {
        try await withStore { store, _ in
            let config = TranslationServiceConfiguration(kind: .openAI)
            try store.save(config, apiKey: "fixture-secret")
            let editor = TranslationServiceEditor(configuration: config, services: store, keyVisibilityDuration: .milliseconds(10))
            editor.toggleKeyVisibility()
            await waitUntil { !editor.isKeyVisible }
            XCTAssertTrue(editor.keyFieldText.isEmpty)
            editor.replacementKey = "fixture-replacement"
            editor.toggleKeyVisibility()
            await waitUntil { !editor.isKeyVisible }
            XCTAssertEqual(editor.replacementKey, "fixture-replacement")
            XCTAssertTrue(editor.isDirty)
            editor.close()
        }
    }

    func testReadFailureIsSafeAndMissingKeyIsNotReportedAsStored() async throws {
        try await withStore { store, credentials in
            let config = TranslationServiceConfiguration(kind: .openAI)
            try store.save(config, apiKey: "fixture-secret")
            let editor = TranslationServiceEditor(configuration: config, services: store)
            credentials.failReads = true
            editor.toggleKeyVisibility()
            XCTAssertEqual(editor.keyState, .unavailable)
            XCTAssertFalse(editor.isKeyVisible)
            XCTAssertTrue(editor.keyFieldText.isEmpty)
            XCTAssertEqual(editor.keyErrorMessage, TranslationServiceConfigurationError.credentialUnavailable.localizedDescription)
            credentials.failReads = false
            credentials.values[config.id] = nil
            editor.refreshKeyState()
            XCTAssertEqual(editor.keyState, .missing)
            editor.toggleKeyVisibility()
            XCTAssertEqual(editor.keyState, .missing)
            XCTAssertFalse(editor.isKeyVisible)
        }
    }

    func testManualAddressChangeClearsTypedAndRevealedKeyBeforeAnyRead() async throws {
        try await withStore { store, credentials in
            let config = TranslationServiceConfiguration(kind: .openAI)
            try store.save(config, apiKey: "fixture-secret")
            let editor = TranslationServiceEditor(configuration: config, services: store)
            editor.toggleKeyVisibility()
            editor.replacementKey = "fixture-for-original-address"
            let reads = credentials.reads
            editor.configuration.endpoint = "https://other.example/v1"
            XCTAssertEqual(editor.keyState, .addressChanged)
            XCTAssertFalse(editor.isKeyVisible)
            XCTAssertTrue(editor.replacementKey.isEmpty)
            editor.toggleKeyVisibility()
            XCTAssertEqual(credentials.reads, reads)
            XCTAssertFalse(editor.isKeyVisible)
            XCTAssertTrue(editor.keyFieldText.isEmpty)
        }
    }

    func testProviderDraftsKeepIndependentIDsAndSuspendWithoutLosingInput() async throws {
        try await withStore { store, credentials in
            let session = TranslationServiceDraftSession(services: store)
            let first = session.editor
            first.configuration.name = "First draft"
            first.replacementKey = "fixture-first-key"
            first.toggleKeyVisibility()
            session.selectKind(.deepSeek)
            let second = session.editor
            XCTAssertNotEqual(first.configuration.id, second.configuration.id)
            XCTAssertTrue(second.replacementKey.isEmpty)
            XCTAssertFalse(first.isKeyVisible)
            second.replacementKey = "fixture-second-key"
            session.selectKind(.openAI)
            XCTAssertTrue(session.editor === first)
            XCTAssertEqual(first.configuration.name, "First draft")
            XCTAssertEqual(first.replacementKey, "fixture-first-key")
            session.suspend()
            XCTAssertEqual(first.replacementKey, "fixture-first-key")
            XCTAssertEqual(second.replacementKey, "fixture-second-key")
            XCTAssertTrue(session.hasUnsavedChanges)
            XCTAssertEqual(credentials.reads, 0)
            session.close()
            XCTAssertTrue(first.replacementKey.isEmpty)
            XCTAssertTrue(second.replacementKey.isEmpty)
            XCTAssertFalse(first.save())
            XCTAssertTrue(store.configurations.isEmpty)
        }
    }

    func testDirtyBaselineReturnsToCleanAndSavedProviderCannotSwitch() async throws {
        try await withStore { store, _ in
            let config = TranslationServiceConfiguration(kind: .openAI)
            try store.save(config, apiKey: "fixture-secret")
            let session = TranslationServiceDraftSession(services: store, configuration: config)
            let editor = session.editor
            XCTAssertFalse(editor.canSave)
            editor.configuration.name = "Changed"
            XCTAssertTrue(editor.isDirty)
            editor.configuration.name = config.name
            XCTAssertFalse(editor.isDirty)
            editor.replacementKey = "replacement"
            XCTAssertTrue(editor.isDirty)
            editor.replacementKey = ""
            XCTAssertFalse(editor.isDirty)
            session.selectKind(.deepSeek)
            XCTAssertTrue(session.editor === editor)
            XCTAssertEqual(editor.configuration.kind, .openAI)
        }
    }

    func testCatalogDoesNotRequireNameOrModelAndNeverSelectsAResult() async throws {
        try await withStore { store, _ in
            let loader = EditorModelLoader()
            let editor = TranslationServiceEditor(configuration: .init(kind: .openAI), services: store, modelLoader: loader)
            editor.configuration.name = ""
            editor.configuration.model = ""
            editor.replacementKey = "fixture-key"
            editor.fetchModels()
            await waitUntil { await loader.requestCount == 1 }
            XCTAssertEqual(editor.catalogState, .loading)
            await loader.finish([.init(id: "fixture-model", name: "Fixture model")])
            await waitUntil { editor.catalogState == .loaded }
            XCTAssertTrue(editor.configuration.model.isEmpty)
            XCTAssertTrue(editor.configuration.name.isEmpty)
            XCTAssertEqual(editor.models.map(\.id), ["fixture-model"])
            XCTAssertTrue(editor.testResult.isEmpty)
            XCTAssertTrue(store.configurations.isEmpty)
            editor.chooseModel("fixture-model")
            XCTAssertEqual(editor.configuration.model, "fixture-model")
        }
    }

    func testChangedCredentialCancelsCatalogAndRejectsALateResponse() async throws {
        try await withStore { store, _ in
            let loader = EditorModelLoader()
            let editor = TranslationServiceEditor(configuration: .init(kind: .openAI), services: store, modelLoader: loader)
            editor.replacementKey = "fixture-key"
            editor.fetchModels()
            await waitUntil { await loader.requestCount == 1 }
            editor.replacementKey = "fixture-new-key"
            await loader.finish([.init(id: "obsolete", name: "Obsolete")])
            await waitUntil { await loader.sawCancellation }
            XCTAssertEqual(editor.catalogState, .idle)
            XCTAssertTrue(editor.models.isEmpty)
            XCTAssertEqual(editor.configuration.model, TranslationServiceKind.openAI.defaultModel)
            XCTAssertNil(editor.modelErrorMessage)
        }
    }

    func testCatalogFailurePreservesManualModelAndSanitizesUnknownErrors() async throws {
        try await withStore { store, _ in
            let loader = EditorModelLoader()
            let editor = TranslationServiceEditor(configuration: .init(kind: .openAI), services: store, modelLoader: loader)
            editor.replacementKey = "fixture-key"
            editor.configuration.model = "manual-model"
            editor.fetchModels()
            await waitUntil { await loader.requestCount == 1 }
            await loader.fail()
            await waitUntil { editor.catalogState == .failed }
            XCTAssertEqual(editor.configuration.model, "manual-model")
            XCTAssertTrue(editor.models.isEmpty)
            XCTAssertEqual(editor.modelErrorMessage, L10n.string("Couldn’t update translation services. Please try again."))
            XCTAssertFalse(editor.modelErrorMessage?.contains("secret") ?? true)
        }
    }

    func testStoppingWaitsForTheOldTaskAndPreventsANewTest() async throws {
        try await withStore { store, _ in
            let editor = TranslationServiceEditor(configuration: .init(kind: .openAI), services: store)
            editor.replacementKey = "fixture-key"
            let first = EditorTestProvider(), second = EditorTestProvider()
            editor.test(using: first)
            await waitUntil { first.request != nil }
            editor.cancelTest()
            XCTAssertEqual(editor.testState, .stopping)
            XCTAssertTrue(editor.isTesting)
            XCTAssertFalse(editor.canSave)
            editor.configuration.model = "changed-while-stopping"
            XCTAssertEqual(editor.testState, .stopping)
            XCTAssertFalse(editor.save())
            editor.test(using: second)
            XCTAssertNil(second.request)
            first.finish(text: "obsolete")
            await waitUntil { editor.testState == .idle }
            XCTAssertFalse(editor.isTesting)
            XCTAssertTrue(editor.testResult.isEmpty)
            XCTAssertTrue(first.sawCancellation)
        }
    }

    func testFailedSavePreservesDraftAndDoesNotChangeSelectedService() async throws {
        try await withStore { store, credentials in
            let config = TranslationServiceConfiguration(kind: .openAI)
            try store.save(config, apiKey: "fixture-old-key")
            try store.select(config.id)
            let editor = TranslationServiceEditor(configuration: config, services: store)
            editor.configuration.name = "Unsaved name"
            editor.replacementKey = "fixture-new-key"
            credentials.failWrites = true
            XCTAssertFalse(editor.save())
            XCTAssertTrue(editor.isDirty)
            XCTAssertEqual(editor.replacementKey, "fixture-new-key")
            XCTAssertEqual(editor.configuration.name, "Unsaved name")
            XCTAssertEqual(store.selectedID, config.id)
            XCTAssertEqual(store.configurations.first?.name, config.name)
            XCTAssertEqual(credentials.values[config.id]?.apiKey, "fixture-old-key")
        }
    }

    private func waitUntil(_ predicate: () async -> Bool) async {
        for _ in 0..<200 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("The constructed editor operation did not reach its expected state.")
    }

    private func withStore(_ body: (TranslationServiceStore, EditorCredentialStore) async throws -> Void) async throws {
        let suite = "LumaxTranslateTests.TranslationServiceEditor.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = EditorCredentialStore()
        let store = TranslationServiceStore(defaults: defaults, credentials: credentials)
        try await body(store, credentials)
    }

    private func settleTasks() async {
        for _ in 0..<30 { await Task.yield() }
    }
}

@MainActor
private final class EditorTestProvider: TranslationProvider {
    var request: TranslationRequest?
    var sawCancellation = false
    private var continuation: CheckedContinuation<TranslationResult, any Error>?

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        self.request = request
        defer { sawCancellation = Task.isCancelled }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(text: String) {
        continuation?.resume(returning: .init(text: text, source: "en", target: "zh-Hans"))
        continuation = nil
    }

    func fail() {
        continuation?.resume(throwing: NSError(domain: "test", code: 1,
                                               userInfo: [NSLocalizedDescriptionKey: "secret source and key"]))
        continuation = nil
    }
}

@MainActor
private final class EditorCredentialStore: TranslationCredentialStore {
    var values: [UUID: TranslationServiceCredential] = [:]
    var reads = 0
    var metadataReads = 0
    var failReads = false
    var failWrites = false

    func containsCredential(for id: UUID) throws -> Bool? {
        metadataReads += 1
        if failReads { throw TranslationServiceConfigurationError.credentialUnavailable }
        return values[id] != nil
    }

    func credential(for id: UUID) throws -> TranslationServiceCredential? {
        reads += 1
        if failReads { throw TranslationServiceConfigurationError.credentialUnavailable }
        return values[id]
    }

    func setCredential(_ credential: TranslationServiceCredential, for id: UUID) throws {
        if failWrites { throw TranslationServiceConfigurationError.credentialUnavailable }
        values[id] = credential
    }

    func removeCredential(for id: UUID) throws {
        values[id] = nil
    }
}

private actor EditorModelLoader: TranslationServiceModelLoading {
    private(set) var requestCount = 0
    private(set) var sawCancellation = false
    private var continuation: CheckedContinuation<[TranslationServiceModel], any Error>?

    func models(configuration: TranslationServiceConfiguration, apiKey: String?) async throws -> [TranslationServiceModel] {
        requestCount += 1
        defer { sawCancellation = Task.isCancelled }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ models: [TranslationServiceModel]) {
        continuation?.resume(returning: models)
        continuation = nil
    }
    func fail() {
        continuation?.resume(throwing: NSError(domain: "fixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "secret key and server body"]))
        continuation = nil
    }
}
