import Carbon
import Foundation
import Observation
import os
import XCTest
@testable import TranslateX

@MainActor
final class AppPreferencesTests: XCTestCase {
    func testFreshPreferencesUseDefaultsWithoutWritingData() async throws {
        try withDefaults { defaults, suite in
            let preferences = AppPreferences(defaults: defaults)
            XCTAssertEqual(preferences.defaultTarget, "zh-Hans")
            XCTAssertEqual(preferences.appearance, .system)
            for action in ShortcutAction.allCases {
                XCTAssertEqual(preferences.shortcut(for: action), action.defaultShortcut)
            }
            XCTAssertEqual(preferences.shortcutRevision, 0)
            XCTAssertTrue(defaults.persistentDomain(forName: suite)?.isEmpty ?? true)
        }
    }

    func testHoverCursorPersistsAndUnknownValuesFallBackWithoutChangingAppearance() async throws {
        try withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            XCTAssertEqual(preferences.hoverCursor, .pointingHand)
            preferences.appearance = .dark
            preferences.hoverCursor = .arrow
            XCTAssertEqual(AppPreferences(defaults: defaults).hoverCursor, .arrow)
            preferences.hoverCursor = .pointingHand
            XCTAssertEqual(AppPreferences(defaults: defaults).hoverCursor, .pointingHand)
            defaults.set("unknown", forKey: AppPreferences.StorageKey.hoverCursor)
            let restored = AppPreferences(defaults: defaults)
            XCTAssertEqual(restored.hoverCursor, .pointingHand)
            XCTAssertEqual(restored.appearance, .dark)
        }
    }

    func testTargetCanonicalizationAndPersistence() async throws {
        try withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            preferences.setDefaultTarget(" zh_TW \n")
            XCTAssertEqual(preferences.defaultTarget, "zh-Hant")
            XCTAssertEqual(AppPreferences(defaults: defaults).defaultTarget, "zh-Hant")
            preferences.setDefaultTarget("en-GB")
            XCTAssertEqual(AppPreferences(defaults: defaults).defaultTarget, "en-GB")
            preferences.setDefaultTarget("zh-CN")
            XCTAssertEqual(AppPreferences(defaults: defaults).defaultTarget, "zh-Hans")
        }
    }

    func testLayoutAndPointingSwitchRoundTripWithoutOverwritingExistingChoices() async throws {
        try withDefaults { defaults, _ in
            defaults.set(HoverCursor.arrow.rawValue, forKey: AppPreferences.StorageKey.hoverCursor)
            let preferences = AppPreferences(defaults: defaults)
            XCTAssertFalse(preferences.usesPointingCursor)
            XCTAssertEqual(preferences.translationLayout, .sideBySide)
            preferences.usesPointingCursor = true
            preferences.translationLayout = .stacked
            let restored = AppPreferences(defaults: defaults)
            XCTAssertTrue(restored.usesPointingCursor)
            XCTAssertEqual(restored.translationLayout, .stacked)
            restored.usesPointingCursor = false
            XCTAssertEqual(AppPreferences(defaults: defaults).hoverCursor, .arrow)
            defaults.set("future-layout", forKey: AppPreferences.StorageKey.translationLayout)
            XCTAssertEqual(AppPreferences(defaults: defaults).translationLayout, .sideBySide)
        }
    }

    func testWindowSizesPersistIndependentlyForEachWindowAndLayout() async throws {
        try withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            var expected: [String: CGSize] = [:]
            for kind in TranslationWindowKind.allCases {
                for layout in TranslationLayout.allCases {
                    let size = CGSize(width: 800 + expected.count * 20, height: 600 + expected.count * 20)
                    preferences.rememberWindowSize(size, for: kind, layout: layout)
                    expected[AppPreferences.StorageKey.windowSize(kind, layout)] = size
                }
            }
            let restored = AppPreferences(defaults: defaults)
            for kind in TranslationWindowKind.allCases {
                for layout in TranslationLayout.allCases {
                    XCTAssertEqual(restored.windowSize(for: kind, layout: layout), expected[AppPreferences.StorageKey.windowSize(kind, layout)])
                }
            }
        }
    }

    func testCorruptAndNonFiniteWindowSizesCannotReplaceAUsablePreference() async throws {
        try withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            let size = CGSize(width: 820, height: 550)
            preferences.rememberWindowSize(size, for: .quick, layout: .sideBySide)
            for invalid in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 550), CGSize(width: 820, height: CGFloat.nan)] {
                preferences.rememberWindowSize(invalid, for: .quick, layout: .sideBySide)
                XCTAssertEqual(preferences.windowSize(for: .quick, layout: .sideBySide), size)
            }
            for invalid in ["not JSON", #"{"width":-1,"height":620}"#, #"{"width":800,"height":999999999}"#] {
                defaults.set(Data(invalid.utf8), forKey: AppPreferences.StorageKey.windowSize(.main, .stacked))
                XCTAssertNil(preferences.windowSize(for: .main, layout: .stacked))
                XCTAssertEqual(preferences.windowSize(for: .quick, layout: .sideBySide), size)
            }
        }
    }

    func testInvalidTargetDoesNotReplacePreviousPreference() async throws {
        try withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            preferences.setDefaultTarget("fr")
            for invalid in ["", "  ", "auto", "AUTO", "a", "123", "en--US", "en-", "-en", "en_US!", "中文", "en US", "en-u", "en-x", "en-US-US", "sl-rozaj-rozaj"] {
                preferences.setDefaultTarget(invalid)
                XCTAssertEqual(preferences.defaultTarget, "fr", invalid)
            }
            XCTAssertEqual(AppPreferences(defaults: defaults).defaultTarget, "fr")
        }
    }

    func testWellFormedUnknownLanguageRemainsAPreference() async throws {
        try withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            // qaa is in the language-tag range reserved for local use. Keeping it
            // does not add it to Apple's supported language catalog.
            preferences.setDefaultTarget("qaa")
            XCTAssertEqual(preferences.defaultTarget, "qaa")
            XCTAssertEqual(AppPreferences(defaults: defaults).defaultTarget, "qaa")
        }
    }

    func testAppearancePersistsAndCanReturnToSystem() async throws {
        try withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            preferences.appearance = .dark
            XCTAssertEqual(AppPreferences(defaults: defaults).appearance, .dark)
            preferences.appearance = .light
            XCTAssertEqual(AppPreferences(defaults: defaults).appearance, .light)
            preferences.appearance = .system
            XCTAssertEqual(AppPreferences(defaults: defaults).appearance, .system)
        }
    }

    func testCustomShortcutRoundTripsWithoutChangingOtherActions() async throws {
        try withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            let shortcut = GlobalShortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | cmdKey))
            preferences.setShortcut(shortcut, for: .selection)
            let restored = AppPreferences(defaults: defaults)
            XCTAssertEqual(restored.shortcut(for: .selection), shortcut)
            XCTAssertEqual(restored.shortcut(for: .input), ShortcutAction.input.defaultShortcut)
            XCTAssertEqual(restored.shortcut(for: .ocr), ShortcutAction.ocr.defaultShortcut)
        }
    }

    func testExplicitlyDisabledShortcutIsDifferentFromMissingOverride() async throws {
        try withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            XCTAssertEqual(preferences.shortcut(for: .input), ShortcutAction.input.defaultShortcut)
            preferences.setShortcut(nil, for: .input)
            let disabled = AppPreferences(defaults: defaults)
            XCTAssertNil(disabled.shortcut(for: .input))
            XCTAssertEqual(disabled.shortcut(for: .selection), ShortcutAction.selection.defaultShortcut)
            disabled.setShortcut(ShortcutAction.input.defaultShortcut, for: .input)
            XCTAssertEqual(AppPreferences(defaults: defaults).shortcut(for: .input), ShortcutAction.input.defaultShortcut)
        }
    }

    func testCorruptFieldsFallBackIndependently() async throws {
        try withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            preferences.appearance = .dark
            preferences.setShortcut(nil, for: .input)
            defaults.set(["bad": "type"], forKey: AppPreferences.StorageKey.defaultTarget)
            defaults.set(Data("not JSON".utf8), forKey: AppPreferences.StorageKey.shortcut(.selection))
            let restored = AppPreferences(defaults: defaults)
            XCTAssertEqual(restored.defaultTarget, "zh-Hans")
            XCTAssertEqual(restored.appearance, .dark)
            XCTAssertNil(restored.shortcut(for: .input))
            XCTAssertEqual(restored.shortcut(for: .selection), ShortcutAction.selection.defaultShortcut)
            XCTAssertEqual(restored.shortcut(for: .ocr), ShortcutAction.ocr.defaultShortcut)
        }
    }

    func testInvalidStoredValuesFallBackWithoutErasingOtherPreferences() async throws {
        try withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            preferences.setDefaultTarget("ja")
            preferences.setShortcut(nil, for: .ocr)
            defaults.set("future-appearance", forKey: AppPreferences.StorageKey.appearance)
            defaults.set(Data(#"{"enabled":{"_0":{"keyCode":4294967295,"modifiers":256}}}"#.utf8),
                         forKey: AppPreferences.StorageKey.shortcut(.selection))
            defaults.set(42, forKey: AppPreferences.StorageKey.shortcut(.input))
            let restored = AppPreferences(defaults: defaults)
            XCTAssertEqual(restored.defaultTarget, "ja")
            XCTAssertEqual(restored.appearance, .system)
            XCTAssertEqual(restored.shortcut(for: .selection), ShortcutAction.selection.defaultShortcut)
            XCTAssertEqual(restored.shortcut(for: .input), ShortcutAction.input.defaultShortcut)
            XCTAssertNil(restored.shortcut(for: .ocr))
        }
    }

    func testInvalidShortcutCannotReplaceSavedShortcutOrDisabledState() async throws {
        try withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            preferences.setShortcut(nil, for: .selection)
            let revision = preferences.shortcutRevision
            preferences.setShortcut(GlobalShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: 0), for: .selection)
            preferences.setShortcut(GlobalShortcut(keyCode: .max, modifiers: UInt32(cmdKey)), for: .input)
            XCTAssertNil(preferences.shortcut(for: .selection))
            XCTAssertNil(AppPreferences(defaults: defaults).shortcut(for: .selection))
            XCTAssertEqual(preferences.shortcut(for: .input), ShortcutAction.input.defaultShortcut)
            XCTAssertEqual(preferences.shortcutRevision, revision)
        }
    }

    func testShortcutGetterParticipatesInObservation() async throws {
        try withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            let changes = OSAllocatedUnfairLock(initialState: 0)
            withObservationTracking {
                _ = preferences.shortcut(for: .selection)
            } onChange: {
                changes.withLock { $0 += 1 }
            }
            preferences.setShortcut(nil, for: .selection)
            XCTAssertEqual(changes.withLock { $0 }, 1)
            XCTAssertEqual(preferences.shortcutRevision, 1)
            preferences.setShortcut(nil, for: .selection)
            XCTAssertEqual(preferences.shortcutRevision, 1)
        }
    }

    func testStoresOnlyPreferenceFieldsAndPreservesUnrelatedKeys() async throws {
        try withDefaults { defaults, suite in
            defaults.set("preserve", forKey: "unrelated")
            let preferences = AppPreferences(defaults: defaults)
            preferences.setDefaultTarget("de")
            preferences.appearance = .light
            preferences.setShortcut(nil, for: .input)
            let stored = try XCTUnwrap(defaults.persistentDomain(forName: suite))
            XCTAssertEqual(Set(stored.keys), ["unrelated", AppPreferences.StorageKey.defaultTarget,
                                             AppPreferences.StorageKey.appearance, AppPreferences.StorageKey.shortcut(.input)])
            XCTAssertEqual(stored["unrelated"] as? String, "preserve")
        }
    }

    func testLegacyEnabledAndDisabledRecordsRemainCompatibleWithoutOverwritingCustomKeys() async throws {
        try withDefaults { defaults, _ in
            let key = AppPreferences.StorageKey.shortcut
            defaults.set(Data(#"{"disabled":{}}"#.utf8), forKey: key(.input))
            let legacy = GlobalShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey | cmdKey))
            defaults.set(Data(#"{"enabled":{"_0":{"keyCode":17,"modifiers":6400}}}"#.utf8), forKey: key(.selection))
            let preferences = AppPreferences(defaults: defaults)
            XCTAssertNil(preferences.shortcut(for: .input))
            XCTAssertEqual(preferences.rememberedShortcut(for: .input), ShortcutAction.input.defaultShortcut)
            XCTAssertEqual(preferences.shortcut(for: .selection), legacy)
            preferences.setShortcut(nil, for: .selection)
            let reloaded = AppPreferences(defaults: defaults)
            XCTAssertNil(reloaded.shortcut(for: .selection))
            XCTAssertEqual(reloaded.rememberedShortcut(for: .selection), legacy)
        }
    }

    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) throws {
        let suite = "TranslateXTests.AppPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, suite)
    }
}
