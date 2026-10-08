import AppKit

@main
enum TranslateXApp {
    @MainActor
    static func main() {
        // Run before any preferences or service store reads the new app domain.
        // Test hosts must never import the user's real settings or services.
        if Bundle.main.bundleIdentifier == LegacyPreferencesMigration.currentBundleIdentifier,
           NSClassFromString("XCTestCase") == nil {
            LegacyPreferencesMigration.migrateIfNeeded()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
