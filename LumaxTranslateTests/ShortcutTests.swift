import Carbon
import XCTest
@testable import LumaxTranslate

final class ShortcutTests: XCTestCase {
    func testRequiresOptionControlOrCommandAndRejectsUnsupportedModifierBits() {
        let key = UInt32(kVK_ANSI_T)
        XCTAssertFalse(GlobalShortcut(keyCode: key, modifiers: 0).isValid)
        XCTAssertTrue(GlobalShortcut(keyCode: key, modifiers: UInt32(optionKey | shiftKey)).isValid)
        XCTAssertTrue(GlobalShortcut(keyCode: key, modifiers: UInt32(optionKey)).isValid)
        XCTAssertFalse(GlobalShortcut(keyCode: key, modifiers: UInt32(shiftKey)).isValid)
        XCTAssertFalse(GlobalShortcut(keyCode: key, modifiers: UInt32(cmdKey | alphaLock)).isValid)
        XCTAssertTrue(GlobalShortcut(keyCode: key, modifiers: UInt32(cmdKey)).isValid)
        XCTAssertTrue(GlobalShortcut(keyCode: key, modifiers: UInt32(controlKey)).isValid)
    }

    func testRejectsModifierKeysAndUnknownKeyCodes() {
        XCTAssertFalse(GlobalShortcut(keyCode: UInt32(kVK_Shift), modifiers: UInt32(cmdKey)).isValid)
        XCTAssertFalse(GlobalShortcut(keyCode: UInt32.max, modifiers: UInt32(cmdKey)).isValid)
    }

    func testDefaultsAreDistinctValidAndHaveReadableLabels() throws {
        let shortcuts = ShortcutAction.allCases.map(\.defaultShortcut)
        XCTAssertEqual(Set(shortcuts).count, 3)
        XCTAssertTrue(shortcuts.allSatisfy(\.isValid))
        XCTAssertEqual(ShortcutAction.selection.defaultShortcut.displayString, "⌥T")
        XCTAssertEqual(ShortcutAction.input.defaultShortcut.displayString, "⌥I")
        XCTAssertEqual(ShortcutAction.ocr.defaultShortcut.displayString, "⌥O")
        let data = try JSONEncoder().encode(shortcuts)
        XCTAssertEqual(try JSONDecoder().decode([GlobalShortcut].self, from: data), shortcuts)
    }
}

@MainActor
final class ShortcutManagerTests: XCTestCase {
    func testFailedReplacementKeepsPreviousBindingAndHandler() async throws {
        let backend = TestHotKeyRegistrar()
        let manager = ShortcutManager(registrar: backend)
        var originalInvocations = 0
        var replacementInvocations = 0
        try manager.register(ShortcutAction.selection.defaultShortcut, for: .selection) {
            originalInvocations += 1
        }
        let originalID = try XCTUnwrap(backend.registered.keys.first)
        backend.nextRegistrationError = .alreadyInUse

        XCTAssertThrowsError(try manager.register(ShortcutAction.input.defaultShortcut, for: .selection) {
            replacementInvocations += 1
        }) { error in
            XCTAssertEqual(error as? ShortcutError, .alreadyInUse)
        }

        XCTAssertEqual(manager.shortcut(for: .selection), ShortcutAction.selection.defaultShortcut)
        XCTAssertEqual(backend.registered.count, 1)
        backend.onHotKey?(originalID)
        XCTAssertEqual(originalInvocations, 1)
        XCTAssertEqual(replacementInvocations, 0)
    }

    func testSuccessfulReplacementRemovesOldBindingAndIgnoresQueuedOldEvent() async throws {
        let backend = TestHotKeyRegistrar()
        let manager = ShortcutManager(registrar: backend)
        var invoked = 0
        try manager.register(ShortcutAction.selection.defaultShortcut, for: .selection) { invoked += 1 }
        let oldID = try XCTUnwrap(backend.registered.keys.first)
        try manager.register(ShortcutAction.input.defaultShortcut, for: .selection) { invoked += 10 }
        let newID = try XCTUnwrap(backend.registered.keys.first)

        XCTAssertNotEqual(oldID, newID)
        XCTAssertEqual(backend.registered.count, 1)
        XCTAssertEqual(manager.shortcut(for: .selection), ShortcutAction.input.defaultShortcut)
        backend.onHotKey?(oldID)
        XCTAssertEqual(invoked, 0)
        backend.onHotKey?(newID)
        XCTAssertEqual(invoked, 10)
    }

    func testSameCombinationUpdatesHandlerWithoutReregistering() async throws {
        let backend = TestHotKeyRegistrar()
        let manager = ShortcutManager(registrar: backend)
        var invoked = 0
        try manager.register(ShortcutAction.selection.defaultShortcut, for: .selection) { invoked += 1 }
        let id = try XCTUnwrap(backend.registered.keys.first)
        try manager.register(ShortcutAction.selection.defaultShortcut, for: .selection) { invoked += 10 }

        XCTAssertEqual(backend.registrationAttempts, 1)
        backend.onHotKey?(id)
        XCTAssertEqual(invoked, 10)
    }

