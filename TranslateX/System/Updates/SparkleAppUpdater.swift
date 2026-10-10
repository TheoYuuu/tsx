import AppKit
import Combine
import Sparkle

/// Only the user driver is customized. Sparkle's signed appcast, archive
/// verification, privileged installer and normal AppKit termination stay intact.
@MainActor
final class SparkleAppUpdater: NSObject, AppUpdaterBackend {
    private let updater: SPUUpdater
    private let updateDelegate: AppSparkleDelegate
    private let userDriver: AppSparkleUserDriver
    private var subscriptions = Set<AnyCancellable>()
    private weak var owner: AppUpdateController?

    init(owner: AppUpdateController) {
        self.owner = owner
        updateDelegate = AppSparkleDelegate(owner: owner)
        userDriver = AppSparkleUserDriver(owner: owner)
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: userDriver, delegate: updateDelegate)
        super.init()
        updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).sink { [weak owner] _ in
            MainActor.assumeIsolated { owner?.refreshUpdaterState() }
        }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main).sink { [weak owner] _ in
            MainActor.assumeIsolated { owner?.refreshUpdaterState() }
        }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyDownloadsUpdates).receive(on: RunLoop.main).sink { [weak owner] _ in
            MainActor.assumeIsolated { owner?.refreshUpdaterState() }
        }.store(in: &subscriptions)
    }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }
    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }
    func start() throws { try updater.start() }
    func checkInformation() { updater.checkForUpdateInformation() }
    func checkUpdates() { updater.checkForUpdates() }
    @objc func menuCheckForUpdates() { owner?.checkForUpdates() }
}

@MainActor
private final class AppSparkleDelegate: NSObject, SPUUpdaterDelegate {
    private weak var owner: AppUpdateController?
    init(owner: AppUpdateController) { self.owner = owner }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // This product checks on launch and on demand. Keep those sessions on
        // the cancellable user-driver path: Sparkle's separate background
        // driver can commit an install-on-quit after the preference is disabled.
        if updateCheck == .updatesInBackground {
            throw NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue),
                          userInfo: [NSLocalizedDescriptionKey: "Update checks run at launch or on request."])
        }
    }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool { false }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        owner?.foundUpdate(item.displayVersionString, publishedAt: item.date)
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { owner?.foundNoUpdate() }
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) { owner?.checkAborted(error) }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) { owner?.finishedCheck() }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { owner?.willInstallVersion(item.displayVersionString) }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard let owner, owner.automaticUpdatesEnabled else { return false }
        owner.foundUpdate(item.displayVersionString, publishedAt: item.date)
        // This is Sparkle's supported immediate-install hook, not a custom quit
        // or installer. A resumed installation must also wait until About is
        // actually visible, so navigating there cannot discard a live draft.
        owner.readyToInstall { [weak owner] choice in
            guard choice == .install else { return }
            owner?.willInstallVersion(item.displayVersionString)
            owner?.installing()
            Task { @MainActor in immediateInstallHandler() }
        }
        return true
    }
}

@MainActor
private final class AppSparkleUserDriver: NSObject, SPUUserDriver {
    private weak var owner: AppUpdateController?
    init(owner: AppUpdateController) { self.owner = owner }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        let enabled = owner?.automaticUpdatesEnabled == true
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: enabled, automaticUpdateDownloading: NSNumber(value: enabled), sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { owner?.showUpdateCheck(cancellation: cancellation) }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let owner else { reply(.dismiss); return }
        owner.offerUpdate(version: appcastItem.displayVersionString, informationOnly: appcastItem.isInformationOnlyUpdate,
                          informationURL: appcastItem.infoURL, publishedAt: appcastItem.date,
                          userInitiated: state.userInitiated, reply: reply)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Release history uses the fixed public repository feed. Sparkle's
        // downloaded HTML is never executed inside the settings interface.
    }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        owner?.updateNotFound(); acknowledgement()
    }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        owner?.updateErrored(); acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { owner?.downloadStarted(cancellation: cancellation) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { owner?.downloadExpected(expectedContentLength) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { owner?.downloadReceived(length) }
    func showDownloadDidStartExtractingUpdate() { owner?.extractionStarted() }
    func showExtractionReceivedProgress(_ progress: Double) { owner?.extractionProgress(progress) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let owner else { reply(.skip); return }
        owner.readyToInstall(reply: reply)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { owner?.installing() }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() { owner?.installationDismissed() }
    func showUpdateInFocus() { owner?.focusUpdate() }
}
