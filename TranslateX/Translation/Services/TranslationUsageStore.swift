import Foundation
import Observation

enum TranslationUsagePurpose: String, Codable, Sendable { case translation, sampleTest }
enum TranslationUsageOutcome: String, Codable, Sendable { case succeeded, failed, cancelled }

/// Numeric request metadata only. Never include text, endpoint, errors or keys.
struct TranslationUsageRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let configurationID: UUID?
    let model: String
    let purpose: TranslationUsagePurpose
    let outcome: TranslationUsageOutcome
    let completedAt: Date
    let duration: TimeInterval
    let usage: TranslationUsage?
}

@MainActor @Observable
final class TranslationUsageStore {
    static let maximumRecords = 10_000
    // Accommodates 10,000 bounded UTF-8 model identifiers plus JSON metadata.
    static let maximumStorageBytes = 32 * 1_024 * 1_024
    static let retention: TimeInterval = 30 * 24 * 60 * 60
    enum StorageKey {
        static let enabled = "preferences.translationUsage.enabled"
        static let records = "preferences.translationUsage.records"
    }

    struct Ticket {
        let id = UUID()
        let configurationID: UUID?
        let model: String
        let purpose: TranslationUsagePurpose
        let startedAt: Date
        let epoch: UUID
        let configurationEpoch: UUID?
    }

    private(set) var isEnabled: Bool
    private(set) var records: [TranslationUsageRecord]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var configurationEpochs: [String: UUID] = [:]
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: StorageKey.enabled) as? Bool ?? true
        if let data = defaults.data(forKey: StorageKey.records), data.count <= Self.maximumStorageBytes,
           let decoded = try? JSONDecoder().decode([TranslationUsageRecord].self, from: data) {
            records = Self.retained(decoded, now: now)
        } else { records = [] }
        // Remove expired or malformed disk metadata even if recording is off.
        flush()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        epoch = UUID() // Re-enabling cannot resurrect an in-flight older request.
        isEnabled = enabled
        defaults.set(enabled, forKey: StorageKey.enabled)
        prune()
    }

    func begin(configurationID: UUID?, model: String, purpose: TranslationUsagePurpose,
               now: Date = Date()) -> Ticket? {
        guard isEnabled, now.timeIntervalSince1970.isFinite else { return nil }
        let boundedModel = String(String(decoding: model.utf8.prefix(1_024), as: UTF8.self).prefix(256))
        return Ticket(configurationID: configurationID, model: boundedModel,
                      purpose: purpose, startedAt: now, epoch: epoch,
                      configurationEpoch: configurationEpochs[key(configurationID)])
    }

    func finish(_ ticket: Ticket?, outcome: TranslationUsageOutcome, usage: TranslationUsage? = nil,
                now: Date = Date()) {
        guard let ticket, isEnabled, ticket.epoch == epoch,
              ticket.configurationEpoch == configurationEpochs[key(ticket.configurationID)],
              now.timeIntervalSince1970.isFinite, !records.contains(where: { $0.id == ticket.id }) else { return }
        let duration = max(0, now.timeIntervalSince(ticket.startedAt))
        guard duration.isFinite else { return }
        records.append(.init(id: ticket.id, configurationID: ticket.configurationID, model: ticket.model,
                             purpose: ticket.purpose, outcome: outcome, completedAt: now,
                             duration: duration, usage: usage))
        records = Self.retained(records, now: now)
        persistInBackground()
    }

    func records(for configurationID: UUID?, days: Int, now: Date = Date()) -> [TranslationUsageRecord] {
        let start = Calendar.current.date(byAdding: .day, value: -(min(30, max(1, days)) - 1),
                                          to: Calendar.current.startOfDay(for: now)) ?? now
        return records.filter { $0.configurationID == configurationID && $0.completedAt >= start && $0.completedAt <= now }
    }

    func clear(configurationID: UUID?) {
        configurationEpochs[key(configurationID)] = UUID()
        records.removeAll { $0.configurationID == configurationID }
        flush()
    }

    func clearAll() {
        epoch = UUID()
        records = []
        flush()
    }

    func prune(now: Date = Date()) {
        let retained = Self.retained(records, now: now)
        guard retained != records else { return }
        records = retained
        persistInBackground()
    }

    /// Clear and normal app exit synchronously settle the latest snapshot.
    /// Ordinary translations encode off the main actor, independent of routing.
    func flush() {
        persistenceTask?.cancel()
        persistenceTask = nil
        if records.isEmpty { defaults.removeObject(forKey: StorageKey.records) }
        else if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: StorageKey.records) }
    }

    private func persistInBackground() {
        persistenceTask?.cancel()
        let snapshot = records
        persistenceTask = Task { [weak self] in
            let data = await Task.detached(priority: .utility) { try? JSONEncoder().encode(snapshot) }.value
            guard !Task.isCancelled, let self, let data else { return }
            self.defaults.set(data, forKey: StorageKey.records)
            self.persistenceTask = nil
        }
    }

    private func key(_ id: UUID?) -> String { id?.uuidString ?? "apple" }
    private static func retained(_ records: [TranslationUsageRecord], now: Date) -> [TranslationUsageRecord] {
        let oldest = now.addingTimeInterval(-retention)
        var ids = Set<UUID>()
        return Array(records.filter {
            $0.completedAt.timeIntervalSince1970.isFinite && $0.completedAt >= oldest && $0.completedAt <= now
                && $0.duration.isFinite && $0.duration >= 0 && $0.model.count <= 256 && $0.model.utf8.count <= 1_026
                && ids.insert($0.id).inserted
        }.sorted { $0.completedAt < $1.completedAt }.suffix(maximumRecords))
    }
}

/// One entry per provider invocation, including individual screenshot regions.
/// The wrapper observes completion but never retries, changes routing or text.
@MainActor
struct UsageRecordingTranslationProvider: TranslationProvider {
    let base: any TranslationProvider
    let store: TranslationUsageStore
    let configurationID: UUID?
    let model: String
    var purpose: TranslationUsagePurpose = .translation

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try Task.checkCancellation()
        let ticket = store.begin(configurationID: configurationID, model: model, purpose: purpose)
        do {
            let result = try await base.translate(request)
            store.finish(ticket, outcome: Task.isCancelled ? .cancelled : .succeeded, usage: result.usage)
            return result
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            store.finish(ticket, outcome: cancelled ? .cancelled : .failed)
            throw error
        }
    }
}
