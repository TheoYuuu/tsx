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
        XCTAssertEqual(info["SUFeedURL"] as? String, "https://updates.uuthings.com/tsx/macos/stable/appcast.xml")
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
    var onCheckUpdates: (() -> Void)?
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        automaticallyChecksForUpdates = defaults?.bool(forKey: "SUEnableAutomaticChecks") ?? false
        automaticallyDownloadsUpdates = defaults?.bool(forKey: "SUAutomaticallyUpdate") ?? false
    }
    func start() throws { calls.append("start") }
    func checkInformation() { calls.append("information") }
    func checkUpdates() { calls.append("update"); onCheckUpdates?() }
}

extension AppUpdateControllerTests {
    func testLaunchFailureIsSilentRegardlessOfAutomaticPreferenceAndCallbackOrder() {
        for automatic in [false, true] {
            for delegateFirst in [false, true] {
                let backend = UpdateBackendFixture()
                backend.automaticallyChecksForUpdates = automatic
                backend.automaticallyDownloadsUpdates = automatic
                let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false,
                    isReleaseBuild: true, recordsInstalledVersions: false, backend: backend)
                var presentations = 0
                updates.onPresentUpdate = { presentations += 1 }
                updates.start()
                if automatic { updates.showUpdateCheck(cancellation: {}) }
                let error = URLError(.timedOut)
                if delegateFirst { updates.checkAborted(error); updates.finishedCheck() }
                updates.updateErrored(error)
                if !delegateFirst { updates.checkAborted(error); updates.finishedCheck() }
                XCTAssertNil(updates.updatePresentation)
                XCTAssertEqual(presentations, 0)
                XCTAssertTrue(updates.lastCheckFailed)
                XCTAssertFalse(updates.hasChecked)
                XCTAssertTrue(updates.releases.failed)
                updates.checkForUpdates()
                updates.showUpdateCheck(cancellation: {})
                updates.updateErrored(error)
                XCTAssertEqual(updates.updatePresentation?.phase, .failed)
                XCTAssertEqual(updates.updatePresentation?.isCheckFailure, true)
            }
        }
    }

    func testCancelledCheckDoesNotResurfaceFromLateErrorCallbacks() {
        let (updates, _) = aboutUpdateFixture()
        updates.checkForUpdates()
        updates.showUpdateCheck(cancellation: {})
        updates.dismissUpdate()
        updates.finishedCheck()
        updates.updateErrored(URLError(.cancelled))
        XCTAssertNil(updates.updatePresentation)
    }

    func testAutomaticInstallationFailureIsVisibleEvenAfterPresentationIsDismissed() {
        let backend = UpdateBackendFixture()
        backend.automaticallyDownloadsUpdates = true
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false,
            isReleaseBuild: true, recordsInstalledVersions: false, backend: backend)
        updates.start()
        updates.downloadStarted(cancellation: {})
        updates.installationDismissed()
        updates.finishedCheck()
        updates.updateErrored(URLError(.timedOut))
        XCTAssertEqual(updates.updatePresentation?.phase, .failed)
        XCTAssertEqual(updates.updatePresentation?.isCheckFailure, false)
    }

    func testReleaseNotesReuseCurrentCheckAndRetryOnlyProbesInformation() async {
        let backend = UpdateBackendFixture()
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false,
            isReleaseBuild: true, recordsInstalledVersions: false, backend: backend)
        updates.start()
        await updates.loadReleaseNotes(force: true)
        XCTAssertEqual(backend.calls, ["start", "information"])
        updates.checkAborted(URLError(.timedOut)); updates.finishedCheck()
        await updates.loadReleaseNotes(force: true)
        await updates.loadReleaseNotes(force: true)
        XCTAssertEqual(backend.calls, ["start", "information", "information"])
        XCTAssertNil(updates.updatePresentation)
    }

    func testManualCheckReplacesCompactDialogWithExistingOffer() {
        let (updates, _) = aboutUpdateFixture()
        updates.performUpdateAction()
        var cancellations = 0
        updates.showUpdateCheck { cancellations += 1 }
        updates.presentUpdateInMainWindow()
        XCTAssertEqual(updates.updatePresentation?.phase, .checking)
        XCTAssertEqual(updates.updatePresentation?.usesCheckDialog, true)
        XCTAssertTrue(updates.showsMainUpdate)
        var choice: SPUUserUpdateChoice?
        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            userInitiated: true) { choice = $0 }
        XCTAssertEqual(updates.updatePresentation?.phase, .available)
        XCTAssertEqual(updates.updatePresentation?.usesCheckDialog, false)
        XCTAssertTrue(updates.showsMainUpdate)
        XCTAssertNil(choice)
        updates.dismissUpdate()
        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(cancellations, 0, "Closing an offer must not cancel the completed check.")
    }

    func testKnownVersionCheckFailureUsesCompactDialogAndCanRetry() {
        let (updates, backend) = aboutUpdateFixture()
        updates.performUpdateAction()
        updates.showUpdateCheck(cancellation: {})
        updates.updateErrored()
        XCTAssertEqual(updates.updatePresentation?.version, "2.0.0")
        XCTAssertEqual(updates.updatePresentation?.usesCheckDialog, true)
        updates.retryUpdate()
        XCTAssertNil(updates.updatePresentation)
        XCTAssertEqual(backend.calls.filter { $0 == "update" }.count, 2)
        updates.showUpdateCheck(cancellation: {})
        updates.updateNotFound()
        XCTAssertEqual(updates.updatePresentation?.phase, .current)
        XCTAssertEqual(updates.updatePresentation?.usesCheckDialog, true)
        updates.dismissUpdate()
        XCTAssertNil(updates.updatePresentation)
    }

    func testRepeatedRetryDoesNotCancelOrRestartTheNewCheck() {
        for location in [AppUpdateLocation.mainWindow, .settings] {
            let (updates, backend) = aboutUpdateFixture()
            updates.performUpdateAction(in: location)
            updates.showUpdateCheck(cancellation: {})
            updates.updateErrored(URLError(.timedOut))

            updates.retryUpdate()
            updates.retryUpdate()
            XCTAssertEqual(backend.calls.filter { $0 == "update" }.count, 2)
            XCTAssertTrue(updates.isChecking)
            XCTAssertNil(updates.updatePresentation)

            var cancellations = 0
            updates.showUpdateCheck { cancellations += 1; updates.finishedCheck() }
            updates.retryUpdate()
            XCTAssertEqual(updates.updatePresentation?.phase, .checking)
            XCTAssertEqual(updates.updateLocation, location)
            XCTAssertEqual(cancellations, 0, "A repeated retry cannot cancel its replacement check.")
            XCTAssertEqual(backend.calls.filter { $0 == "update" }.count, 2)
            XCTAssertNil(updates.updatePresentation?.failure)
            updates.dismissUpdate()
            XCTAssertEqual(cancellations, 1)
        }
    }

    func testRetryDoesNotDismissAnOfferOrAnActiveDownload() {
        let (updates, backend) = aboutUpdateFixture()
        var choices: [SPUUserUpdateChoice] = []
        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            userInitiated: true) { choices.append($0) }
        updates.retryUpdate()
        XCTAssertEqual(updates.updatePresentation?.phase, .available)
        XCTAssertTrue(choices.isEmpty)

        var cancellations = 0
        updates.downloadStarted { cancellations += 1 }
        updates.retryUpdate()
        XCTAssertEqual(updates.updatePresentation?.phase, .downloading)
        XCTAssertEqual(cancellations, 0)
        XCTAssertEqual(backend.calls, ["start", "information"])
    }

    func testUpdateFailureUsesSafeCodesWithoutEchoingSDKMetadata() {
        let privateMarker = "constructed-update-error-metadata"
        let underlying = NSError(domain: NSURLErrorDomain, code: URLError.networkConnectionLost.rawValue,
            userInfo: [NSLocalizedDescriptionKey: privateMarker,
                       NSURLErrorFailingURLStringErrorKey: "https://example.invalid/\(privateMarker)"])
        let wrapped = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.downloadError.rawValue),
            userInfo: [NSLocalizedDescriptionKey: privateMarker,
                       NSFilePathErrorKey: "/constructed/\(privateMarker)", NSUnderlyingErrorKey: underlying])
        let updates = AppUpdateController(bundleIdentifier: "preview", isTesting: true)
        updates.downloadStarted {}
        updates.updateErrored(wrapped)
        XCTAssertEqual(updates.updatePresentation?.failure, .networkUnavailable)
        XCTAssertEqual(updates.updatePresentation?.errorMessage, AppUpdateFailure.networkUnavailable.message)
        XCTAssertFalse(updates.updatePresentation?.errorMessage?.contains(privateMarker) ?? true)
        XCTAssertTrue(updates.updatePresentation?.errorMessage?.contains("VPN") == true,
                      "A classified network error offers a useful, safely generated recovery explanation.")
        XCTAssertEqual(updates.updatePresentation?.usesCheckDialog, false)

        updates.showUpdateCheck(cancellation: {})
        updates.updateErrored(wrapped)
        XCTAssertEqual(updates.updatePresentation?.usesCheckDialog, true)
        XCTAssertEqual(updates.updatePresentation?.failure, .networkUnavailable)

        updates.updateErrored(NSError(domain: "ConstructedUnknownUpdateError", code: 1,
                                     userInfo: [NSLocalizedDescriptionKey: privateMarker]))
        XCTAssertNil(updates.updatePresentation?.failure)
        XCTAssertNil(updates.updatePresentation?.errorMessage, "Unknown descriptions must use the UI's fixed fallback.")
    }

    func testUpdateVerificationAndStorageFailuresHaveFixedRecoveryMessages() {
        for code in [SUError.signatureError, .validationError, .unarchivingError, .notValidUpdateError] {
            XCTAssertEqual(AppUpdateFailure.classify(NSError(domain: SUSparkleErrorDomain, code: Int(code.rawValue))),
                           .invalidUpdate)
        }
        let storage = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteOutOfSpace.rawValue)
        XCTAssertEqual(AppUpdateFailure.classify(storage), .insufficientSpace)
        let wrapped = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.downloadError.rawValue),
                              userInfo: [NSUnderlyingErrorKey: storage])
        XCTAssertEqual(AppUpdateFailure.classify(wrapped), .insufficientSpace)
        XCTAssertNil(AppUpdateFailure.classify(NSError(domain: "ConstructedUnknownDomain",
                                                       code: Int(SUError.signatureError.rawValue))),
                     "A matching numeric code from another domain must not invent a verification failure.")
    }

    func testCheckFailureMessageSurvivesSparkleDelegateAndCompletionCallbacks() {
        let error = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.appcastError.rawValue),
                            userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)])
        for delegateFirst in [false, true] {
            let updates = AppUpdateController(bundleIdentifier: "preview", isTesting: true)
            updates.showUpdateCheck(cancellation: {})
            if delegateFirst { updates.checkAborted(error) }
            updates.updateErrored(error)
            if !delegateFirst { updates.checkAborted(error) }
            updates.finishedCheck()
            updates.installationDismissed()
            XCTAssertEqual(updates.updatePresentation?.phase, .failed)
            XCTAssertEqual(updates.updatePresentation?.usesCheckDialog, true)
            XCTAssertEqual(updates.updatePresentation?.failure, .networkUnavailable)
            XCTAssertEqual(updates.updatePresentation?.errorMessage, AppUpdateFailure.networkUnavailable.message)
        }
    }

    func testDownloadAndInstallFailuresKeepExistingPresentation() {
        for phase in [AppUpdatePresentation.Phase.downloading, .extracting, .installing] {
            let (updates, _) = aboutUpdateFixture()
            updates.performUpdateAction()
            updates.showUpdateCheck(cancellation: {})
            updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                                userInitiated: true, reply: { _ in })
            switch phase {
            case .downloading: updates.downloadStarted {}
            case .extracting: updates.extractionStarted()
            default: updates.installing()
            }
            updates.updateErrored()
            XCTAssertEqual(updates.updatePresentation?.phase, .failed)
            XCTAssertEqual(updates.updatePresentation?.usesCheckDialog, false)
        }
    }

    func testCompactCheckCancelRunsCancellationOnceAndClosesModal() {
        let (updates, _) = aboutUpdateFixture()
        updates.performUpdateAction()
        var cancellations = 0
        updates.showUpdateCheck { cancellations += 1; updates.finishedCheck() }
        updates.presentUpdateInMainWindow()
        updates.dismissUpdate()
        updates.dismissUpdate()
        XCTAssertEqual(cancellations, 1)
        XCTAssertNil(updates.updatePresentation)
        XCTAssertFalse(updates.isPresentingMainModal)
        XCTAssertFalse(updates.isChecking)
    }

    private func aboutUpdateFixture() -> (AppUpdateController, UpdateBackendFixture) {
        let backend = UpdateBackendFixture()
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                          recordsInstalledVersions: false, backend: backend)
        updates.start()
        updates.foundUpdate("2.0.0")
        updates.finishedCheck()
        return (updates, backend)
    }

    func testAboutUpdateDownloadsAndInstallsWithOneActionWithoutChangingAutomaticPreference() {
        let (updates, backend) = aboutUpdateFixture()
        var locations: [AppUpdateLocation] = []
        updates.onPresentUpdate = { locations.append(updates.updateLocation) }
        updates.performUpdateAction(in: .settings)
        updates.performUpdateAction(in: .settings)
        updates.showUpdateCheck(cancellation: {})
        var choices: [SPUUserUpdateChoice] = []
        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            userInitiated: true) { choices.append($0) }
        XCTAssertEqual(backend.calls, ["start", "information", "update"])
        XCTAssertEqual(choices, [.install])
        XCTAssertTrue(updates.showsSettingsUpdate)
        XCTAssertFalse(updates.showsMainUpdate)
        updates.downloadStarted {}
        updates.extractionStarted()
        updates.readyToInstall { choices.append($0) }
        XCTAssertEqual(choices, [.install, .install])
        XCTAssertEqual(locations, [.settings])
        XCTAssertFalse(updates.automaticUpdatesEnabled)
        XCTAssertFalse(backend.automaticallyChecksForUpdates)
        updates.installing()
        updates.installationDismissed()
        XCTAssertFalse(updates.showsSettingsUpdate)
    }

    func testAboutCheckWithoutKnownVersionOnlyChecksAndDoesNotAuthorizeInstallation() {
        let (updates, backend) = aboutUpdateFixture()
        updates.foundNoUpdate()
        updates.performUpdateAction(in: .settings)
        XCTAssertEqual(backend.calls, ["start", "information", "update"])
        var choice: SPUUserUpdateChoice?
        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            userInitiated: true) { choice = $0 }
        XCTAssertNil(choice)
        XCTAssertTrue(updates.showsSettingsUpdate)
        updates.installPendingUpdate()
        XCTAssertEqual(choice, .install)
        XCTAssertFalse(updates.showsMainUpdate)
    }

    func testAboutUnknownVersionUsesTheVisibleCheckPathForCurrentAndFailureResults() {
        for fails in [false, true] {
            let (updates, backend) = aboutUpdateFixture()
            updates.foundNoUpdate()
            XCTAssertNil(updates.availableVersion)
            var checkingPresentations = 0
            var cancellations = 0
            updates.onPresentUpdate = { [weak updates] in
                if let updates, updates.updatePresentation?.phase == .checking {
                    checkingPresentations += 1
                    XCTAssertTrue(updates.showsSettingsUpdate)
                    XCTAssertEqual(updates.updatePresentation?.usesCheckDialog, true)
                }
            }
            backend.onCheckUpdates = { [weak updates] in
                guard let updates else { return }
                updates.showUpdateCheck { cancellations += 1 }
                if fails { updates.updateErrored(URLError(.timedOut)) }
                else { updates.updateNotFound() }
                updates.finishedCheck()
            }

            updates.performUpdateAction(in: .settings)

            XCTAssertEqual(backend.calls, ["start", "information", "update"],
                           "The About action uses the cancellable user-driver path; only launch uses the information probe.")
            XCTAssertEqual(checkingPresentations, 1)
            XCTAssertEqual(updates.updatePresentation?.phase, fails ? .failed : .current)
            XCTAssertEqual(updates.updatePresentation?.usesCheckDialog, true)
            XCTAssertTrue(updates.showsSettingsUpdate)
            XCTAssertFalse(updates.showsMainUpdate)
            XCTAssertFalse(updates.isChecking)
            updates.dismissUpdate()
            XCTAssertNil(updates.updatePresentation)
            XCTAssertEqual(cancellations, 0, "Closing a completed check must not cancel a finished request.")
        }
    }

    func testAboutDoesNotAutomaticallyInstallAChangedCandidateOrInformationOnlyUpdate() {
        for (version, informationOnly) in [("2.0.1", false), ("2.0.0", true)] {
            let (updates, _) = aboutUpdateFixture()
            updates.performUpdateAction(in: .settings)
            var choice: SPUUserUpdateChoice?
            updates.offerUpdate(version: version, informationOnly: informationOnly,
                                informationURL: URL(string: "https://example.invalid/update"),
                                userInitiated: true) { choice = $0 }
            updates.continueAutomaticUpdate()
            XCTAssertNil(choice)
            XCTAssertTrue(updates.showsSettingsUpdate)
            XCTAssertFalse(updates.showsMainUpdate)
        }
    }

    func testAboutCancellationClearsThePendingDirectInstallIntent() {
        let (updates, _) = aboutUpdateFixture()
        updates.performUpdateAction(in: .settings)
        var cancellations = 0
        updates.showUpdateCheck { cancellations += 1 }
        updates.dismissUpdate()
        XCTAssertEqual(cancellations, 1)
        var choice: SPUUserUpdateChoice?
        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            userInitiated: true) { choice = $0 }
        XCTAssertNil(choice, "A late offer cannot reuse canceled install intent.")
    }

    func testAboutCheckFailureRetryWaitsForConfirmationEvenWithKnownVersion() {
        let (updates, backend) = aboutUpdateFixture()
        updates.performUpdateAction(in: .settings)
        updates.showUpdateCheck(cancellation: {})
        updates.updateErrored()
        XCTAssertEqual(updates.updatePresentation?.phase, .failed)
        XCTAssertTrue(updates.showsSettingsUpdate)
        XCTAssertEqual(backend.calls.filter { $0 == "update" }.count, 1)
        updates.retryUpdate()
        var choices: [SPUUserUpdateChoice] = []
        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            userInitiated: true) { choices.append($0) }
        XCTAssertTrue(choices.isEmpty, "Retrying a check must not restore the earlier direct-install intent.")
        XCTAssertEqual(updates.updatePresentation?.phase, .available)
        XCTAssertTrue(updates.showsSettingsUpdate)
        XCTAssertFalse(updates.showsMainUpdate)
        XCTAssertEqual(backend.calls.filter { $0 == "update" }.count, 2)
        updates.continueAutomaticUpdate()
        XCTAssertTrue(choices.isEmpty)
        updates.installPendingUpdate()
        XCTAssertEqual(choices, [.install], "The offered version waits for a new Update now action.")
        updates.downloadStarted {}
        updates.updateErrored()
        updates.readyToInstall { choices.append($0) }
        XCTAssertEqual(choices, [.install], "A failed attempt cannot authorize a late installation reply.")
    }

    func testAboutInstallationFailureRetryPreservesExplicitInstallAction() {
        let (updates, backend) = aboutUpdateFixture()
        updates.performUpdateAction(in: .settings)
        var choices: [SPUUserUpdateChoice] = []
        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            userInitiated: true) { choices.append($0) }
        XCTAssertEqual(choices, [.install])
        updates.downloadStarted {}
        updates.updateErrored(URLError(.networkConnectionLost))
        XCTAssertEqual(updates.updatePresentation?.isCheckFailure, false)

        updates.retryUpdate()
        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            userInitiated: true) { choices.append($0) }
        XCTAssertEqual(choices, [.install, .install])
        XCTAssertEqual(backend.calls.filter { $0 == "update" }.count, 2)
        XCTAssertTrue(updates.showsSettingsUpdate)
        XCTAssertFalse(updates.showsMainUpdate)
    }

    func testMainEntryRefocusesAnAboutDownloadWithoutMovingItOrRestartingIt() {
        let (updates, backend) = aboutUpdateFixture()
        updates.performUpdateAction(in: .settings)
        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            userInitiated: true, reply: { _ in })
        updates.downloadStarted {}
        var focusedLocation: AppUpdateLocation?
        updates.onPresentUpdate = { focusedLocation = updates.updateLocation }
        updates.performUpdateAction()
        updates.checkForUpdates()
        XCTAssertEqual(focusedLocation, .settings)
        XCTAssertEqual(backend.calls.filter { $0 == "update" }.count, 1)
        XCTAssertFalse(updates.showsMainUpdate)
    }

    func testAboutUsesAnExistingReadyReplyWithoutCheckingOrConfirmingAgain() {
        let (updates, backend) = aboutUpdateFixture()
        var choices: [SPUUserUpdateChoice] = []
        updates.readyToInstall { choices.append($0) }
        updates.presentUpdateInMainWindow()
        XCTAssertTrue(updates.showsMainUpdate)
        updates.performUpdateAction(in: .settings)
        updates.performUpdateAction(in: .settings)
        XCTAssertEqual(choices, [.install])
        XCTAssertTrue(updates.showsSettingsUpdate)
        XCTAssertFalse(updates.showsMainUpdate)
        XCTAssertEqual(backend.calls, ["start", "information"])
    }

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


    func testSettingsUpdateModalCoversGlassEdgesAndTracksPresentationLifecycle() async throws {
        let monitor = try isolateUnscriptedWindowInput()
        defer { NSEvent.removeMonitor(monitor) }
        let windows = try isolatedWindows()
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                          recordsInstalledVersions: false, backend: UpdateBackendFixture(),
                                          releases: AppReleaseNotesStore(entries: [], allowsNetworkLoading: false))
        windows.updates = updates
        updates.start()
        updates.finishedCheck()
        defer { windows.shutdown() }
        windows.preferences.material = .glass
        let shortcuts = ShortcutSettings(preferences: windows.preferences, manager: ShortcutManager(),
                                         onAction: { _ in }, onBindingsChanged: {})
        // Presentation may be requested before the settings window is created.
        updates.showRecentReleaseNotes()
        windows.showSettings(shortcuts: shortcuts)
        windows.showAbout()
        let window = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.settings" && $0.isVisible })
        defer { window.close() }
        let surface = try XCTUnwrap(window.contentView as? WindowSurface<SettingsView>)
        let contentParent = surface.hostingView.superview
        let overlay = try XCTUnwrap(surface.modalHostingView)
        XCTAssertTrue(surface.subviews.last === overlay, "Dim above native glass edge highlights.")
        XCTAssertTrue(overlay.superview === surface)
        for size in [NSSize(width: 900, height: 600), NSSize(width: 1600, height: 1000)] {
            window.setContentSize(size)
            surface.layoutSubtreeIfNeeded()
            XCTAssertEqual(overlay.frame, surface.bounds)
            XCTAssertTrue(surface.hostingView.superview === contentParent)
        }
        updates.dismissReleaseNotes()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertNil(surface.modalHostingView)
        XCTAssertTrue(window.contentView === surface)

        updates.checkForUpdates(in: .settings)
        updates.showUpdateCheck(cancellation: {})
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(updates.showsSettingsUpdate)
        XCTAssertTrue(surface.subviews.last === surface.modalHostingView)
        XCTAssertNotNil(surface.modalHostingView)
        updates.dismissUpdate()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertNil(surface.modalHostingView)
        XCTAssertTrue(surface.hostingView.superview === contentParent)
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

    func testDownloadPresentationPublishesBytesBeforeTotalIsKnownAndResetsBetweenPhases() {
        let updates = AppUpdateController(bundleIdentifier: "preview", isTesting: true)
        updates.downloadStarted {}
        let initial = updates.updatePresentation
        XCTAssertEqual(initial?.downloadedBytes, 0)
        XCTAssertNil(initial?.totalDownloadBytes)

        updates.downloadReceived(10)
        XCTAssertEqual(updates.updatePresentation?.downloadedBytes, 10)
        XCTAssertNil(updates.updatePresentation?.totalDownloadBytes)
        XCTAssertNil(updates.updatePresentation?.progress)
        XCTAssertNotEqual(updates.updatePresentation, initial,
                          "Byte-only changes must update the observable presentation even without a known total.")

        updates.downloadExpected(100)
        XCTAssertEqual(updates.updatePresentation?.totalDownloadBytes, 100)
        XCTAssertEqual(updates.updatePresentation?.downloadedBytes, 10)
        XCTAssertEqual(updates.updatePresentation?.progress, 0.1)
        updates.downloadReceived(UInt64.max)
        XCTAssertEqual(updates.updatePresentation?.downloadedBytes, UInt64.max)
        XCTAssertEqual(updates.updatePresentation?.progress, 1)

        updates.extractionStarted()
        XCTAssertEqual(updates.updatePresentation?.downloadedBytes, 0)
        XCTAssertNil(updates.updatePresentation?.totalDownloadBytes)
        updates.updateErrored(URLError(.timedOut))
        XCTAssertNotNil(updates.updatePresentation?.errorMessage)
        updates.downloadStarted {}
        XCTAssertEqual(updates.updatePresentation?.downloadedBytes, 0)
        XCTAssertNil(updates.updatePresentation?.totalDownloadBytes)
        XCTAssertNil(updates.updatePresentation?.errorMessage)
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
