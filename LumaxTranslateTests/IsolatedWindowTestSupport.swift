import AppKit
import XCTest
@testable import LumaxTranslate

extension XCTestCase {
    /// These tests exercise text input through NSTextInputClient directly. A
    /// visible key window must not also consume unrelated desktop keystrokes or
    /// clicks while an async layout assertion is suspended. This monitor is
    /// local to the isolated XCTest host, never the user's running application.
    @MainActor
    func isolateUnscriptedWindowInput() throws -> Any {
        try XCTUnwrap(NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        ) { _ in nil })
    }

    /// Window tests must never load a user's selected remote service or Keychain.
    /// Explicit preferences remain owned by the calling test; service state is
    /// always scoped to this fixture's fresh defaults and in-memory credentials.
    @MainActor
    func isolatedWindows(preferences: AppPreferences? = nil) throws -> WindowCoordinator {
        let suite = "LumaxTranslateTests.Windows.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let services = TranslationServiceStore(
            defaults: defaults, credentials: WindowTestCredentials()
        )
        return WindowCoordinator(
            preferences: preferences ?? AppPreferences(defaults: defaults), services: services
        )
    }
}

@MainActor
private final class WindowTestCredentials: TranslationCredentialStore {
    private var values: [UUID: TranslationServiceCredential] = [:]

    func credential(for id: UUID) throws -> TranslationServiceCredential? { values[id] }

    func setCredential(_ credential: TranslationServiceCredential, for id: UUID) throws {
        values[id] = credential
    }

    func removeCredential(for id: UUID) throws {
        values.removeValue(forKey: id)
    }
}
