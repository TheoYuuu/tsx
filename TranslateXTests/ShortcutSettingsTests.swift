import Carbon
import XCTest
@testable import TranslateX

@MainActor
final class ShortcutSettingsTests: XCTestCase {
    func testResetAllRestoresSwappedCombinationsAndKeepsPausedActionPaused() async throws {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        let temporary = GlobalShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(optionKey))
        XCTAssertTrue(fixture.settings.update(temporary, for: .selection))
        XCTAssertTrue(fixture.settings.update(ShortcutAction.selection.defaultShortcut, for: .input))
        XCTAssertTrue(fixture.settings.update(ShortcutAction.input.defaultShortcut, for: .selection))
        XCTAssertTrue(fixture.settings.update(temporary, for: .ocr))
        XCTAssertTrue(fixture.settings.setEnabled(false, for: .ocr))
        let attempts = fixture.registrar.registrationAttempts
        XCTAssertTrue(fixture.settings.hasCustomizedCombinations)
        XCTAssertTrue(fixture.settings.resetAll())
        XCTAssertFalse(fixture.settings.hasCustomizedCombinations)
        XCTAssertFalse(fixture.settings.isEnabled(.ocr))
        XCTAssertNil(fixture.settings.effectiveShortcut(for: .ocr))
        XCTAssertEqual(fixture.registrar.registrationAttempts, attempts, "Swapped reservations should be reused")
        for action in [ShortcutAction.selection, .input] {
            XCTAssertEqual(fixture.settings.effectiveShortcut(for: action), action.defaultShortcut)
            fixture.registrar.onHotKey?(try fixture.id(for: action))
        }
        XCTAssertEqual(fixture.events.actions, [.selection, .input])
        let reloaded = AppPreferences(defaults: fixture.defaults)
        XCTAssertEqual(reloaded.rememberedShortcut(for: .ocr), ShortcutAction.ocr.defaultShortcut)
        XCTAssertNil(reloaded.shortcut(for: .ocr))
    }

    func testFailedResetAllKeepsEveryPreferenceAndExistingBinding() async {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        let custom = GlobalShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(optionKey))
        XCTAssertTrue(fixture.settings.update(custom, for: .selection))
        let prior = fixture.registrar.registered
        let revision = fixture.preferences.shortcutRevision
        fixture.registrar.failingShortcuts = [ShortcutAction.selection.defaultShortcut]
        XCTAssertFalse(fixture.settings.resetAll())
        XCTAssertEqual(fixture.registrar.registered, prior)
        XCTAssertEqual(fixture.preferences.shortcutRevision, revision)
        XCTAssertEqual(fixture.settings.rememberedShortcut(for: .selection), custom)
        XCTAssertEqual(fixture.settings.effectiveShortcut(for: .selection), custom)
    }

    func testResetAllRemovalFailureReleasesCandidateWithoutCommitting() async throws {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        let custom = GlobalShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(optionKey))
        XCTAssertTrue(fixture.settings.update(custom, for: .selection))
        fixture.registrar.failingRemovalIDs = [try fixture.id(for: .selection)]
        let prior = fixture.registrar.registered
        let revision = fixture.preferences.shortcutRevision
        XCTAssertFalse(fixture.settings.resetAll())
        XCTAssertEqual(fixture.registrar.registered, prior)
        XCTAssertEqual(fixture.preferences.shortcutRevision, revision)
        XCTAssertEqual(fixture.settings.effectiveShortcut(for: .selection), custom)
    }

    func testResetAllRollbackRegistrationFailureNotifiesMenusOfLostBinding() async throws {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        let customBindings: [ShortcutAction: GlobalShortcut] = [
            .selection: .init(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(optionKey)),
            .input: .init(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(optionKey)),
            .ocr: .init(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey))
        ]
        for (action, shortcut) in customBindings {
            XCTAssertTrue(fixture.settings.update(shortcut, for: action))
        }
        let originalIDs = try Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map {
            ($0, try fixture.id(for: $0))
        })
        let preferenceRevision = fixture.preferences.shortcutRevision
        let notifications = fixture.events.bindingChanges
        // Whichever dictionary entry is removed first cannot be restored after
        // the second removal fails. No assertion depends on iteration order.
        fixture.registrar.failingRemovalAttempt = fixture.registrar.removalAttempts + 2
        fixture.registrar.failingShortcuts = Set(customBindings.values)

        XCTAssertFalse(fixture.settings.resetAll())

        let lostActions = ShortcutAction.allCases.filter { fixture.settings.effectiveShortcut(for: $0) == nil }
        XCTAssertEqual(lostActions.count, 1)
        XCTAssertEqual(fixture.events.bindingChanges, notifications + 1,
                       "Menus must refresh when rollback cannot restore an active shortcut.")
        XCTAssertEqual(fixture.preferences.shortcutRevision, preferenceRevision)
        for action in ShortcutAction.allCases {
            XCTAssertEqual(fixture.settings.configuredShortcut(for: action), customBindings[action])
            XCTAssertEqual(fixture.manager.shortcut(for: action), fixture.settings.effectiveShortcut(for: action))
            if lostActions.contains(action) {
                XCTAssertNotNil(fixture.settings.error(for: action))
                XCTAssertNil(fixture.registrar.registered[try XCTUnwrap(originalIDs[action])])
            } else {
                XCTAssertEqual(fixture.settings.effectiveShortcut(for: action), customBindings[action])
            }
        }
        let lostAction = try XCTUnwrap(lostActions.first)
        fixture.registrar.onHotKey?(try XCTUnwrap(originalIDs[lostAction]))
        XCTAssertTrue(fixture.events.actions.isEmpty, "A removed reservation must not route a stale action.")
    }

    func testPauseRetainsCustomCombinationAcrossRestartAndResumeChecksConflicts() async {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        let custom = GlobalShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey))
        XCTAssertTrue(fixture.settings.update(custom, for: .input))
        XCTAssertTrue(fixture.settings.setEnabled(false, for: .input))
        XCTAssertNil(fixture.settings.effectiveShortcut(for: .input))
        let reloaded = AppPreferences(defaults: fixture.defaults)
        XCTAssertNil(reloaded.shortcut(for: .input))
        XCTAssertEqual(reloaded.rememberedShortcut(for: .input), custom)
        fixture.registrar.failingShortcuts = [custom]
        XCTAssertFalse(fixture.settings.setEnabled(true, for: .input))
        XCTAssertFalse(fixture.settings.isEnabled(.input))
        XCTAssertNil(fixture.settings.effectiveShortcut(for: .input))
        XCTAssertEqual(fixture.settings.rememberedShortcut(for: .input), custom)
        fixture.registrar.failingShortcuts = []
        XCTAssertTrue(fixture.settings.setEnabled(true, for: .input))
        XCTAssertEqual(fixture.settings.effectiveShortcut(for: .input), custom)
        XCTAssertEqual(AppPreferences(defaults: fixture.defaults).shortcut(for: .input), custom)
    }

    func testResetWhilePausedKeepsOffAndDuplicateResumeKeepsBothPreferences() async {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        let custom = GlobalShortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey))
        XCTAssertTrue(fixture.settings.update(custom, for: .selection))
        XCTAssertTrue(fixture.settings.setEnabled(false, for: .selection))
        XCTAssertTrue(fixture.settings.reset(for: .selection))
        XCTAssertFalse(fixture.settings.isEnabled(.selection))
        XCTAssertEqual(fixture.settings.rememberedShortcut(for: .selection), ShortcutAction.selection.defaultShortcut)
        XCTAssertTrue(fixture.settings.update(ShortcutAction.selection.defaultShortcut, for: .input))
        XCTAssertFalse(fixture.settings.setEnabled(true, for: .selection))
        XCTAssertFalse(fixture.settings.isEnabled(.selection))
        XCTAssertEqual(fixture.settings.effectiveShortcut(for: .input), ShortcutAction.selection.defaultShortcut)
    }

    func testDisablingDuringRecordingDoesNotRestoreStaleErrorOrTriggerAction() async throws {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        let token = fixture.settings.beginRecording(for: .selection)
        let candidate = GlobalShortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey))
        fixture.settings.record(candidate, token: token)
        XCTAssertEqual(fixture.settings.candidate, candidate)
        XCTAssertTrue(fixture.settings.setEnabled(false, for: .selection))
        fixture.settings.endRecording(token)
        XCTAssertNil(fixture.settings.error(for: .selection))
        XCTAssertNil(fixture.settings.candidate)
        XCTAssertNil(fixture.settings.recordingAction)
        XCTAssertFalse(fixture.settings.isEnabled(.selection))
        XCTAssertTrue(fixture.events.actions.isEmpty)
    }

    func testStartupConflictDoesNotStopOtherActionsOrRewritePreference() async {
        let fixture = ShortcutSettingsFixture()
        fixture.registrar.failingShortcuts = [ShortcutAction.selection.defaultShortcut]
        fixture.settings.start()

        XCTAssertNil(fixture.settings.effectiveShortcut(for: .selection))
        XCTAssertNotNil(fixture.settings.error(for: .selection))
        XCTAssertEqual(fixture.settings.configuredShortcut(for: .selection), ShortcutAction.selection.defaultShortcut)
        XCTAssertEqual(fixture.settings.effectiveShortcut(for: .input), ShortcutAction.input.defaultShortcut)
        XCTAssertEqual(fixture.settings.effectiveShortcut(for: .ocr), ShortcutAction.ocr.defaultShortcut)
        XCTAssertEqual(fixture.preferences.shortcutRevision, 0)

        let startupError = fixture.settings.error(for: .selection)
        let token = fixture.settings.beginRecording(for: .selection)
        fixture.settings.record(GlobalShortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey)), token: token)
        XCTAssertNotEqual(fixture.settings.error(for: .selection), startupError)
        fixture.settings.endRecording(token)
        XCTAssertEqual(fixture.settings.error(for: .selection), startupError, "Esc must restore an unresolved startup conflict.")

        fixture.registrar.failingShortcuts = []
        fixture.settings.start()
        XCTAssertNil(fixture.settings.error(for: .selection))
        XCTAssertEqual(fixture.registrar.registered.count, 3)
        XCTAssertEqual(fixture.preferences.shortcutRevision, 0)
    }

    func testFailedReplacementPreservesPersistedAndEffectiveShortcut() async throws {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        let original = try XCTUnwrap(fixture.settings.effectiveShortcut(for: .selection))
        let originalID = try fixture.id(for: .selection)
        let candidate = GlobalShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey | optionKey))
        fixture.registrar.failingShortcuts = [candidate]
        let previousNotifications = fixture.events.bindingChanges

        XCTAssertFalse(fixture.settings.update(candidate, for: .selection))
        XCTAssertEqual(fixture.preferences.shortcutRevision, 0)
        XCTAssertEqual(fixture.settings.configuredShortcut(for: .selection), original)
        XCTAssertEqual(fixture.settings.effectiveShortcut(for: .selection), original)
        XCTAssertEqual(fixture.events.bindingChanges, previousNotifications)
        fixture.registrar.onHotKey?(originalID)
        XCTAssertEqual(fixture.events.actions, [.selection])
    }

    func testFailedDisableDoesNotWritePreferencesAndSuccessfulDisableSurvivesRestart() async throws {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        let selectionID = try fixture.id(for: .selection)
        fixture.registrar.failingRemovalIDs = [selectionID]

        XCTAssertFalse(fixture.settings.update(nil, for: .selection))
        XCTAssertEqual(fixture.preferences.shortcutRevision, 0)
        XCTAssertNotNil(fixture.settings.configuredShortcut(for: .selection))
        XCTAssertNotNil(fixture.settings.effectiveShortcut(for: .selection))

        fixture.registrar.failingRemovalIDs = []
        XCTAssertTrue(fixture.settings.update(nil, for: .selection))
        XCTAssertNil(fixture.settings.error(for: .selection))
        XCTAssertNil(fixture.settings.effectiveShortcut(for: .selection))
        let reloaded = AppPreferences(defaults: fixture.defaults)
        XCTAssertNil(reloaded.shortcut(for: .selection))
        let restarted = ShortcutSettings(
            preferences: reloaded, manager: ShortcutManager(registrar: SettingsHotKeyRegistrar()),
            onAction: { _ in }, onBindingsChanged: {}
        )
        restarted.start()
        XCTAssertNil(restarted.effectiveShortcut(for: .selection))
        XCTAssertNotNil(restarted.effectiveShortcut(for: .input))
    }

    func testSuccessfulUpdateAndResetNotifyAfterPersistenceMatchesEffectiveBinding() async {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        let candidate = GlobalShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey | optionKey))
        XCTAssertTrue(fixture.settings.update(candidate, for: .selection))
        XCTAssertEqual(fixture.settings.configuredShortcut(for: .selection), candidate)
        XCTAssertEqual(fixture.settings.effectiveShortcut(for: .selection), candidate)
        XCTAssertEqual(AppPreferences(defaults: fixture.defaults).shortcut(for: .selection), candidate)
        XCTAssertTrue(fixture.settings.reset(for: .selection))
        XCTAssertEqual(fixture.settings.configuredShortcut(for: .selection), ShortcutAction.selection.defaultShortcut)
        XCTAssertEqual(fixture.settings.effectiveShortcut(for: .selection), ShortcutAction.selection.defaultShortcut)
        XCTAssertEqual(fixture.events.bindingChanges, 5)
    }

    func testRegisteredKeysAreCandidatesUntilRecordingEnds() async throws {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        let selectionID = try fixture.id(for: .selection)
        let inputID = try fixture.id(for: .input)
        let initialRegistrations = fixture.registrar.registrationAttempts
        fixture.settings.beginRecording(for: .selection)

        // A key belonging to another action is an in-app conflict, not that action.
        fixture.registrar.onHotKey?(inputID)
        XCTAssertTrue(fixture.events.actions.isEmpty)
        XCTAssertEqual(fixture.settings.recordingAction, .selection)
        XCTAssertNotNil(fixture.settings.error(for: .selection))
        XCTAssertEqual(fixture.preferences.shortcutRevision, 0)
        XCTAssertEqual(fixture.registrar.registrationAttempts, initialRegistrations)

        // Choosing the same key commits without releasing/re-registering it.
        fixture.registrar.onHotKey?(selectionID)
        XCTAssertTrue(fixture.events.actions.isEmpty)
        XCTAssertNil(fixture.settings.recordingAction)
        XCTAssertNil(fixture.settings.error(for: .selection))
        XCTAssertEqual(fixture.registrar.registrationAttempts, initialRegistrations)
        fixture.registrar.onHotKey?(selectionID)
        fixture.registrar.onHotKey?(inputID)
        XCTAssertEqual(fixture.events.actions, [.selection, .input])
    }

    func testOldRecorderCleanupCannotCancelNewRowAndCancelRestoresRouting() async throws {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        let first = fixture.settings.beginRecording(for: .selection)
        let second = fixture.settings.beginRecording(for: .ocr)
        fixture.settings.endRecording(first)
        fixture.settings.record(ShortcutAction.input.defaultShortcut, token: first)
        XCTAssertEqual(fixture.settings.recordingAction, .ocr)
        XCTAssertTrue(fixture.settings.isRecording(second))
        fixture.settings.endRecording()
        fixture.registrar.onHotKey?(try fixture.id(for: .selection))
        XCTAssertEqual(fixture.events.actions, [.selection])
        XCTAssertEqual(fixture.preferences.shortcutRevision, 0)
    }

    func testCancelDiscardsCandidateErrorButSuccessfulRecordingClearsPreviousFailure() async {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        let reserved = GlobalShortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey))
        let token = fixture.settings.beginRecording(for: .selection)
        fixture.settings.record(reserved, token: token)
        XCTAssertNotNil(fixture.settings.error(for: .selection))
        fixture.settings.endRecording(token)
        XCTAssertNil(fixture.settings.error(for: .selection))
        XCTAssertEqual(fixture.preferences.shortcutRevision, 0)

        XCTAssertFalse(fixture.settings.update(reserved, for: .selection))
        XCTAssertNotNil(fixture.settings.error(for: .selection))
        let retry = fixture.settings.beginRecording(for: .selection)
        fixture.settings.record(ShortcutAction.selection.defaultShortcut, token: retry)
        XCTAssertNil(fixture.settings.error(for: .selection))
        XCTAssertNil(fixture.settings.recordingAction)
    }

    func testReservedCommandsCannotReachSystemOrReplaceExistingShortcut() async {
        let fixture = ShortcutSettingsFixture()
        fixture.settings.start()
        let initialRegistrations = fixture.registrar.registrationAttempts
        for (key, modifiers) in [
            (kVK_ANSI_Q, cmdKey), (kVK_ANSI_W, cmdKey), (kVK_ANSI_Comma, cmdKey),
            (kVK_ANSI_C, cmdKey), (kVK_ANSI_V, cmdKey), (kVK_ANSI_Z, cmdKey | shiftKey),
            (kVK_ANSI_B, cmdKey), (kVK_ANSI_I, cmdKey), (kVK_ANSI_U, cmdKey),
            (kVK_ANSI_4, cmdKey | shiftKey), (kVK_Space, controlKey),
            (kVK_ANSI_A, controlKey), (kVK_LeftArrow, optionKey),
            (kVK_Delete, optionKey), (kVK_RightArrow, optionKey | shiftKey), (kVK_Space, cmdKey), (kVK_Escape, cmdKey | optionKey)
        ] {
            let shortcut = GlobalShortcut(keyCode: UInt32(key), modifiers: UInt32(modifiers))
            XCTAssertTrue(shortcut.isValid)
            XCTAssertTrue(shortcut.isReserved)
            XCTAssertFalse(fixture.settings.update(shortcut, for: .selection))
        }
        XCTAssertEqual(fixture.preferences.shortcutRevision, 0)
        XCTAssertEqual(fixture.registrar.registrationAttempts, initialRegistrations)
        XCTAssertEqual(fixture.settings.effectiveShortcut(for: .selection), ShortcutAction.selection.defaultShortcut)
        XCTAssertTrue(ShortcutAction.allCases.allSatisfy { !$0.defaultShortcut.isReserved })
    }
}

