import Foundation
import Observation

nonisolated struct TranslationAccountUsageSnapshot: Equatable, Sendable {
    struct Balance: Equatable, Sendable {
        let currency: String
        let total: Decimal
        let granted: Decimal?
        let toppedUp: Decimal?
    }

    let fetchedAt: Date
    var balances: [Balance] = []
    var usedCharacters: Int?
    var characterLimit: Int?
    var hasUnlimitedCharacters = false
}

nonisolated protocol TranslationAccountUsageLoading: Sendable {
    func usage(configuration: TranslationServiceConfiguration, apiKey: String?) async throws -> TranslationAccountUsageSnapshot
    func usage(configuration: TranslationServiceConfiguration, apiKey: String?, timeout: Duration) async throws -> TranslationAccountUsageSnapshot
}

extension TranslationAccountUsageLoading {
    nonisolated func usage(configuration: TranslationServiceConfiguration, apiKey: String?, timeout: Duration) async throws -> TranslationAccountUsageSnapshot {
        try await usage(configuration: configuration, apiKey: apiKey)
    }
}

nonisolated enum TranslationAccountUsageError: String, Error, LocalizedError, Sendable {
    case unsupportedService, unavailable, invalidResponse

    var errorDescription: String? { L10n.string("translationService.accountUsageError.\(rawValue)") }
}

/// In-memory account snapshots are bound to the same configuration generation
/// as credentials. This controller never saves a service or changes routing.
@MainActor @Observable
final class TranslationAccountUsageController {
    struct State {
        var snapshot: TranslationAccountUsageSnapshot?
        var isLoading = false
        fileprivate var failure: (any Error)?
        var errorMessage: String? { failure?.localizedDescription }
    }
    private struct Entry { let revision: UUID; var state: State }
    private struct AutomaticPlan: Equatable {
        let configuration: TranslationServiceConfiguration
        let revision: UUID
        let preferences: TranslationAccountQueryPreferences

        static func == (lhs: Self, rhs: Self) -> Bool {
            // The store advances this generation for connection/key changes.
            // Display metadata must not restart the timer or read credentials.
            lhs.configuration.id == rhs.configuration.id
                && lhs.revision == rhs.revision && lhs.preferences == rhs.preferences
        }
    }
    private var entries: [UUID: Entry] = [:]
    @ObservationIgnored private let services: TranslationServiceStore
    @ObservationIgnored private let loader: any TranslationAccountUsageLoading
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var requestIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var automaticRequestIDs: Set<UUID> = []
    @ObservationIgnored private var automaticTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var automaticPlans: [UUID: AutomaticPlan] = [:]
    @ObservationIgnored private var automaticRefreshStarted = false
    @ObservationIgnored private var automaticGeneration = UUID()
    @ObservationIgnored private let automaticSleep: @Sendable (Duration) async throws -> Void

    init(services: TranslationServiceStore, loader: any TranslationAccountUsageLoading = TranslationAccountUsageLoader(),
         automaticSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.services = services
        self.loader = loader
        self.automaticSleep = automaticSleep
    }

    static func supports(_ configuration: TranslationServiceConfiguration) -> Bool {
        TranslationAccountUsageLoader.supports(configuration)
    }

    func state(for id: UUID) -> State {
        guard let entry = entries[id], services.configurationRevision(for: id) == entry.revision else { return State() }
        return entry.state
    }

    func refresh(_ configuration: TranslationServiceConfiguration, timeoutSeconds: Int? = nil) {
        refresh(configuration, timeoutSeconds: timeoutSeconds, allowsCredentialInteraction: true)
    }

