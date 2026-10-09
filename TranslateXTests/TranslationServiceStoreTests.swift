import Foundation
import Observation
import os
import XCTest
@testable import TranslateX

@MainActor
final class TranslationServiceStoreTests: XCTestCase {
    func testSampleHistoryIsObservablePersistsAndDoesNotReadKeysOrChangeRouting() throws {
        try withStore { store, defaults, credentials, _ in
            let configuration = TranslationServiceConfiguration(kind: .deepSeek)
            try store.save(configuration, apiKey: "fixture-key")
            let data = defaults.data(forKey: TranslationServiceStore.StorageKey.services)
            let revision = store.revision
            let reads = credentials.readIDs
            let changed = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking {
                _ = store.sampleTestOutcome(for: configuration)
            } onChange: {
                changed.withLock { $0 = true }
            }
            store.recordSampleTest(.succeeded, for: configuration, revision: store.configurationRevision(for: configuration.id))
            XCTAssertTrue(changed.withLock { $0 })
            XCTAssertEqual(store.sampleTestOutcome(for: configuration), .succeeded)
            XCTAssertEqual(store.revision, revision)
            XCTAssertNotEqual(defaults.data(forKey: TranslationServiceStore.StorageKey.services), data)
            XCTAssertEqual(credentials.readIDs, reads)
            let reloaded = TranslationServiceStore(defaults: defaults, credentials: credentials)
            XCTAssertEqual(reloaded.sampleTestOutcome(for: configuration), .succeeded)
            XCTAssertEqual(reloaded.sampleTestRecord(for: configuration.id), store.sampleTestRecord(for: configuration.id))
            try store.remove(configuration.id)
            XCTAssertNil(store.sampleTestOutcome(for: configuration))
        }
    }

    func testStaleRecordKeepsActualCompletionTimeAcrossRelaunchAndCannotBeRevived() throws {
        try withStore { store, defaults, credentials, _ in
            var configuration = TranslationServiceConfiguration(kind: .deepSeek)
            try store.save(configuration, apiKey: "fixture-key")
            let revision = store.configurationRevision(for: configuration.id)
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            store.recordSampleTest(.succeeded, for: configuration, revision: revision, completedAt: date)
            let old = configuration
            configuration.model = "changed-fixture-model"
            try store.save(configuration, apiKey: nil)
            XCTAssertNil(store.sampleTestOutcome(for: configuration))
            XCTAssertEqual(store.sampleTestRecord(for: configuration.id)?.completedAt, date)
            store.recordSampleTest(.failed, for: old, revision: revision)
            let reloaded = TranslationServiceStore(defaults: defaults, credentials: credentials)
            XCTAssertNil(reloaded.sampleTestOutcome(for: configuration))
            XCTAssertEqual(reloaded.sampleTestRecord(for: configuration.id)?.outcome, .succeeded)
            XCTAssertEqual(reloaded.sampleTestRecord(for: configuration.id)?.completedAt, date)
            try reloaded.remove(configuration.id)
            XCTAssertNil(TranslationServiceStore(defaults: defaults, credentials: credentials).sampleTestRecord(for: configuration.id))
        }
    }