@MainActor
final class ShortcutSettingsFixture {
    final class Events {
        var actions: [ShortcutAction] = []
        var bindingChanges = 0
    }
    let suite = "TranslateX.ShortcutTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let preferences: AppPreferences
    let registrar: SettingsHotKeyRegistrar
    let manager: ShortcutManager
    let settings: ShortcutSettings
    let events = Events()

    init() {
        defaults = UserDefaults(suiteName: suite)!
        preferences = AppPreferences(defaults: defaults)
        registrar = SettingsHotKeyRegistrar()
        manager = ShortcutManager(registrar: registrar)
        let events = events
        settings = ShortcutSettings(
            preferences: preferences, manager: manager,
            onAction: { events.actions.append($0) },
            onBindingsChanged: { events.bindingChanges += 1 }
        )
    }

    func id(for action: ShortcutAction) throws -> UInt32 {
        try XCTUnwrap(registrar.registered.first { $0.value == settings.effectiveShortcut(for: action) }?.key)
    }

    isolated deinit { defaults.removePersistentDomain(forName: suite) }
}

@MainActor
final class SettingsHotKeyRegistrar: HotKeyRegistering {
    var onHotKey: (@MainActor (UInt32) -> Void)?
    var registered: [UInt32: GlobalShortcut] = [:]
    var failingShortcuts: Set<GlobalShortcut> = []
    var failingRemovalIDs: Set<UInt32> = []
    var registrationAttempts = 0
    var removalAttempts = 0
    var failingRemovalAttempt: Int?

    func register(_ shortcut: GlobalShortcut, id: UInt32) throws {
        registrationAttempts += 1
        if failingShortcuts.contains(shortcut) { throw ShortcutError.alreadyInUse }
        registered[id] = shortcut
    }

    func unregister(id: UInt32) throws {
        removalAttempts += 1
        if failingRemovalIDs.contains(id) || removalAttempts == failingRemovalAttempt {
            throw ShortcutError.unregistrationFailed(-50)
        }
        registered[id] = nil
    }
}