    private func refresh(_ configuration: TranslationServiceConfiguration, timeoutSeconds: Int?, allowsCredentialInteraction: Bool) {
        guard let saved = services.configurations.first(where: { $0.id == configuration.id }),
              TranslationServiceStore.sameRequest(saved, configuration),
              let revision = services.configurationRevision(for: configuration.id) else { return }
        let id = configuration.id
        cancel(id)
        let snapshot = state(for: id).snapshot
        guard Self.supports(saved) else {
            entries[id] = Entry(revision: revision, state: State(failure: TranslationAccountUsageError.unsupportedService))
            return
        }
        let requestID = UUID()
        let timeout = max(1, min(timeoutSeconds ?? services.accountQueryPreferences.preferences(for: id).timeoutSeconds, 120))
        requestIDs[id] = requestID
        entries[id] = Entry(revision: revision, state: State(snapshot: snapshot, isLoading: true))
        tasks[id] = Task { [weak self, loader] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard self.services.configurationRevision(for: id) == revision else { throw CancellationError() }
                let key = try self.services.apiKey(for: id, allowsInteraction: allowsCredentialInteraction)
                let result = try await loader.usage(configuration: saved, apiKey: key, timeout: .seconds(timeout))
                try Task.checkCancellation()
                self.complete(id, revision: revision, requestID: requestID, snapshot: result, error: nil)
            } catch {
                self.complete(id, revision: revision, requestID: requestID, snapshot: snapshot,
                              error: Task.isCancelled || error is CancellationError ? nil : Self.safeError(error))
            }
        }
    }

    func cancel(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        requestIDs[id] = nil
        automaticRequestIDs.remove(id)
        if var entry = entries[id] {
            entry.state.isLoading = false
            entries[id] = entry
        }
    }

    func cancelAll() {
        for id in Array(tasks.keys) { cancel(id) }
    }

    func cancelManualQueries() {
        for id in Array(tasks.keys) where !automaticRequestIDs.contains(id) { cancel(id) }
    }

    /// Called only by app assembly. Merely opening a settings view never starts
    /// the scheduler. Existing configurations default to a zero/manual interval.
    func startAutomaticRefresh() {
        guard !automaticRefreshStarted else { return }
        automaticRefreshStarted = true
        automaticGeneration = UUID()
        observeQueryPreferences()
        configurationDidChange()
    }

    func stopAutomaticRefresh() {
        automaticRefreshStarted = false
        automaticGeneration = UUID()
        automaticTasks.values.forEach { $0.cancel() }
        automaticTasks.removeAll()
        automaticPlans.removeAll()
        cancelAll()
    }

    /// App assembly calls this when service configurations or credentials
    /// change. Saved query preferences are observed separately below.
    func configurationDidChange() {
        for id in Array(entries.keys) where services.configurationRevision(for: id) != entries[id]?.revision {
            cancel(id)
            entries[id] = nil
        }
        guard automaticRefreshStarted else { return }
        var plans: [UUID: AutomaticPlan] = [:]
        for configuration in services.configurations {
            let preferences = services.accountQueryPreferences.preferences(for: configuration.id)
            guard preferences.automaticallyQueries, Self.supports(configuration),
                  let revision = services.configurationRevision(for: configuration.id) else { continue }
            plans[configuration.id] = AutomaticPlan(configuration: configuration, revision: revision, preferences: preferences)
        }
        for id in Array(automaticPlans.keys) where automaticPlans[id] != plans[id] {
            automaticTasks.removeValue(forKey: id)?.cancel()
            automaticPlans[id] = nil
            cancel(id)
        }
        for (id, plan) in plans where automaticPlans[id] == nil {
            automaticPlans[id] = plan
            automaticTasks[id] = Task { [weak self, automaticSleep] in
                while !Task.isCancelled {
                    guard self != nil else { return }
                    self?.refreshAutomatically(plan)
                    do { try await automaticSleep(.seconds(plan.preferences.intervalSeconds)) }
                    catch { return }
                }
            }
        }
    }

    private func refreshAutomatically(_ plan: AutomaticPlan) {
        let id = plan.configuration.id
        guard automaticRefreshStarted, automaticPlans[id] == plan,
              services.configurationRevision(for: id) == plan.revision,
              services.accountQueryPreferences.preferences(for: id) == plan.preferences,
              !state(for: id).isLoading else { return }
        refresh(plan.configuration, timeoutSeconds: plan.preferences.timeoutSeconds, allowsCredentialInteraction: false)
        if tasks[id] != nil { automaticRequestIDs.insert(id) }
    }

    private func observeQueryPreferences() {
        let generation = automaticGeneration
        withObservationTracking {
            _ = services.accountQueryPreferences.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.automaticRefreshStarted, self.automaticGeneration == generation else { return }
                self.configurationDidChange()
                self.observeQueryPreferences()
            }
        }
    }

    private func complete(_ id: UUID, revision: UUID, requestID: UUID,
                          snapshot: TranslationAccountUsageSnapshot?, error: (any Error)?) {
        guard requestIDs[id] == requestID else { return }
        tasks[id] = nil
        requestIDs[id] = nil
        automaticRequestIDs.remove(id)
        guard services.configurationRevision(for: id) == revision else {
            entries[id] = nil
            return
        }
        entries[id] = Entry(revision: revision, state: State(snapshot: snapshot, failure: error))
    }

    private static func safeError(_ error: any Error) -> any Error {
        if let error = error as? TranslationAccountUsageError { return error }
        if let error = error as? RemoteTranslationError { return error }
        if let error = error as? TranslationServiceConfigurationError { return error }
        return RemoteTranslationError.connectionFailed
    }
}
