import Foundation
import LocalAuthentication
import Observation
import Security

/// Endpoint binding prevents an interrupted update or modified preference file
/// from reusing a credential with a different receiver. This record is stored
/// entirely in Keychain, and is never part of the preferences payload.
struct TranslationServiceCredential: Codable, Equatable, Sendable {
    let apiKey: String
    let endpoint: String
}

@MainActor
protocol TranslationCredentialStore {
    func credential(for id: UUID) throws -> TranslationServiceCredential?
    /// Scheduled work must fail rather than showing system authentication UI.
    func credentialWithoutInteraction(for id: UUID) throws -> TranslationServiceCredential?
    /// Metadata only. A store that cannot inspect presence without loading the
    /// value returns nil rather than silently reading a secret.
    func containsCredential(for id: UUID) throws -> Bool?
    func setCredential(_ credential: TranslationServiceCredential, for id: UUID) throws
    func removeCredential(for id: UUID) throws
}

extension TranslationCredentialStore {
    func credentialWithoutInteraction(for id: UUID) throws -> TranslationServiceCredential? {
        throw TranslationServiceConfigurationError.credentialUnavailable
    }
    func containsCredential(for id: UUID) throws -> Bool? { nil }
}

/// Only exact generic-password items in this app's service namespace are
/// queried. No account discovery, access groups, or synchronizable items.
@MainActor
struct KeychainTranslationCredentialStore: TranslationCredentialStore {
    // Keep this pre-release namespace when changing the app's bundle ID so
    // existing API keys remain addressable; macOS still controls access.
    private let service = "com.theoyuuu.LumaxTranslate.translation-api"

    func containsCredential(for id: UUID) throws -> Bool? {
        var query = query(for: id)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Opening an editor never prompts to unlock a secret. Explicit reveal
        // and a user-requested service operation use the separate value query.
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = authentication
        var result: CFTypeRef?
        let status = TSXCopyKeychainItemWithoutInteraction(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw TranslationServiceConfigurationError.credentialUnavailable
        }
        return true
    }

    func credential(for id: UUID) throws -> TranslationServiceCredential? {
        try credential(for: id, allowsInteraction: true)
    }

    func credentialWithoutInteraction(for id: UUID) throws -> TranslationServiceCredential? {
        try credential(for: id, allowsInteraction: false)
    }

    private func credential(for id: UUID, allowsInteraction: Bool) throws -> TranslationServiceCredential? {
        var query = query(for: id)
        if !allowsInteraction {
            let authentication = LAContext()
            authentication.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = authentication
        }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = allowsInteraction
            ? SecItemCopyMatching(query as CFDictionary, &result)
            : TSXCopyKeychainItemWithoutInteraction(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let credential = try? JSONDecoder().decode(TranslationServiceCredential.self, from: data) else {
            throw TranslationServiceConfigurationError.credentialUnavailable
        }
        return credential
    }

    func setCredential(_ credential: TranslationServiceCredential, for id: UUID) throws {
        let data: Data
        do { data = try JSONEncoder().encode(credential) }
        catch { throw TranslationServiceConfigurationError.credentialUnavailable }
        let query = query(for: id)
        let changes = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, changes)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw TranslationServiceConfigurationError.credentialUnavailable
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "TSX API key"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw TranslationServiceConfigurationError.credentialUnavailable
        }
    }

    func removeCredential(for id: UUID) throws {
        let status = SecItemDelete(query(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TranslationServiceConfigurationError.credentialUnavailable
        }
    }

    private func query(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString.lowercased(),
            kSecAttrSynchronizable as String: false
        ]
    }
}

@MainActor @Observable
final class TranslationServiceStore {
    enum SampleTestOutcome: String, Codable, Equatable { case succeeded, failed }
    struct SampleTestRecord: Codable, Equatable {
        let outcome: SampleTestOutcome
        let completedAt: Date
        let configurationRevision: UUID
        var duration: TimeInterval?
    }

    let codex: CodexAccountController
    let usage: TranslationUsageStore
    let accountQueryPreferences: TranslationAccountQueryPreferencesStore
    private(set) var configurations: [TranslationServiceConfiguration]
    private(set) var selectedID: UUID?
    private(set) var revision: Int = 0
    private(set) var automaticTranslationRevision = 0
    private(set) var appleAutomaticallyTranslates: Bool
    // Only completion time/outcome/generation persist. Never sample text, error
    // details, response bodies, keys, or account tokens.
    private var sampleTests: [UUID: SampleTestRecord] = [:]
    private var configurationRevisions: [UUID: UUID] = [:]

