import Foundation
import Observation

enum CodexAccountError: String, Error, LocalizedError, Equatable, Sendable {
    case runtimeUnavailable, invalidConfiguration, busy, authenticationRequired, accountChanged
    case recoveryRequired, storageUnavailable, loginUnavailable, authenticationFailed
    case managedPolicyDenied, modelUnavailable, requestFailed, rateLimited, accessDenied
    case networkUnavailable, timedOut, shuttingDown

    var errorDescription: String? { L10n.string("codexAccount.error.\(rawValue)") }

    fileprivate static func from(_ status: String) -> Self {
        switch status {
        case "account_changed": .accountChanged
        case "busy", "already_signed_in": .busy
        case "authentication_failed": .authenticationFailed
        case "storage_unavailable", "invalid_account_storage": .storageUnavailable
        case "recovery_required", "cleanup_required": .recoveryRequired
        case "login_unavailable", "login_failed": .loginUnavailable
        case "managed_policy_denied": .managedPolicyDenied
        case "model_unavailable": .modelUnavailable
        case "rate_limited": .rateLimited
        case "access_denied": .accessDenied
        case "network_unavailable": .networkUnavailable
        case "timeout": .timedOut
        default: .requestFailed
        }
    }
}

/// Owns the sole account-operation slot. Initialization neither starts the
/// helper nor checks account storage; only explicit operations do so.
@MainActor @Observable
final class CodexAccountController {
    enum Status: Equatable { case unknown, signedOut, signedIn }
    struct SessionHandle {
        let run: @MainActor (@escaping @MainActor (CodexRuntimeSession.Event) -> Void) async -> CodexRuntimeSession.Result
        let cancel: @MainActor () -> Void
    }
    typealias SessionFactory = @MainActor (CodexRuntimeSession.Request) -> SessionHandle

    private(set) var status: Status = .unknown
    private(set) var generation: String?
    private(set) var accountPlan: String?
    private(set) var operation: CodexRuntimeSession.Operation?
    private(set) var hasActiveOperation = false
    private(set) var deviceCode: String?
    private(set) var verificationURL: URL?
    private(set) var isCommitting = false
    private(set) var isCancelling = false
    private(set) var models: [CodexRuntimeSession.Model] = []
    private(set) var modelsGeneration: String?
    private(set) var error: CodexAccountError?
    private(set) var identityRevision = 0
    private(set) var isShuttingDown = false
    private var transitioning = false
    var isBusy: Bool { hasActiveOperation || transitioning }

    @ObservationIgnored var onIdentityChange: (@MainActor () -> Void)?
    @ObservationIgnored private let sessionFactory: SessionFactory
    @ObservationIgnored private var intent = 0
    @ObservationIgnored private var unreaped = false
    @ObservationIgnored private var active: ActiveOperation?

    private final class ActiveOperation {
        let id: UUID
        let request: CodexRuntimeSession.Request
        let owner: UUID?
        let session: SessionHandle
        let task: Task<CodexRuntimeSession.Result, Never>
        var cancelled = false

        init(id: UUID, request: CodexRuntimeSession.Request, owner: UUID?, session: SessionHandle,
             task: Task<CodexRuntimeSession.Result, Never>) {
            self.id = id; self.request = request; self.owner = owner; self.session = session; self.task = task
        }
    }

    init(sessionFactory: SessionFactory? = nil) {
        self.sessionFactory = sessionFactory ?? { request in
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lumax-codex-runtime")
            let session = CodexRuntimeSession(helper: helper)
            return SessionHandle(run: { notice in await session.run(request, onEvent: notice) }, cancel: { session.cancel() })
        }
    }

    func refreshStatus(owner: UUID) async {
        await runMetadata(.init(operation: .status), owner: owner)
    }

    func login(owner: UUID) async {
        await runMetadata(.init(operation: .login), owner: owner)
    }

    func loadModels(owner: UUID) async {
        guard !Task.isCancelled else { return }
        clearModels()
        guard status == .signedIn, let generation else { error = .authenticationRequired; return }
        await runMetadata(.init(operation: .models, expectedGeneration: generation), owner: owner)
    }

    func canUseModel(id: String, generation: String?) -> Bool {
        guard status == .signedIn, let generation, self.generation == generation,
              modelsGeneration == generation else { return false }
        return models.contains { $0.id == id }
    }

