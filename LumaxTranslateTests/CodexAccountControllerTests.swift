import XCTest
@testable import LumaxTranslate

@MainActor
final class CodexAccountControllerTests: XCTestCase {
    func testInitializationIsLazyAndCancelledPageCannotStartMetadata() async {
        let fixture = CodexControllerSessionFixture()
        let controller = fixture.controller()
        XCTAssertEqual(fixture.created, 0)
        XCTAssertEqual(controller.status, .unknown)
        XCTAssertFalse(controller.hasActiveOperation)
        let task = Task {
            await controller.refreshStatus(owner: UUID())
            await controller.login(owner: UUID())
            await controller.loadModels(owner: UUID())
        }
        task.cancel()
        await task.value
        XCTAssertEqual(fixture.created, 0)
    }

    func testStatusAndModelCatalogRemainBoundToExplicitGeneration() async throws {
        let fixture = CodexControllerSessionFixture()
        let controller = fixture.controller()
        var revisions: [Int] = []
        controller.onIdentityChange = { revisions.append(controller.identityRevision) }
        try await fixture.signInStatus(controller)
        XCTAssertEqual(revisions, [1])
        XCTAssertTrue(controller.models.isEmpty)
        let models = Task { await controller.loadModels(owner: UUID()) }
        try await fixture.waitForRequests(2)
        XCTAssertEqual(fixture.requests[1].expectedGeneration, fixture.generation)
        try fixture.finish(1, status: "ok", models: [fixture.model])
        await models.value
        XCTAssertTrue(controller.canUseModel(id: fixture.model.id, generation: fixture.generation))
        XCTAssertFalse(controller.canUseModel(id: fixture.model.id, generation: nil))
        XCTAssertFalse(controller.canUseModel(id: "invented", generation: fixture.generation))
        let refresh = Task { await controller.refreshStatus(owner: UUID()) }
        try await fixture.waitForRequests(3)
        try fixture.finish(2, status: "signed_in", generation: fixture.otherGeneration)
        await refresh.value
        XCTAssertEqual(controller.generation, fixture.otherGeneration)
        XCTAssertTrue(controller.models.isEmpty)
        XCTAssertNil(controller.modelsGeneration)
        XCTAssertEqual(revisions, [1, 2])
    }

    func testFailedCatalogRefreshDiscardsPreviousModels() async throws {
        let fixture = CodexControllerSessionFixture(); let controller = fixture.controller()
        try await fixture.signInStatus(controller)
        let first = Task { await controller.loadModels(owner: UUID()) }
        try await fixture.waitForRequests(2); try fixture.finish(1, status: "ok", models: [fixture.model]); await first.value
        let second = Task { await controller.loadModels(owner: UUID()) }
        try await fixture.waitForRequests(3); try fixture.finish(2, status: "network_unavailable"); await second.value
        XCTAssertTrue(controller.models.isEmpty)
        XCTAssertNil(controller.modelsGeneration)
        XCTAssertEqual(controller.error, .networkUnavailable)
    }

    func testLoginCannotBePreemptedByTranslationAndOwnerIsScoped() async throws {
        let fixture = CodexControllerSessionFixture(); let controller = fixture.controller(); let owner = UUID()
        let login = Task { await controller.login(owner: owner) }
        try await fixture.waitForRequests(1)
        try fixture.notice(0, kind: .ready)
        XCTAssertEqual(controller.deviceCode, "CONSTRUCTED-CODE")
        await controller.cancelOperations(owner: UUID())
        XCTAssertTrue(fixture.cancelled.isEmpty)
        do {
            _ = try await controller.translate(fixture.translation(), model: fixture.model.id, generation: fixture.generation)
            XCTFail("Translation must not replace login.")
        } catch { XCTAssertEqual(error as? CodexAccountError, .busy) }
        XCTAssertEqual(fixture.requests.count, 1)
        let close = Task { await controller.cancelOperations(owner: owner) }
        await fixture.waitForCancellation()
        XCTAssertNil(controller.deviceCode)
        XCTAssertNil(controller.verificationURL)
        try fixture.notice(0, kind: .committing)
        try fixture.finish(0, status: "signed_in", generation: fixture.generation)
        await close.value; await login.value
        XCTAssertEqual(controller.status, .signedIn)
        XCTAssertEqual(controller.generation, fixture.generation)
        XCTAssertNil(controller.deviceCode)
        XCTAssertNil(controller.verificationURL)
        XCTAssertFalse(controller.isBusy)
    }