    func testRenameAndSchedulingPreferencesPreserveTestWhileKeyReplacementRequiresRetest() throws {
        try withStore { store, defaults, credentials, _ in
            var configuration = TranslationServiceConfiguration(kind: .deepSeek)
            try store.save(configuration, apiKey: "fixture-key")
            let revision = store.configurationRevision(for: configuration.id)
            store.recordSampleTest(.failed, for: configuration, revision: revision)
            let record = store.sampleTestRecord(for: configuration.id)
            configuration.name = "Renamed service"
            configuration.automaticallyTranslates.toggle()
            try store.save(configuration, apiKey: nil)
            XCTAssertEqual(store.sampleTestOutcome(for: configuration), .failed)
            XCTAssertEqual(store.configurationRevision(for: configuration.id), revision)
            XCTAssertEqual(store.sampleTestRecord(for: configuration.id), record)
            try store.save(configuration, apiKey: "fixture-replacement")
            let reloaded = TranslationServiceStore(defaults: defaults, credentials: credentials)
            XCTAssertNil(reloaded.sampleTestOutcome(for: configuration))
            XCTAssertEqual(reloaded.sampleTestRecord(for: configuration.id), record)
            let bytes = try XCTUnwrap(defaults.data(forKey: TranslationServiceStore.StorageKey.services))
            let json = String(decoding: bytes, as: UTF8.self)
            XCTAssertFalse(json.contains("fixture-key")); XCTAssertFalse(json.contains("fixture-replacement"))
            XCTAssertFalse(json.contains(TranslationServiceEditor.testSample))
        }
    }

