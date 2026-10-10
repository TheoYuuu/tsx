import AppKit
import Observation
import Sparkle

@MainActor
protocol AppUpdaterBackend: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    func start() throws
    func checkInformation()
    func checkUpdates()
}

struct AppUpdatePresentation: Equatable {
    enum Phase { case checking, available, downloading, extracting, ready, installing, failed, current }
    var version: String?
    var phase: Phase
    var progress: Double?
    var informationURL: URL?
    var informationOnly = false
}

enum AppReleaseNotesMode: Equatable {
    case recent
    case installed(version: String)
}

enum AppReleaseNotesLocation { case settings, mainWindow }

/// Sparkle owns feed/archive verification, installation, authorization and relaunch.
/// The app only chooses when to probe and supplies the shared main-window presentation.
@MainActor
@Observable
final class AppUpdateController {
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var automaticallyDownloadsUpdates = false
    private(set) var started = false
    private(set) var availableVersion: String?
    private(set) var hasChecked = false
    private(set) var isChecking = false
    private(set) var lastCheckFailed = false
    private(set) var updatePresentation: AppUpdatePresentation?
    private var mainUpdatePresentationApproved = false
    private(set) var pendingReleaseNotesVersion: String?
    private(set) var releaseNotesPresentation: AppReleaseNotesMode?
    private(set) var mainReleaseNotesPresentation: AppReleaseNotesMode?
    let currentVersion: String
    let isAvailable: Bool
    let releases: AppReleaseNotesStore
    var automaticUpdatesEnabled: Bool { automaticallyDownloadsUpdates }
    var isPresentingModal: Bool { updatePresentation != nil || releaseNotesPresentation != nil }
    var showsMainUpdate: Bool { mainUpdatePresentationApproved && updatePresentation != nil }
    var isPresentingMainModal: Bool { showsMainUpdate || mainReleaseNotesPresentation != nil }
    @ObservationIgnored var onPresentUpdate: (() -> Void)?
    @ObservationIgnored var onPresentReleaseNotes: (() -> Void)?
    @ObservationIgnored private var backend: (any AppUpdaterBackend)?
    @ObservationIgnored private var nativeBackend: SparkleAppUpdater?
    @ObservationIgnored private lazy var menuTarget = AppUpdateMenuTarget(owner: self)
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let recordsInstalledVersions: Bool
    @ObservationIgnored private let hadLegacyLaunch: Bool
    @ObservationIgnored private var updateReply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var cancellation: (() -> Void)?
    @ObservationIgnored private var automaticSession = false
    @ObservationIgnored private var automaticInstallAttemptedVersion: String?
    @ObservationIgnored private var installRequested = false
    @ObservationIgnored private var expectedDownloadBytes: UInt64 = 0
    @ObservationIgnored private var receivedDownloadBytes: UInt64 = 0

