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
    private var entries: [UUID: Entry] = [:]
    @ObservationIgnored private let services: TranslationServiceStore
    @ObservationIgnored private let loader: any TranslationAccountUsageLoading
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var requestIDs: [UUID: UUID] = [:]

    init(services: TranslationServiceStore, loader: any TranslationAccountUsageLoading = TranslationAccountUsageLoader()) {
        self.services = services
        self.loader = loader
    }

    static func supports(_ configuration: TranslationServiceConfiguration) -> Bool {
        TranslationAccountUsageLoader.supports(configuration)
    }

    func state(for id: UUID) -> State {
        guard let entry = entries[id], services.configurationRevision(for: id) == entry.revision else { return State() }
        return entry.state
    }

    func refresh(_ configuration: TranslationServiceConfiguration) {
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
        requestIDs[id] = requestID
        entries[id] = Entry(revision: revision, state: State(snapshot: snapshot, isLoading: true))
        tasks[id] = Task { [weak self, loader] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard self.services.configurationRevision(for: id) == revision else { throw CancellationError() }
                let key = try self.services.apiKey(for: id)
                let result = try await loader.usage(configuration: saved, apiKey: key)
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
        if var entry = entries[id] {
            entry.state.isLoading = false
            entries[id] = entry
        }
    }

    func cancelAll() {
        for id in Array(tasks.keys) { cancel(id) }
    }

    private func complete(_ id: UUID, revision: UUID, requestID: UUID,
                          snapshot: TranslationAccountUsageSnapshot?, error: (any Error)?) {
        guard requestIDs[id] == requestID else { return }
        tasks[id] = nil
        requestIDs[id] = nil
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