    func testNewTranslationWaitsForReapAndDiscardsOldCompletion() async throws {
        let fixture = CodexControllerSessionFixture(); let controller = fixture.controller()
        let first = Task { try await controller.translate(fixture.translation("first"), model: fixture.model.id, generation: fixture.generation) }
        try await fixture.waitForRequests(1)
        let second = Task { try await controller.translate(fixture.translation("second"), model: fixture.model.id, generation: fixture.generation) }
        await fixture.waitForCancellation()
        XCTAssertEqual(fixture.requests.count, 1, "Replacement must wait until the old helper is reaped.")
        try fixture.finish(0, status: "ok", text: "old translation")
        try await fixture.waitForRequests(2)
        XCTAssertEqual(fixture.requests[1].text, "second")
        try fixture.finish(1, status: "ok", text: "new translation")
        do { _ = try await first.value; XCTFail("Cancelled old result must not escape.") } catch { XCTAssertTrue(error is CancellationError) }
        let result = try await second.value
        XCTAssertEqual(result.text, "new translation")
    }

    func testAlreadyCancelledTranslationCannotCancelTheActiveRequest() async throws {
        let fixture = CodexControllerSessionFixture(); let controller = fixture.controller()
        let first = Task {
            try await controller.translate(fixture.translation("active passage"), model: fixture.model.id, generation: fixture.generation)
        }
        try await fixture.waitForRequests(1)
        var abandonedEntered = false
        let abandoned = Task {
            abandonedEntered = true
            return try await controller.translate(fixture.translation("abandoned sample"), model: fixture.model.id, generation: fixture.generation)
        }
        // Both actions run on the main actor, so cancellation precedes admission.
        abandoned.cancel()
        for _ in 0..<200 {
            if abandonedEntered { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(abandonedEntered)
        XCTAssertTrue(fixture.cancelled.isEmpty, "An already-cancelled task must not cancel another entry point's translation.")
        XCTAssertEqual(fixture.created, 1)
        try fixture.finish(0, status: "ok", text: "active result")
        do {
            let result = try await first.value
            XCTAssertEqual(result.text, "active result")
        } catch { XCTFail("The active request must complete normally.") }
        do { _ = try await abandoned.value; XCTFail("The abandoned task must remain cancelled.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(controller.hasActiveOperation)
    }

    func testOnlyNewestWaitingTranslationCanClaimTheSlot() async throws {
        let fixture = CodexControllerSessionFixture(); let controller = fixture.controller()
        let first = Task { try await controller.translate(fixture.translation("first"), model: fixture.model.id, generation: fixture.generation) }
        try await fixture.waitForRequests(1)
        let second = Task { try await controller.translate(fixture.translation("second"), model: fixture.model.id, generation: fixture.generation) }
        await fixture.waitForCancellation()
        let third = Task { try await controller.translate(fixture.translation("third"), model: fixture.model.id, generation: fixture.generation) }
        for _ in 0..<5 { await Task.yield() }
        try fixture.finish(0, status: "cancelled")
        try await fixture.waitForRequests(2)
        XCTAssertEqual(fixture.requests[1].text, "third")
        try fixture.finish(1, status: "ok", text: "third result")
        _ = try? await first.value
        do { _ = try await second.value; XCTFail("Stale waiting request must not start.") } catch { XCTAssertTrue(error is CancellationError) }
        _ = try await third.value
    }

    func testClosingAnEditorDoesNotCancelAnotherTranslation() async throws {
        let fixture = CodexControllerSessionFixture(); let controller = fixture.controller()
        let translation = Task { try await controller.translate(fixture.translation(), model: fixture.model.id, generation: fixture.generation) }
        try await fixture.waitForRequests(1)
        await controller.cancelOperations(owner: UUID())
        XCTAssertTrue(fixture.cancelled.isEmpty)
        try fixture.finish(0, status: "ok", text: "result")
        _ = try await translation.value
    }

    func testLogoutInvalidatesIntentThenWaitsAndBindsDeletion() async throws {
        let fixture = CodexControllerSessionFixture(); let controller = fixture.controller()
        try await fixture.signInStatus(controller)
        let translation = Task { try await controller.translate(fixture.translation(), model: fixture.model.id, generation: fixture.generation) }
        try await fixture.waitForRequests(2)
        var revisionCalledBeforeLogout = false
        controller.onIdentityChange = { revisionCalledBeforeLogout = fixture.requests.count == 2 }
        let logout = Task { await controller.logout() }
        await fixture.waitForCancellation()
        XCTAssertTrue(revisionCalledBeforeLogout)
        XCTAssertEqual(fixture.requests.count, 2)
        try fixture.finish(1, status: "cancelled")
        try await fixture.waitForRequests(3)
        XCTAssertEqual(fixture.requests[2].operation, .logout)
        XCTAssertEqual(fixture.requests[2].expectedGeneration, fixture.generation)
        try fixture.finish(2, status: "signed_out")
        await logout.value; _ = try? await translation.value
        XCTAssertEqual(controller.status, .signedOut)
        XCTAssertNil(controller.generation)
    }

    func testExplicitLogoutFromUnknownChecksStatusBeforeBoundDeletion() async throws {
        let fixture = CodexControllerSessionFixture(); let controller = fixture.controller()
        let logout = Task { await controller.logout() }
        try await fixture.waitForRequests(1)
        XCTAssertEqual(fixture.requests[0].operation, .status)
        try fixture.finish(0, status: "signed_in", generation: fixture.generation)
        try await fixture.waitForRequests(2)
        XCTAssertEqual(fixture.requests[1].operation, .logout)
        XCTAssertEqual(fixture.requests[1].expectedGeneration, fixture.generation)
        try fixture.finish(1, status: "signed_out")
        await logout.value
    }

    func testShutdownPreservesCommittedLoginAndNeverIssuesLogout() async throws {
        let fixture = CodexControllerSessionFixture(); let controller = fixture.controller()
        let login = Task { await controller.login(owner: UUID()) }
        try await fixture.waitForRequests(1)
        try fixture.notice(0, kind: .ready); try fixture.notice(0, kind: .committing)
        let shutdown = Task { await controller.shutdownAndWait() }
        await fixture.waitForCancellation()
        try fixture.finish(0, status: "signed_in", generation: fixture.generation)
        let reaped = await shutdown.value; await login.value
        XCTAssertTrue(reaped)
        XCTAssertEqual(controller.status, .signedIn)
        XCTAssertEqual(fixture.requests.map(\.operation), [.login])
        await controller.refreshStatus(owner: UUID())
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testSynchronousShutdownPreventsLogoutLaunchingAfterItsStatusRead() async throws {
        let fixture = CodexControllerSessionFixture(); let controller = fixture.controller()
        controller.onIdentityChange = {
            if controller.status == .signedIn { controller.beginShutdown() }
        }
        let logout = Task { await controller.logout() }
        try await fixture.waitForRequests(1)
        try fixture.finish(0, status: "signed_in", generation: fixture.generation)
        await logout.value
        XCTAssertTrue(controller.isShuttingDown)
        XCTAssertEqual(fixture.requests.map(\.operation), [.status])
        XCTAssertFalse(controller.hasActiveOperation)
    }

    func testUnreapedHelperBlocksEveryFollowingOperation() async throws {
        let fixture = CodexControllerSessionFixture(); let controller = fixture.controller()
        let status = Task { await controller.refreshStatus(owner: UUID()) }
        try await fixture.waitForRequests(1)
        try fixture.finish(0, status: "cleanup_required", reaped: false)
        await status.value
        XCTAssertTrue(controller.hasActiveOperation)
        await controller.login(owner: UUID()); await controller.logout()
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(controller.error, .recoveryRequired)
        let reaped = await controller.shutdownAndWait()
        XCTAssertFalse(reaped)
    }

    func testAccountMismatchInvalidatesEvenAnInitiallyUnknownSnapshot() async throws {
        let fixture = CodexControllerSessionFixture(); let controller = fixture.controller()
        var changes = 0; controller.onIdentityChange = { changes += 1 }
        let task = Task { try await controller.translate(fixture.translation(), model: fixture.model.id, generation: fixture.generation) }
        try await fixture.waitForRequests(1)
        try fixture.finish(0, status: "account_changed")
        do { _ = try await task.value; XCTFail("Changed account must fail.") } catch { XCTAssertEqual(error as? CodexAccountError, .accountChanged) }
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(controller.status, .unknown)
        XCTAssertNil(controller.generation)
    }
}

/// Deterministic runtime injection; it never creates a process or accesses an
/// account. Delayed completions deliberately challenge slot ownership races.
@MainActor
final class CodexControllerSessionFixture {
    let generation = "11111111-2222-4333-8444-555555555555"
    let otherGeneration = "66666666-7777-4888-8999-aaaaaaaaaaaa"
    let model = CodexRuntimeSession.Model(id: "constructed-model", name: "Constructed", reasoningEfforts: ["low"], defaultReasoningEffort: "low")
    var created = 0
    var requests: [CodexRuntimeSession.Request] = []
    var cancelled: [String] = []
    private var pending: [String: CheckedContinuation<CodexRuntimeSession.Result, Never>] = [:]
    private var notices: [String: @MainActor (CodexRuntimeSession.Event) -> Void] = [:]

    func controller() -> CodexAccountController {
        CodexAccountController(sessionFactory: { [self] request in
            created += 1
            return .init(run: { [self] notice in
                await withCheckedContinuation { continuation in
                    requests.append(request); pending[request.requestID] = continuation; notices[request.requestID] = notice
                }
            }, cancel: { [self] in cancelled.append(request.requestID) })
        })
    }

    func translation(_ text: String = "constructed source", source: String? = nil) -> TranslationRequest {
        .init(id: UUID(), text: text, source: source, target: "zh-Hans")
    }

    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<200 {
            if requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Expected constructed request did not arrive.")
        throw CancellationError()
    }

    func waitForCancellation() async {
        for _ in 0..<200 {
            if !cancelled.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Expected cancellation did not arrive.")
    }

    func signInStatus(_ controller: CodexAccountController) async throws {
        let task = Task { await controller.refreshStatus(owner: UUID()) }
        let index = requests.count
        try await waitForRequests(index + 1)
        try finish(index, status: "signed_in", generation: generation)
        await task.value
    }

    func notice(_ index: Int, kind: CodexRuntimeSession.Event.Kind) throws {
        let request = requests[index]
        let callback = try XCTUnwrap(notices[request.requestID])
        callback(.init(event: kind, protocolVersion: 1, requestID: request.requestID,
                       userCode: kind == .ready ? "CONSTRUCTED-CODE" : nil,
                       verificationURL: kind == .ready ? "https://auth.openai.com/codex/device" : nil, result: nil))
    }

    func finish(_ index: Int, status: String, text: String? = nil, generation: String? = nil,
                models: [CodexRuntimeSession.Model]? = nil, reaped: Bool = true,
                failure: CodexRuntimeSession.HostFailure? = nil) throws {
        let request = requests[index]
        let continuation = try XCTUnwrap(pending.removeValue(forKey: request.requestID))
        notices.removeValue(forKey: request.requestID)
        let outcome = CodexRuntimeSession.Outcome(status: status, text: text, models: models, accountPlan: nil,
            generation: generation, remoteRevocation: request.operation == .logout && status == "signed_out" ? "unconfirmed" : nil)
        let event = CodexRuntimeSession.Event(event: .terminal, protocolVersion: 1, requestID: request.requestID,
            userCode: nil, verificationURL: nil, result: outcome)
        continuation.resume(returning: .init(terminal: event, failure: failure, helperReaped: reaped))
    }
}
