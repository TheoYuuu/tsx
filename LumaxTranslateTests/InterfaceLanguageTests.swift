import Foundation
import Observation
import Synchronization
import XCTest
@testable import LumaxTranslate

@MainActor
final class InterfaceLanguageTests: XCTestCase {
    func testSystemLanguageUsesTheFirstSupportedPreferenceAndEnglishFallback() async {
        let system = AppInterfaceLanguage.system
        XCTAssertEqual(system.resolvedLanguageIdentifier(preferredLanguages: ["ja-JP", "zh-CN", "en"]), "zh-Hans")
        XCTAssertEqual(system.resolvedLanguageIdentifier(preferredLanguages: ["fr-FR", "en-GB", "zh-Hans"]), "en")
        XCTAssertEqual(system.resolvedLanguageIdentifier(preferredLanguages: ["zh-Hant", "ja-JP"]), "en")
        XCTAssertEqual(system.resolvedLanguageIdentifier(preferredLanguages: ["ja-JP"]), "en")
        XCTAssertEqual(system.resolvedLanguageIdentifier(preferredLanguages: []), "en")
        for identifier in ["zh", "zh-CN", "zh-SG", "zh_Hans", "zh-Hans-TW"] {
            XCTAssertEqual(system.resolvedLanguageIdentifier(preferredLanguages: [identifier]), "zh-Hans", identifier)
        }
        for identifier in ["en", "en-US", "en_GB", "en-AU"] {
            XCTAssertEqual(system.resolvedLanguageIdentifier(preferredLanguages: [identifier]), "en", identifier)
        }
        XCTAssertEqual(AppInterfaceLanguage.english.resolvedLanguageIdentifier(preferredLanguages: ["zh-Hans"]), "en")
        XCTAssertEqual(AppInterfaceLanguage.simplifiedChinese.resolvedLanguageIdentifier(preferredLanguages: ["en"]), "zh-Hans")
    }

    func testInterfacePreferencePersistsWithoutChangingTranslationOrSystemPreferences() async throws {
        let suite = "LumaxTranslateTests.InterfaceLanguage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.interfaceLanguage, .system)
        XCTAssertTrue(defaults.persistentDomain(forName: suite)?.isEmpty ?? true)
        preferences.setDefaultTarget("ja")
        preferences.appearance = .dark
        defaults.set(["fr-FR"], forKey: "AppleLanguages")
        let activeLanguage = L10n.currentLanguageIdentifier

        for language in AppInterfaceLanguage.allCases {
            preferences.interfaceLanguage = language
            let restored = AppPreferences(defaults: defaults)
            XCTAssertEqual(restored.interfaceLanguage, language)
            XCTAssertEqual(restored.defaultTarget, "ja")
            XCTAssertEqual(restored.appearance, .dark)
            XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["fr-FR"])
            XCTAssertEqual(L10n.currentLanguageIdentifier, activeLanguage,
                           "Creating preferences must not reconfigure the shared UI localization")
        }
        for invalid in ["fr", "future-language", ""] {
            defaults.set(invalid, forKey: AppPreferences.StorageKey.interfaceLanguage)
            XCTAssertEqual(AppPreferences(defaults: defaults).interfaceLanguage, .system)
        }
        defaults.set(12, forKey: AppPreferences.StorageKey.interfaceLanguage)
        XCTAssertEqual(AppPreferences(defaults: defaults).interfaceLanguage, .system)
    }

    func testLocalizationsSwitchImmediatelyAndDynamicStringReadsAreObservable() async {
        let original = AppInterfaceLanguage(rawValue: L10n.currentLanguageIdentifier)!
        defer { L10n.apply(original) }
        L10n.apply(.english)
        XCTAssertEqual(L10n.string("Settings"), "Settings")
        let changes = Mutex(0)
        withObservationTracking {
            _ = L10n.string("Settings")
            _ = L10n.currentLocale
        } onChange: {
            changes.withLock { $0 += 1 }
        }

        XCTAssertTrue(L10n.apply(.simplifiedChinese))
        XCTAssertEqual(changes.withLock { $0 }, 1)
        XCTAssertEqual(L10n.currentLocale.identifier, "zh-Hans")
        XCTAssertEqual(L10n.string("Settings"), "设置")
        XCTAssertEqual(L10n.string("Detect language"), "自动识别")
        XCTAssertFalse(L10n.apply(.simplifiedChinese))
        XCTAssertEqual(L10n.string("a.missing.localization.key"), "a.missing.localization.key")
        L10n.apply(.system, preferredLanguages: ["de-DE"])
        XCTAssertEqual(L10n.string("Settings"), "Settings")
    }

    func testBackgroundErrorDescriptionsUseSafeLanguageSnapshotsDuringSwitching() async {
        let original = AppInterfaceLanguage(rawValue: L10n.currentLanguageIdentifier)!
        defer { L10n.apply(original) }
        L10n.apply(.english)
        await withTaskGroup(of: String.self) { group in
            for _ in 0..<64 {
                group.addTask { L10n.string("Settings") }
            }
            for _ in 0..<8 {
                L10n.apply(.simplifiedChinese)
                L10n.apply(.english)
            }
            for await label in group {
                XCTAssertTrue(["Settings", "设置"].contains(label))
            }
        }
    }

    func testLanguageChoicesRelocalizeWithoutChangingIdentifiersOrSavedService() async {
        let original = AppInterfaceLanguage(rawValue: L10n.currentLanguageIdentifier)!
        defer { L10n.apply(original) }
        let catalog = LanguageCatalog()
        let service = TranslationServiceConfiguration(kind: .openAI)
        L10n.apply(.english)
        let english = catalog.languages(for: service)
        L10n.apply(.simplifiedChinese)
        let chinese = catalog.languages(for: service)
        XCTAssertEqual(Set(english.map(\.id)), Set(chinese.map(\.id)))
        XCTAssertEqual(english.first { $0.id == "en" }?.name, "English")
        XCTAssertEqual(chinese.first { $0.id == "en" }?.name, "英语")
        XCTAssertNotEqual(english.first { $0.id == "zh-Hant" }?.name, chinese.first { $0.id == "zh-Hant" }?.name)
        XCTAssertTrue(catalog.languages.isEmpty, "Relabeling must not load Apple capabilities or request a translation")
        XCTAssertEqual(service.name, "OpenAI")
        XCTAssertEqual(service.model, TranslationServiceKind.openAI.defaultModel)
    }
}
