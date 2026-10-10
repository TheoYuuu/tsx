import AppKit
import Sparkle
import XCTest
@testable import TranslateX

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    func testTestHostsAndPreviewBundlesCannotStartUpdaterOrChangePreferences() {
        for identifier in [nil, "com.lumax.tsx.TestHost", "preview", "com.lumax.tsx"] {
            let updates = AppUpdateController(bundleIdentifier: identifier, isTesting: true, isReleaseBuild: true)
            updates.start()
            updates.setAutomaticChecks(true)
            updates.setAutomaticDownloads(true)
            updates.checkForUpdates()
            XCTAssertFalse(updates.isAvailable)
            XCTAssertFalse(updates.started)
            XCTAssertFalse(updates.canCheckForUpdates)
            XCTAssertFalse(updates.automaticallyChecksForUpdates)
            XCTAssertFalse(updates.automaticallyDownloadsUpdates)
        }
        XCTAssertFalse(AppUpdateController(bundleIdentifier: "preview", isTesting: false, isReleaseBuild: true).isAvailable)
    }

    func testConstructingControllerDoesNotStartNetworkOrEnableAutomaticUpdates() {
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true)
        XCTAssertTrue(updates.isAvailable)
        XCTAssertFalse(updates.started)
        XCTAssertFalse(updates.canCheckForUpdates)
        XCTAssertFalse(updates.automaticallyChecksForUpdates)
        XCTAssertFalse(updates.automaticallyDownloadsUpdates)
    }

    func testBuildConfigurationControlsDefaultUpdateAvailability() {
        let backend = UpdateBackendFixture()
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false,
                                          recordsInstalledVersions: false, backend: backend)
        updates.start()
        #if DEBUG
        XCTAssertFalse(AppUpdateController.isReleaseBuild)
        XCTAssertFalse(updates.isAvailable)
        XCTAssertFalse(updates.started)
        XCTAssertTrue(backend.calls.isEmpty)
        #else
        XCTAssertTrue(AppUpdateController.isReleaseBuild)
        XCTAssertTrue(updates.isAvailable)
        XCTAssertTrue(updates.started)
        XCTAssertEqual(backend.calls, ["start", "information"])
        #endif
    }

    func testDevelopmentBuildCannotStartUpdaterOrChangePersistedPreferences() throws {
        let suite = "TSX.DevelopmentUpdateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "SUEnableAutomaticChecks")
        defaults.set(true, forKey: "SUAutomaticallyUpdate")
        defaults.set("1.0.0", forKey: "TSXLastLaunchedReleaseVersion")
        let before = defaults.persistentDomain(forName: suite)! as NSDictionary
        let backend = UpdateBackendFixture(defaults: defaults)
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: false,
                                          currentVersion: "2.0.0", defaults: defaults,
                                          recordsInstalledVersions: true, backend: backend)

        updates.start()
        updates.refreshUpdaterState()
        updates.performUpdateAction()
        updates.foundUpdate("3.0.0")
        updates.performUpdateAction()
        updates.checkForUpdates()
        updates.setAutomaticUpdates(false)
        updates.setAutomaticChecks(true)
        updates.setAutomaticDownloads(true)
        updates.prepareInstalledReleaseNotes()
        updates.willInstallVersion("3.0.0")

        XCTAssertFalse(updates.isAvailable)
        XCTAssertFalse(updates.started)
        XCTAssertFalse(updates.canCheckForUpdates)
        XCTAssertFalse(updates.isChecking)
        XCTAssertFalse(updates.automaticUpdatesEnabled)
        XCTAssertNil(updates.updatePresentation)
        XCTAssertNil(updates.pendingReleaseNotesVersion)
        XCTAssertTrue(backend.calls.isEmpty)
        XCTAssertTrue(backend.automaticallyChecksForUpdates)
        XCTAssertTrue(backend.automaticallyDownloadsUpdates)
        XCTAssertEqual(defaults.persistentDomain(forName: suite)! as NSDictionary, before)
    }

    func testReleaseBuildUsesExistingAutomaticUpdatePreferences() throws {
        let suite = "TSX.ReleaseUpdatePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "SUEnableAutomaticChecks")
        defaults.set(true, forKey: "SUAutomaticallyUpdate")
        let before = defaults.persistentDomain(forName: suite)! as NSDictionary
        let backend = UpdateBackendFixture(defaults: defaults)
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                          defaults: defaults, recordsInstalledVersions: false, backend: backend)
        updates.start()
        XCTAssertTrue(updates.isAvailable)
        XCTAssertTrue(updates.started)
        XCTAssertTrue(updates.canCheckForUpdates)
        XCTAssertTrue(updates.automaticallyChecksForUpdates)
        XCTAssertTrue(updates.automaticUpdatesEnabled)
        XCTAssertEqual(backend.calls, ["start", "update"])
        XCTAssertEqual(defaults.persistentDomain(forName: suite)! as NSDictionary, before)
    }

    func testVersionProbeUpdatesCombinedActionStateWithoutStartingUpdater() {
        let updates = AppUpdateController(bundleIdentifier: "preview", isTesting: true)
        XCTAssertNil(updates.availableVersion)
        XCTAssertFalse(updates.hasChecked)
        updates.foundUpdate("2.3.4")
        XCTAssertEqual(updates.availableVersion, "2.3.4")
        XCTAssertTrue(updates.hasChecked)
        updates.checkFailed()
        XCTAssertTrue(updates.lastCheckFailed)
        XCTAssertEqual(updates.availableVersion, "2.3.4", "A transient error preserves the known update.")
        updates.checkAborted(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
        XCTAssertNil(updates.availableVersion)
        XCTAssertFalse(updates.lastCheckFailed)
        updates.checkAborted(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue)))
        XCTAssertFalse(updates.lastCheckFailed)
        updates.performUpdateAction()
        XCTAssertFalse(updates.started)
        XCTAssertFalse(updates.canCheckForUpdates)
    }

    func testPackagedUpdatePolicyRequiresSignaturesAndLeavesScheduledUpdatesOffByDefault() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["SUFeedURL"] as? String, "https://lumaxspace.com/updates/tsx/appcast.xml")
        let publicKey = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: publicKey)?.count, 32)
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(info["SUEnableSystemProfiling"] as? Bool, false)
    }
}

