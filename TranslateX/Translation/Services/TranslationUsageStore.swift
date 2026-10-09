import Foundation
import Observation

enum TranslationUsagePurpose: String, Codable, Sendable { case translation, sampleTest }
enum TranslationUsageOutcome: String, Codable, Sendable { case succeeded, failed, cancelled }

/// Request metrics only. Never include text, endpoint, errors or keys.
struct TranslationUsageRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let configurationID: UUID?
    let model: String
    let purpose: TranslationUsagePurpose
    let outcome: TranslationUsageOutcome
    let completedAt: Date
    let duration: TimeInterval
    let usage: TranslationUsage?
    var serviceName: String? = nil
    var httpStatus: Int? = nil
    var priceSnapshot: TranslationModelPrice? = nil
    // nil is a legacy record; an empty value explicitly excludes unsupported or proxy tariffs.
    var pricingProvider: String? = nil
    var priceBackfilled: Bool? = nil

    var estimatedCost: Decimal? { configurationID == nil ? 0 : priceSnapshot?.estimate(usage) }
    var estimatedUSD: Decimal? { configurationID == nil ? 0 : priceSnapshot?.currency == "USD" ? estimatedCost : nil }
}

struct TranslationUsageTotals: Codable, Equatable, Sendable {
    var requests = 0
    var succeeded = 0
    var failed = 0
    var cancelled = 0
    var duration: TimeInterval = 0
    var inputTokens: Decimal?
    var outputTokens: Decimal?
    var totalTokens: Decimal?
    var characters: Decimal?
    var tokenReports = 0
    var costs: [String: Decimal]?
    var costReports: Int?

    var averageDuration: TimeInterval? { requests > 0 ? duration / Double(requests) : nil }
    mutating func add(_ record: TranslationUsageRecord) {
        requests += 1
        switch record.outcome {
        case .succeeded: succeeded += 1
        case .failed: failed += 1
        case .cancelled: cancelled += 1
        }
        duration += record.duration
        if record.configurationID != nil, let amount = record.estimatedCost, let currency = record.priceSnapshot?.currency {
            var values = costs ?? [:]; values[currency, default: 0] += amount; costs = values
            costReports = (costReports ?? 0) + 1
        }
        if let value = record.usage?.inputTokens { inputTokens = (inputTokens ?? 0) + Decimal(value) }
        if let value = record.usage?.outputTokens { outputTokens = (outputTokens ?? 0) + Decimal(value) }
        if let value = record.usage?.characters { characters = (characters ?? 0) + Decimal(value) }
        if let value = record.usage?.reportedTokenTotal {
            totalTokens = (totalTokens ?? 0) + Decimal(value)
            tokenReports += 1
        }
    }
    mutating func merge(_ other: Self) {
        requests += other.requests; succeeded += other.succeeded
        failed += other.failed; cancelled += other.cancelled; duration += other.duration
        tokenReports += other.tokenReports
        costReports = (costReports ?? 0) + (other.costReports ?? 0)
        for (currency, amount) in other.costs ?? [:] {
            var values = costs ?? [:]; values[currency, default: 0] += amount; costs = values
        }
        if let value = other.inputTokens { inputTokens = (inputTokens ?? 0) + value }
        if let value = other.outputTokens { outputTokens = (outputTokens ?? 0) + value }
        if let value = other.totalTokens { totalTokens = (totalTokens ?? 0) + value }
        if let value = other.characters { characters = (characters ?? 0) + value }
    }
    var isValid: Bool {
        requests > 0 && requests < Int.max / 4 && succeeded >= 0 && failed >= 0 && cancelled >= 0
            && succeeded <= requests && failed <= requests && cancelled <= requests
            && succeeded + failed + cancelled == requests && duration.isFinite && duration >= 0
            && tokenReports >= 0 && tokenReports <= requests
            && (costReports ?? 0) >= 0 && (costReports ?? 0) <= requests
            && (costs ?? [:]).allSatisfy { ["USD", "CNY"].contains($0.key) && !$0.value.isNaN && $0.value >= 0 }
            && [inputTokens, outputTokens, totalTokens, characters].allSatisfy { value in
                value.map { !$0.isNaN && $0 >= 0 } ?? true
            }
    }
}