    private func runMetadata(_ request: CodexRuntimeSession.Request, owner: UUID) async {
        guard !Task.isCancelled else { return }
        if let rejection = admissionFailure() { error = rejection; return }
        guard active == nil, !transitioning else { error = .busy; return }
        // The slot itself applies results, so an older awaiting caller cannot
        // overwrite a new operation's error after actor reentrancy.
        _ = try? await execute(request, owner: owner)
    }

    func cancelOperations(owner: UUID) async {
        guard let active, active.owner == owner,
              [.login, .models, .status].contains(active.request.operation) else { return }
        intent &+= 1
        cancel(active)
        _ = await active.task.value
    }

    /// Logout is an explicit account action. Finish any current operation first,
    /// then bind deletion to the latest committed generation, including a login
    /// that won its commit race. Page closure cannot cancel this cleanup chain.
    func logout() async {
        if let rejection = admissionFailure() { error = rejection; return }
        guard !transitioning else { error = .busy; return }
        transitioning = true
        defer { transitioning = false }
        intent &+= 1
        clearModels()
        advanceIdentityRevision()
        if let active { cancel(active); _ = await active.task.value }
        guard !unreaped, !isShuttingDown else { error = unreaped ? .recoveryRequired : .shuttingDown; return }
        if generation == nil {
            guard (try? await execute(.init(operation: .status), owner: nil, honourCallerCancellation: false)) != nil else { return }
            if status == .signedOut { return }
        }
        guard let generation else { error = .authenticationRequired; return }
        _ = try? await execute(.init(operation: .logout, expectedGeneration: generation), owner: nil, honourCallerCancellation: false)
    }