@MainActor
private final class UpdateBackendFixture: AppUpdaterBackend {
    private let defaults: UserDefaults?
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false {
        didSet { defaults?.set(automaticallyChecksForUpdates, forKey: "SUEnableAutomaticChecks") }
    }
    var automaticallyDownloadsUpdates = false {
        didSet { defaults?.set(automaticallyDownloadsUpdates, forKey: "SUAutomaticallyUpdate") }
    }
    var calls: [String] = []
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        automaticallyChecksForUpdates = defaults?.bool(forKey: "SUEnableAutomaticChecks") ?? false
        automaticallyDownloadsUpdates = defaults?.bool(forKey: "SUAutomaticallyUpdate") ?? false
    }
    func start() throws { calls.append("start") }
    func checkInformation() { calls.append("information") }
    func checkUpdates() { calls.append("update") }
}

extension AppUpdateControllerTests {
    func testInstalledNotesReuseMainWindowAndPreserveDraftAndSettingsNavigation() async throws {
        let monitor = try isolateUnscriptedWindowInput()
        defer { NSEvent.removeMonitor(monitor) }
        let (windows, updates, defaults) = try releaseNotesWindowFixture()
        defer { windows.shutdown() }
        windows.inputModel.setAutomaticTranslation(false)
        windows.inputModel.text = "Constructed draft survives the update notice."
        windows.showMain()
        let window = try visibleMainWindow()
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)
        var settingsRequests = 0
        var draftExitRequests = 0
        windows.onSettings = { settingsRequests += 1 }
        windows.settingsNavigation.requestedTab = 3
        windows.serviceNavigation.exitHandler = { _ in draftExitRequests += 1 }

