import Carbon
import XCTest
@testable import TranslateX

@MainActor
final class LocalizedEditorFeedbackTests: XCTestCase {
    func testFieldAndSaveFailuresChangeLanguageWithoutChangingTheDraft() throws {
        let originalLanguage = try XCTUnwrap(AppInterfaceLanguage(rawValue: L10n.currentLanguageIdentifier))
        defer { L10n.apply(originalLanguage) }
        let fixture = FeedbackServiceFixture()
        let editor = TranslationServiceEditor(configuration: .init(kind: .deepSeek), services: fixture.store)
        defer { editor.close() }
        editor.configuration.name = ""
        editor.replacementKey = "fixture-draft-key"

        L10n.apply(.simplifiedChinese)
        XCTAssertFalse(editor.save())
        XCTAssertEqual(editor.fieldErrors[.name], "请输入 1–120 个字符的服务名称。")
        let draft = editor.configuration
        L10n.apply(.english)
        XCTAssertEqual(editor.fieldErrors[.name], "Enter a service name of 1–120 characters.")
        XCTAssertEqual(editor.errorMessage, editor.fieldErrors[.name])
        XCTAssertEqual(editor.configuration, draft)
        XCTAssertEqual(editor.replacementKey, "fixture-draft-key")
        XCTAssertTrue(fixture.store.configurations.isEmpty)
        XCTAssertEqual(fixture.credentials.reads, 0)

        // A changed identity is a form-level error, rather than a field error.
        editor.configuration = .init(kind: .deepSeek)
        XCTAssertFalse(editor.save())
        XCTAssertEqual(editor.saveErrorMessage, "This translation service is no longer available. Select another service.")
        L10n.apply(.simplifiedChinese)
        XCTAssertEqual(editor.saveErrorMessage, TranslationServiceConfigurationError.unknownService.localizedDescription)
        XCTAssertFalse(editor.saveErrorMessage?.contains("This translation") ?? true)
        XCTAssertTrue(editor.fieldErrors.isEmpty)
        XCTAssertTrue(fixture.store.configurations.isEmpty)
    }

    func testKeyAccessFailureChangesLanguageWithoutReadingTheKeyAgain() throws {
        let originalLanguage = try XCTUnwrap(AppInterfaceLanguage(rawValue: L10n.currentLanguageIdentifier))
        defer { L10n.apply(originalLanguage) }
        let fixture = FeedbackServiceFixture()
        let configuration = TranslationServiceConfiguration(kind: .deepSeek)
        try fixture.store.save(configuration, apiKey: "fixture-saved-key")
        let editor = TranslationServiceEditor(configuration: configuration, services: fixture.store)
        defer { editor.close() }
        fixture.credentials.failReads = true
        L10n.apply(.english)
        editor.refreshKeyState()
        let englishMessage = try XCTUnwrap(editor.keyErrorMessage)
        let reads = fixture.credentials.reads
        let metadataReads = fixture.credentials.metadataReads

        L10n.apply(.simplifiedChinese)
        XCTAssertEqual(editor.keyErrorMessage, TranslationServiceConfigurationError.credentialUnavailable.localizedDescription)
        XCTAssertNotEqual(editor.keyErrorMessage, englishMessage)
        XCTAssertEqual(fixture.credentials.reads, reads)
        XCTAssertEqual(fixture.credentials.metadataReads, metadataReads)
        XCTAssertEqual(editor.configuration, configuration)
        XCTAssertFalse(editor.isKeyVisible)
    }

    func testModelFailureChangesLanguageWithoutReloadingModels() async throws {
        let originalLanguage = try XCTUnwrap(AppInterfaceLanguage(rawValue: L10n.currentLanguageIdentifier))
        defer { L10n.apply(originalLanguage) }
        let fixture = FeedbackServiceFixture()
        let loader = FeedbackModelLoader()
        let editor = TranslationServiceEditor(configuration: .init(kind: .deepSeek), services: fixture.store,
                                               modelLoader: loader)
        defer { editor.close() }
        editor.replacementKey = "fixture-model-key"
        editor.configuration.model = "draft-model"
        L10n.apply(.english)
        editor.fetchModels()
        await waitUntil { editor.catalogState == .failed }
        let englishMessage = try XCTUnwrap(editor.modelErrorMessage)
        let draft = editor.configuration

        L10n.apply(.simplifiedChinese)
        XCTAssertEqual(editor.modelErrorMessage, TranslationServiceModelCatalogError.catalogUnavailable.localizedDescription)
        XCTAssertNotEqual(editor.modelErrorMessage, englishMessage)
        let requests = await loader.requests
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(editor.configuration, draft)
        XCTAssertEqual(editor.replacementKey, "fixture-model-key")
        XCTAssertEqual(editor.catalogState, .failed)
    }