    /// Ordinary application exit preserves a committed account. False means an
    /// owned helper was not confirmed reaped; it must not be replaced in-process.
    func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        intent &+= 1
        if let active { cancel(active) }
    }

    func shutdownAndWait() async -> Bool {
        beginShutdown()
        if let active { cancel(active); _ = await active.task.value }
        return !unreaped
    }

    func translate(_ request: TranslationRequest, model: String, generation expected: String) async throws -> TranslationResult {
        // An abandoned caller must not reserve the slot or cancel another entry point.
        try Task.checkCancellation()
        if let rejection = admissionFailure() { throw rejection }
        guard CodexRuntimeSession.Request.canonicalGeneration(expected) else { throw CodexAccountError.invalidConfiguration }
        try checkIdentity(expected)
        guard !transitioning else { throw CodexAccountError.busy }
        if let active, active.request.operation != .translate { throw CodexAccountError.busy }
        intent &+= 1
        let reservation = intent
        if let active { cancel(active); _ = await active.task.value }
        try Task.checkCancellation()
        guard reservation == intent else { throw CancellationError() }
        if let rejection = admissionFailure() { throw rejection }
        guard active == nil, !transitioning else { throw CodexAccountError.busy }
        try checkIdentity(expected)
        let outcome = try await execute(.init(operation: .translate, requestID: request.id, model: model,
            text: request.text, sourceLanguage: request.source, targetLanguage: request.target, expectedGeneration: expected), owner: nil)
        guard outcome.status == "ok", let text = outcome.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 512 * 1024 else { throw CodexAccountError.requestFailed }
        return TranslationResult(text: text, source: request.source, target: request.target)
    }

    private func checkIdentity(_ expected: String) throws {
        if let generation, generation != expected { throw CodexAccountError.accountChanged }
        if status == .signedOut { throw CodexAccountError.authenticationRequired }
        // Unknown is deliberately permitted for an explicitly requested saved
        // configuration. The helper checks expected_generation before any HTTP.
    }

    private func admissionFailure() -> CodexAccountError? {
        if unreaped { return .recoveryRequired }
        if isShuttingDown { return .shuttingDown }
        return nil
    }

    private func execute(_ request: CodexRuntimeSession.Request, owner: UUID?,
                         honourCallerCancellation: Bool = true) async throws -> CodexRuntimeSession.Outcome {
        guard !isShuttingDown else { throw CodexAccountError.shuttingDown }
        guard active == nil, !unreaped else { throw CodexAccountError.recoveryRequired }
        if honourCallerCancellation { try Task.checkCancellation() }
        intent &+= 1
        let id = UUID()
        let session = sessionFactory(request)
        error = nil
        operation = request.operation
        hasActiveOperation = true
        isCancelling = false
        deviceCode = nil; verificationURL = nil; isCommitting = false
        let task = Task { [weak self] in
            let result = await session.run { [weak self] event in self?.receive(event, id: id) }
            self?.complete(result, id: id)
            return result
        }
        let slot = ActiveOperation(id: id, request: request, owner: owner, session: session, task: task)
        active = slot
        let result: CodexRuntimeSession.Result
        if honourCallerCancellation {
            result = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel(id: id) }
            }
        } else { result = await task.value }
        if !result.helperReaped { throw CodexAccountError.recoveryRequired }
        if request.operation != .login, request.operation != .logout,
           (slot.cancelled || (honourCallerCancellation && Task.isCancelled)) { throw CancellationError() }
        if result.failure == .cancelledBeforeLaunch { throw CancellationError() }
        if let hostFailure = result.failure { throw Self.hostError(hostFailure) }
        guard let outcome = result.terminal?.result else { throw CodexAccountError.requestFailed }
        if outcome.status == "cancelled" { throw CancellationError() }
        guard ["ok", "signed_in", "signed_out"].contains(outcome.status) else { throw CodexAccountError.from(outcome.status) }
        return outcome
    }

    private func receive(_ event: CodexRuntimeSession.Event, id: UUID) {
        guard let active, active.id == id, event.requestID == active.request.requestID,
              active.request.operation == .login else { return }
        switch event.event {
        case .ready:
            guard !active.cancelled else { return }
            deviceCode = event.userCode
            verificationURL = event.verificationURL.flatMap(URL.init(string:))
        case .committing: isCommitting = true; deviceCode = nil; verificationURL = nil
        case .terminal: break
        }
    }

    private func complete(_ result: CodexRuntimeSession.Result, id: UUID) {
        guard let slot = active, slot.id == id else { return }
        active = nil
        operation = nil
        hasActiveOperation = !result.helperReaped
        unreaped = !result.helperReaped
        isCancelling = false; isCommitting = false; deviceCode = nil; verificationURL = nil
        if !result.helperReaped {
            error = .recoveryRequired
            updateIdentity(.unknown, generation: nil, plan: nil)
            clearModels()
            return
        }
        if let failure = result.failure {
            if failure == .cancelledBeforeLaunch { error = nil; return }
            error = Self.hostError(failure)
            clearModels()
            if slot.request.operation == .login || slot.request.operation == .logout || failure == .cleanupRequired {
                let revision = identityRevision
                updateIdentity(.unknown, generation: nil, plan: nil)
                if revision == identityRevision { advanceIdentityRevision() }
            }
            return
        }
        guard let outcome = result.terminal?.result else { error = .requestFailed; clearModels(); return }
        switch outcome.status {
        case "signed_in":
            guard let generation = outcome.generation else { error = .requestFailed; return }
            updateIdentity(.signedIn, generation: generation, plan: outcome.accountPlan)
            error = nil
        case "signed_out": updateIdentity(.signedOut, generation: nil, plan: nil); error = nil
        case "ok":
            if slot.request.operation == .models, !slot.cancelled,
               slot.request.expectedGeneration == generation, let models = outcome.models {
                self.models = models
                modelsGeneration = generation
            }
            error = nil
        case "cancelled": error = nil; if slot.request.operation == .models { clearModels() }
        default:
            error = CodexAccountError.from(outcome.status)
            clearModels()
            if ["account_changed", "authentication_failed", "invalid_account_storage"].contains(outcome.status) {
                let revision = identityRevision
                updateIdentity(.unknown, generation: nil, plan: nil)
                if revision == identityRevision { advanceIdentityRevision() }
            }
        }
    }

    private func cancel(id: UUID) { if let active, active.id == id { cancel(active) } }
    private func cancel(_ slot: ActiveOperation) {
        guard !slot.cancelled else { return }
        slot.cancelled = true
        isCancelling = true
        if slot.request.operation == .login { deviceCode = nil; verificationURL = nil }
        slot.session.cancel()
    }

    private func updateIdentity(_ status: Status, generation: String?, plan: String?) {
        let changed = self.status != status || self.generation != generation
        self.status = status; self.generation = generation; accountPlan = plan
        if changed { clearModels(); advanceIdentityRevision() }
    }

    private func advanceIdentityRevision() { identityRevision &+= 1; onIdentityChange?() }
    private func clearModels() { models = []; modelsGeneration = nil }
    private static func hostError(_ failure: CodexRuntimeSession.HostFailure) -> CodexAccountError {
        switch failure {
        case .launchFailed: .runtimeUnavailable
        case .invalidRequest: .invalidConfiguration
        case .cleanupRequired: .recoveryRequired
        case .timedOut: .timedOut
        case .cancelledBeforeLaunch: .requestFailed
        case .protocolFailed: .requestFailed
        }
    }
}