struct TranslationUsageDay: Codable, Equatable, Sendable {
    let configurationID: UUID?
    let model: String
    let purpose: TranslationUsagePurpose
    let day: Date
    var totals: TranslationUsageTotals
    var serviceName: String? = nil
}

@MainActor @Observable
final class TranslationUsageStore {
    // This is an internal memory budget, not a statistics limit: older metrics
    // are rolled up before being removed, including when this budget is reached.
    static let maximumRecords = 10_000
    static let maximumStorageBytes = 32 * 1_024 * 1_024
    static let retention: TimeInterval = 30 * 24 * 60 * 60
    enum StorageKey {
        static let enabled = "preferences.translationUsage.enabled" // legacy global preference
        static let records = "preferences.translationUsage.records" // legacy array
        static let services = "preferences.translationUsage.services"
        static let snapshot = "preferences.translationUsage.snapshot"
    }
    struct Snapshot: Codable, Sendable {
        var version = 2
        var records: [TranslationUsageRecord]
        var summaries: [TranslationUsageDay]
    }
    struct Ticket {
        let id = UUID()
        let configurationID: UUID?
        let model: String
        let purpose: TranslationUsagePurpose
        let startedAt: Date
        let epoch: UUID
        let configurationEpoch: UUID?
        let priceSnapshot: TranslationModelPrice?
        let serviceName: String?
        let pricingProvider: String?
    }