    static var isReleaseBuild: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier,
         isTesting: Bool = NSClassFromString("XCTestCase") != nil,
         isReleaseBuild: Bool = AppUpdateController.isReleaseBuild,
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
         defaults: UserDefaults = .standard,
         recordsInstalledVersions: Bool = AppUpdateController.isReleaseBuild,
         backend: (any AppUpdaterBackend)? = nil,
         releases: AppReleaseNotesStore? = nil) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.recordsInstalledVersions = recordsInstalledVersions
        // Capture before starting Sparkle: 1.0.0 only persisted this launch marker.
        hadLegacyLaunch = defaults.bool(forKey: "SUHasLaunchedBefore")
        self.backend = backend
        // A release update must never replace Xcode's development product.
        let available = bundleIdentifier == "com.lumax.tsx" && !isTesting && isReleaseBuild
        self.releases = releases ?? AppReleaseNotesStore(allowsNetworkLoading: available)
        isAvailable = available
    }

    func start() {
        guard !started, startBackend(), let backend else { return }
        prepareInstalledReleaseNotes()
        // A launch always checks, including when installation is disabled. The
        // information-only API cannot download or install an update.
        automaticSession = automaticUpdatesEnabled
        isChecking = true
        if automaticSession { backend.checkUpdates() }
        else { backend.checkInformation() }
    }

    private func startBackend() -> Bool {
        guard isAvailable else { return false }
        if started { return true }
        if backend == nil {
            let native = SparkleAppUpdater(owner: self)
            nativeBackend = native
            backend = native
        }
        guard let backend else { return false }
        do { try backend.start() }
        catch { checkFailed(); return false }
        started = true
        refreshUpdaterState()
        return true
    }

    func refreshUpdaterState() {
        guard isAvailable, let backend else { return }
        canCheckForUpdates = backend.canCheckForUpdates
        automaticallyChecksForUpdates = backend.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = backend.automaticallyDownloadsUpdates
    }

    func checkForUpdates() {
        guard started, canCheckForUpdates else { return }
        automaticSession = false
        lastCheckFailed = false
        isChecking = true
        backend?.checkUpdates()
    }

    func performUpdateAction() {
        if updatePresentation != nil { onPresentUpdate?(); return }
        guard started, canCheckForUpdates else { return }
        if availableVersion != nil { checkForUpdates() }
        else {
            automaticSession = false
            lastCheckFailed = false
            isChecking = true
            backend?.checkInformation()
        }
    }

    func setAutomaticUpdates(_ enabled: Bool) {
        guard isAvailable, let backend else { return }
        // Sparkle persists these preferences; there is no second copy of them.
        if enabled {
            backend.automaticallyChecksForUpdates = true
            backend.automaticallyDownloadsUpdates = true
        } else {
            backend.automaticallyDownloadsUpdates = false
            backend.automaticallyChecksForUpdates = false
        }
        refreshUpdaterState()
        if !enabled, automaticSession {
            let cancel = cancellation
            cancellation = nil
            cancel?()
        }
    }

    // Kept for the existing menu/settings integration while the two controls
    // migrate to the single automatic-update preference.
    func setAutomaticChecks(_ enabled: Bool) { setAutomaticUpdates(enabled) }
    func setAutomaticDownloads(_ enabled: Bool) { setAutomaticUpdates(enabled) }

    func foundUpdate(_ version: String) {
        availableVersion = version; hasChecked = true; lastCheckFailed = false
    }
    func foundNoUpdate() {
        availableVersion = nil; hasChecked = true; lastCheckFailed = false; isChecking = false
    }
    func checkFailed() { lastCheckFailed = true; isChecking = false }
    func checkAborted(_ error: any Error) {
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue) { foundNoUpdate() }
        else if error.domain != SUSparkleErrorDomain || error.code != Int(SUError.installationCanceledError.rawValue) { checkFailed() }
        else { isChecking = false }
    }
    func finishedCheck() { isChecking = false; refreshUpdaterState() }

    func installPendingUpdate() {
        guard updatePresentation?.informationOnly == false, let reply = updateReply else { return }
        updateReply = nil
        installRequested = true
        reply(.install)
    }

    /// Called only after the window coordinator has passed the settings draft
    /// guard. A pending update alone must not mount a modal or trigger a restart.
    func presentUpdateInMainWindow() {
        guard updatePresentation != nil else { return }
        mainUpdatePresentationApproved = true
    }

    /// The visible main-window modal continues automatic installation only
    /// after the settings draft guard has accepted the window handoff.
    func continueAutomaticUpdate() {
        guard automaticSession, automaticUpdatesEnabled, !installRequested,
              let presentation = updatePresentation,
              [.available, .ready].contains(presentation.phase),
              !presentation.informationOnly, let version = presentation.version,
              automaticInstallAttemptedVersion != version, updateReply != nil else { return }
        automaticInstallAttemptedVersion = version
        installPendingUpdate()
    }

    func dismissUpdate() {
        guard let presentation = updatePresentation else { return }
        if [.extracting, .installing].contains(presentation.phase) { return }
        let cancel = cancellation
        cancellation = nil
        let reply = updateReply
        updateReply = nil
        updatePresentation = nil
        cancel?()
        reply?(presentation.phase == .ready ? .skip : .dismiss)
        installRequested = false
    }

    func showUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        if !automaticSession { present(.init(phase: .checking)) }
    }

    func offerUpdate(version: String, informationOnly: Bool, informationURL: URL?,
                     userInitiated: Bool, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        foundUpdate(version)
        isChecking = false
        cancellation = nil
        updateReply = reply
        if !userInitiated { automaticSession = automaticUpdatesEnabled }
        let safeURL = informationURL?.scheme == "https" ? informationURL : nil
        present(.init(version: version, phase: .available, informationURL: safeURL, informationOnly: informationOnly))
    }

    func downloadStarted(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        receivedDownloadBytes = 0; expectedDownloadBytes = 0
        setPhase(.downloading, progress: nil)
        if automaticSession, !automaticUpdatesEnabled { dismissUpdate() }
    }
    func downloadExpected(_ bytes: UInt64) { expectedDownloadBytes = bytes; updateDownloadProgress() }
    func downloadReceived(_ bytes: UInt64) {
        receivedDownloadBytes = receivedDownloadBytes.addingReportingOverflow(bytes).overflow ? UInt64.max : receivedDownloadBytes + bytes
        updateDownloadProgress()
    }
    private func updateDownloadProgress() {
        setPhase(.downloading, progress: expectedDownloadBytes > 0 ? min(1, Double(receivedDownloadBytes) / Double(expectedDownloadBytes)) : nil)
    }
    func extractionStarted() { cancellation = nil; setPhase(.extracting, progress: nil) }
    func extractionProgress(_ progress: Double) { setPhase(.extracting, progress: progress.isFinite ? min(1, max(0, progress)) : nil) }
    func readyToInstall(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil
        if automaticSession, !automaticUpdatesEnabled { reply(.skip); updatePresentation = nil; return }
        setPhase(.ready, progress: nil)
        if installRequested { reply(.install) }
        else { updateReply = reply }
    }
    func installing() { cancellation = nil; updateReply = nil; setPhase(.installing, progress: nil) }
    func updateErrored() {
        checkFailed(); cancellation = nil; updateReply = nil
        present(.init(version: availableVersion, phase: .failed))
    }
    func updateNotFound() {
        foundNoUpdate(); cancellation = nil; updateReply = nil
        if !automaticSession { present(.init(phase: .current)) }
    }
    func installationDismissed() {
        cancellation = nil; updateReply = nil; installRequested = false
        if let phase = updatePresentation?.phase, ![.failed, .current].contains(phase) { updatePresentation = nil }
    }
    func focusUpdate() { if updatePresentation != nil { onPresentUpdate?() } }
    private func setPhase(_ phase: AppUpdatePresentation.Phase, progress: Double?) {
        var presentation = updatePresentation ?? .init(version: availableVersion, phase: phase)
        presentation.phase = phase; presentation.progress = progress
        present(presentation)
    }
    private func present(_ presentation: AppUpdatePresentation) {
        let firstPresentation = updatePresentation == nil
        if firstPresentation { mainUpdatePresentationApproved = false }
        updatePresentation = presentation
        if firstPresentation { onPresentUpdate?() }
    }

    func willInstallVersion(_ version: String) {
        guard isAvailable, recordsInstalledVersions else { return }
        defaults.set(currentVersion, forKey: "TSXLastLaunchedReleaseVersion")
        defaults.set(version, forKey: "TSXPendingInstalledReleaseVersion")
    }

    func prepareInstalledReleaseNotes() {
        guard isAvailable, recordsInstalledVersions, currentVersion != "—" else { return }
        let previous = defaults.string(forKey: "TSXLastLaunchedReleaseVersion")
            ?? (hadLegacyLaunch ? "1.0.0" : nil)
        let pending = defaults.string(forKey: "TSXPendingInstalledReleaseVersion")
        let acknowledged = defaults.string(forKey: "TSXAcknowledgedReleaseNotesVersion")
        let upgraded = previous.map { SUStandardVersionComparator().compareVersion(currentVersion, toVersion: $0) == .orderedDescending } ?? false
        if acknowledged != currentVersion, pending == currentVersion || upgraded {
            defaults.set(currentVersion, forKey: "TSXPendingInstalledReleaseVersion")
            pendingReleaseNotesVersion = currentVersion
            mainReleaseNotesPresentation = .installed(version: currentVersion)
            onPresentReleaseNotes?()
        }
        defaults.set(currentVersion, forKey: "TSXLastLaunchedReleaseVersion")
    }

    func acknowledgeInstalledReleaseNotes() {
        guard let version = pendingReleaseNotesVersion else { return }
        defaults.set(version, forKey: "TSXAcknowledgedReleaseNotesVersion")
        defaults.removeObject(forKey: "TSXPendingInstalledReleaseVersion")
        pendingReleaseNotesVersion = nil
    }

    func showRecentReleaseNotes(in location: AppReleaseNotesLocation = .settings) {
        switch location {
        case .settings: releaseNotesPresentation = .recent
        case .mainWindow: mainReleaseNotesPresentation = .recent
        }
    }
    func dismissReleaseNotes(in location: AppReleaseNotesLocation = .settings, acknowledging: Bool = true) {
        switch location {
        case .settings:
            releaseNotesPresentation = nil
        case .mainWindow:
            if acknowledging { acknowledgeInstalledReleaseNotes() }
            mainReleaseNotesPresentation = nil
        }
    }
    func loadReleaseNotes() async { await releases.load() }

    func configureMenuItem(_ item: NSMenuItem) {
        item.title = L10n.string("Check for updates")
        item.target = menuTarget
        item.action = #selector(AppUpdateMenuTarget.checkForUpdates)
        item.isEnabled = canCheckForUpdates
    }

    #if TRANSLATEX_VISUAL_QA
    static func visualReview(previewInstalledNotes: Bool = false, shortReleaseNotes: Bool = false,
                             previewAvailableUpdate: Bool = false) -> AppUpdateController {
        let backend = VisualReviewAppUpdater()
        let entries: [AppRelease]? = previewAvailableUpdate ? [.init(version: "1.0.1", publishedAt: .distantPast,
            notes: "## 中文\n- 修复双栏编辑中删除到空白后，另一侧仍残留旧内容的问题；清空后重新输入可继续双向翻译。\n- 清空时取消旧翻译，避免延迟返回的结果重新填入；保留中文输入法组合输入的正常行为。\n## English\n- Clear stale content in the other pane when editing down to an empty draft. Typing again resumes translation.\n- Cancel pending translations when clearing the draft while preserving composed text input.",
            url: URL(string: "https://github.com/TheoYuuu/tsx/releases")!)] : shortReleaseNotes ? [.init(version: "1.0.0", publishedAt: .distantPast,
            notes: "## 中文\n- 更新说明现在显示在翻译窗口中央。\n- 改善服务切换图标的圆角。\n## English\n- Release notes now appear over the translation workspace.\n- Service action icons have softer corners.",
            url: URL(string: "https://github.com/TheoYuuu/tsx/releases/tag/v1.0.0")!)] : nil
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false, isReleaseBuild: true,
                                          currentVersion: "1.0.0", recordsInstalledVersions: false,
                                          backend: backend, releases: AppReleaseNotesStore(entries: entries, allowsNetworkLoading: false))
        backend.owner = updates
        if previewInstalledNotes, updates.releases.entries.contains(where: { $0.version == updates.currentVersion }) {
            _ = updates.startBackend()
            updates.mainReleaseNotesPresentation = .installed(version: updates.currentVersion)
        } else { updates.start() }
        return updates
    }
    #endif
}