    func testMultipleActionsAndDuplicateCombinationRejection() async throws {
        let backend = TestHotKeyRegistrar()
        let manager = ShortcutManager(registrar: backend)
        var invoked: [ShortcutAction] = []
        for action in [ShortcutAction.selection, .input] {
            try manager.register(action.defaultShortcut, for: action) { invoked.append(action) }
        }
        XCTAssertThrowsError(try manager.register(ShortcutAction.selection.defaultShortcut, for: .input) {}) {
            XCTAssertEqual($0 as? ShortcutError, .alreadyInUse)
        }
        XCTAssertEqual(backend.registrationAttempts, 2)
        for id in backend.registered.keys.sorted() { backend.onHotKey?(id) }
        XCTAssertEqual(invoked, [.selection, .input])
        XCTAssertNil(manager.shortcut(for: .ocr))
    }

    func testOldRemovalFailureRollsBackNewBinding() async throws {
        let backend = TestHotKeyRegistrar()
        let manager = ShortcutManager(registrar: backend)
        try manager.register(ShortcutAction.selection.defaultShortcut, for: .selection) {}
        let oldID = try XCTUnwrap(backend.registered.keys.first)
        backend.failingRemovalIDs = [oldID]

        XCTAssertThrowsError(try manager.register(ShortcutAction.input.defaultShortcut, for: .selection) {})
        XCTAssertEqual(backend.registered, [oldID: ShortcutAction.selection.defaultShortcut])
        XCTAssertEqual(manager.shortcut(for: .selection), ShortcutAction.selection.defaultShortcut)
    }

    func testUnregisterAllRetriesFailedRollbackCleanup() async throws {
        let backend = TestHotKeyRegistrar()
        let manager = ShortcutManager(registrar: backend)
        try manager.register(ShortcutAction.selection.defaultShortcut, for: .selection) {}
        backend.failingRemovalIDs = [1, 2]
        XCTAssertThrowsError(try manager.register(ShortcutAction.input.defaultShortcut, for: .selection) {})
        XCTAssertEqual(backend.registered.count, 2)

        backend.failingRemovalIDs = []
        try manager.unregisterAll()
        XCTAssertTrue(backend.registered.isEmpty)
        XCTAssertNil(manager.shortcut(for: .selection))
    }

    func testUnregisterAllContinuesAfterOneFailureAndPreservesFailedBinding() async throws {
        let backend = TestHotKeyRegistrar()
        let manager = ShortcutManager(registrar: backend)
        try manager.register(ShortcutAction.selection.defaultShortcut, for: .selection) {}
        try manager.register(ShortcutAction.input.defaultShortcut, for: .input) {}
        let selectionID = try XCTUnwrap(backend.registered.first {
            $0.value == ShortcutAction.selection.defaultShortcut
        }?.key)
        backend.failingRemovalIDs = [selectionID]

        XCTAssertThrowsError(try manager.unregisterAll())
        XCTAssertEqual(backend.registered.count, 1)
        XCTAssertEqual(manager.shortcut(for: .selection), ShortcutAction.selection.defaultShortcut)
        XCTAssertNil(manager.shortcut(for: .input))
        backend.failingRemovalIDs = []
        try manager.unregisterAll()
        XCTAssertTrue(backend.registered.isEmpty)
    }

    func testInvalidShortcutNeverReachesSystemRegistration() async {
        let backend = TestHotKeyRegistrar()
        let manager = ShortcutManager(registrar: backend)
        XCTAssertThrowsError(try manager.register(
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(shiftKey)), for: .selection
        ) {}) {
            XCTAssertEqual($0 as? ShortcutError, .invalidShortcut)
        }
        XCTAssertEqual(backend.registrationAttempts, 0)
    }
}

@MainActor
private final class TestHotKeyRegistrar: HotKeyRegistering {
    var onHotKey: (@MainActor (UInt32) -> Void)?
    var registered: [UInt32: GlobalShortcut] = [:]
    var registrationAttempts = 0
    var nextRegistrationError: ShortcutError?
    var failingRemovalIDs: Set<UInt32> = []

    func register(_ shortcut: GlobalShortcut, id: UInt32) throws {
        registrationAttempts += 1
        if let error = nextRegistrationError {
            nextRegistrationError = nil
            throw error
        }
        registered[id] = shortcut
    }

    func unregister(id: UInt32) throws {
        if failingRemovalIDs.contains(id) { throw ShortcutError.unregistrationFailed(-50) }
        registered[id] = nil
    }
}
