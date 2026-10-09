import Foundation
import Observation

/// Query preferences contain scheduling numbers only. Credentials and account
/// snapshots remain outside UserDefaults and outside this value.
nonisolated struct TranslationAccountQueryPreferences: Codable, Equatable, Sendable {
    var enabled = true
    var intervalSeconds = 0
    var timeoutSeconds = 10

    static let intervalRange = 0...86_400
    static let timeoutRange = 1...120

    init(enabled: Bool = true, intervalSeconds: Int = 0, timeoutSeconds: Int = 10) {
        self.enabled = enabled
        self.intervalSeconds = intervalSeconds
        self.timeoutSeconds = timeoutSeconds
    }

    var isValid: Bool {
        Self.intervalRange.contains(intervalSeconds) && Self.timeoutRange.contains(timeoutSeconds)
    }

    var automaticallyQueries: Bool { enabled && intervalSeconds > 0 }

    private enum CodingKeys: String, CodingKey {
        case enabled, intervalSeconds, intervalMinutes, timeoutSeconds
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        timeoutSeconds = try values.decode(Int.self, forKey: .timeoutSeconds)
        if values.contains(.intervalSeconds) {
            intervalSeconds = try values.decode(Int.self, forKey: .intervalSeconds)
        } else {
            // The previous format stored minutes. Validate before multiplying
            // so corrupt values cannot overflow or turn into a fast schedule.
            let minutes = try values.decode(Int.self, forKey: .intervalMinutes)
            intervalSeconds = (0...1_440).contains(minutes) ? minutes * 60 : -1
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(intervalSeconds, forKey: .intervalSeconds)
        try values.encode(timeoutSeconds, forKey: .timeoutSeconds)
    }
}

@MainActor @Observable
final class TranslationAccountQueryPreferencesStore {
    enum StorageKey {
        static let preferences = "translationAccountQueryPreferences.v1"
    }

    private var values: [UUID: TranslationAccountQueryPreferences] = [:]
    private(set) var revision = 0
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: StorageKey.preferences),
           let saved = try? JSONDecoder().decode([UUID: TranslationAccountQueryPreferences].self, from: data) {
            values = saved.filter { $0.value.isValid }
        }
    }

    func preferences(for id: UUID) -> TranslationAccountQueryPreferences {
        values[id] ?? TranslationAccountQueryPreferences()
    }

    func set(_ preferences: TranslationAccountQueryPreferences, for id: UUID) {
        guard preferences.isValid, values[id] != preferences else { return }
        values[id] = preferences
        persist()
    }

    func remove(_ id: UUID) {
        guard values.removeValue(forKey: id) != nil else { return }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: StorageKey.preferences)
        }
        revision &+= 1
    }
}

/// A separate draft keeps Cancel and navigation-away behavior consistent with
/// the service editor. Toggling these fields never starts a background query.
@MainActor @Observable
final class TranslationAccountQueryDraft {
    let configuration: TranslationServiceConfiguration?
    var enabled: Bool
    var interval: String
    var timeout: String
    var recordsUsage: Bool
    var errorMessage: String?
    @ObservationIgnored private let services: TranslationServiceStore
    @ObservationIgnored private var original: TranslationAccountQueryPreferences
    @ObservationIgnored private var originalRecordsUsage: Bool

    init(configuration: TranslationServiceConfiguration?, services: TranslationServiceStore) {
        self.configuration = configuration
        self.services = services
        let preferences = configuration.map { services.accountQueryPreferences.preferences(for: $0.id) }
            ?? TranslationAccountQueryPreferences(enabled: false)
        original = preferences
        originalRecordsUsage = services.usage.isEnabled(for: configuration?.id)
        enabled = preferences.enabled
        interval = String(preferences.intervalSeconds)
        timeout = String(preferences.timeoutSeconds)
        recordsUsage = originalRecordsUsage
    }

    var supportsAccountQuery: Bool {
        configuration.map(TranslationAccountUsageController.supports) ?? false
    }

    var hasUnsavedChanges: Bool {
        recordsUsage != originalRecordsUsage || (supportsAccountQuery && (
            enabled != original.enabled || interval != String(original.intervalSeconds)
            || timeout != String(original.timeoutSeconds)
        ))
    }

    // Keep an existing custom duration selectable when opening older settings.
    // Choosing a new preset is the only way the draft replaces that duration.
    var intervalOptions: [Int] { Array(Set([0, 5, 30, 60, original.intervalSeconds])).sorted() }
    var timeoutOptions: [Int] { Array(Set([10, 30, 60, original.timeoutSeconds])).sorted() }

    func validatedPreferences() -> TranslationAccountQueryPreferences? {
        guard supportsAccountQuery else { errorMessage = nil; return original }
        if !enabled {
            // Hidden numeric fields must not prevent switching account queries
            // off. Retain their last valid values when a partial edit exists.
            let intervalSeconds = Int(interval).flatMap { TranslationAccountQueryPreferences.intervalRange.contains($0) ? $0 : nil } ?? original.intervalSeconds
            let timeoutSeconds = Int(timeout).flatMap { TranslationAccountQueryPreferences.timeoutRange.contains($0) ? $0 : nil } ?? original.timeoutSeconds
            errorMessage = nil
            return .init(enabled: false, intervalSeconds: intervalSeconds, timeoutSeconds: timeoutSeconds)
        }
        guard let intervalSeconds = Int(interval), TranslationAccountQueryPreferences.intervalRange.contains(intervalSeconds),
              let timeoutSeconds = Int(timeout), TranslationAccountQueryPreferences.timeoutRange.contains(timeoutSeconds) else {
            errorMessage = L10n.string("Choose a valid query interval and request timeout.")
            return nil
        }
        errorMessage = nil
        return .init(enabled: enabled, intervalSeconds: intervalSeconds, timeoutSeconds: timeoutSeconds)
    }

    @discardableResult
    func save() -> Bool {
        guard let preferences = validatedPreferences() else { return false }
        if let configuration, supportsAccountQuery {
            services.accountQueryPreferences.set(preferences, for: configuration.id)
        }
        services.usage.setEnabled(recordsUsage, for: configuration?.id)
        original = preferences
        interval = String(preferences.intervalSeconds)
        timeout = String(preferences.timeoutSeconds)
        originalRecordsUsage = recordsUsage
        return true
    }
}
