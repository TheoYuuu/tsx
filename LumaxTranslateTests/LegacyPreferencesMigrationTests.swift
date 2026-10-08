import Foundation
import XCTest
@testable import LumaxTranslate

@MainActor
final class LegacyPreferencesMigrationTests: XCTestCase {
    func testImportsPreferencesServiceStateAndUsageWithoutChangingLegacyData() throws {
        try withDomains { defaults, source, destination in
            let preferences = AppPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: source)))
            preferences.setDefaultTarget("ja")
            preferences.interfaceLanguage = .english
            preferences.appearance = .dark
            preferences.material = .glass
            preferences.translationLayout = .stacked
            preferences.rememberWindowSize(CGSize(width: 780, height: 800), for: .main, layout: .stacked)
            let sourceDefaults = try XCTUnwrap(UserDefaults(suiteName: source))
            let services = Data("synthetic-service-state".utf8)
            let usage = Data("synthetic-usage-records".utf8)
            sourceDefaults.set(services, forKey: TranslationServiceStore.StorageKey.services)
            sourceDefaults.set(false, forKey: TranslationServiceStore.StorageKey.appleAutomaticTranslation)
            sourceDefaults.set(usage, forKey: TranslationUsageStore.StorageKey.records)
            sourceDefaults.set(false, forKey: TranslationUsageStore.StorageKey.enabled)
            let before = try XCTUnwrap(defaults.persistentDomain(forName: source))

            LegacyPreferencesMigration.migrateIfNeeded(defaults: defaults, sourceDomain: source, destinationDomain: destination)

            let imported = AppPreferences(defaults: defaults)
            XCTAssertEqual(imported.defaultTarget, "ja")
            XCTAssertEqual(imported.interfaceLanguage, .english)
            XCTAssertEqual(imported.appearance, .dark)
            XCTAssertEqual(imported.material, .glass)
            XCTAssertEqual(imported.translationLayout, .stacked)
            XCTAssertEqual(imported.windowSize(for: .main, layout: .stacked), CGSize(width: 780, height: 800))
            XCTAssertEqual(defaults.data(forKey: TranslationServiceStore.StorageKey.services), services)
            XCTAssertFalse(defaults.bool(forKey: TranslationServiceStore.StorageKey.appleAutomaticTranslation))
            XCTAssertEqual(defaults.data(forKey: TranslationUsageStore.StorageKey.records), usage)
            XCTAssertFalse(defaults.bool(forKey: TranslationUsageStore.StorageKey.enabled))
            XCTAssertTrue(NSDictionary(dictionary: before).isEqual(to: try XCTUnwrap(defaults.persistentDomain(forName: source))))
        }
    }

    func testCopiesAllStoredShortcutAndWindowKeysButNotUnrelatedOrRegisteredDefaults() throws {
        try withDomains { defaults, source, destination in
            var legacy: [String: Any] = [:]
            for key in LegacyPreferencesMigration.preferenceKeys { legacy[key] = Data(key.utf8) }
            legacy["private-test-value"] = "must not migrate"
            legacy["AppleLanguages"] = ["ja"]
            defaults.setPersistentDomain(legacy, forName: source)
            defaults.register(defaults: ["registered-value": "not persisted"])
            defaults.setPersistentDomain(["new-domain-only": "keep"], forName: destination)

            LegacyPreferencesMigration.migrateIfNeeded(defaults: defaults, sourceDomain: source, destinationDomain: destination)

            let imported = try XCTUnwrap(defaults.persistentDomain(forName: destination))
            for key in LegacyPreferencesMigration.preferenceKeys {
                XCTAssertEqual(imported[key] as? Data, Data(key.utf8), key)
            }
            XCTAssertNil(imported["private-test-value"])
            XCTAssertNil(imported["AppleLanguages"])
            XCTAssertNil(imported["registered-value"])
            XCTAssertEqual(imported["new-domain-only"] as? String, "keep")
        }
    }

    func testExistingNewPreferencesPreventMixingInOldServicesAndUsage() throws {
        try withDomains { defaults, source, destination in
            defaults.setPersistentDomain([
                AppPreferences.StorageKey.appearance: "dark",
                TranslationServiceStore.StorageKey.services: Data("old-services".utf8),
                TranslationUsageStore.StorageKey.records: Data("old-usage".utf8)
            ], forName: source)
            defaults.set(AppAppearance.light.rawValue, forKey: AppPreferences.StorageKey.appearance)

            LegacyPreferencesMigration.migrateIfNeeded(defaults: defaults, sourceDomain: source, destinationDomain: destination)

            XCTAssertEqual(defaults.string(forKey: AppPreferences.StorageKey.appearance), "light")
            XCTAssertNil(defaults.object(forKey: TranslationServiceStore.StorageKey.services))
            XCTAssertNil(defaults.object(forKey: TranslationUsageStore.StorageKey.records))
            XCTAssertTrue(defaults.bool(forKey: LegacyPreferencesMigration.completionKey))
        }
    }

    func testRelaunchDoesNotRestoreAnImportedValueTheUserRemoved() throws {
        try withDomains { defaults, source, destination in
            let key = TranslationServiceStore.StorageKey.services
            defaults.setPersistentDomain([key: Data("old-services".utf8)], forName: source)
            LegacyPreferencesMigration.migrateIfNeeded(defaults: defaults, sourceDomain: source, destinationDomain: destination)
            defaults.removeObject(forKey: key)

            LegacyPreferencesMigration.migrateIfNeeded(defaults: defaults, sourceDomain: source, destinationDomain: destination)

            XCTAssertNil(defaults.object(forKey: key))
            XCTAssertNotNil(defaults.persistentDomain(forName: source)?[key])
        }
    }

    func testFreshInstallDoesNotImportSettingsWrittenByAnOldAppLater() throws {
        try withDomains { defaults, source, destination in
            LegacyPreferencesMigration.migrateIfNeeded(defaults: defaults, sourceDomain: source, destinationDomain: destination)
            defaults.setPersistentDomain([AppPreferences.StorageKey.appearance: "dark"], forName: source)

            LegacyPreferencesMigration.migrateIfNeeded(defaults: defaults, sourceDomain: source, destinationDomain: destination)

            XCTAssertNil(defaults.object(forKey: AppPreferences.StorageKey.appearance))
            XCTAssertTrue(defaults.bool(forKey: LegacyPreferencesMigration.completionKey))
        }
    }

    func testSameDomainIsNeverRewritten() throws {
        try withDomains { defaults, source, _ in
            let original = [AppPreferences.StorageKey.appearance: "dark"]
            defaults.setPersistentDomain(original, forName: source)

            LegacyPreferencesMigration.migrateIfNeeded(defaults: defaults, sourceDomain: source, destinationDomain: source)

            XCTAssertEqual(defaults.persistentDomain(forName: source) as? [String: String], original)
        }
    }

    private func withDomains(_ body: (UserDefaults, String, String) throws -> Void) throws {
        let source = "TSX.MigrationTests.\(UUID().uuidString).old"
        let destination = "TSX.MigrationTests.\(UUID().uuidString).new"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: destination))
        defer {
            defaults.removePersistentDomain(forName: source)
            defaults.removePersistentDomain(forName: destination)
        }
        try body(defaults, source, destination)
    }
}