        updates.prepareInstalledReleaseNotes()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(try visibleMainWindow() === window)
        XCTAssertTrue(window.contentView === host)
        XCTAssertFalse(NSApp.windows.contains { $0.identifier?.rawValue == "translatex.release-notes" && $0.isVisible })
        XCTAssertEqual(settingsRequests, 0)
        XCTAssertEqual(draftExitRequests, 0)
        XCTAssertEqual(windows.settingsNavigation.requestedTab, 3)
        XCTAssertFalse(updates.isPresentingModal, "The main overlay must not block settings navigation.")
        XCTAssertFalse(window.firstResponder is TranslationInputTextView, "The delayed input-focus request must not escape the overlay.")
        let surface = try XCTUnwrap(host as? WindowSurface<InputTranslationView>)
        let overlay = try XCTUnwrap(surface.modalHostingView)
        XCTAssertTrue(surface.subviews.last === overlay, "Dimming must composite above native glass edge highlights.")
        XCTAssertTrue(overlay.superview === surface)
        let editorParent = surface.hostingView.superview
        for size in [NSSize(width: 660, height: 440), NSSize(width: 1080, height: 720)] {
            window.setContentSize(size)
            surface.layoutSubtreeIfNeeded()
            XCTAssertEqual(overlay.frame, surface.bounds, "Modal coverage must include top and bottom after resizing.")
            XCTAssertTrue(surface.hostingView.superview === editorParent)
        }

