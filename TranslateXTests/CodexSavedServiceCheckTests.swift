import Foundation
import XCTest
@testable import TranslateX

@MainActor
final class CodexSavedServiceCheckTests: XCTestCase {
    func testSavedCodexCheckAfterLaunchDoesNotRequireAccountOrModelDiscovery() async throws {
        let fixture = try SavedCodexCheckFixture()
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.services.codex.status, .unknown)
        XCTAssertTrue(fixture.services.codex.models.isEmpty)
        let checks = TranslationServiceChecksController(services: fixture.services)
        let revision = fixture.services.revision
        checks.toggle(fixture.configuration)
        try await fixture.runtime.waitForRequests(1)
        let request = try XCTUnwrap(fixture.runtime.requests.first)
        XCTAssertEqual(request.operation, .translate)
        XCTAssertEqual(request.model, fixture.configuration.model)
        XCTAssertEqual(request.expectedGeneration, fixture.runtime.generation)
        XCTAssertEqual(request.text, TranslationServiceEditor.testSample)
        try fixture.runtime.finish(0, status: "ok", text: "构造样例译文")
        try await waitUntil { checks.editor(for: fixture.configuration.id)?.testState == .succeeded }
        XCTAssertEqual(fixture.services.sampleTestOutcome(for: fixture.configuration), .succeeded)
        XCTAssertEqual(fixture.services.revision, revision)
        XCTAssertEqual(fixture.services.selectedID, fixture.configuration.id)
        XCTAssertEqual(fixture.credentials.accesses, 0)
        XCTAssertEqual(fixture.runtime.requests.map(\.operation), [.translate])
        checks.cancelAll()
    }

    func testBusyCodexCheckReportsBusyWithoutInterruptingActualTranslation() async throws {
        let fixture = try SavedCodexCheckFixture()
        defer { fixture.cleanup() }
        let model = TranslationModel(services: fixture.services)
        model.source = "en"
        model.target = "zh-Hans"
        model.text = "A separate constructed request."
        model.submit()
        try await fixture.runtime.waitForRequests(1)
        let checks = TranslationServiceChecksController(services: fixture.services)
        checks.toggle(fixture.configuration)
        await settle()
        let editor = try XCTUnwrap(checks.editor(for: fixture.configuration.id))
        XCTAssertEqual(editor.testState, .failed)
        XCTAssertEqual(editor.errorMessage, CodexAccountError.busy.localizedDescription)
        XCTAssertEqual(fixture.runtime.requests.count, 1)
        XCTAssertTrue(fixture.runtime.cancelled.isEmpty)
        XCTAssertEqual(model.phase, .translating)
        XCTAssertNil(fixture.services.sampleTestRecord(for: fixture.configuration.id))
        XCTAssertTrue(fixture.services.usage.records.isEmpty)
        try fixture.runtime.finish(0, status: "ok", text: "正文构造译文")
        try await waitUntil { model.phase == .completed }
        XCTAssertEqual(model.result?.text, "正文构造译文")
        XCTAssertEqual(fixture.services.usage.records.count, 1)
        XCTAssertEqual(fixture.services.usage.records.first?.purpose, .translation)
        XCTAssertEqual(fixture.credentials.accesses, 0)
        checks.cancelAll()
    }

    func testUnsavedOrChangedCodexDraftStillRequiresExplicitCatalogSelection() async throws {
        let fixture = try SavedCodexCheckFixture()
        defer { fixture.cleanup() }
        var new = fixture.configuration
        new.id = UUID()
        var changedModel = fixture.configuration
        changedModel.model = "unselected-draft-model"
        var changedGeneration = fixture.configuration
        changedGeneration.codexAccountGeneration = fixture.runtime.otherGeneration
        for draft in [new, changedModel, changedGeneration] {
            let editor = TranslationServiceEditor(configuration: draft, services: fixture.services)
            editor.test()
            await settle()
            XCTAssertEqual(editor.testState, .failed)
            XCTAssertEqual(editor.errorMessage, TranslationServiceConfigurationError.codexLoginRequired.localizedDescription)
            XCTAssertFalse(editor.isTesting)
            editor.close()
        }
        XCTAssertTrue(fixture.runtime.requests.isEmpty)
        XCTAssertEqual(fixture.credentials.accesses, 0)
        XCTAssertNil(fixture.services.sampleTestRecord(for: fixture.configuration.id))
    }

    func testSavedCodexGenerationStillRejectsAChangedSignedInAccount() async throws {
        let fixture = try SavedCodexCheckFixture()
        defer { fixture.cleanup() }
        let status = Task { await fixture.services.codex.refreshStatus(owner: UUID()) }
        try await fixture.runtime.waitForRequests(1)
        try fixture.runtime.finish(0, status: "signed_in", generation: fixture.runtime.otherGeneration)
        await status.value
        let checks = TranslationServiceChecksController(services: fixture.services)
        checks.toggle(fixture.configuration)
        try await waitUntil { checks.editor(for: fixture.configuration.id)?.testState == .failed }
        XCTAssertEqual(checks.editor(for: fixture.configuration.id)?.errorMessage, CodexAccountError.accountChanged.localizedDescription)
        XCTAssertEqual(fixture.runtime.requests.map(\.operation), [.status], "The old generation must not reach translation")
        XCTAssertEqual(fixture.credentials.accesses, 0)
        checks.cancelAll()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Saved Codex check did not reach its expected state")
        throw CancellationError()
    }
    private func settle() async { for _ in 0..<40 { await Task.yield() } }
}

@MainActor
private final class SavedCodexCheckFixture {
    let suite = "CodexSavedServiceCheckTests." + UUID().uuidString
    let runtime = CodexControllerSessionFixture()
    let credentials = SavedCodexCheckCredentials()
    let defaults: UserDefaults
    let services: TranslationServiceStore
    let configuration: TranslationServiceConfiguration

    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        services = TranslationServiceStore(defaults: defaults, credentials: credentials, codex: runtime.controller())
        var configuration = TranslationServiceConfiguration(kind: .codex)
        configuration.model = runtime.model.id
        configuration.codexAccountGeneration = runtime.generation
        configuration.automaticallyTranslates = false
        self.configuration = configuration
        try services.save(configuration, apiKey: nil)
        try services.select(configuration.id)
    }
    func cleanup() {
        services.usage.flush()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class SavedCodexCheckCredentials: TranslationCredentialStore {
    private(set) var accesses = 0
    func credential(for id: UUID) throws -> TranslationServiceCredential? { accesses += 1; return nil }
    func setCredential(_ credential: TranslationServiceCredential, for id: UUID) throws { accesses += 1 }
    func removeCredential(for id: UUID) throws { accesses += 1 }
}