    var selectedConfiguration: TranslationServiceConfiguration? {
        configurations.first { $0.id == selectedID }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: any TranslationCredentialStore

    init(
        defaults: UserDefaults = .standard,
        credentials: any TranslationCredentialStore = KeychainTranslationCredentialStore(),
        codex: CodexAccountController = CodexAccountController()
    ) {
        self.defaults = defaults
        self.credentials = credentials
        self.codex = codex
        usage = TranslationUsageStore(defaults: defaults)
        accountQueryPreferences = TranslationAccountQueryPreferencesStore(defaults: defaults)
        appleAutomaticallyTranslates = defaults.object(forKey: StorageKey.appleAutomaticTranslation) as? Bool ?? true
        // Invalid versions, duplicate identifiers, and any malformed record fail
        // closed. Do not rewrite or automatically activate recovered cloud data.
        if let data = defaults.data(forKey: StorageKey.services),
           let state = try? JSONDecoder().decode(StoredState.self, from: data),
           state.version == 1,
           Set(state.configurations.map(\.id)).count == state.configurations.count,
           let validated = try? state.configurations.map({ try $0.validated() }) {
            configurations = validated
            let ids = Set(validated.map(\.id))
            sampleTests = (state.sampleTests ?? [:]).filter { ids.contains($0.key) && $0.value.completedAt.timeIntervalSince1970.isFinite }
            configurationRevisions = (state.configurationRevisions ?? [:]).filter { ids.contains($0.key) }
            selectedID = state.selectedID.flatMap { selected in
                validated.contains { $0.id == selected } ? selected : nil
            }
        } else {
            configurations = []
            selectedID = nil
        }
        for configuration in configurations where configurationRevisions[configuration.id] == nil {
            configurationRevisions[configuration.id] = UUID()
        }
        usage.registerServices([nil] + configurations.map { Optional($0.id) })
        usage.registerConfigurations(configurations)
        codex.onIdentityChange = { [weak self] in
            guard let self else { return }
            for configuration in self.configurations where configuration.kind == .codex {
                self.invalidateSampleTest(for: configuration.id)
            }
            self.persistTestHistory()
            if self.selectedConfiguration?.kind == .codex { self.revision &+= 1 }
        }
    }

    func sampleTestOutcome(for configuration: TranslationServiceConfiguration) -> SampleTestOutcome? {
        guard let saved = configurations.first(where: { $0.id == configuration.id }),
              Self.sameRequest(saved, configuration), let test = sampleTests[configuration.id],
              test.configurationRevision == configurationRevisions[configuration.id] else { return nil }
        return test.outcome
    }

    func sampleTestRecord(for id: UUID) -> SampleTestRecord? { sampleTests[id] }

    /// Ignores display/scheduling preferences; every field sent to a provider
    /// remains part of the equality check.
    static func sameRequest(_ lhs: TranslationServiceConfiguration, _ rhs: TranslationServiceConfiguration) -> Bool {
        var lhs = lhs
        lhs.name = rhs.name; lhs.automaticallyTranslates = rhs.automaticallyTranslates
        lhs.website = rhs.website
        return lhs == rhs
    }

    /// Changes even for a key-only save. Reading feedback must never read a key.
    func configurationRevision(for id: UUID) -> UUID? { configurationRevisions[id] }

    func recordSampleTest(_ outcome: SampleTestOutcome, for configuration: TranslationServiceConfiguration,
                          revision: UUID?, completedAt: Date = Date(), duration: TimeInterval? = nil) {
        guard let revision, configurationRevisions[configuration.id] == revision,
              let saved = configurations.first(where: { $0.id == configuration.id }) else { return }
        guard Self.sameRequest(configuration, saved), completedAt.timeIntervalSince1970.isFinite else { return }
        sampleTests[configuration.id] = SampleTestRecord(outcome: outcome, completedAt: completedAt, configurationRevision: revision,
            duration: duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
        persistTestHistory()
        // Do not advance the translation-routing revision for display feedback.
    }

    private func invalidateSampleTest(for id: UUID) {
        configurationRevisions[id] = UUID()
    }

    /// A nil key preserves the existing credential. An explicit empty string
    /// removes it for services that allow unauthenticated requests.
    func save(_ configuration: TranslationServiceConfiguration, apiKey: String?) throws {
        let configuration = try configuration.validated()
        let key = try self.apiKey(for: configuration, replacement: apiKey)
        var updated = configurations
        if let index = updated.firstIndex(where: { $0.id == configuration.id }) {
            updated[index] = configuration
        } else {
            updated.append(configuration)
        }
        // Encode before changing Keychain; validation/encoding/keychain failure
        // leaves the previous in-memory and persisted configuration untouched.
        var revisions = configurationRevisions
        let prior = configurations.first { $0.id == configuration.id }
        let requestChanged = apiKey != nil || prior.map({ !Self.sameRequest($0, configuration) }) != false
        if requestChanged {
            revisions[configuration.id] = UUID()
        }
        let data = try encoded(configurations: updated, selectedID: selectedID, revisions: revisions)
        if apiKey != nil, configuration.kind != .codex {
            if let key {
                try credentials.setCredential(.init(apiKey: key, endpoint: configuration.endpoint), for: configuration.id)
            } else {
                try credentials.removeCredential(for: configuration.id)
            }
        }
        defaults.set(data, forKey: StorageKey.services)
        configurations = updated
        usage.registerConfigurations(configurations)
        configurationRevisions = revisions
        var priorIgnoringWebsite = prior
        priorIgnoringWebsite?.website = configuration.website
        // Only a public website edit is new display-only metadata. Preserve the
        // existing routing behavior of other editor saves and key replacements.
        if apiKey != nil || priorIgnoringWebsite != configuration { revision &+= 1 }
    }

    func remove(_ id: UUID) throws {
        guard configurations.contains(where: { $0.id == id }) else {
            throw TranslationServiceConfigurationError.unknownService
        }
        let updated = configurations.filter { $0.id != id }
        let selection = selectedID == id ? nil : selectedID
        let data = try encoded(configurations: updated, selectedID: selection)
        if configurations.first(where: { $0.id == id })?.kind != .codex {
            try credentials.removeCredential(for: id)
        }
        defaults.set(data, forKey: StorageKey.services)
        configurations = updated
        usage.registerConfigurations(configurations)
        selectedID = selection
        sampleTests[id] = nil
        configurationRevisions[id] = nil
        usage.setEnabled(false, for: id)
        accountQueryPreferences.remove(id)
        revision &+= 1
    }

    func select(_ id: UUID?) throws {
        guard selectedID != id else { return }
        if let id {
            guard let configuration = configurations.first(where: { $0.id == id }) else {
                throw TranslationServiceConfigurationError.unknownService
            }
            _ = try apiKey(for: configuration, replacement: nil)
        }
        let data = try encoded(configurations: configurations, selectedID: id)
        defaults.set(data, forKey: StorageKey.services)
        selectedID = id
        revision &+= 1
    }

    /// A scheduling preference does not read credentials, change the destination,
    /// or invalidate a successful sample. Both windows observe this same value.
    func setAutomaticTranslation(_ enabled: Bool, for id: UUID?) throws {
        guard let id else {
            guard appleAutomaticallyTranslates != enabled else { return }
            defaults.set(enabled, forKey: StorageKey.appleAutomaticTranslation)
            appleAutomaticallyTranslates = enabled
            automaticTranslationRevision &+= 1
            return
        }
        guard let index = configurations.firstIndex(where: { $0.id == id }) else {
            throw TranslationServiceConfigurationError.unknownService
        }
        guard configurations[index].automaticallyTranslates != enabled else { return }
        var updated = configurations
        updated[index].automaticallyTranslates = enabled
        let data = try encoded(configurations: updated, selectedID: selectedID)
        defaults.set(data, forKey: StorageKey.services)
        configurations = updated
        usage.registerConfigurations(configurations)
        automaticTranslationRevision &+= 1
    }

    func apiKey(for id: UUID, allowsInteraction: Bool = true) throws -> String? {
        guard let configuration = configurations.first(where: { $0.id == id }) else {
            throw TranslationServiceConfigurationError.unknownService
        }
        return try resolveAPIKey(for: configuration.validated(), replacement: nil, allowsInteraction: allowsInteraction)
    }

    /// Resolve the credential for an unsaved Test request using the same rules
    /// as Save. A changed endpoint cannot silently receive the previous key.
    func apiKey(for configuration: TranslationServiceConfiguration, replacement: String?) throws -> String? {
        let configuration = try configuration.validated()
        return try resolveAPIKey(for: configuration, replacement: replacement)
    }

    /// Model discovery validates only its actual inputs. In particular, an
    /// empty model/name must not prevent fetching a catalog for the first time.
    func apiKeyForModelCatalog(for configuration: TranslationServiceConfiguration, replacement: String?) throws -> String? {
        var configuration = configuration
        configuration.endpoint = try configuration.validatedEndpoint().absoluteString
        return try resolveAPIKey(for: configuration, replacement: replacement)
    }

    /// Exact-item metadata lookup; never obtains the Keychain value.
    func storedKeyPresence(for configuration: TranslationServiceConfiguration) throws -> Bool? {
        guard configuration.kind != .codex else { return false }
        try validateSavedCredentialIdentity(configuration)
        return try credentials.containsCredential(for: configuration.id)
    }

    /// This is called only by an explicit Reveal action. Validate against the
    /// saved record as well as the Keychain binding, independently of the draft
    /// name/model fields the user may currently be editing.
    func savedKeyForReveal(for configuration: TranslationServiceConfiguration) throws -> String? {
        guard configuration.kind != .codex else { return nil }
        try validateSavedCredentialIdentity(configuration)
        guard let credential = try credentials.credential(for: configuration.id) else { return nil }
        let endpoint = try configuration.validatedEndpoint().absoluteString
        guard credential.endpoint == endpoint else { throw TranslationServiceConfigurationError.endpointChanged }
        return try validatedKey(credential.apiKey, required: false)
    }

    private func validateSavedCredentialIdentity(_ configuration: TranslationServiceConfiguration) throws {
        guard let saved = configurations.first(where: { $0.id == configuration.id }) else {
            throw TranslationServiceConfigurationError.unknownService
        }
        guard saved.kind == configuration.kind,
              saved.endpoint == (try configuration.validatedEndpoint().absoluteString) else {
            throw TranslationServiceConfigurationError.endpointChanged
        }
    }

    private func resolveAPIKey(for configuration: TranslationServiceConfiguration, replacement: String?, allowsInteraction: Bool = true) throws -> String? {
        if configuration.kind == .codex {
            guard replacement == nil || replacement == "" else { throw TranslationServiceConfigurationError.invalidAPIKey }
            return nil
        }
        if let saved = configurations.first(where: { $0.id == configuration.id }), saved.kind != configuration.kind {
            throw TranslationServiceConfigurationError.endpointChanged
        }
        let candidate: String?
        if let replacement {
            candidate = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let credential = try allowsInteraction
                ? credentials.credential(for: configuration.id)
                : credentials.credentialWithoutInteraction(for: configuration.id)
            if let credential {
                guard credential.endpoint == configuration.endpoint else {
                    throw TranslationServiceConfigurationError.endpointChanged
                }
                candidate = credential.apiKey
            } else {
                candidate = nil
            }
        }
        return try validatedKey(candidate, required: configuration.kind.requiresAPIKey)
    }

    private func validatedKey(_ candidate: String?, required: Bool) throws -> String? {
        let key = candidate.flatMap { $0.isEmpty ? nil : $0 }
        if required, key == nil {
            throw TranslationServiceConfigurationError.missingAPIKey
        }
        if let key {
            guard key.utf8.count <= 8_192,
                  !key.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
                  !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw TranslationServiceConfigurationError.invalidAPIKey
            }
        }
        return key
    }

    enum StorageKey {
        static let services = "preferences.translationServices"
        static let appleAutomaticTranslation = "preferences.appleAutomaticTranslation"
    }

    private struct StoredState: Codable {
        var version = 1
        let configurations: [TranslationServiceConfiguration]
        let selectedID: UUID?
        var sampleTests: [UUID: SampleTestRecord]?
        var configurationRevisions: [UUID: UUID]?

        enum CodingKeys: String, CodingKey { case version, configurations, selectedID, sampleTests, configurationRevisions }
        init(configurations: [TranslationServiceConfiguration], selectedID: UUID?, sampleTests: [UUID: SampleTestRecord]?, configurationRevisions: [UUID: UUID]?) {
            self.configurations = configurations; self.selectedID = selectedID
            self.sampleTests = sampleTests; self.configurationRevisions = configurationRevisions
        }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            configurations = try values.decode([TranslationServiceConfiguration].self, forKey: .configurations)
            selectedID = try values.decodeIfPresent(UUID.self, forKey: .selectedID)
            // A malformed optional history must not make valid services vanish.
            sampleTests = try? values.decodeIfPresent([UUID: SampleTestRecord].self, forKey: .sampleTests)
            configurationRevisions = try? values.decodeIfPresent([UUID: UUID].self, forKey: .configurationRevisions)
        }
    }

    private func persistTestHistory() {
        if let data = try? encoded(configurations: configurations, selectedID: selectedID) {
            defaults.set(data, forKey: StorageKey.services)
        }
    }

    private func encoded(configurations: [TranslationServiceConfiguration], selectedID: UUID?, revisions: [UUID: UUID]? = nil) throws -> Data {
        let ids = Set(configurations.map(\.id))
        do { return try JSONEncoder().encode(StoredState(configurations: configurations, selectedID: selectedID,
            sampleTests: sampleTests.filter { ids.contains($0.key) },
            configurationRevisions: (revisions ?? configurationRevisions).filter { ids.contains($0.key) })) }
        catch { throw TranslationServiceConfigurationError.storageUnavailable }
    }
}