        updates.showRecentReleaseNotes(in: .mainWindow)
        XCTAssertTrue(try visibleMainWindow() === window)
        XCTAssertEqual(updates.mainReleaseNotesPresentation, .recent)
        XCTAssertEqual(defaults.string(forKey: "TSXPendingInstalledReleaseVersion"), "1.1.0")
        windows.dismissMainReleaseNotes()
        XCTAssertTrue(window.isVisible, "Dismissing the notice returns to translation, without closing its window.")
        XCTAssertTrue(window.contentView === host)
        XCTAssertEqual(windows.inputModel.text, "Constructed draft survives the update notice.")
        XCTAssertNil(updates.mainReleaseNotesPresentation)
        XCTAssertNil(surface.modalHostingView)
        XCTAssertNil(overlay.superview)
        XCTAssertNil(updates.pendingReleaseNotesVersion)
        XCTAssertEqual(defaults.string(forKey: "TSXAcknowledgedReleaseNotesVersion"), "1.1.0")
    }

    func testTemporarilyHidingOrClosingMainWindowDoesNotAcknowledgeReleaseNotes() throws {
        let (windows, updates, defaults) = try releaseNotesWindowFixture()
        defer { windows.shutdown() }
        updates.prepareInstalledReleaseNotes()
        let window = try visibleMainWindow()
        defer { window.close() }
        // Presentation and restoration must not depend on this test host owning
        // foreground activation; active-window origin selection has separate tests.
        _ = windows.hideForScreenshot()
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(updates.mainReleaseNotesPresentation, .installed(version: "1.1.0"))
        XCTAssertEqual(updates.pendingReleaseNotesVersion, "1.1.0")
        XCTAssertNil(defaults.string(forKey: "TSXAcknowledgedReleaseNotesVersion"))
        windows.restoreAfterScreenshotCancellation(.input)
        XCTAssertTrue(try visibleMainWindow() === window)
        XCTAssertEqual(updates.pendingReleaseNotesVersion, "1.1.0")
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(updates.mainReleaseNotesPresentation, .installed(version: "1.1.0"))
        XCTAssertNil(defaults.string(forKey: "TSXAcknowledgedReleaseNotesVersion"))
        windows.showMain()
        XCTAssertTrue(try visibleMainWindow() === window)
        windows.dismissMainReleaseNotes()
        XCTAssertTrue(window.isVisible)
        XCTAssertNil(updates.mainReleaseNotesPresentation)
        XCTAssertEqual(defaults.string(forKey: "TSXAcknowledgedReleaseNotesVersion"), "1.1.0")
    }


    private func releaseNotesWindowFixture() throws -> (WindowCoordinator, AppUpdateController, UserDefaults) {
        _ = NSApplication.shared
        let suite = "TSX.ReleaseNotesWindowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        defaults.set("1.0.0", forKey: "TSXLastLaunchedReleaseVersion")
        let release = AppRelease(version: "1.1.0", publishedAt: .distantPast, notes: "Constructed release note",
                                 url: URL(string: "https://github.com/TheoYuuu/tsx/releases/tag/v1.1.0")!)
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                          currentVersion: release.version, defaults: defaults,
                                          recordsInstalledVersions: true, backend: UpdateBackendFixture(),
                                          releases: AppReleaseNotesStore(entries: [release], allowsNetworkLoading: false))
        let windows = try isolatedWindows()
        windows.updates = updates
        updates.onPresentReleaseNotes = { [weak windows] in windows?.showMainReleaseNotes() }
        return (windows, updates, defaults)
    }

    private func visibleMainWindow() throws -> NSWindow {
        try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.main" && $0.isVisible })
    }


    func testCleanLaunchDoesNotShowNotesEvenAfterUpdaterSetsItsLaunchFlag() throws {
        let suite = "TSX.CleanReleaseLaunchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = UpdateBackendFixture()
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                          currentVersion: "1.1.0", defaults: defaults,
                                          recordsInstalledVersions: true, backend: backend)
        defaults.set(true, forKey: "SUHasLaunchedBefore")
        updates.start()
        XCTAssertEqual(backend.calls, ["start", "information"])
        XCTAssertNil(updates.mainReleaseNotesPresentation)
        XCTAssertNil(updates.pendingReleaseNotesVersion)
    }

    func testLegacyReleaseUpgradeShowsNotesOnceWithoutNewerVersionMarkers() throws {
        let suite = "TSX.LegacyReleaseLaunchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "SUHasLaunchedBefore")
        func launch() -> AppUpdateController {
            let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                              currentVersion: "1.1.0", defaults: defaults,
                                              recordsInstalledVersions: true, backend: UpdateBackendFixture())
            updates.start()
            return updates
        }
        let upgraded = launch()
        XCTAssertEqual(upgraded.mainReleaseNotesPresentation, .installed(version: "1.1.0"))
        upgraded.dismissReleaseNotes(in: .mainWindow)
        XCTAssertNil(launch().mainReleaseNotesPresentation)
        XCTAssertEqual(defaults.string(forKey: "TSXAcknowledgedReleaseNotesVersion"), "1.1.0")
    }

    func testEachLaunchProbesWithoutDownloadingWhenAutomaticUpdatesAreOff() {
        let backend = UpdateBackendFixture()
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                          recordsInstalledVersions: false, backend: backend)
        updates.start()
        updates.start()
        XCTAssertEqual(backend.calls, ["start", "information"], "Only one launch probe per application lifecycle.")
        XCTAssertTrue(updates.isChecking)
        XCTAssertFalse(updates.automaticUpdatesEnabled)
        XCTAssertNil(updates.updatePresentation)
        updates.foundNoUpdate()
        XCTAssertFalse(updates.isChecking)
        XCTAssertTrue(updates.hasChecked)
    }

    func testAutomaticLaunchUsesSparkleInstallAndRelaunchReplies() {
        let backend = UpdateBackendFixture()
        backend.automaticallyChecksForUpdates = true
        backend.automaticallyDownloadsUpdates = true
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                          recordsInstalledVersions: false, backend: backend)
        updates.start()
        XCTAssertEqual(backend.calls, ["start", "update"])
        var downloadChoice: SPUUserUpdateChoice?
        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            userInitiated: true) { downloadChoice = $0 }
        XCTAssertNil(downloadChoice, "A navigation request must not start installation before the draft guard finishes.")
        updates.continueAutomaticUpdate()
        XCTAssertEqual(downloadChoice, .install)
        var installChoice: SPUUserUpdateChoice?
        updates.readyToInstall { installChoice = $0 }
        XCTAssertEqual(installChoice, .install)
    }

    func testAutomaticInstallWaitsForVisibleModalAndDoesNotReenterForSameVersion() {
        let backend = UpdateBackendFixture()
        backend.automaticallyChecksForUpdates = true
        backend.automaticallyDownloadsUpdates = true
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                          recordsInstalledVersions: false, backend: backend)
        var navigationRequests = 0
        updates.onPresentUpdate = { navigationRequests += 1 } // A draft keeps About from appearing.
        updates.start()
        var choices: [SPUUserUpdateChoice] = []
        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            userInitiated: true) { choices.append($0) }
        XCTAssertEqual(navigationRequests, 1)
        XCTAssertTrue(choices.isEmpty)
        // Only after the draft guard succeeds does the modal invoke this.
        updates.continueAutomaticUpdate()
        updates.continueAutomaticUpdate()
        XCTAssertEqual(choices, [.install])
        updates.installationDismissed()
        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            userInitiated: true) { choices.append($0) }
        updates.continueAutomaticUpdate()
        XCTAssertEqual(choices, [.install], "Reappearance must not silently start the same canceled candidate again.")
    }

    func testAutomaticInstallDoesNotStartWhenDisabledBeforeModalAppears() {
        let backend = UpdateBackendFixture()
        backend.automaticallyChecksForUpdates = true
        backend.automaticallyDownloadsUpdates = true
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                          recordsInstalledVersions: false, backend: backend)
        updates.start()
        var choices: [SPUUserUpdateChoice] = []
        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            userInitiated: true) { choices.append($0) }
        updates.setAutomaticUpdates(false)
        updates.continueAutomaticUpdate()
        updates.continueAutomaticUpdate()
        XCTAssertTrue(choices.isEmpty)
    }

    func testResumedReadyUpdateAlsoWaitsForVisibleModal() {
        let backend = UpdateBackendFixture()
        backend.automaticallyChecksForUpdates = true
        backend.automaticallyDownloadsUpdates = true
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                          recordsInstalledVersions: false, backend: backend)
        updates.start()
        updates.foundUpdate("2.0.0")
        var choice: SPUUserUpdateChoice?
        updates.readyToInstall { choice = $0 }
        XCTAssertNil(choice)
        updates.continueAutomaticUpdate()
        XCTAssertEqual(choice, .install)
    }

    func testManualUpdateWaitsForConfirmationAndThenUsesSparkleRelaunch() {
        let backend = UpdateBackendFixture()
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                          recordsInstalledVersions: false, backend: backend)
        updates.start()
        updates.foundUpdate("2.0.0")
        updates.finishedCheck()
        updates.performUpdateAction()
        var choice: SPUUserUpdateChoice?
        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            userInitiated: true) { choice = $0 }
        updates.continueAutomaticUpdate()
        XCTAssertNil(choice)
        XCTAssertEqual(updates.updatePresentation?.phase, .available)
        updates.installPendingUpdate()
        XCTAssertEqual(choice, .install)
        var installChoice: SPUUserUpdateChoice?
        updates.readyToInstall { installChoice = $0 }
        XCTAssertEqual(installChoice, .install)
    }

    func testInformationOnlyUpdatesNeverInvokeInstallEvenWhenAutomaticIsEnabled() {
        let backend = UpdateBackendFixture()
        backend.automaticallyChecksForUpdates = true
        backend.automaticallyDownloadsUpdates = true
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                          recordsInstalledVersions: false, backend: backend)
        updates.start()
        var choice: SPUUserUpdateChoice?
        updates.offerUpdate(version: "2.0.0", informationOnly: true,
                            informationURL: URL(string: "file:///untrusted"), userInitiated: false) { choice = $0 }
        updates.continueAutomaticUpdate()
        updates.installPendingUpdate()
        XCTAssertNil(choice)
        XCTAssertNil(updates.updatePresentation?.informationURL)
        updates.dismissUpdate()
        XCTAssertEqual(choice, .dismiss)
    }

    func testTurningOffAutomaticUpdatesCancelsDownloadAndDeclinesPendingInstallation() {
        let backend = UpdateBackendFixture()
        backend.automaticallyChecksForUpdates = true
        backend.automaticallyDownloadsUpdates = true
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                          recordsInstalledVersions: false, backend: backend)
        updates.start()
        var cancellations = 0
        updates.downloadStarted { cancellations += 1 }
        updates.setAutomaticUpdates(false)
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(backend.automaticallyChecksForUpdates)
        XCTAssertFalse(backend.automaticallyDownloadsUpdates)
        var choice: SPUUserUpdateChoice?
        updates.readyToInstall { choice = $0 }
        XCTAssertEqual(choice, .skip)
        XCTAssertNil(updates.updatePresentation)
    }

    func testProgressStaysIndeterminateUntilKnownAndClampsOversizedDownload() {
        let updates = AppUpdateController(bundleIdentifier: "preview", isTesting: true)
        updates.downloadStarted {}
        updates.downloadReceived(10)
        XCTAssertNil(updates.updatePresentation?.progress)
        updates.downloadExpected(100)
        XCTAssertEqual(updates.updatePresentation?.progress, 0.1)
        updates.downloadReceived(UInt64.max)
        XCTAssertEqual(updates.updatePresentation?.progress, 1)
        updates.extractionProgress(.nan)
        XCTAssertNil(updates.updatePresentation?.progress)
    }

    func testFirstInstallAndDebugBuildDoNotClaimAnUpgrade() throws {
        let suite = "TSX.UpdateLaunchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                        currentVersion: "1.0.0", defaults: defaults, recordsInstalledVersions: true)
        first.prepareInstalledReleaseNotes()
        XCTAssertNil(first.pendingReleaseNotesVersion)
        XCTAssertEqual(defaults.string(forKey: "TSXLastLaunchedReleaseVersion"), "1.0.0")
        let debug = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: false,
                                        currentVersion: "2.0.0", defaults: defaults, recordsInstalledVersions: false)
        debug.prepareInstalledReleaseNotes()
        debug.willInstallVersion("3.0.0")
        XCTAssertNil(debug.pendingReleaseNotesVersion)
        XCTAssertEqual(defaults.string(forKey: "TSXLastLaunchedReleaseVersion"), "1.0.0")
        XCTAssertNil(defaults.string(forKey: "TSXPendingInstalledReleaseVersion"))
    }

    func testInstalledNotesSurviveDismissalAndStopAfterAcknowledgement() throws {
        let suite = "TSX.UpdateAcknowledgementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let previous = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                           currentVersion: "1.0.0", defaults: defaults, recordsInstalledVersions: true)
        previous.willInstallVersion("1.1.0")
        func launch() -> AppUpdateController {
            let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                              currentVersion: "1.1.0", defaults: defaults, recordsInstalledVersions: true)
            updates.prepareInstalledReleaseNotes()
            return updates
        }
        let first = launch()
        XCTAssertEqual(first.pendingReleaseNotesVersion, "1.1.0")
        XCTAssertEqual(first.mainReleaseNotesPresentation, .installed(version: "1.1.0"))
        XCTAssertNil(first.releaseNotesPresentation)
        XCTAssertFalse(first.isPresentingModal)
        first.dismissReleaseNotes(in: .mainWindow, acknowledging: false)
        XCTAssertEqual(launch().pendingReleaseNotesVersion, "1.1.0")
        let acknowledged = launch()
        acknowledged.showRecentReleaseNotes()
        acknowledged.dismissReleaseNotes()
        XCTAssertEqual(acknowledged.pendingReleaseNotesVersion, "1.1.0", "Settings notes do not acknowledge a main-window overlay.")
        acknowledged.showRecentReleaseNotes(in: .mainWindow)
        XCTAssertEqual(acknowledged.mainReleaseNotesPresentation, .recent)
        acknowledged.dismissReleaseNotes(in: .mainWindow)
        XCTAssertNil(acknowledged.pendingReleaseNotesVersion)
        XCTAssertNil(launch().pendingReleaseNotesVersion)
    }

    func testSameVersionOrDowngradeDoesNotShowUpgradeNotes() throws {
        let suite = "TSX.UpdateVersionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for version in ["2.0.0", "1.0.0"] {
            defaults.set("2.0.0", forKey: "TSXLastLaunchedReleaseVersion")
            let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                              currentVersion: version, defaults: defaults, recordsInstalledVersions: true)
            updates.prepareInstalledReleaseNotes()
            XCTAssertNil(updates.pendingReleaseNotesVersion)
        }
    }
}