    func testKnownAndUnknownTestFailuresRelocalizeWithoutRetryOrPrivateErrorText() async throws {
        let originalLanguage = try XCTUnwrap(AppInterfaceLanguage(rawValue: L10n.currentLanguageIdentifier))
        defer { L10n.apply(originalLanguage) }
        for error in [RemoteTranslationError.offline as any Error, CodexAccountError.authenticationRequired,
                      NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "private provider body"])] {
            let fixture = FeedbackServiceFixture()
            let editor = TranslationServiceEditor(configuration: .init(kind: .deepSeek), services: fixture.store)
            defer { editor.close() }
            editor.replacementKey = "fixture-test-key"
            let provider = FeedbackTestProvider(error: error)
            L10n.apply(.english)
            editor.test(using: provider)
            await waitUntil { editor.testState == .failed }
            let englishMessage = try XCTUnwrap(editor.errorMessage)

            L10n.apply(.simplifiedChinese)
            let chineseMessage = try XCTUnwrap(editor.errorMessage)
            XCTAssertNotEqual(chineseMessage, englishMessage)
            XCTAssertEqual(chineseMessage, TranslationServiceEditor.safeMessage(for: error))
            XCTAssertFalse(chineseMessage.contains("private provider body"))
            XCTAssertFalse(englishMessage.contains("private provider body"))
            XCTAssertEqual(provider.requests, 1)
            XCTAssertEqual(editor.testState, .failed)
            XCTAssertTrue(editor.testResult.isEmpty)
            XCTAssertEqual(editor.replacementKey, "fixture-test-key")
            XCTAssertTrue(fixture.store.configurations.isEmpty)
        }
    }

    func testStoppedSampleMessageChangesLanguageWithoutRestartingTheTest() async throws {
        let originalLanguage = try XCTUnwrap(AppInterfaceLanguage(rawValue: L10n.currentLanguageIdentifier))
        defer { L10n.apply(originalLanguage) }
        let fixture = FeedbackServiceFixture()
        let editor = TranslationServiceEditor(configuration: .init(kind: .deepSeek), services: fixture.store)
        defer { editor.close() }
        editor.replacementKey = "fixture-test-key"
        let provider = FeedbackTestProvider()
        L10n.apply(.english)
        editor.test(using: provider)
        await waitUntil { provider.requests == 1 }
        editor.cancelTest()
        await waitUntil { editor.testState == .stopped }
        XCTAssertEqual(editor.errorMessage, "Test cancelled")

        L10n.apply(.simplifiedChinese)
        XCTAssertEqual(editor.errorMessage, "测试已取消")
        XCTAssertEqual(provider.requests, 1)
        XCTAssertEqual(editor.testState, .stopped)
        XCTAssertFalse(editor.isTesting)
    }

    func testShortcutFailureAndRecordingRestoreUseCurrentLanguageWithoutReregistering() throws {
        let originalLanguage = try XCTUnwrap(AppInterfaceLanguage(rawValue: L10n.currentLanguageIdentifier))
        defer { L10n.apply(originalLanguage) }
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        L10n.apply(.english)
        let originalBinding = fixture.settings.effectiveShortcut(for: .selection)
        let reserved = GlobalShortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey))
        XCTAssertFalse(fixture.settings.update(reserved, for: .selection))
        let englishMessage = try XCTUnwrap(fixture.settings.error(for: .selection))
        let registrationAttempts = fixture.registrar.registrationAttempts
        let revision = fixture.preferences.shortcutRevision
        let token = fixture.settings.beginRecording(for: .selection)

        L10n.apply(.simplifiedChinese)
        fixture.settings.endRecording(token)
        XCTAssertEqual(fixture.settings.error(for: .selection), ShortcutError.reservedShortcut.errorDescription)
        XCTAssertNotEqual(fixture.settings.error(for: .selection), englishMessage)
        XCTAssertEqual(fixture.settings.effectiveShortcut(for: .selection), originalBinding)
        XCTAssertEqual(fixture.preferences.shortcutRevision, revision)
        XCTAssertEqual(fixture.registrar.registrationAttempts, registrationAttempts)
        XCTAssertTrue(fixture.events.actions.isEmpty)

        L10n.apply(.english)
        XCTAssertEqual(fixture.settings.error(for: .selection), englishMessage)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("The constructed feedback operation did not reach its expected state.")
    }
}

@MainActor
private final class FeedbackServiceFixture {
    let suite = "TranslateXTests.LocalizedFeedback.\(UUID().uuidString)"
    let defaults: UserDefaults
    let credentials: FeedbackCredentialStore
    let store: TranslationServiceStore

    init() {
        defaults = UserDefaults(suiteName: suite)!
        credentials = FeedbackCredentialStore()
        store = TranslationServiceStore(defaults: defaults, credentials: credentials)
    }

    isolated deinit { defaults.removePersistentDomain(forName: suite) }
}

@MainActor
private final class FeedbackCredentialStore: TranslationCredentialStore {
    private var values: [UUID: TranslationServiceCredential] = [:]
    var failReads = false
    var reads = 0
    var metadataReads = 0

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

    func setCredential(_ credential: TranslationServiceCredential, for id: UUID) throws { values[id] = credential }
    func removeCredential(for id: UUID) throws { values[id] = nil }
}

private actor FeedbackModelLoader: TranslationServiceModelLoading {
    private(set) var requests = 0

    func models(configuration: TranslationServiceConfiguration, apiKey: String?) async throws -> [TranslationServiceModel] {
        requests += 1
        throw TranslationServiceModelCatalogError.catalogUnavailable
    }
}

@MainActor
private final class FeedbackTestProvider: TranslationProvider {
    let error: (any Error)?
    private(set) var requests = 0

    init(error: (any Error)? = nil) { self.error = error }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        requests += 1
        if let error { throw error }
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
}