    private(set) var records: [TranslationUsageRecord]
    private(set) var summaries: [TranslationUsageDay]
    let pricing: TranslationUsagePricing
    @ObservationIgnored private var configurations: [UUID: TranslationServiceConfiguration] = [:]
    private var recording: [String: Bool]
    private let legacyEnabled: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var configurationEpochs: [String: UUID] = [:]
    @ObservationIgnored private var pending: Set<UUID> = []
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        pricing = TranslationUsagePricing(defaults: defaults)
        legacyEnabled = defaults.object(forKey: StorageKey.enabled) as? Bool ?? true
        recording = defaults.dictionary(forKey: StorageKey.services) as? [String: Bool] ?? [:]
        if let data = defaults.data(forKey: StorageKey.snapshot), data.count <= Self.maximumStorageBytes,
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), (1...2).contains(snapshot.version) {
            records = snapshot.records
            summaries = snapshot.summaries.filter { $0.day.timeIntervalSince1970.isFinite && $0.day <= now
                && $0.model.count <= 256 && ($0.serviceName?.count ?? 0) <= 128 && $0.totals.isValid }
        } else if defaults.data(forKey: StorageKey.snapshot) == nil,
                  let data = defaults.data(forKey: StorageKey.records), data.count <= Self.maximumStorageBytes,
                  let decoded = try? JSONDecoder().decode([TranslationUsageRecord].self, from: data) {
            records = decoded; summaries = []
        } else { records = []; summaries = [] }
        compact(now: now)
        if defaults.data(forKey: StorageKey.snapshot) != nil || defaults.data(forKey: StorageKey.records) != nil { flush() }
    }

    /// Preserve an old global opt-out for existing services. New services use
    /// the normal enabled default after this one-time migration.
    func registerServices(_ ids: [UUID?]) {
        guard defaults.object(forKey: StorageKey.enabled) != nil else { return }
        for id in ids where recording[key(id)] == nil { recording[key(id)] = legacyEnabled }
        defaults.set(recording, forKey: StorageKey.services)
        defaults.removeObject(forKey: StorageKey.enabled)
    }
    func registerConfigurations(_ values: [TranslationServiceConfiguration]) {
        configurations = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }
    func isEnabled(for configurationID: UUID?) -> Bool {
        recording[key(configurationID)] ?? (defaults.object(forKey: StorageKey.enabled) == nil ? true : legacyEnabled)
    }
    func setEnabled(_ enabled: Bool, for configurationID: UUID?) {
        guard enabled != isEnabled(for: configurationID) else { return }
        configurationEpochs[key(configurationID)] = UUID()
        recording[key(configurationID)] = enabled
        defaults.set(recording, forKey: StorageKey.services)
    }

    func begin(configurationID: UUID?, model: String, purpose: TranslationUsagePurpose,
               now: Date = Date()) -> Ticket? {
        guard isEnabled(for: configurationID), now.timeIntervalSince1970.isFinite else { return nil }
        let boundedModel = String(String(decoding: model.utf8.prefix(1_024), as: UTF8.self).prefix(256))
        let ticket = Ticket(configurationID: configurationID, model: boundedModel,
                            purpose: purpose, startedAt: now, epoch: epoch,
                            configurationEpoch: configurationEpochs[key(configurationID)],
                            priceSnapshot: configurationID.flatMap { configurations[$0] }.flatMap { pricing.price(for: $0, model: boundedModel) },
                            serviceName: configurationID.flatMap { configurations[$0]?.name }.map { String($0.prefix(128)) },
                            pricingProvider: configurationID.flatMap { configurations[$0] }.flatMap(TranslationUsagePricing.provider) ?? "")
        pending.insert(ticket.id)
        return ticket
    }
    func finish(_ ticket: Ticket?, outcome: TranslationUsageOutcome, usage: TranslationUsage? = nil, httpStatus: Int? = nil,
                now: Date = Date()) {
        guard let ticket, pending.remove(ticket.id) != nil, isEnabled(for: ticket.configurationID),
              ticket.epoch == epoch,
              ticket.configurationEpoch == configurationEpochs[key(ticket.configurationID)],
              now.timeIntervalSince1970.isFinite else { return }
        let duration = max(0, now.timeIntervalSince(ticket.startedAt))
        guard duration.isFinite else { return }
        records.append(.init(id: ticket.id, configurationID: ticket.configurationID, model: ticket.model,
                             purpose: ticket.purpose, outcome: outcome, completedAt: now,
                             duration: duration, usage: usage, serviceName: ticket.serviceName,
                             httpStatus: ticket.configurationID == nil ? nil : httpStatus.flatMap { (100...599).contains($0) ? $0 : nil },
                             priceSnapshot: ticket.priceSnapshot, pricingProvider: ticket.pricingProvider))
        compact(now: now)
        persistInBackground()
    }
    func refreshPrices() async {
        guard await pricing.refresh() else { return }
        backfillMissingCosts()
    }

    /// Fill only missing recent estimates. Existing priced requests and rolled-up
    /// history retain their original rates. Legacy records lack endpoint identity:
    /// their current official configuration must still use the recorded model,
    /// and the resulting estimate is explicitly marked as a current-rate backfill.
    @discardableResult
    func backfillMissingCosts() -> Int {
        var count = 0
        for index in records.indices {
            let record = records[index]
            guard record.configurationID != nil, record.priceSnapshot == nil else { continue }
            let provider: String?
            if let recorded = record.pricingProvider {
                provider = recorded
            } else if let id = record.configurationID, let configuration = configurations[id], configuration.model == record.model {
                provider = TranslationUsagePricing.provider(for: configuration)
            } else { provider = nil }
            guard let provider,
                  let price = pricing.prices.first(where: { $0.provider == provider && $0.model == record.model && $0.currency == "USD" }),
                  price.estimate(record.usage) != nil else { continue }
            records[index].priceSnapshot = price
            records[index].priceBackfilled = true
            count += 1
        }
        if count > 0 { flush() }
        return count
    }

    func records(for configurationID: UUID?, days: Int, now: Date = Date()) -> [TranslationUsageRecord] {
        let start = periodStart(days: days, now: now)
        return records.filter { $0.configurationID == configurationID && $0.completedAt >= start && $0.completedAt <= now }
    }
    /// Zero days means all time. Summaries and recent records are disjoint.
    func daily(for configurationID: UUID?, days: Int, purpose: TranslationUsagePurpose? = nil,
               now: Date = Date(), calendar: Calendar = .current) -> [TranslationUsageDay] {
        let start = periodStart(days: days, now: now, calendar: calendar)
        var result = summaries.filter { $0.configurationID == configurationID && $0.day >= start && $0.day <= now
            && (purpose == nil || $0.purpose == purpose) }
        for record in records where record.configurationID == configurationID && record.completedAt >= start
            && record.completedAt <= now && (purpose == nil || record.purpose == purpose) {
            var totals = TranslationUsageTotals(); totals.add(record)
            result.append(.init(configurationID: configurationID, model: record.model, purpose: record.purpose,
                                day: calendar.startOfDay(for: record.completedAt), totals: totals))
        }
        return result
    }
    func totals(for configurationID: UUID?, days: Int = 0, purpose: TranslationUsagePurpose? = nil,
                now: Date = Date()) -> TranslationUsageTotals {
        daily(for: configurationID, days: days, purpose: purpose, now: now).reduce(into: .init()) { $0.merge($1.totals) }
    }
    func hasStatistics(for configurationID: UUID?) -> Bool {
        records.contains { $0.configurationID == configurationID } || summaries.contains { $0.configurationID == configurationID }
    }
    var hasStatistics: Bool { !records.isEmpty || !summaries.isEmpty }
    func clear(configurationID: UUID?) {
        configurationEpochs[key(configurationID)] = UUID()
        records.removeAll { $0.configurationID == configurationID }
        summaries.removeAll { $0.configurationID == configurationID }
        flush()
    }
    func clearAll() {
        epoch = UUID(); pending.removeAll(); records = []; summaries = []; flush()
    }
    func prune(now: Date = Date()) {
        compact(now: now)
        persistInBackground()
    }
    func flush() {
        persistenceTask?.cancel(); persistenceTask = nil
        persist(snapshotData())
    }
    private func snapshotData() -> Data? { try? JSONEncoder().encode(Snapshot(records: records, summaries: summaries)) }
    private func persist(_ data: Data?) {
        guard let data else { return }
        // A single snapshot commits the rollup and detail removal together.
        defaults.set(data, forKey: StorageKey.snapshot)
        defaults.removeObject(forKey: StorageKey.records)
    }
    private func persistInBackground() {
        persistenceTask?.cancel()
        let snapshot = Snapshot(records: records, summaries: summaries)
        persistenceTask = Task { [weak self] in
            let data = await Task.detached(priority: .utility) { try? JSONEncoder().encode(snapshot) }.value
            guard !Task.isCancelled, let self else { return }
            self.persist(data); self.persistenceTask = nil
        }
    }
    private func compact(now: Date) {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(-Self.retention)
        var ids = Set<UUID>()
        let valid = records.filter {
            $0.completedAt.timeIntervalSince1970.isFinite && $0.completedAt <= now
                && $0.duration.isFinite && $0.duration >= 0 && $0.model.count <= 256 && $0.model.utf8.count <= 1_026
                && ($0.serviceName?.count ?? 0) <= 128
                && ($0.httpStatus.map { (100...599).contains($0) } ?? true)
                && ($0.priceSnapshot?.isValid ?? true)
                && ids.insert($0.id).inserted
        }.sorted { $0.completedAt < $1.completedAt }
        let recentCount = valid.filter { $0.completedAt >= cutoff }.count
        var excess = max(0, recentCount - Self.maximumRecords)
        var grouped = Dictionary(grouping: summaries) { SummaryKey(id: $0.configurationID, model: $0.model, purpose: $0.purpose, day: $0.day, serviceName: $0.serviceName) }
            .mapValues { values in values.reduce(into: TranslationUsageTotals()) { $0.merge($1.totals) } }
        records = valid.filter { record in
            guard record.completedAt < cutoff || excess > 0 else { return true }
            if record.completedAt >= cutoff { excess -= 1 }
            let key = SummaryKey(id: record.configurationID, model: record.model, purpose: record.purpose,
                                 day: calendar.startOfDay(for: record.completedAt), serviceName: record.serviceName)
            grouped[key, default: .init()].add(record)
            return false
        }
        summaries = grouped.map { key, totals in .init(configurationID: key.id, model: key.model, purpose: key.purpose, day: key.day, totals: totals, serviceName: key.serviceName) }
            .sorted { $0.day < $1.day }
    }
    private struct SummaryKey: Hashable {
        let id: UUID?; let model: String; let purpose: TranslationUsagePurpose; let day: Date; let serviceName: String?
    }
    private func periodStart(days: Int, now: Date, calendar: Calendar = .current) -> Date {
        days == 0 ? .distantPast : calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: calendar.startOfDay(for: now)) ?? now
    }
    private func key(_ id: UUID?) -> String { id?.uuidString ?? "apple" }
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
        let response = TranslationUsageHTTPResponse()
        do {
            let result = try await TranslationUsageHTTPContext.$response.withValue(response) { try await base.translate(request) }
            store.finish(ticket, outcome: Task.isCancelled ? .cancelled : .succeeded, usage: result.usage, httpStatus: response.status)
            return result
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            store.finish(ticket, outcome: cancelled ? .cancelled : .failed, httpStatus: response.status)
            throw error
        }
    }
}