@MainActor
private final class AppUpdateMenuTarget: NSObject, NSMenuItemValidation {
    private weak var owner: AppUpdateController?
    init(owner: AppUpdateController) { self.owner = owner }
    @objc func checkForUpdates() { owner?.checkForUpdates() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { owner?.canCheckForUpdates == true }
}

#if TRANSLATEX_VISUAL_QA
/// An isolated presentation fixture. No Sparkle object, network request,
/// install operation, preference write or application termination is performed.
@MainActor
private final class VisualReviewAppUpdater: AppUpdaterBackend {
    weak var owner: AppUpdateController?
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    private var simulation: Task<Void, Never>?
    // This candidate only exercises the UI; it is not a published release.
    private let fixtureVersion = "1.0.1"

    func start() throws {}
    func checkInformation() { owner?.foundUpdate(fixtureVersion); owner?.finishedCheck() }
    func checkUpdates() {
        owner?.offerUpdate(version: fixtureVersion, informationOnly: false, informationURL: nil,
                           userInitiated: true) { [weak self] choice in
            guard choice == .install, let self else { return }
            self.simulation = Task { [weak self] in await self?.simulateDownload() }
        }
    }
    private func simulateDownload() async {
        owner?.downloadStarted { [weak self] in self?.simulation?.cancel() }
        owner?.downloadExpected(100)
        for _ in 0..<5 {
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            owner?.downloadReceived(20)
        }
        guard !Task.isCancelled else { return }
        owner?.extractionStarted()
        owner?.extractionProgress(1)
        owner?.readyToInstall { [weak self] choice in
            guard choice == .install else { return }
            self?.owner?.installing()
        }
        do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
        owner?.installationDismissed()
        owner?.finishedCheck()
    }
}
#endif