    func testOldPreferencePayloadLoadsWithoutInventingTestDate() throws {
        try withStore { store, defaults, credentials, _ in
            let configuration = TranslationServiceConfiguration(kind: .deepSeek)
            try store.save(configuration, apiKey: "fixture-key")
            var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: TranslationServiceStore.StorageKey.services))) as? [String: Any])
            payload["sampleTests"] = nil; payload["configurationRevisions"] = nil
            defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: TranslationServiceStore.StorageKey.services)
            let reloaded = TranslationServiceStore(defaults: defaults, credentials: credentials)
            XCTAssertEqual(reloaded.configurations, [configuration])
            XCTAssertNil(reloaded.sampleTestRecord(for: configuration.id))
            XCTAssertNil(reloaded.sampleTestOutcome(for: configuration))
        }
    }

    func testCorruptOptionalHistoryDoesNotDiscardValidServiceConfiguration() throws {
        try withStore { store, defaults, credentials, _ in
            let configuration = TranslationServiceConfiguration(kind: .deepSeek)
            try store.save(configuration, apiKey: "fixture-key")
            var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: TranslationServiceStore.StorageKey.services))) as? [String: Any])
            payload["sampleTests"] = "malformed"
            defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: TranslationServiceStore.StorageKey.services)
            let reloaded = TranslationServiceStore(defaults: defaults, credentials: credentials)
            XCTAssertEqual(reloaded.configurations, [configuration])
            XCTAssertNil(reloaded.sampleTestRecord(for: configuration.id))
        }
    }

    func testCredentialAndAccountChangesInvalidateOnlyTheirOwnSampleEvidence() throws {
        try withStore { store, _, _, _ in
            let api = TranslationServiceConfiguration(kind: .deepSeek)
            var account = TranslationServiceConfiguration(kind: .codex)
            account.model = "fixture-model"
            account.codexAccountGeneration = UUID().uuidString.lowercased()
            try store.save(api, apiKey: "fixture-key")
            try store.save(account, apiKey: nil)
            let accountRevision = store.configurationRevision(for: account.id)
            store.recordSampleTest(.succeeded, for: api, revision: store.configurationRevision(for: api.id))
            store.recordSampleTest(.succeeded, for: account, revision: accountRevision)
            let changed = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking {
                _ = store.sampleTestOutcome(for: account)
            } onChange: { changed.withLock { $0 = true } }
            store.codex.onIdentityChange?()
            XCTAssertTrue(changed.withLock { $0 }, "Account changes must refresh historical status even when that service is not selected")
            XCTAssertNil(store.sampleTestOutcome(for: account))
            XCTAssertEqual(store.sampleTestOutcome(for: api), .succeeded)
            store.recordSampleTest(.succeeded, for: account, revision: accountRevision)
            XCTAssertNil(store.sampleTestOutcome(for: account), "Old account response cannot certify the replacement account")
            let oldRevision = store.configurationRevision(for: api.id)
            try store.save(api, apiKey: "fixture-new-key")
            XCTAssertNil(store.sampleTestOutcome(for: api))
            store.recordSampleTest(.succeeded, for: api, revision: oldRevision)
            XCTAssertNil(store.sampleTestOutcome(for: api))
        }
    }

    func testCodexPersistenceSelectionAndDeletionNeverAccessAPIKeyStore() async throws {
        try withStore { store, defaults, credentials, _ in
            var config = TranslationServiceConfiguration(kind: .codex)
            config.model = "fixture-model"
            config.codexAccountGeneration = UUID().uuidString.lowercased()
            credentials.failWrites = true
            try store.save(config, apiKey: nil)
            try store.save(config, apiKey: "")
            XCTAssertThrowsError(try store.save(config, apiKey: "fixture-key"))
            XCTAssertNil(store.selectedID)
            try store.select(config.id)
            XCTAssertNil(try store.apiKey(for: config.id))
            let reloaded = TranslationServiceStore(defaults: defaults, credentials: credentials)
            XCTAssertEqual(reloaded.selectedConfiguration, config)
            XCTAssertEqual(reloaded.codex.status, .unknown)
            XCTAssertFalse(reloaded.codex.hasActiveOperation)
            try reloaded.remove(config.id)
            XCTAssertNil(reloaded.selectedID)
            XCTAssertEqual(reloaded.codex.status, .unknown)
            XCTAssertTrue(credentials.readIDs.isEmpty)
            XCTAssertTrue(credentials.values.isEmpty)
        }
    }

    func testAccountIdentityChangesSynchronouslyInvalidateOnlySelectedCodexService() async throws {
        try withStore { store, _, _, _ in
            var config = TranslationServiceConfiguration(kind: .codex)
            config.model = "fixture-model"
            config.codexAccountGeneration = UUID().uuidString.lowercased()
            try store.save(config, apiKey: nil)
            let appleRevision = store.revision
            store.codex.onIdentityChange?()
            XCTAssertEqual(store.revision, appleRevision)
            try store.select(config.id)
            let revision = store.revision
            let model = TranslationModel(services: store)
            let captureIntent = model.captureServiceIntent()
            store.codex.onIdentityChange?()
            XCTAssertEqual(store.revision, revision + 1)
            model.submitCapturedText("fixture captured text", serviceRevision: captureIntent)
            XCTAssertNil(model.request, "Captured text from an earlier account must require a new user action.")
            try store.select(nil)
            let localRevision = store.revision
            store.codex.onIdentityChange?()
            XCTAssertEqual(store.revision, localRevision)
        }
    }

    func testS1PersistedServicesWithoutRegionKeepSelectionAndExistingCredentials() async throws {
        try withStore { store, defaults, credentials, _ in
            let selected = TranslationServiceConfiguration(kind: .deepSeek)
            let other = validCustom()
            try store.save(selected, apiKey: "fixture-preserved-key")
            try store.save(other, apiKey: nil)
            try store.select(selected.id)
            let key = TranslationServiceStore.StorageKey.services
            let data = try XCTUnwrap(defaults.data(forKey: key))
            var state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let configs = try XCTUnwrap(state["configurations"] as? [[String: Any]])
            state["configurations"] = configs.map { original in
                var legacy = original
                legacy.removeValue(forKey: "region")
                return legacy
            }
            let legacyData = try JSONSerialization.data(withJSONObject: state)
            defaults.set(legacyData, forKey: key)
            let reads = credentials.readIDs.count
            let reloaded = TranslationServiceStore(defaults: defaults, credentials: credentials)
            XCTAssertEqual(reloaded.configurations, [selected, other])
            XCTAssertEqual(reloaded.selectedID, selected.id)
            XCTAssertEqual(credentials.readIDs.count, reads)
            XCTAssertEqual(defaults.data(forKey: key), legacyData, "Migration reads must not rewrite existing preferences.")
            XCTAssertEqual(try reloaded.apiKey(for: selected.id), "fixture-preserved-key")
            var azure = TranslationServiceConfiguration(kind: .azureTranslator)
            azure.region = "eastus"
            try reloaded.save(azure, apiKey: "fixture-azure-key")
            let afterSave = TranslationServiceStore(defaults: defaults, credentials: credentials)
            XCTAssertEqual(afterSave.configurations, [selected, other, azure])
            XCTAssertEqual(afterSave.selectedID, selected.id)
        }
    }

    func testAzureRegionAndDeepLPlanPersistWithoutModelOrInstructionResidue() async throws {
        try withStore { store, defaults, credentials, _ in
            var azure = TranslationServiceConfiguration(kind: .azureTranslator)
            azure.region = " EASTUS "
            azure.model = "stale-model"
            azure.additionalInstructions = "stale-instructions"
            try store.save(azure, apiKey: "fixture-azure-key")
            var deepL = TranslationServiceConfiguration(kind: .deepL)
            deepL.endpoint = DeepLAPIEndpoint.pro.rawValue
            try store.save(deepL, apiKey: "fixture-deepl-key")
            let reloaded = TranslationServiceStore(defaults: defaults, credentials: credentials)
            XCTAssertEqual(reloaded.configurations[0].region, "eastus")
            XCTAssertEqual(reloaded.configurations[0].model, "")
            XCTAssertEqual(reloaded.configurations[0].additionalInstructions, "")
            XCTAssertEqual(reloaded.configurations[1], deepL)
            XCTAssertEqual(try reloaded.apiKey(for: azure.id), "fixture-azure-key")
            XCTAssertEqual(try reloaded.apiKey(for: deepL.id), "fixture-deepl-key")
        }
    }

    func testFreshStoreUsesAppleWithoutWritingOrReadingCredentials() async throws {
        try withStore { store, defaults, credentials, suite in
            XCTAssertTrue(store.configurations.isEmpty)
            XCTAssertNil(store.selectedID)
            XCTAssertNil(store.selectedConfiguration)
            XCTAssertEqual(store.revision, 0)
            XCTAssertTrue(credentials.readIDs.isEmpty)
            XCTAssertTrue(defaults.persistentDomain(forName: suite)?.isEmpty ?? true)
        }
    }

    func testSaveDoesNotSelectAndSelectionSurvivesReload() async throws {
        try withStore { store, defaults, credentials, _ in
            let config = TranslationServiceConfiguration(kind: .deepSeek)
            try store.save(config, apiKey: "test-key-only")
            XCTAssertNil(store.selectedID)
            try store.select(config.id)
            let readCount = credentials.readIDs.count
            let revision = store.revision
            try store.select(config.id)
            XCTAssertEqual(credentials.readIDs.count, readCount, "Selecting the current service must not re-read its key.")
            XCTAssertEqual(store.revision, revision)
            let reloaded = TranslationServiceStore(defaults: defaults, credentials: credentials)
            XCTAssertEqual(reloaded.selectedConfiguration, config)
            XCTAssertEqual(credentials.readIDs.count, readCount, "Loading preferences must not prompt for Keychain.")
            XCTAssertEqual(try reloaded.apiKey(for: config.id), "test-key-only")
            try reloaded.select(nil)
            XCTAssertNil(TranslationServiceStore(defaults: defaults, credentials: credentials).selectedID)
        }
    }

    func testSecretsNeverEnterPreferencesAndOtherPreferencesSurvive() async throws {
        try withStore { store, defaults, _, suite in
            defaults.set("untouched", forKey: "unrelated")
            let config = TranslationServiceConfiguration(kind: .openAI)
            try store.save(config, apiKey: "fixture-secret-that-must-not-be-persisted")
            let data = try XCTUnwrap(defaults.data(forKey: TranslationServiceStore.StorageKey.services))
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("fixture-secret"))
            XCTAssertFalse(text.contains("apiKey"))
            let stored = try XCTUnwrap(defaults.persistentDomain(forName: suite))
            XCTAssertEqual(Set(stored.keys), ["unrelated", TranslationServiceStore.StorageKey.services])
            XCTAssertEqual(stored["unrelated"] as? String, "untouched")
        }
    }

    func testSameProviderConfigurationsHaveIndependentCredentials() async throws {
        try withStore { store, _, credentials, _ in
            let first = TranslationServiceConfiguration(kind: .deepSeek)
            let second = TranslationServiceConfiguration(kind: .deepSeek)
            try store.save(first, apiKey: "fixture-first")
            try store.save(second, apiKey: "fixture-second")
            XCTAssertEqual(try store.apiKey(for: first.id), "fixture-first")
            XCTAssertEqual(try store.apiKey(for: second.id), "fixture-second")
            try store.remove(first.id)
            XCTAssertNil(credentials.values[first.id])
            XCTAssertEqual(try store.apiKey(for: second.id), "fixture-second")
            XCTAssertEqual(store.configurations.map(\.id), [second.id])
        }
    }

    func testNilKeyPreservesAndExplicitEmptyRemovesOptionalCredential() async throws {
        try withStore { store, _, credentials, _ in
            var config = validCustom()
            try store.save(config, apiKey: "fixture-original")
            config.name = "Renamed service"
            try store.save(config, apiKey: nil)
            XCTAssertEqual(try store.apiKey(for: config.id), "fixture-original")
            try store.save(config, apiKey: "")
            XCTAssertNil(try store.apiKey(for: config.id))
            XCTAssertNil(credentials.values[config.id])
        }
    }

    func testInvalidConfigurationDoesNotReplaceConfigurationOrCredential() async throws {
        try withStore { store, defaults, credentials, _ in
            var config = TranslationServiceConfiguration(kind: .openAI)
            try store.save(config, apiKey: "fixture-original")
            try store.select(config.id)
            let before = try XCTUnwrap(defaults.data(forKey: TranslationServiceStore.StorageKey.services))
            let revision = store.revision
            config.endpoint = "http://external.example/v1"
            XCTAssertThrowsError(try store.save(config, apiKey: "fixture-replacement"))
            XCTAssertEqual(defaults.data(forKey: TranslationServiceStore.StorageKey.services), before)
            XCTAssertEqual(credentials.values[config.id]?.apiKey, "fixture-original")
            XCTAssertEqual(store.selectedConfiguration?.endpoint, TranslationServiceKind.openAI.defaultEndpoint)
            XCTAssertEqual(store.revision, revision)
        }
    }

    func testCredentialWriteFailureKeepsPreviousConfigurationAndSelection() async throws {
        try withStore { store, defaults, credentials, _ in
            var config = TranslationServiceConfiguration(kind: .deepSeek)
            try store.save(config, apiKey: "fixture-original")
            try store.select(config.id)
            let before = defaults.data(forKey: TranslationServiceStore.StorageKey.services)
            let revision = store.revision
            credentials.failWrites = true
            config.model = "a-different-model"
            XCTAssertThrowsError(try store.save(config, apiKey: "fixture-replacement"))
            XCTAssertEqual(store.selectedConfiguration?.model, TranslationServiceKind.deepSeek.defaultModel)
            XCTAssertEqual(store.revision, revision)
            XCTAssertEqual(defaults.data(forKey: TranslationServiceStore.StorageKey.services), before)
            XCTAssertEqual(credentials.values[config.id]?.apiKey, "fixture-original")
        }
    }

    func testCredentialDeleteFailureKeepsConfigurationAndSelection() async throws {
        try withStore { store, defaults, credentials, _ in
            let config = TranslationServiceConfiguration(kind: .deepSeek)
            try store.save(config, apiKey: "fixture-original")
            try store.select(config.id)
            let before = defaults.data(forKey: TranslationServiceStore.StorageKey.services)
            let revision = store.revision
            credentials.failWrites = true
            XCTAssertThrowsError(try store.remove(config.id))
            XCTAssertEqual(store.selectedConfiguration, config)
            XCTAssertEqual(store.revision, revision)
            XCTAssertEqual(defaults.data(forKey: TranslationServiceStore.StorageKey.services), before)
            XCTAssertEqual(credentials.values[config.id]?.apiKey, "fixture-original")
        }
    }

    func testDeletingSelectedServiceReturnsToAppleAndOtherServiceRemains() async throws {
        try withStore { store, defaults, credentials, _ in
            let first = TranslationServiceConfiguration(kind: .deepSeek)
            let second = validCustom()
            try store.save(first, apiKey: "fixture-original")
            try store.save(second, apiKey: nil)
            try store.select(first.id)
            try store.remove(first.id)
            XCTAssertNil(store.selectedID)
            XCTAssertEqual(store.configurations, [second])
            XCTAssertNil(TranslationServiceStore(defaults: defaults, credentials: credentials).selectedID)
        }
    }

    func testUnknownSelectionAndDeletionLeaveStateUntouched() async throws {
        try withStore { store, defaults, _, _ in
            let config = validCustom()
            try store.save(config, apiKey: nil)
            try store.select(config.id)
            let before = defaults.data(forKey: TranslationServiceStore.StorageKey.services)
            let revision = store.revision
            XCTAssertThrowsError(try store.select(UUID()))
            XCTAssertThrowsError(try store.remove(UUID()))
            XCTAssertThrowsError(try store.apiKey(for: UUID()))
            XCTAssertEqual(store.selectedID, config.id)
            XCTAssertEqual(store.revision, revision)
            XCTAssertEqual(defaults.data(forKey: TranslationServiceStore.StorageKey.services), before)
        }
    }

    func testCorruptOrUnsupportedSavedDataFailsClosedWithoutOverwritingIt() async throws {
        try withStore { _, defaults, credentials, _ in
            let key = TranslationServiceStore.StorageKey.services
            for value in [Data("broken".utf8), Data(#"{"version":2,"configurations":[]}"#.utf8), Data(#"{}"#.utf8)] {
                defaults.set(value, forKey: key)
                let reloaded = TranslationServiceStore(defaults: defaults, credentials: credentials)
                XCTAssertTrue(reloaded.configurations.isEmpty)
                XCTAssertNil(reloaded.selectedID)
                XCTAssertEqual(defaults.data(forKey: key), value)
            }
            defaults.set("wrong type", forKey: key)
            XCTAssertNil(TranslationServiceStore(defaults: defaults, credentials: credentials).selectedID)
            XCTAssertEqual(defaults.string(forKey: key), "wrong type")
            XCTAssertTrue(credentials.readIDs.isEmpty)
        }
    }

    func testDuplicateIDsAndInvalidConfigurationFailClosed() async throws {
        try withStore { _, defaults, credentials, _ in
            let config = validCustom()
            var invalid = config
            invalid.endpoint = "http://not-local.example/v1"
            for configs in [[config, config], [invalid]] {
                let data = try JSONEncoder().encode(SavedState(configurations: configs, selectedID: config.id))
                defaults.set(data, forKey: TranslationServiceStore.StorageKey.services)
                let reloaded = TranslationServiceStore(defaults: defaults, credentials: credentials)
                XCTAssertTrue(reloaded.configurations.isEmpty)
                XCTAssertNil(reloaded.selectedID)
            }
        }
    }

    func testUnknownPersistedSelectionDoesNotSelectFirstCloudService() async throws {
        try withStore { _, defaults, credentials, _ in
            let config = validCustom()
            let data = try JSONEncoder().encode(SavedState(configurations: [config], selectedID: UUID()))
            defaults.set(data, forKey: TranslationServiceStore.StorageKey.services)
            let reloaded = TranslationServiceStore(defaults: defaults, credentials: credentials)
            XCTAssertEqual(reloaded.configurations, [config])
            XCTAssertNil(reloaded.selectedID)
        }
    }

    func testAddressChangeCannotReuseStoredKeyForSaveOrUnsavedTest() async throws {
        try withStore { store, _, credentials, _ in
            var config = validCustom()
            try store.save(config, apiKey: "fixture-original")
            for endpoint in ["https://another.example/v1", "https://api.example/other", "https://api.example:9443/v1"] {
                config.endpoint = endpoint
                XCTAssertThrowsError(try store.apiKey(for: config, replacement: nil)) { error in
                    XCTAssertEqual(error as? TranslationServiceConfigurationError, .endpointChanged)
                }
                XCTAssertThrowsError(try store.save(config, apiKey: nil))
                XCTAssertEqual(credentials.values[config.id]?.endpoint, "https://api.example/v1")
            }
            XCTAssertEqual(try store.apiKey(for: config, replacement: "fixture-new-receiver"), "fixture-new-receiver")
            XCTAssertEqual(credentials.values[config.id]?.apiKey, "fixture-original", "Testing a draft cannot mutate credentials.")
            try store.save(config, apiKey: "fixture-new-receiver")
            XCTAssertEqual(try store.apiKey(for: config.id), "fixture-new-receiver")
        }
    }

    func testInterruptedOrTamperedConfigurationCannotUseKeyForAnotherEndpoint() async throws {
        try withStore { store, defaults, credentials, _ in
            var config = validCustom()
            try store.save(config, apiKey: "fixture-secret")
            config.endpoint = "https://different.example/v1"
            let data = try JSONEncoder().encode(SavedState(configurations: [config], selectedID: config.id))
            defaults.set(data, forKey: TranslationServiceStore.StorageKey.services)
            let reloaded = TranslationServiceStore(defaults: defaults, credentials: credentials)
            XCTAssertThrowsError(try reloaded.apiKey(for: config.id)) { error in
                XCTAssertEqual(error as? TranslationServiceConfigurationError, .endpointChanged)
            }
        }
    }

    func testMissingOrInvalidKeysCannotSelectOrReplaceRequiredService() async throws {
        try withStore { store, _, credentials, _ in
            let config = TranslationServiceConfiguration(kind: .deepSeek)
            XCTAssertThrowsError(try store.save(config, apiKey: nil))
            XCTAssertThrowsError(try store.save(config, apiKey: ""))
            for key in ["fixture key", "fixture\r\nInjected-header", "fixture\u{0}key"] {
                XCTAssertThrowsError(try store.save(config, apiKey: key))
            }
            XCTAssertTrue(store.configurations.isEmpty)
            try store.save(config, apiKey: "fixture-original")
            XCTAssertThrowsError(try store.save(config, apiKey: ""))
            XCTAssertEqual(credentials.values[config.id]?.apiKey, "fixture-original")
            credentials.values.removeValue(forKey: config.id)
            XCTAssertThrowsError(try store.select(config.id))
            XCTAssertNil(store.selectedID)
        }
    }

    func testAllMutationsAdvanceObservedRevisionIncludingKeyOnlyEdits() async throws {
        try withStore { store, _, _, _ in
            let config = validCustom()
            let changes = OSAllocatedUnfairLock(initialState: 0)
            withObservationTracking {
                _ = store.revision
            } onChange: {
                changes.withLock { $0 += 1 }
            }
            try store.save(config, apiKey: "fixture-first")
            XCTAssertEqual(changes.withLock { $0 }, 1)
            XCTAssertEqual(store.revision, 1)
            try store.select(config.id)
            XCTAssertEqual(store.revision, 2)
            try store.select(config.id)
            XCTAssertEqual(store.revision, 2)
            try store.save(config, apiKey: "fixture-second")
            XCTAssertEqual(store.revision, 3)
            try store.remove(config.id)
            XCTAssertEqual(store.revision, 4)
        }
    }

    private struct SavedState: Codable {
        var version = 1
        let configurations: [TranslationServiceConfiguration]
        let selectedID: UUID?
    }

    func testMetadataAndRevealAreExactAndIndependentOfUnfinishedModel() throws {
        try withStore { store, _, credentials, _ in
            let config = validCustom()
            try store.save(config, apiKey: "fixture-first-key")
            var other = validCustom()
            other.id = UUID()
            try store.save(other, apiKey: "fixture-second-key")
            let before = credentials.readIDs
            XCTAssertEqual(try store.storedKeyPresence(for: config), true)
            XCTAssertEqual(credentials.readIDs, before)
            var draft = config
            draft.name = ""
            draft.model = ""
            XCTAssertEqual(try store.savedKeyForReveal(for: draft), "fixture-first-key")
            XCTAssertEqual(try store.apiKeyForModelCatalog(for: draft, replacement: nil), "fixture-first-key")
            XCTAssertEqual(credentials.readIDs.suffix(2), [config.id, config.id])
            draft.endpoint = "https://other.example/v1"
            let count = credentials.readIDs.count
            XCTAssertThrowsError(try store.savedKeyForReveal(for: draft)) {
                XCTAssertEqual($0 as? TranslationServiceConfigurationError, .endpointChanged)
            }
            XCTAssertThrowsError(try store.storedKeyPresence(for: draft))
            XCTAssertEqual(credentials.readIDs.count, count)
            draft.endpoint = config.endpoint
            draft.kind = .openAI
            XCTAssertThrowsError(try store.savedKeyForReveal(for: draft))
            XCTAssertThrowsError(try store.apiKeyForModelCatalog(for: draft, replacement: nil))
            XCTAssertEqual(credentials.readIDs.count, count)
        }
    }

    func testModelCatalogCredentialResolutionStillRejectsUnsafeEndpointAndInvalidKey() throws {
        try withStore { store, _, credentials, _ in
            var config = validCustom()
            config.name = ""
            config.model = ""
            config.endpoint = "http://untrusted.example/v1"
            XCTAssertThrowsError(try store.apiKeyForModelCatalog(for: config, replacement: "fixture-key")) {
                XCTAssertEqual($0 as? TranslationServiceConfigurationError, .insecureEndpoint)
            }
            config.endpoint = "https://trusted.example/v1"
            XCTAssertThrowsError(try store.apiKeyForModelCatalog(for: config, replacement: "key\nheader")) {
                XCTAssertEqual($0 as? TranslationServiceConfigurationError, .invalidAPIKey)
            }
            XCTAssertTrue(credentials.readIDs.isEmpty)
            XCTAssertTrue(store.configurations.isEmpty)
        }
    }

    private func validCustom() -> TranslationServiceConfiguration {
        .init(name: "Custom", kind: .openAICompatible, endpoint: "https://api.example/v1", model: "fixture-model")
    }

    private func withStore(_ body: (TranslationServiceStore, UserDefaults, MemoryTranslationCredentialStore, String) throws -> Void) throws {
        let suite = "TranslateXTests.TranslationServices.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryTranslationCredentialStore()
        let store = TranslationServiceStore(defaults: defaults, credentials: credentials)
        try body(store, defaults, credentials, suite)
    }
}

@MainActor
private final class MemoryTranslationCredentialStore: TranslationCredentialStore {
    var values: [UUID: TranslationServiceCredential] = [:]
    var readIDs: [UUID] = []
    var failWrites = false

    func containsCredential(for id: UUID) throws -> Bool? { values[id] != nil }

    func credential(for id: UUID) throws -> TranslationServiceCredential? {
        readIDs.append(id)
        return values[id]
    }

    func setCredential(_ credential: TranslationServiceCredential, for id: UUID) throws {
        if failWrites { throw TranslationServiceConfigurationError.credentialUnavailable }
        values[id] = credential
    }

    func removeCredential(for id: UUID) throws {
        if failWrites { throw TranslationServiceConfigurationError.credentialUnavailable }
        values.removeValue(forKey: id)
    }
}
