import XCTest
@testable import LumaxTranslate

@MainActor
final class CodexAccountEditorTests: XCTestCase {
    func testAccountAndCatalogNeverSelectAModelOrActivateTheDraft() async throws {
        try await withFixture { fixture, store, credentials in
            let editor = TranslationServiceEditor(configuration: .init(kind: .codex), services: store)
            XCTAssertTrue(editor.configuration.automaticallyTranslates)
            XCTAssertFalse(editor.canSaveCodex)
            editor.openCodex()
            await settleTasks()
            XCTAssertEqual(fixture.requests.map(\.operation), [.status])
            editor.refreshCodexModels()
            await settleTasks()
            XCTAssertEqual(fixture.requests.map(\.operation), [.status, .models])
            XCTAssertTrue(editor.configuration.model.isEmpty)
            XCTAssertNil(editor.configuration.codexAccountGeneration)
            XCTAssertFalse(editor.save())
            editor.chooseCodexModel("not-in-the-catalog")
            XCTAssertTrue(editor.configuration.model.isEmpty)
            editor.chooseCodexModel("constructed-model")
            XCTAssertEqual(editor.configuration.codexAccountGeneration, fixture.generation)
            XCTAssertTrue(editor.canSaveCodex)
            editor.makeDefault = true // Even a stale generic-editor flag cannot activate Codex.
            XCTAssertTrue(editor.save())
            XCTAssertNil(store.selectedID)
            XCTAssertEqual(store.configurations.first?.model, "constructed-model")
            XCTAssertEqual(credentials.accesses, 0)
            editor.close()
        }
    }

    func testAccountChangeRequiresExplicitSelectionEvenWhenModelIDIsTheSame() async throws {
        try await withFixture { fixture, store, _ in
            await prepareCatalog(store.codex)
            let editor = TranslationServiceEditor(configuration: .init(kind: .codex), services: store)
            editor.chooseCodexModel("constructed-model")
            let previous = editor.configuration.codexAccountGeneration
            fixture.generation = UUID().uuidString.lowercased()
            await prepareCatalog(store.codex)
            editor.codexIdentityChanged()
            XCTAssertEqual(editor.configuration.codexAccountGeneration, previous)
            XCTAssertFalse(editor.codexModelSelectionIsValid)
            XCTAssertFalse(editor.save())
            XCTAssertTrue(store.configurations.isEmpty)
            editor.chooseCodexModel("constructed-model")
            XCTAssertEqual(editor.configuration.codexAccountGeneration, fixture.generation)
            XCTAssertTrue(editor.save())
            editor.close()
        }
    }

    func testRemovedModelCannotBeSavedOrTestedFromAnOldDraft() async throws {
        try await withFixture { fixture, store, credentials in
            await prepareCatalog(store.codex)
            let editor = TranslationServiceEditor(configuration: .init(kind: .codex), services: store)
            editor.chooseCodexModel("constructed-model")
            fixture.models = []
            await store.codex.loadModels(owner: UUID())
            XCTAssertFalse(editor.canSaveCodex)
            editor.test()
            await settleTasks()
            XCTAssertFalse(editor.isTesting)
            XCTAssertFalse(fixture.requests.contains { $0.operation == .translate })
            XCTAssertFalse(editor.save())
            XCTAssertEqual(credentials.accesses, 0)
            editor.close()
        }
    }

    func testExplicitSampleUsesTheSharedControllerAndDoesNotSave() async throws {
        try await withFixture { fixture, store, credentials in
            await prepareCatalog(store.codex)
            let editor = TranslationServiceEditor(configuration: .init(kind: .codex), services: store)
            editor.chooseCodexModel("constructed-model")
            editor.test()
            await settleTasks()
            let request = try XCTUnwrap(fixture.requests.last)
            XCTAssertEqual(request.operation, .translate)
            XCTAssertEqual(request.text, TranslationServiceEditor.testSample)
            XCTAssertEqual(request.sourceLanguage, "en")
            XCTAssertEqual(request.targetLanguage, "zh-Hans")
            XCTAssertEqual(request.expectedGeneration, fixture.generation)
            XCTAssertEqual(editor.testResult, "构造的公开样例译文。")
            XCTAssertTrue(store.configurations.isEmpty)
            XCTAssertNil(store.selectedID)
            XCTAssertEqual(credentials.accesses, 0)
            editor.close()
        }
    }

    func testClosingBeforeAnOperationStartsPreventsALateRequest() async throws {
        try await withFixture { fixture, store, _ in
            let editor = TranslationServiceEditor(configuration: .init(kind: .codex), services: store)
            editor.signInCodex()
            editor.close()
            await settleTasks()
            XCTAssertTrue(fixture.requests.isEmpty)
            XCTAssertFalse(editor.ownsCodexOperation)
            XCTAssertNil(store.codex.deviceCode)
        }
    }

    private func prepareCatalog(_ controller: CodexAccountController) async {
        let owner = UUID()
        await controller.refreshStatus(owner: owner)
        await controller.loadModels(owner: owner)
    }

    private func settleTasks() async {
        for _ in 0..<80 { await Task.yield() }
    }

    private func withFixture(_ body: (CodexEditorFixture, TranslationServiceStore, CodexEditorCredentials) async throws -> Void) async throws {
        let suite = "LumaxTranslateTests.CodexAccountEditor.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = CodexEditorFixture()
        let controller = CodexAccountController(sessionFactory: { fixture.session($0) })
        let credentials = CodexEditorCredentials()
        let store = TranslationServiceStore(defaults: defaults, credentials: credentials, codex: controller)
        try await body(fixture, store, credentials)
        let stopped = await controller.shutdownAndWait()
        XCTAssertTrue(stopped)
    }
}

@MainActor
private final class CodexEditorFixture {
    var generation = UUID().uuidString.lowercased()
    var requests: [CodexRuntimeSession.Request] = []
    var models = [CodexRuntimeSession.Model(id: "constructed-model", name: "Constructed model",
        reasoningEfforts: [], defaultReasoningEffort: nil)]

    func session(_ request: CodexRuntimeSession.Request) -> CodexAccountController.SessionHandle {
        requests.append(request)
        return .init(run: { [self] _ in
            let outcome: CodexRuntimeSession.Outcome
            switch request.operation {
            case .status:
                outcome = .init(status: "signed_in", text: nil, models: nil, accountPlan: "plus",
                                generation: generation, remoteRevocation: nil)
            case .models:
                outcome = .init(status: "ok", text: nil, models: models, accountPlan: nil,
                                generation: nil, remoteRevocation: nil)
            case .translate:
                outcome = .init(status: "ok", text: "构造的公开样例译文。", models: nil, accountPlan: nil,
                                generation: nil, remoteRevocation: nil)
            default:
                outcome = .init(status: "request_failed", text: nil, models: nil, accountPlan: nil,
                                generation: nil, remoteRevocation: nil)
            }
            let terminal = CodexRuntimeSession.Event(event: .terminal, protocolVersion: 1,
                requestID: request.requestID, userCode: nil, verificationURL: nil, result: outcome)
            return .init(terminal: terminal, failure: nil, helperReaped: true)
        }, cancel: {})
    }
}

@MainActor
private final class CodexEditorCredentials: TranslationCredentialStore {
    var accesses = 0
    func credential(for id: UUID) throws -> TranslationServiceCredential? { accesses += 1; return nil }
    func setCredential(_ credential: TranslationServiceCredential, for id: UUID) throws { accesses += 1 }
    func removeCredential(for id: UUID) throws { accesses += 1 }
}
