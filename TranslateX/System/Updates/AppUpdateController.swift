import AppKit
import Combine
import Observation
import Sparkle

/// One updater owned by the application, independent of translation services.
/// Test hosts and preview tools must never start an updater or touch its defaults.
@MainActor
@Observable
final class AppUpdateController {
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var automaticallyDownloadsUpdates = false
    private(set) var started = false
    let isAvailable: Bool
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()

    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier,
         isTesting: Bool = NSClassFromString("XCTestCase") != nil) {
        isAvailable = bundleIdentifier == "com.lumax.tsx" && !isTesting
    }

    func start() {
        guard isAvailable, !started else { return }
        started = true
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).sink { [weak self] value in
            MainActor.assumeIsolated { self?.canCheckForUpdates = value }
        }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main).sink { [weak self] value in
            MainActor.assumeIsolated { self?.automaticallyChecksForUpdates = value }
        }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyDownloadsUpdates).receive(on: RunLoop.main).sink { [weak self] value in
            MainActor.assumeIsolated { self?.automaticallyDownloadsUpdates = value }
        }.store(in: &subscriptions)
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }

    func setAutomaticDownloads(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyDownloadsUpdates = enabled
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }

    func configureMenuItem(_ item: NSMenuItem) {
        item.title = L10n.string("Check for Updates…")
        item.target = controller
        item.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        item.isEnabled = canCheckForUpdates
    }
}
