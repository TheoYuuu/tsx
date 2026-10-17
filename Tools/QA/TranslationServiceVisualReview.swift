import AppKit
import Darwin
import ImageIO
import SwiftUI

// The visual binary excludes the real catalog implementation. These matching
// interfaces ensure no review action can contact an API, including new drafts.
nonisolated struct TranslationServiceModel: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
}
nonisolated protocol TranslationServiceModelLoading: Sendable {
    func models(configuration: TranslationServiceConfiguration, apiKey: String?) async throws -> [TranslationServiceModel]
}
nonisolated enum TranslationServiceModelCatalogError: String, Error, LocalizedError, Sendable {
    case unsupportedService, catalogUnavailable, invalidCatalog, catalogTooLarge
    var errorDescription: String? { L10n.string("translationService.catalogError.\(rawValue)") }
}
nonisolated struct TranslationServiceModelCatalog: TranslationServiceModelLoading {
    var scene = "normal"
    static func supports(_ kind: TranslationServiceKind) -> Bool {
        [.openAI, .deepSeek, .claude, .openAICompatible, .ollama].contains(kind)
    }
    func models(configuration: TranslationServiceConfiguration, apiKey: String?) async throws -> [TranslationServiceModel] {
        try await Task.sleep(for: scene == "catalog-loading" ? .seconds(60) : .milliseconds(500))
        try Task.checkCancellation()
        if scene == "catalog-error" { throw TranslationServiceModelCatalogError.catalogUnavailable }
        if scene == "catalog-empty" { return [] }
        return [configuration.model, "constructed-model-a", "constructed-model-b"].filter { !$0.isEmpty }
            .map { .init(id: $0, name: $0) }
    }
}

// The isolated binary excludes the production account loader as well. Even a
// manual Refresh click remains entirely in memory and never opens a URLSession.
nonisolated struct TranslationAccountUsageLoader: TranslationAccountUsageLoading {
    static func supports(_ configuration: TranslationServiceConfiguration) -> Bool {
        [.deepSeek, .deepL].contains(configuration.kind)
    }
    func usage(configuration: TranslationServiceConfiguration, apiKey: String?) async throws -> TranslationAccountUsageSnapshot {
        try await Task.sleep(for: .milliseconds(250))
        try Task.checkCancellation()
        guard Self.supports(configuration) else { throw TranslationAccountUsageError.unsupportedService }
        return VisualAccountUsageFixture.snapshot(kind: configuration.kind)
    }
}

nonisolated private enum VisualAccountUsageFixture {
    static func snapshot(kind: TranslationServiceKind) -> TranslationAccountUsageSnapshot {
        if kind == .deepL {
            return .init(fetchedAt: Date().addingTimeInterval(-120), usedCharacters: 128_460, characterLimit: 500_000)
        }
        return .init(fetchedAt: Date().addingTimeInterval(-120), balances: [
            .init(currency: "CNY", total: Decimal(string: "19.64")!, granted: 4, toppedUp: Decimal(string: "15.64")!)
        ])
    }
}

/// Hosts the shipping SettingsView and WindowSurface. Only service dependencies
/// and preferences are isolated; layout, controls and native material are real.
@MainActor
final class TranslationServiceVisualReview: NSObject {
    private static var retained: TranslationServiceVisualReview?
    private var window: NSWindow?
    private var backdrop: NSWindow?
    private var session: TranslationServiceDraftSession?
    private var frames: [String: CGRect] = [:]
    private var defaults: UserDefaults?
    private var fixture: VisualCodexAccount?
    private var workspaceModel: TranslationModel?
    private var reviewWindows: WindowCoordinator?
    private var reviewSourceApplication: NSRunningApplication?
    private var unifiedObservationTimer: Timer?
    private var unifiedObservationChanges: [UnifiedWindowObservation] = []
    private var screenshotOverlay: ScreenshotOverlayController?
    private var screenshotCapture: ScreenshotTranslationController?
    private var screenshotObservationTimer: Timer?
    private var screenshotRequestTask: Task<Void, Never>?
    private var screenshotObservationChanges: [[String: Any]] = []
    private var screenshotLastObservation: Data?
    private var screenshotDraft = ""
    private var screenshotDraftTranslation = ""
    private var screenshotScene = "normal"
    private var screenshotDocumentID: UUID?
    private var screenshotExportedTranslation: String?
    private var screenshotManualHandoffObserved = false
    private var screenshotManualRestoreObserved = false
    private var screenshotRealCaptureStarted = false
    private var screenshotOutput: URL?
    private var screenshotPasteboardChangeCount = NSPasteboard.general.changeCount
    private var screenshotExpectedClipboardText: [String: String] = [:]
    private var screenshotExpectedClipboardPNG: [String: Data] = [:]
    private var screenshotClipboardChecks: [String: Bool] = ["changedSinceReviewStart": false]
    private var permissionObservationTimer: Timer?
    private var permissionObservationChanges: [[String: Any]] = []
    private var permissionLastObservation: Data?
    private var permissionRequestCount = 0
    private var permissionSourceActivationCount = 0
    private var permissionObservationOutput: URL?
    private var reviewPermission: SystemPermission = .screenCapture

    private struct UnifiedWindowObservation: Equatable {
        let mainVisible: Bool
        let mainIsKey: Bool
        let reviewAppActive: Bool
        let sourceIsFrontmost: Bool
        let canRestorePrevious: Bool
        let mainFrameSize: [String: Double]

        var report: [String: Any] {
            ["mainVisible": mainVisible, "mainIsKey": mainIsKey, "reviewAppActive": reviewAppActive,
             "sourceIsFrontmost": sourceIsFrontmost, "canRestorePrevious": canRestorePrevious,
             "mainFrameSize": mainFrameSize]
        }
    }

    static func start() {
        let review = TranslationServiceVisualReview()
        retained = review
        review.configureMenu()
        Task { await review.run() }
    }

    private func configureMenu() {
        let bar = NSMenu()
        let item = NSMenuItem()
        let menu = NSMenu()
        let quit = menu.addItem(withTitle: "退出视觉核查", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        item.submenu = menu
        bar.addItem(item)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let reopen = fileMenu.addItem(withTitle: "打开翻译窗口", action: #selector(reopenWorkspace), keyEquivalent: "n")
        reopen.target = self
        let capture = fileMenu.addItem(withTitle: "模拟快捷翻译（构造文本）", action: #selector(replaceWithSelection), keyEquivalent: "k")
        capture.target = self
        if CommandLine.arguments.contains("--permission-window-review") {
            let permission = fileMenu.addItem(withTitle: "重新打开构造权限提示", action: #selector(reopenPermission), keyEquivalent: "r")
            permission.target = self
        }
        if CommandLine.arguments.contains("--screenshot-overlay-review") {
            fileMenu.autoenablesItems = false
            let realCapture = fileMenu.addItem(withTitle: "真实框选（仅选择构造样例）", action: #selector(captureConstructedScreen), keyEquivalent: "r")
            realCapture.target = self
            realCapture.isEnabled = ScreenCaptureService.hasPermission
        }
        fileItem.submenu = fileMenu
        bar.addItem(fileItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = editMenu
        bar.addItem(editItem)
        NSApp.mainMenu = bar
    }

    private func argument(_ key: String, fallback: String) -> String {
        guard let i = CommandLine.arguments.firstIndex(of: key), i + 1 < CommandLine.arguments.count else { return fallback }
        return CommandLine.arguments[i + 1]
    }

    @objc private func reopenWorkspace() { reviewWindows?.showTranslationWindow() }
    @objc private func replaceWithSelection() { Task { await replaceWithSelectionFixture() } }

    @objc private func reopenPermission() {
        reviewWindows?.showPermission(reviewPermission, source: reviewSourceApplication)
        window = NSApp.windows.first { $0.identifier?.rawValue == "translatex.permission" && $0.isVisible }
    }

    /// Uses the shipping permission window with a counter instead of TCC or
    /// System Settings. Manual UI actions are observed without storing content.
    private func presentPermissionFixture(output: URL) async {
        let sourceBundle = argument("--review-source-bundle", fallback: "")
        reviewSourceApplication = sourceBundle.isEmpty ? nil
            : NSRunningApplication.runningApplications(withBundleIdentifier: sourceBundle).first
        let scene = argument("--review-scene", fallback: "quick-permission-screen")
        reviewPermission = scene.contains("screen") ? .screenCapture : .accessibility
        await present(scene: scene, theme: argument("--review-theme", fallback: "light"))
        reviewWindows?.onPermission = { [weak self] _ in self?.permissionRequestCount += 1 }
        permissionObservationOutput = output
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(permissionSourceActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(permissionKeyChanged(_:)), name: name, object: window)
        }
        recordPermissionObservation(output: output)
        permissionObservationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recordPermissionObservation(output: output) }
        }
    }

    @objc private func permissionSourceActivated(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.processIdentifier == reviewSourceApplication?.processIdentifier {
            permissionSourceActivationCount += 1
        }
        if let permissionObservationOutput { recordPermissionObservation(output: permissionObservationOutput) }
    }

    @objc private func permissionKeyChanged(_ notification: Notification) {
        if let permissionObservationOutput { recordPermissionObservation(output: permissionObservationOutput) }
    }

    private func recordPermissionObservation(output: URL) {
        guard let window else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        let report: [String: Any] = [
            "visible": window.isVisible, "key": window.isKeyWindow,
            "miniaturized": window.isMiniaturized, "active": NSApp.isActive,
            "sourceIsFrontmost": reviewSourceApplication.map {
                !$0.isTerminated && NSWorkspace.shared.frontmostApplication?.processIdentifier == $0.processIdentifier
            } ?? false,
            "mainVisible": NSApp.windows.contains { $0.identifier?.rawValue == "translatex.main" && $0.isVisible },
            "permissionRequestCount": permissionRequestCount,
            "sourceAvailable": reviewSourceApplication != nil,
            "sourceActivationCount": permissionSourceActivationCount,
            "nativeTitleVisible": window.titleVisibility == .visible,
            "nativeControlsVisible": [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].allSatisfy {
                window.standardWindowButton($0).map { !$0.isHidden } ?? false
            },
            "contentSize": ["width": content.width, "height": content.height],
            "frameSize": ["width": window.frame.width, "height": window.frame.height]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
              data != permissionLastObservation else { return }
        permissionLastObservation = data
        permissionObservationChanges.append(report)
        if permissionObservationChanges.count > 20 { permissionObservationChanges.removeFirst() }
        var payload = report
        payload["recentChanges"] = permissionObservationChanges
        writeScreenshotReport(payload, name: "permission-window-observation.json", output: output)
    }

    private func replaceWithSelectionFixture() async {
        guard let windows = reviewWindows else { return }
        windows.prepareCapturedTranslation()
        let model = windows.inputModel
        model.source = "en"
        model.sourceName = reviewSourceApplication?.localizedName ?? "Constructed source app"
        model.submitCapturedText("A new selection replaces the previous translation.", serviceRevision: model.serviceRevision)
        if let request = model.request {
            await model.run(request, provider: FixtureProvider(output: "新的选区替换上一条翻译。"))
        }
        model.cancel()
        windows.showCapturedTranslation(source: reviewSourceApplication)
    }

    /// Keep the real coordinator and shipping controls available for manual Esc,
    /// restore and reopen checks. The report covers constructed lifecycle calls;
    /// it does not stand in for keyboard or cross-application focus verification.
    private func presentUnifiedWindowFixture(output: URL) async {
        let sourceBundle = argument("--review-source-bundle", fallback: "")
        reviewSourceApplication = sourceBundle.isEmpty
            ? NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0 }
            : NSRunningApplication.runningApplications(withBundleIdentifier: sourceBundle).first
        let domain = "TranslateX.TranslationServiceVisualReview.Unified.Ephemeral"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        self.defaults = defaults
        let preferences = AppPreferences(defaults: defaults)
        preferences.appearance = argument("--review-theme", fallback: "light") == "dark" ? .dark : .light
        preferences.interfaceLanguage = argument("--review-interface-language", fallback: "zh-Hans") == "en" ? .english : .simplifiedChinese
        let services = TranslationServiceStore(defaults: defaults, credentials: VisualCredentialStore())
        let windows = WindowCoordinator(preferences: preferences, services: services)
        windows.applyAppearance()
        reviewWindows = windows
        windows.onSelection = { [weak self] in self?.replaceWithSelection() }
        let model = windows.inputModel
        model.setAutomaticTranslation(false)
        model.source = "en"
        model.target = "zh-Hans"
        model.text = "The previous draft remains recoverable."
        model.submit()
        if let request = model.request {
            await model.run(request, provider: FixtureProvider(output: "上一份草稿仍然可以恢复。"))
        }
        model.cancel()
        let originalText = model.text
        let originalTranslation = model.translatedText
        windows.showMain()
        let originalWindow = NSApp.windows.first { $0.identifier?.rawValue == "translatex.main" && $0.isVisible }
        await replaceWithSelectionFixture()
        var checks: [String: Bool] = [
            "captureReusesMainWindow": originalWindow != nil
                && NSApp.windows.first { $0.identifier?.rawValue == "translatex.main" && $0.isVisible } === originalWindow,
            "onlyOneTranslationWindowVisible": NSApp.windows.filter { $0.identifier?.rawValue == "translatex.main" && $0.isVisible }.count == 1
                && !NSApp.windows.contains { $0.identifier?.rawValue == "translatex.quick" && $0.isVisible },
            "previousWorkspaceAvailable": model.canRestorePreviousWorkspace,
            "constructedCaptureCompleted": model.phase == .completed && model.request == nil
        ]
        let capturedText = model.text
        let capturedTranslation = model.translatedText
        windows.dismissTranslation(restoreFocus: false)
        checks["dismissHidesMainWindow"] = originalWindow?.isVisible == false
        windows.showTranslationWindow()
        checks["reopenReusesMainWindow"] = originalWindow?.isVisible == true
            && NSApp.windows.first { $0.identifier?.rawValue == "translatex.main" && $0.isVisible } === originalWindow
        checks["reopenPreservesResultWithoutRequest"] = model.text == capturedText
            && model.translatedText == capturedTranslation && model.request == nil
        windows.restorePreviousTranslation()
        checks["restoreRecoversOriginalPairWithoutRequest"] = model.text == originalText
            && model.translatedText == originalTranslation && model.sourceName.isEmpty
            && model.request == nil && !model.canRestorePreviousWorkspace
        await replaceWithSelectionFixture()
        window = originalWindow
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks,
            "manualChecks": ["Press Esc and confirm focus returns to the specified source app", "Reopen with File > 打开翻译窗口", "Use the production restore-previous button", "Use File > 模拟快捷翻译（构造文本） to repeat"]]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("unified-window-results.json"), options: .atomic)
        }
        observeUnifiedWindow(output: output)
    }

    /// Passive evidence for manual CUA interaction. Only state flags and window
    /// dimensions leave memory; source identity and workspace contents do not.
    private func observeUnifiedWindow(output: URL) {
        unifiedObservationTimer?.invalidate()
        unifiedObservationChanges = []
        recordUnifiedWindowObservation(output: output)
        unifiedObservationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recordUnifiedWindowObservation(output: output) }
        }
    }

    private func recordUnifiedWindowObservation(output: URL) {
        let sourceIsFrontmost: Bool
        if let source = reviewSourceApplication, !source.isTerminated {
            sourceIsFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == source.processIdentifier
        } else { sourceIsFrontmost = false }
        let state = UnifiedWindowObservation(
            mainVisible: window?.isVisible == true,
            mainIsKey: window?.isKeyWindow == true,
            reviewAppActive: NSApp.isActive,
            sourceIsFrontmost: sourceIsFrontmost,
            canRestorePrevious: reviewWindows?.inputModel.canRestorePreviousWorkspace == true,
            mainFrameSize: ["width": Double(window?.frame.width ?? 0), "height": Double(window?.frame.height ?? 0)]
        )
        guard unifiedObservationChanges.last != state else { return }
        unifiedObservationChanges.append(state)
        if unifiedObservationChanges.count > 10 { unifiedObservationChanges.removeFirst() }
        var report = state.report
        report["recentChanges"] = unifiedObservationChanges.map(\.report)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("unified-window-observation.json"), options: .atomic)
        }
    }

    /// Shipping overlay/controller with original constructed pixels and real
    /// Vision OCR. Only translation execution is supplied by a local fixture.
    private func presentScreenshotOverlayFixture(output: URL) async {
        screenshotOutput = output
        let requestedScene = argument("--review-screenshot-scene", fallback: "normal")
        let supported = ["normal", "menu", "dense", "gradient", "dark", "manual", "error", "oversized", "overflow"]
        screenshotScene = supported.contains(requestedScene) ? requestedScene : "normal"
        let sourceBundle = argument("--review-source-bundle", fallback: "")
        reviewSourceApplication = sourceBundle.isEmpty ? nil
            : NSRunningApplication.runningApplications(withBundleIdentifier: sourceBundle).first
        let domain = "TranslateX.TranslationServiceVisualReview.ScreenshotOverlay.Ephemeral"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        self.defaults = defaults
        let preferences = AppPreferences(defaults: defaults)
        preferences.appearance = argument("--review-theme", fallback: screenshotScene == "dark" ? "dark" : "light") == "dark" ? .dark : .light
        preferences.interfaceLanguage = argument("--review-interface-language", fallback: "zh-Hans") == "en" ? .english : .simplifiedChinese
        let services = TranslationServiceStore(defaults: defaults, credentials: VisualCredentialStore())
        let windows = WindowCoordinator(preferences: preferences, services: services)
        windows.applyAppearance()
        reviewWindows = windows
        let draft = windows.inputModel
        draft.setAutomaticTranslation(false)
        draft.source = "en"
        draft.target = "zh-Hans"
        draft.text = "This constructed draft must survive screenshot translation."
        draft.submit()
        if let request = draft.request { await draft.run(request, provider: FixtureProvider(output: "这份构造草稿应在截图翻译后保留。")) }
        draft.cancel()
        screenshotDraft = draft.text
        screenshotDraftTranslation = draft.translatedText
        let model = TranslationModel(automaticallyTranslates: false, services: services)
        let overlay = ScreenshotOverlayController(windows: windows, model: model)
        screenshotOverlay = overlay
        let document: ScreenshotDocument
        do {
            document = try await ScreenshotReviewFixture.document(menu: screenshotScene == "menu", dense: screenshotScene == "dense",
                background: screenshotScene == "dark" ? .dark : screenshotScene == "gradient" ? .gradient : .plain, edgeMarkers: true)
        } catch {
            writeScreenshotReport(["passed": false, "stage": "constructedVisionOCR", "scene": screenshotScene],
                name: "screenshot-overlay-results.json", output: output)
            return
        }
        screenshotDocumentID = document.id
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let maximumHeight = max(220, min(660, visible.height - 180))
        let scale = maximumHeight / document.pixelSize.height
        let size = CGSize(width: document.pixelSize.width * scale, height: maximumHeight)
        let selection = screenshotScene == "oversized"
            ? CGRect(x: visible.minX - 120, y: visible.minY - 80, width: document.pixelSize.width * 1.5, height: document.pixelSize.height * 1.5)
            : CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + 40, width: size.width, height: size.height)
        let placement = ScreenshotOverlayPlacement(selection: selection, visibleFrame: visible)
        model.source = "en"
        model.target = "zh-Hans"
        model.useScreenshotSourceName()
        model.submitCapturedDocument(document, serviceRevision: model.serviceRevision)
        if let request = model.request { await model.run(request, provider: ScreenshotReviewProvider()) }
        model.cancel()
        var checks = [
            "realVisionOCRProducedRegions": !document.regions.isEmpty,
            "mainDraftUnchangedBeforeHandoff": screenshotDraftMatches(draft),
            "constructedTranslationCompleted": model.phase == .completed && model.request == nil,
            "placementPreservesImageAspect": abs(placement.imageFrame.width / placement.imageFrame.height - document.pixelSize.width / document.pixelSize.height) < 0.001,
            "wholeOverlayFitsVisibleScreen": visible.contains(placement.frame)
        ]
        // Exercise native lifecycle calls separately from the subsequent manual
        // run. This does not claim any button, keyboard or focus verification.
        overlay.present(source: reviewSourceApplication, selection: selection)
        checks["overlayDoesNotOpenMain"] = !NSApp.windows.contains { $0.identifier?.rawValue == "translatex.main" && $0.isVisible }
        overlay.editInMain()
        checks["handoffUsesMainAndPreservesImage"] = draft.screenshot?.id == document.id && draft.canRestorePreviousWorkspace
            && !overlay.isVisible && draft.request == nil
        windows.restorePreviousTranslation()
        checks["restoreRecoversDraftWithoutRequest"] = screenshotDraftMatches(draft)
            && draft.screenshot == nil && draft.request == nil && !draft.canRestorePreviousWorkspace
        windows.dismissTranslation(restoreFocus: false)

        model.source = "en"
        model.useScreenshotSourceName()
        model.submitCapturedDocument(document, serviceRevision: model.serviceRevision, startAutomatically: screenshotScene != "manual")
        if let request = model.request {
            await model.run(request, provider: ScreenshotReviewProvider(fails: screenshotScene == "error",
                forcesOverflow: screenshotScene == "overflow"))
        }
        model.cancel()
        overlay.present(source: reviewSourceApplication, selection: selection)
        window = NSApp.windows.first { $0.identifier?.rawValue == "translatex.main" }
        checks["mainDraftUnchangedWhileOverlayVisible"] = screenshotDraftMatches(draft) && window?.isVisible != true
        checks["finalScenarioReady"] = screenshotScene == "manual" ? model.request == nil && model.screenshot?.translations.isEmpty == true
            : screenshotScene == "error" ? model.hasTranslationFailure : model.phase == .completed
        let exports = exportScreenshotFixture(output: output)
        checks["originalPNGKeepsPixelDimensions"] = exports["originalPNGKeepsPixelDimensions"] as? Bool == true
        checks["translatedPNGKeepsPixelDimensions"] = exports["translatedPNGKeepsPixelDimensions"] as? Bool == true
        checks["fourImageEdgesRemainIntact"] = exports["fourImageEdgesRemainIntact"] as? Bool == true
        if screenshotScene == "overflow" {
            checks["overflowFallbackRequired"] = model.screenshot.flatMap { ScreenshotImageRenderer.render($0) }?.overflowRegionIDs.isEmpty == false
            checks["overflowKeepsCompleteTranslation"] = model.screenshot?.translatedText.contains(ScreenshotReviewProvider.overflowTranslation) == true
        }
        writeScreenshotReport(["passed": checks.values.allSatisfy { $0 }, "scene": screenshotScene, "checks": checks,
            "exports": exports, "screenCapturePermission": ScreenCaptureService.hasPermission,
            "scope": "Constructed pixels, real Vision OCR and shipping lifecycle calls; translation is local fixture output.",
            "manualChecks": ["Compare original/translation and inspect all four colored edges", "Open copy/save menus and exercise the real buttons", "Manual scene: click Translate", "Error scene: inspect status and Retry", "Open in main window, then restore previous draft", "Press Esc and check source focus; changing focus must keep the overlay visible", "If already authorized, File > 真实框选（仅选择构造样例） exercises the real selector with offline QA translation"]],
            name: "screenshot-overlay-results.json", output: output)
        observeScreenshotOverlay(output: output)
    }

    private func screenshotDraftMatches(_ model: TranslationModel) -> Bool {
        model.text == screenshotDraft && model.translatedText == screenshotDraftTranslation
    }

    /// The observer never clicks or sends keyboard events. When a person presses
    /// Translate, this QA worker replaces the excluded Apple translation host.
    private func observeScreenshotOverlay(output: URL) {
        screenshotObservationTimer?.invalidate()
        screenshotObservationChanges = []
        screenshotLastObservation = nil
        recordScreenshotObservation(output: output)
        screenshotObservationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recordScreenshotObservation(output: output)
                guard !self.screenshotRealCaptureStarted, self.screenshotRequestTask == nil,
                      let model = self.screenshotOverlay?.model, let request = model.request else { return }
                self.screenshotRequestTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await model.run(request, provider: ScreenshotReviewProvider(fails: self.screenshotScene == "error",
                        forcesOverflow: self.screenshotScene == "overflow"))
                    if model.request?.id == request.id { model.cancel() }
                    self.screenshotRequestTask = nil
                    self.recordScreenshotObservation(output: output)
                }
            }
        }
    }

    private func recordScreenshotObservation(output: URL) {
        guard let windows = reviewWindows, let overlay = screenshotOverlay else { return }
        let main = NSApp.windows.first { $0.identifier?.rawValue == "translatex.main" }
        let panel = NSApp.windows.first { $0.identifier?.rawValue == "translatex.screenshotResult" && $0.isVisible }
        let model = overlay.model
        recordScreenshotClipboardChecks()
        let draftUnchanged = screenshotDraftMatches(windows.inputModel)
        if windows.inputModel.screenshot?.id == screenshotDocumentID { screenshotManualHandoffObserved = true }
        if screenshotManualHandoffObserved, draftUnchanged, windows.inputModel.screenshot == nil,
           !windows.inputModel.canRestorePreviousWorkspace { screenshotManualRestoreObserved = true }
        let phase: String
        switch model.phase {
        case .empty: phase = "empty"
        case .waiting: phase = "waiting"
        case .composing: phase = "composing"
        case .recognizing: phase = "recognizing"
        case .translating: phase = "translating"
        case .preparingLanguages: phase = "preparingLanguages"
        case .completed: phase = "completed"
        case .unchanged: phase = "unchanged"
        case .noText: phase = "noText"
        case .cancelled: phase = "cancelled"
        case .failed: phase = "failed"
        }
        let state: [String: Any] = [
            "scene": screenshotScene, "overlayVisible": panel != nil, "overlayIsKey": panel?.isKeyWindow == true,
            "mainVisible": main?.isVisible == true, "mainIsKey": main?.isKeyWindow == true,
            "reviewAppActive": NSApp.isActive,
            "sourceIsFrontmost": reviewSourceApplication.map { !$0.isTerminated && NSWorkspace.shared.frontmostApplication?.processIdentifier == $0.processIdentifier } ?? false,
            "screenCapturePermission": ScreenCaptureService.hasPermission,
            "mainDraftUnchanged": draftUnchanged, "canRestorePrevious": windows.inputModel.canRestorePreviousWorkspace,
            "mainRequestPending": windows.inputModel.request != nil,
            "manualHandoffObserved": screenshotManualHandoffObserved, "manualRestoreObserved": screenshotManualRestoreObserved,
            "phase": screenshotRealCaptureStarted ? "observedThroughNativeUI" : phase,
            "realCaptureStarted": screenshotRealCaptureStarted,
            "clipboardChecks": screenshotClipboardChecks,
            "requestPending": model.request != nil, "regionCount": model.screenshot?.regions.count ?? 0,
            "translatedRegionCount": model.screenshot?.translations.count ?? 0,
            "saveSheetVisible": panel?.attachedSheet != nil,
            "overlayFrame": ["x": Double(panel?.frame.minX ?? 0), "y": Double(panel?.frame.minY ?? 0),
                             "width": Double(panel?.frame.width ?? 0), "height": Double(panel?.frame.height ?? 0)]
        ]
        guard let serialized = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
              serialized != screenshotLastObservation else { return }
        screenshotLastObservation = serialized
        screenshotObservationChanges.append(state)
        if screenshotObservationChanges.count > 40 { screenshotObservationChanges.removeFirst() }
        var report = state
        report["recentChanges"] = screenshotObservationChanges
        writeScreenshotReport(report, name: "screenshot-overlay-observation.json", output: output)
        // Only the known fixture document is eligible for automatic QA export.
        // A real capture selected manually remains in memory until explicit UI copy/save.
        if !screenshotRealCaptureStarted, model.screenshot?.id == screenshotDocumentID,
           model.phase == .completed, screenshotExportedTranslation != model.translatedText {
            screenshotExportedTranslation = model.translatedText
            writeScreenshotReport(exportScreenshotFixture(output: output), name: "screenshot-overlay-exports.json", output: output)
        }
    }

    private func exportScreenshotFixture(output: URL) -> [String: Any] {
        guard let overlay = screenshotOverlay, overlay.model.screenshot?.id == screenshotDocumentID,
              let original = overlay.image(for: .originalImage), let translated = overlay.image(for: .translatedImage) else {
            return ["exportAvailable": false]
        }
        var report: [String: Any] = ["exportAvailable": true, "width": original.width, "height": original.height,
            "fourImageEdgesRemainIntact": screenshotEdgesMatch(original, translated)]
        screenshotExpectedClipboardText = ["original": overlay.model.screenshot?.sourceText ?? "",
                                           "translated": overlay.model.screenshot?.translatedText ?? ""]
        for (name, image) in [("original", original), ("translated", translated)] {
            let file = output.appendingPathComponent("screenshot-overlay-\(screenshotScene)-\(name).png")
            do {
                guard let png = ScreenshotImageExport.pngData(image) else { report["\(name)PNGKeepsPixelDimensions"] = false; continue }
                screenshotExpectedClipboardPNG[name] = png
                try png.write(to: file, options: .atomic)
                let source = CGImageSourceCreateWithURL(file as CFURL, nil)
                let decoded = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                report["\(name)PNGKeepsPixelDimensions"] = decoded?.width == original.width && decoded?.height == original.height
            } catch { report["\(name)PNGKeepsPixelDimensions"] = false }
        }
        return report
    }

    /// Observe a real Copy action without writing the clipboard or recording its
    /// contents. Compare only after changeCount advances, against known fixtures.
    private func recordScreenshotClipboardChecks() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != screenshotPasteboardChangeCount else { return }
        screenshotPasteboardChangeCount = pasteboard.changeCount
        screenshotClipboardChecks = ["changedSinceReviewStart": true]
        let text = pasteboard.string(forType: .string)
        let png = pasteboard.data(forType: .png)
        for name in ["original", "translated"] {
            let expected = screenshotExpectedClipboardText[name] ?? ""
            screenshotClipboardChecks["matchesFixture\(name.capitalized)Text"] = !expected.isEmpty && text == expected
            screenshotClipboardChecks["matchesFixture\(name.capitalized)PNG"] = png != nil && png == screenshotExpectedClipboardPNG[name]
        }
    }

    private func screenshotEdgesMatch(_ original: CGImage, _ translated: CGImage) -> Bool {
        guard original.width == translated.width, original.height == translated.height else { return false }
        let w = original.width, h = original.height
        guard w >= 80, h >= 80 else { return false }
        // colorAt() interprets the fixture's deviceRGB and the renderer's sRGB
        // representations differently, even after a lossless PNG round trip.
        // Normalize both through the same pixel context before comparing them.
        func normalized(_ image: CGImage) -> CGContext? {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return context
        }
        guard let first = normalized(original), let second = normalized(translated),
              let firstData = first.data, let secondData = second.data else { return false }
        let a = firstData.assumingMemoryBound(to: UInt8.self)
        let b = secondData.assumingMemoryBound(to: UInt8.self)
        // Check every pixel in all four 10px edge strips and the corner markers,
        // not only midpoints that could miss a partial crop or misplaced canvas.
        let areas = [(0, 0, w, 10), (0, h - 10, w, 10), (0, 10, 10, h - 20), (w - 10, 10, 10, h - 20),
                     (14, 14, 26, 26), (w - 40, 14, 26, 26), (14, h - 40, 26, 26), (w - 40, h - 40, 26, 26)]
        return withExtendedLifetime((first, second)) {
            areas.allSatisfy { x, y, width, height in
                for row in y..<(y + height) {
                    for column in x..<(x + width) {
                        let offset = (row * w + column) * 4
                        for channel in 0..<4 where abs(Int(a[offset + channel]) - Int(b[offset + channel])) > 2 { return false }
                    }
                }
                return true
            }
        }
    }

    private func writeScreenshotReport(_ report: [String: Any], name: String, output: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent(name), options: .atomic)
        }
    }

    @objc private func captureConstructedScreen() {
        // Never requests authorization. The shipping workflow can be entered
        // only after the reviewer clicks this menu and preflight already passes.
        guard ScreenCaptureService.hasPermission, let windows = reviewWindows else { return }
        screenshotRequestTask?.cancel(); screenshotRequestTask = nil
        screenshotCapture?.cancel()
        screenshotOverlay?.dismiss(restoreFocus: false)
        var configuration = TranslationServiceConfiguration(kind: .openAI)
        configuration.name = "Offline QA fixture"
        configuration.automaticallyTranslates = screenshotScene != "manual"
        do {
            try windows.services.save(configuration, apiKey: "constructed-visual-key-never-valid")
            try windows.services.select(configuration.id)
        } catch { return }
        screenshotRealCaptureStarted = true
        // RemoteTranslationProvider is replaced by the in-memory QA provider in
        // this executable. Neither real account credentials nor networking exist.
        screenshotCapture = ScreenshotTranslationController(windows: windows)
        screenshotCapture?.start(source: reviewSourceApplication)
        if let screenshotOutput { recordScreenshotObservation(output: screenshotOutput) }
    }

    /// Real window lifecycle with constructed pixels/results, for leaving the
    /// app, dismissing the shared window and reopening it through the shipping entry.
    private func presentResumeFixture() async {
        let domain = "TranslateX.TranslationServiceVisualReview.Resume.Ephemeral"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        self.defaults = defaults
        let preferences = AppPreferences(defaults: defaults)
        preferences.appearance = .light
        let services = TranslationServiceStore(defaults: defaults, credentials: VisualCredentialStore())
        let windows = WindowCoordinator(preferences: preferences, services: services)
        reviewWindows = windows
        windows.inputModel.text = "The draft before the screenshot remains recoverable."
        guard let document = try? await ScreenshotReviewFixture.document(dense: true) else { return }
        windows.prepareCapturedTranslation()
        windows.inputModel.source = "en"
        windows.inputModel.useScreenshotSourceName()
        windows.inputModel.submitCapturedDocument(document, serviceRevision: windows.inputModel.serviceRevision)
        if let request = windows.inputModel.request {
            await windows.inputModel.run(request, provider: ScreenshotReviewProvider())
        }
        windows.inputModel.cancel()
        windows.showCapturedTranslation(source: nil)
    }

    private func run() async {
        let defaultOutput = CommandLine.arguments.contains("--screenshot-overlay-review")
            ? FileManager.default.currentDirectoryPath + "/.build/QA/ScreenshotOverlayReview" : "/tmp/TranslateXTranslationServiceReview"
        let output = URL(fileURLWithPath: argument("--review-output", fallback: defaultOutput))
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--permission-window-review") {
            await presentPermissionFixture(output: output)
            return
        }
        if CommandLine.arguments.contains("--screenshot-overlay-review") {
            await presentScreenshotOverlayFixture(output: output)
            return
        }
        if CommandLine.arguments.contains("--unified-window-review") {
            await presentUnifiedWindowFixture(output: output)
            return
        }
        if CommandLine.arguments.contains("--review-update-focus") {
            await verifyUpdateFocus(output: output)
            return
        }
        if CommandLine.arguments.contains("--review-resume") {
            await presentResumeFixture()
            return
        }
        let dropdownContextsReview = CommandLine.arguments.contains("--review-dropdown-contexts")
        let refinementReview = CommandLine.arguments.contains("--review-settings-refinement")
        let languageSettingsReview = CommandLine.arguments.contains("--review-language-settings")
        let languageReview = CommandLine.arguments.contains("--review-language")
        let serviceListReview = CommandLine.arguments.contains("--review-service-list")
        let serviceEditorReview = CommandLine.arguments.contains("--review-service-editor")
        let serviceUsageChartsReview = CommandLine.arguments.contains("--review-service-usage-charts")
        let serviceUsageReview = serviceUsageChartsReview || CommandLine.arguments.contains("--review-service-usage")
        let interactions = CommandLine.arguments.contains("--review-interactions")
        let layouts = CommandLine.arguments.contains("--review-layouts")
        let brand = CommandLine.arguments.contains("--review-brand")
        let workspace = CommandLine.arguments.contains("--review-workspace")
        let inputFeedback = CommandLine.arguments.contains("--review-input-feedback")
        let toolbar = CommandLine.arguments.contains("--review-toolbar")
        let captureReview = CommandLine.arguments.contains("--review-capture")
        let toolbarMotion = CommandLine.arguments.contains("--review-toolbar-motion")
        let localSync = CommandLine.arguments.contains("--review-local-sync")
        let allProviders = CommandLine.arguments.contains("--review-all-providers")
        let states = CommandLine.arguments.contains("--review-states")
        let updateDialogs = CommandLine.arguments.contains("--review-update-dialogs")
        let updateScenes = ["small", "large", "download", "verify", "failed", "checking", "current", "check-failed",
                            "failed-long", "check-failed-long", "large-minimum", "failed-long-settings"]
            .map { "main-update-state-" + $0 }
        let batch = updateDialogs || dropdownContextsReview || refinementReview || serviceEditorReview || serviceUsageReview || languageSettingsReview || serviceListReview || languageReview || CommandLine.arguments.contains("--review-batch") || allProviders || states || interactions || layouts || brand || workspace || inputFeedback || localSync || toolbar || toolbarMotion || captureReview
        let scenes = updateDialogs ? updateScenes : dropdownContextsReview ? ["main-minimum", "quick-minimum", "main-capture-stacked-minimum"] : refinementReview ? ["general", "general-minimum", "general-controls", "general-controls-minimum", "usage-card", "usage-card-hover-minimum", "usage-summary-minimum", "usage-manager-minimum", "usage-empty-minimum"] : serviceEditorReview ? ["edit", "edit-minimum"] : serviceUsageChartsReview ? ["usage-7", "usage-30-minimum", "usage-samples-minimum"] : serviceUsageReview ? ["usage-card", "usage-card-hover-minimum", "usage-7", "usage-30-minimum", "usage-day-minimum", "usage-samples-minimum", "usage-empty-minimum", "usage-account-empty", "usage-account-deepseek-minimum", "usage-account-deepl-minimum"] : languageSettingsReview ? ["general", "general-minimum"] : serviceListReview ? ["list-untested", "list-selected", "list-history", "list-long-name", "list-empty"] : languageReview ? ["general", "general-controls", "shortcuts", "privacy", "main-minimum", "quick-stacked-minimum", "main-failed", "test-error"] : captureReview ? ["main-capture-dense-text", "main-capture-dense-image", "main-capture-text", "main-capture-menu-image", "main-capture-menu-original", "main-capture-stacked-minimum", "main-capture-recognizing", "main-capture-failed", "quick-capture-minimum", "quick-capture-menu-image"] : toolbarMotion ? ["main-motion", "main-motion-reduced", "main-motion-off", "quick-motion", "quick-motion-reduced", "quick-motion-off"] : toolbar ? ["main", "main-failed", "main-stopped-empty", "main-requesting", "main-empty", "main-minimum", "main-stacked-minimum", "main-manual-minimum", "quick", "quick-failed", "quick-stacked-minimum", "quick-stacked-minimum-manual-long-name", "list", "list-history"] : localSync ? ["main-numeric", "main-same-language", "main-swapped", "main-swapped-stacked-minimum", "main-manual-minimum", "main-uncertain", "quick-numeric-minimum", "quick-same-language-stacked-minimum", "quick-swapped", "quick-swapped-stacked-minimum"] : inputFeedback ? ["main-numeric", "main-uncertain", "main-manual-minimum", "main-requesting", "main-partial", "quick-numeric-minimum", "quick-uncertain-stacked-minimum", "quick-stacked-minimum-manual-long-name"] : workspace ? ["main-edited", "main-stopped-empty", "main-partial", "main-manual", "main-minimum", "main-stacked-minimum", "quick-edited", "quick-stopped-empty", "quick-partial", "quick-minimum", "quick-stacked-minimum", "quick-stacked-minimum-manual-long-name", "quick-long"] : brand ? ["main", "main-stacked", "main-stacked-minimum"] : layouts ? ["general", "general-controls", "main", "main-stacked", "main-stacked-minimum", "quick", "quick-stacked", "quick-stacked-long", "quick-stacked-minimum"] : interactions ? ["general", "shortcuts", "privacy", "list", "add", "edit", "quick", "quick-long", "quick-minimum"] : allProviders ? TranslationServiceKind.allCases.map(\.rawValue) : states ?
            ["catalog-loading", "catalog-empty", "catalog-error", "test-running", "test-success", "test-error", "validation", "account-code", "account-committing", "account-ready"] :
            batch ? ["list", "add", "edit", "deepl", "codex"] : [argument("--review-scene", fallback: "edit")]
        let themes = batch && !states ? ["light", "dark", "glass"] : [argument("--review-theme", fallback: "light")]
        var all: [String: [String: [String: CGFloat]]] = [:]
        for theme in themes {
            for scene in scenes {
                await present(scene: scene, theme: theme)
                try? await Task.sleep(for: .milliseconds(900))
                guard let window else { continue }
                window.contentView?.layoutSubtreeIfNeeded()
                if scene.hasPrefix("general-controls"), let content = window.contentView, let scroll = findScrollView(content) {
                    scroll.documentView?.scroll(NSPoint(x: 0, y: max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentSize.height)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                if scene.hasPrefix("usage-") { await scrollUsageIntoView(scene: scene, window: window) }
                // Update previews retain their real initial keyboard focus.
                if !scene.hasPrefix("main-update") { window.makeFirstResponder(nil) }
                try? await Task.sleep(for: .milliseconds(200))
                let key = "\(scene)-\(theme)"
                all[key] = frames.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
                await capture(window, key: key, output: output)
                if toolbarMotion {
                    // Compare actual native pixels over time, not just the presence
                    // of a Canvas or a particle at one frozen instant.
                    try? await Task.sleep(for: .milliseconds(800))
                    await capture(window, key: key + "-later", output: output)
                }
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("metrics.json"))
        }
        try? Data("Ready: native production views; constructed credentials, accounts and results only.\n".utf8)
            .write(to: output.appendingPathComponent("ready.txt"))
        if batch {
            closeReviewWindow()
            NSApp.terminate(nil)
        }
    }

    /// Ordinary NSWindow key transitions need a normally launched application.
    /// Keep every native focus assertion here instead of substituting panels or
    /// weakening the check when an XCTest host cannot activate itself.
    private func verifyUpdateFocus(output: URL) async {
        enum ReviewFailure: Error { case assertion(String) }
        var checks: [[String: Any]] = []
        var failures: [String] = []
        var main: NSWindow?
        var settings: NSWindow?
        var coordinator: WindowCoordinator?
        let domain = "TranslateX.TranslationServiceVisualReview.UpdateFocus.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp
        ]) { _ in nil }
        func diagnostic() -> [String: Any] {
            ["active": NSApp.isActive, "activationPolicy": NSApp.activationPolicy().rawValue,
             "keyWindow": NSApp.keyWindow.map { $0.windowNumber as Any } ?? NSNull(),
             "mainWindow": main.map { $0.windowNumber as Any } ?? NSNull(),
             "settingsWindow": settings.map { $0.windowNumber as Any } ?? NSNull(),
             "mainIsKey": main?.isKeyWindow ?? false, "settingsIsKey": settings?.isKeyWindow ?? false,
             "mainVisible": main?.isVisible ?? false, "settingsVisible": settings?.isVisible ?? false]
        }
        func require(_ condition: Bool, _ name: String) throws {
            checks.append(["name": name, "passed": condition, "diagnostic": diagnostic()])
            if !condition { throw ReviewFailure.assertion(name) }
        }
        func wait(_ name: String, until condition: () -> Bool) async throws {
            for _ in 0..<150 {
                if condition() { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try require(condition(), name)
        }
        func editors(in view: NSView) -> [TranslationInputTextView] {
            if let editor = view as? TranslationInputTextView { return [editor] }
            return view.subviews.flatMap { editors(in: $0) }
        }
        func verifyNoDateHint(in window: NSWindow, expectsAnchor: Bool = true, _ name: String) async throws {
            func hasDateAnchor(_ view: NSView) -> Bool {
                view is TooltipAnchorView || view.subviews.contains(where: hasDateAnchor)
            }
            var appeared = false
            for _ in 0..<15 {
                window.contentView?.layoutSubtreeIfNeeded()
                appeared = appeared || (window.childWindows ?? []).contains { child in
                    (child.contentView?.subviews.first as? NSTextField)?.stringValue.contains("(UTC") == true
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let modal = (window.contentView as? WindowSurface<SettingsView>)?.modalHostingView
                ?? (window.contentView as? WindowSurface<InputTranslationView>)?.modalHostingView
            try require(window.isKeyWindow && modal != nil
                        && modal.map(hasDateAnchor) == expectsAnchor && !appeared, name)
        }
        do {
            let preferences = AppPreferences(defaults: defaults)
            preferences.appearance = .light
            let fixture = VisualCodexAccount(.signedOut)
            let services = TranslationServiceStore(defaults: defaults, credentials: VisualCredentialStore(),
                codex: CodexAccountController(sessionFactory: { request in fixture.session(request) }))
            let windows = WindowCoordinator(preferences: preferences, services: services)
            coordinator = windows
            let updates = AppUpdateController.visualReview(previewAvailableUpdate: true)
            windows.updates = updates
            updates.onPresentUpdate = { [weak windows] in windows?.showUpdate() }
            windows.inputModel.setAutomaticTranslation(false)
            windows.inputModel.text = "Constructed draft retained through update focus verification."
            let shortcuts = ShortcutSettings(preferences: preferences, manager: ShortcutManager(),
                                             onAction: { _ in }, onBindingsChanged: {})
            windows.showSettings(shortcuts: shortcuts)
            settings = NSApp.windows.first { $0.identifier?.rawValue == "translatex.settings" && $0.isVisible }
            try require(settings != nil, "Settings uses the real coordinator window")
            windows.showMain()
            main = NSApp.windows.first { $0.identifier?.rawValue == "translatex.main" && $0.isVisible }
            guard let main, let settings, let surface = main.contentView as? WindowSurface<InputTranslationView> else {
                throw ReviewFailure.assertion("Main window and native surface exist")
            }
            try await wait("Main window really becomes key before requesting the update") {
                main.isKeyWindow && !settings.isKeyWindow && editors(in: surface).count == 2
            }
            let originalEditors = editors(in: surface)
            let originalContents = originalEditors.map(\.string)
            let originalDraft = windows.inputModel.text
            var pendingExit: (@MainActor () -> Void)?
            var exitRequests = 0
            var installReplies = 0
            windows.serviceNavigation.exitHandler = { action in
                exitRequests += 1
                pendingExit = action
            }
            updates.offerUpdate(version: "1.0.1", informationOnly: false, informationURL: nil,
                                userInitiated: true) { _ in installReplies += 1 }
            try require(pendingExit != nil && exitRequests == 1, "Update requests the settings draft guard once")
            try require(!windows.serviceNavigation.isPresentingConfirmation && !updates.showsMainUpdate,
                        "An unreported draft confirmation does not approve the update")
            await Task.yield()
            try require(main.isKeyWindow && !settings.isKeyWindow && surface.modalHostingView == nil,
                        "Requesting confirmation does not flash Settings or mount an update")
            try require(installReplies == 0, "Pending confirmation cannot install the update")

            // Match SwiftUI's delayed onChange publication, rather than setting
            // this flag synchronously inside the draft-exit handler.
            windows.serviceNavigation.isPresentingConfirmation = true
            try await wait("Delayed confirmation makes Settings key and Main non-key") {
                settings.isKeyWindow && !main.isKeyWindow
            }
            try require(!updates.showsMainUpdate && !updates.isPresentingMainModal && surface.modalHostingView == nil,
                        "The settings confirmation keeps the main update modal unmounted")
            updates.focusUpdate()
            try require(exitRequests == 1, "Refocusing preserves the pending draft decision")

            windows.serviceNavigation.isPresentingConfirmation = false
            guard let approve = pendingExit else { throw ReviewFailure.assertion("Draft approval remains available") }
            pendingExit = nil
            approve()
            try await wait("Approving the draft makes Main key with its update modal") {
                main.isKeyWindow && !settings.isKeyWindow && surface.modalHostingView != nil
                    && originalEditors.allSatisfy { !$0.isInteractionEnabled }
            }
            try require(updates.showsMainUpdate && updates.isPresentingMainModal && main.contentView === surface,
                        "The approved update reuses the original main content")
            try require(installReplies == 0, "Showing a manual update still waits for install confirmation")
            try await verifyNoDateHint(in: main, "Opening the main update does not show the publication hint")
            updates.dismissUpdate()
            try await wait("Dismissing the update restores editors without leaving Main") {
                main.isKeyWindow && surface.modalHostingView == nil && originalEditors.allSatisfy(\.isInteractionEnabled)
            }
            try require(main.contentView === surface
                        && editors(in: surface).map(ObjectIdentifier.init) == originalEditors.map(ObjectIdentifier.init)
                        && originalEditors.map(\.string) == originalContents && windows.inputModel.text == originalDraft,
                        "Dismissal preserves the native editor instances and constructed draft")
            windows.serviceNavigation.exitHandler = nil
            windows.showAbout()
            try await wait("About becomes key before the direct update") { settings.isKeyWindow && !main.isKeyWindow }
            updates.performUpdateAction(in: .settings)
            try await wait("One About action starts the constructed download") {
                updates.updatePresentation?.phase == .downloading
            }
            try require(settings.isKeyWindow && !main.isKeyWindow && updates.showsSettingsUpdate
                        && !updates.showsMainUpdate && surface.modalHostingView == nil,
                        "About download stays in Settings without a main-window confirmation")
            try await wait("The constructed download proceeds to installation without another action") {
                updates.updatePresentation?.phase == .installing
            }
            try require(settings.isKeyWindow && !main.isKeyWindow,
                        "Installation progress remains in Settings")
            try await wait("The simulated install completes without replacing the real app") {
                updates.updatePresentation == nil
            }
            try require(windows.inputModel.text == originalDraft && !updates.automaticUpdatesEnabled,
                        "Direct installation preserves the draft and automatic-update preference")

            // Hold every phase in the real settings modal long enough for
            // SwiftUI's delayed focus and layout updates. No installer runs.
            updates.offerUpdate(version: "1.0.1", informationOnly: false, informationURL: nil,
                                userInitiated: true, reply: { _ in })
            try await verifyNoDateHint(in: settings, "Opening the settings update does not show the publication hint")
            updates.downloadStarted {}
            try await verifyNoDateHint(in: settings, expectsAnchor: false, "Starting download does not show the publication hint")
            updates.extractionStarted()
            try await verifyNoDateHint(in: settings, expectsAnchor: false, "Preparing the update does not show the publication hint")
            updates.extractionProgress(1)
            try await verifyNoDateHint(in: settings, expectsAnchor: false, "Completing verification does not show the publication hint")
            updates.readyToInstall { _ in }
            try await verifyNoDateHint(in: settings, "Returning to the install action does not show the publication hint")
            updates.installing()
            try await verifyNoDateHint(in: settings, expectsAnchor: false, "Starting installation does not show the publication hint")
            updates.installationDismissed()
            updates.offerUpdate(version: "1.0.1", informationOnly: false, informationURL: nil,
                                userInitiated: true, reply: { _ in })
            try await verifyNoDateHint(in: settings, "Reopening the settings update does not show the publication hint")
            updates.dismissUpdate()
        } catch ReviewFailure.assertion(let name) {
            failures.append(name)
        } catch {
            failures.append("Focus review interrupted: \(String(describing: error))")
        }
        let report: [String: Any] = ["checkCount": checks.count, "checks": checks, "failures": failures,
                                     "passed": failures.isEmpty, "finalDiagnostic": diagnostic()]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("focus-results.json"), options: .atomic)
        } catch {
            failures.append("Could not write the focus review result")
        }
        coordinator?.shutdown()
        main?.close()
        settings?.close()
        defaults.removePersistentDomain(forName: domain)
        if let monitor { NSEvent.removeMonitor(monitor) }
        exit(failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    private func capture(_ window: NSWindow, key: String, output: URL) async {
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        let captureRect = [window.frame.minX, screenTop - window.frame.maxY, window.frame.width, window.frame.height]
        let job: [String: Any] = ["windowID": window.windowNumber, "region": captureRect, "scene": key,
            "output": output.appendingPathComponent("\(key).png").path,
            "sheetCount": window.sheets.count]
        if let data = try? JSONSerialization.data(withJSONObject: job) {
            try? data.write(to: output.appendingPathComponent("capture-job.json"), options: .atomic)
        }
        if CommandLine.arguments.contains("--review-external-capture") {
            for _ in 0..<200 {
                let acknowledgement = try? String(contentsOf: output.appendingPathComponent("capture-done.txt"), encoding: .utf8)
                if acknowledgement == key { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.compactMap(findScrollView).first
    }

    private func scrollUsageIntoView(scene: String, window: NSWindow) async {
        guard scene.contains("day") else { return }
        guard let content = window.contentView, let scroll = findScrollView(content), let document = scroll.documentView,
              let viewport = frames["usage.scroll"] else { return }
        // Lazy request rows below the initial viewport need to be realized
        // before the expanded request can supply its geometry preference.
        if let table = frames["usage.requests"] {
            let proposed = scroll.contentView.bounds.minY + table.minY - viewport.minY
            document.scroll(NSPoint(x: 0, y: min(max(0, proposed), max(0, document.frame.height - scroll.contentSize.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
            try? await Task.sleep(for: .milliseconds(250))
        }
        let targetKey = "usage.details"
        guard let target = frames[targetKey] else { return }
        let currentViewport = frames["usage.scroll"] ?? viewport
        let proposed = scroll.contentView.bounds.minY + target.minY - currentViewport.minY - 8
        let maximum = max(0, document.frame.height - scroll.contentSize.height)
        document.scroll(NSPoint(x: 0, y: min(max(0, proposed), maximum)))
        scroll.reflectScrolledClipView(scroll.contentView)
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func seedUsage(_ store: TranslationUsageStore, configuration: TranslationServiceConfiguration, unpriced: Bool = false) {
        let now = Date()
        // Constructed, isolated visual-review rates, never fetched or used by
        // the installed application. Legacy currency preservation has unit coverage.
        let historical = TranslationServiceConfiguration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!, name: "OpenAI", kind: .openAI,
            endpoint: "https://api.openai.com/v1", model: "fixture-text-model")
        let prices = [
            TranslationModelPrice(provider: "deepseek", model: configuration.model, currency: "USD", input: 0.2, output: 0.8,
                cacheRead: 0.02, cacheWrite: nil, fetchedAt: now, source: "models.dev"),
            TranslationModelPrice(provider: "openai", model: historical.model, currency: "USD", input: 1.5, output: 6,
                cacheRead: 0.15, cacheWrite: nil, fetchedAt: now, source: "models.dev"),
            TranslationModelPrice(provider: "anthropic", model: "fixture-long-model", currency: "USD", input: 3, output: 15,
                cacheRead: 0.3, cacheWrite: 3.75, fetchedAt: now, source: "models.dev")
        ]
        if !unpriced { store.pricing.installReferencePrices(prices) }
        store.registerConfigurations([configuration, historical])
        for offset in (0..<29).reversed() {
            let count = [3, 5, 2, 7, 4, 6, 8][offset % 7]
            for index in (0..<count).reversed() {
                let completed = Calendar.current.date(byAdding: .day, value: -offset, to: now)!
                    .addingTimeInterval(-600 - Double(index * 83))
                let local = index == 1
                let external = index % 4 == 0 ? historical : configuration
                let outcome: TranslationUsageOutcome = index == 0 && offset % 4 == 0 ? .failed : .succeeded
                let ticket = store.begin(configurationID: local ? nil : external.id, model: local ? "" : external.model,
                    purpose: .translation, now: completed.addingTimeInterval(-0.7 - Double(index) * 0.2))
                let counts = local ? nil : TranslationUsage(inputTokens: 180 + index * 32, outputTokens: 90 + offset * 4,
                    totalTokens: 270 + index * 32 + offset * 4, cacheReadTokens: index * 10)
                store.finish(ticket, outcome: outcome, usage: counts,
                    httpStatus: local ? nil : outcome == .succeeded ? 200 : offset % 8 == 0 ? 429 : 500, now: completed)
            }
            if offset % 3 == 0 {
                let completed = Calendar.current.date(byAdding: .day, value: -offset, to: now)!.addingTimeInterval(-300)
                let ticket = store.begin(configurationID: configuration.id, model: configuration.model,
                                         purpose: .sampleTest, now: completed.addingTimeInterval(-0.9))
                store.finish(ticket, outcome: .succeeded, usage: TranslationUsage(inputTokens: 24, outputTokens: 11, totalTokens: 35, cacheReadTokens: 0), httpStatus: 200, now: completed)
            }
        }
        store.flush()
    }

    private func closeReviewWindow() {
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didActivateApplicationNotification, object: nil)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: window)
        }
        permissionObservationOutput = nil
        permissionObservationTimer?.invalidate()
        permissionObservationTimer = nil
        unifiedObservationTimer?.invalidate()
        unifiedObservationTimer = nil
        screenshotObservationTimer?.invalidate()
        screenshotObservationTimer = nil
        screenshotRequestTask?.cancel()
        screenshotRequestTask = nil
        screenshotCapture?.cancel()
        screenshotCapture = nil
        screenshotOverlay?.dismiss(restoreFocus: false)
        screenshotOverlay = nil
        if let window {
            for sheet in window.sheets { window.endSheet(sheet); sheet.orderOut(nil) }
            window.close()
        }
    }

    private func present(scene: String, theme: String) async {
        workspaceModel?.cancel()
        session?.close()
        fixture?.cancelAll()
        closeReviewWindow()
        frames = [:]
        let domain = "TranslateX.TranslationServiceVisualReview.Ephemeral"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        self.defaults = defaults
        let preferences = AppPreferences(defaults: defaults)
        let languageArgument = argument("--review-interface-language", fallback: "system")
        let interfaceLanguage: AppInterfaceLanguage = languageArgument == "en" ? .english : languageArgument == "zh-Hans" ? .simplifiedChinese : .system
        preferences.interfaceLanguage = interfaceLanguage
        L10n.apply(interfaceLanguage)
        preferences.translationLayout = scene.contains("stacked") ? .stacked : .sideBySide
        preferences.appearance = theme.hasPrefix("dark") ? .dark : .light
        preferences.material = theme.contains("glass") ? .glass : .light
        let fixture = VisualCodexAccount(scene == "account-code" ? .deviceCode : scene == "account-committing" ? .committing : scene == "account-ready" ? .signedIn : .signedOut)
        self.fixture = fixture
        let services = TranslationServiceStore(defaults: defaults, credentials: VisualCredentialStore(),
            codex: CodexAccountController(sessionFactory: { request in fixture.session(request) }))
        if backdrop == nil, let screen = NSScreen.main {
            let background = NSWindow(contentRect: screen.visibleFrame, styleMask: [.borderless], backing: .buffered, defer: false)
            background.isReleasedWhenClosed = false
            background.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
            background.contentView = NSHostingView(rootView: ReviewWallpaper())
            background.orderFrontRegardless()
            backdrop = background
        }
        if scene.hasPrefix("quick-permission") {
            // Exercise the real panel sizing and handoff without requesting TCC access.
            let windows = WindowCoordinator(preferences: preferences, services: services)
            windows.inputModel.sourceName = "Google Chrome"
            reviewWindows = windows
            windows.showPermission(scene.contains("screen") ? .screenCapture : .accessibility, source: reviewSourceApplication)
            window = NSApp.windows.first { $0.identifier?.rawValue == "translatex.permission" && $0.isVisible }
            if scene.contains("minimum"), let window {
                window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true)
            }
            window?.appearance = NSAppearance(named: theme.hasPrefix("dark") ? .darkAqua : .aqua)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if scene.hasPrefix("release-notes") || scene.hasPrefix("main-update") {
            // Do not inherit the review app's legacy autosaved window size.
            preferences.rememberWindowSize(scene.contains("minimum")
                ? preferences.translationLayout.minimumSize(for: .main)
                : preferences.translationLayout.defaultSize(for: .main),
                for: .main, layout: preferences.translationLayout)
            let windows = WindowCoordinator(preferences: preferences, services: services)
            let updateFixture = UpdateDialogReviewState(scene: scene)
            let updates = updateFixture.map { UpdateDialogReviewBackend.controller(state: $0, defaults: defaults) }
                ?? AppUpdateController.visualReview(previewInstalledNotes: scene.hasPrefix("release-notes"),
                                                           shortReleaseNotes: scene.contains("short"),
                                                           previewAvailableUpdate: scene.hasPrefix("main-update"),
                                                           compactReleaseNotes: scene.contains("compact"),
                                                           checkOutcome: scene.contains("check")
                                                            ? (scene.contains("failed") ? "failed" : scene.contains("current") ? "current" : "available") : nil)
            windows.updates = updates
            updates.onPresentUpdate = { [weak windows] in windows?.showUpdate() }
            reviewWindows = windows
            if scene.contains("settings") {
                let shortcuts = ShortcutSettings(preferences: preferences, manager: ShortcutManager(), onAction: { _ in }, onBindingsChanged: {})
                windows.showSettings(shortcuts: shortcuts)
                windows.showAbout()
                if scene.hasPrefix("release-notes") { updates.showRecentReleaseNotes() }
                if scene.contains("check") || updateFixture != nil { updates.checkForUpdates(in: .settings) }
            } else if scene.hasPrefix("main-update") {
                windows.showMain()
                if updateFixture != nil { updates.checkForUpdates(in: .mainWindow) }
                else if scene.contains("modal") || scene.contains("check") { updates.performUpdateAction() }
            } else {
                if scene.contains("recent") { updates.showRecentReleaseNotes(in: .mainWindow) }
                windows.showMainReleaseNotes()
            }
            window = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue == (scene.contains("settings") ? "translatex.settings" : "translatex.main") }
            window?.level = .floating
            window?.appearance = NSAppearance(named: theme.hasPrefix("dark") ? .darkAqua : .aqua)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        var deepSeek = TranslationServiceConfiguration(kind: .deepSeek)
        deepSeek.name = scene.contains("long-name") ? "My translation service with a long name" : "DeepSeek"
        var openAI = TranslationServiceConfiguration(kind: .openAI)
        openAI.name = "英文阅读"
        let singleExternalService = ["list-untested", "list-selected"].contains(scene)
        if singleExternalService { deepSeek.model = "deepseek-flash" }
        if scene != "list-empty" {
            try? services.save(deepSeek, apiKey: "constructed-visual-key-never-valid")
            if !singleExternalService { try? services.save(openAI, apiKey: "constructed-visual-key-never-valid") }
        }
        if scene == "list-selected" { try? services.select(deepSeek.id) }
        var usageState: TranslationServiceReviewUsageState?
        if scene.hasPrefix("usage-") || scene.hasPrefix("statistics") {
            let reviewed: TranslationServiceConfiguration
            if scene.contains("deepl") {
                reviewed = TranslationServiceConfiguration(kind: .deepL)
                try? services.save(reviewed, apiKey: "constructed-visual-key-never-valid")
            } else { reviewed = deepSeek }
            try? services.select(reviewed.id)
            if !scene.contains("empty") { seedUsage(services.usage, configuration: reviewed, unpriced: scene.contains("unpriced")) }
            usageState = .init(configurationID: reviewed.id, accountTab: scene.contains("account"),
                days: scene.contains("summary") ? 0 : scene.contains("30") ? 30 : 7,
                selectedDay: scene.contains("day") ? Calendar.current.startOfDay(for: Date().addingTimeInterval(-600)) : nil,
                sampleTests: scene.contains("samples"),
                snapshot: scene.contains("account") && !scene.contains("empty") ? VisualAccountUsageFixture.snapshot(kind: reviewed.kind) : nil)
            usageState?.opensUsagePage = !scene.contains("account") && scene != "usage-card" && scene != "usage-card-hover-minimum"
            usageState?.hoveredID = scene == "usage-card-hover-minimum" ? reviewed.id : nil
            usageState?.expandDetails = scene.contains("day") || scene.contains("samples") || scene.contains("30") || scene == "usage-7"
            if scene.contains("manager") { usageState?.opensUsagePage = false; usageState?.opensManager = true }
            if scene == "usage-card" || scene == "usage-card-hover-minimum" {
                usageState?.snapshot = VisualAccountUsageFixture.snapshot(kind: reviewed.kind)
                services.recordSampleTest(.succeeded, for: reviewed, revision: services.configurationRevision(for: reviewed.id), completedAt: Date())
            }
        }
        if scene.hasPrefix("list"), scene != "list-empty", !singleExternalService {
            services.recordSampleTest(.succeeded, for: deepSeek, revision: services.configurationRevision(for: deepSeek.id), completedAt: Date().addingTimeInterval(-1800))
            if scene == "list-history" {
                services.recordSampleTest(.failed, for: openAI, revision: services.configurationRevision(for: openAI.id), completedAt: Date().addingTimeInterval(-86400))
                var changed = TranslationServiceConfiguration(kind: .claude)
                try? services.save(changed, apiKey: "constructed-visual-key-never-valid")
                services.recordSampleTest(.succeeded, for: changed, revision: services.configurationRevision(for: changed.id), completedAt: Date().addingTimeInterval(-86400 * 3))
                changed.model = "constructed-new-model"
                try? services.save(changed, apiKey: nil)
            }
        }
        let kind = TranslationServiceKind(rawValue: scene) ?? (scene == "deepl" ? .deepL : scene == "codex" || scene.hasPrefix("account-") ? .codex : .openAI)
        let pageTabs = ["general": 0, "general-minimum": 0, "general-controls": 0, "general-controls-minimum": 0, "shortcuts": 1, "privacy": 2, "statistics": 4, "statistics-minimum": 4, "statistics-unpriced-minimum": 4, "about": 5, "about-minimum": 5]
        let isQuick = scene.hasPrefix("quick")
        let isMain = scene.hasPrefix("main")
        let session: TranslationServiceDraftSession? = scene.hasPrefix("list") || scene.hasPrefix("usage-") || pageTabs[scene] != nil || isQuick || isMain ? nil : .init(services: services,
            configuration: scene.hasPrefix("edit") ? openAI : nil, modelLoader: TranslationServiceModelCatalog(scene: scene))
        if !scene.hasPrefix("edit") { session?.selectKind(kind) }
        self.session = session
        let shortcuts = ShortcutSettings(preferences: preferences, manager: ShortcutManager(), onAction: { _ in }, onBindingsChanged: {})
        let navigation = TranslationServiceNavigationCoordinator()
        let content = SettingsView(preferences: preferences, shortcuts: shortcuts, permissions: PermissionStatus(),
            catalog: LanguageCatalog(), defaultTargetChanged: {}, appearanceChanged: {},
            interfaceLanguageChanged: { L10n.apply(preferences.interfaceLanguage) }, services: services,
            serviceNavigation: navigation, updates: AppUpdateController.visualReview(), serviceSession: session, tab: pageTabs[scene] ?? 3)
        let size: NSSize = isQuick || isMain
            ? (scene.contains("minimum") ? preferences.translationLayout.minimumSize(for: .main)
                : preferences.translationLayout.defaultSize(for: .main))
            : (scene.contains("minimum") ? NSSize(width: 900, height: 600) : NSSize(width: 1100, height: 700))
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: rect,
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        TranslateXWindowChrome.configure(window)
        window.setFrame(rect, display: false)
        window.appearance = NSAppearance(named: theme.hasPrefix("dark") ? .darkAqua : .aqua)
        window.title = "翻译服务 · 原生视觉核查（构造数据）"
        // Keep the owned synthetic capture surface above unrelated desktop
        // windows. This affects only the review fixture, never shipping windows.
        window.level = .floating
        window.identifier = NSUserInterfaceItemIdentifier("translatex.service.visual-review")
        window.isReleasedWhenClosed = false
        if isQuick || isMain {
            let reviewSource = "Good design makes complex things feel effortless.\nKeep useful tools close to the text.\nSmall adjustments can bring noticeable improvements."
            let reviewTarget = "好的设计，让复杂的事情变得轻松。\n让常用工具贴近内容。\n小小的调整，也能带来明显的改善。"
            if scene.contains("partial") || scene.contains("long-name") || scene.contains("interactive") { try? services.select(deepSeek.id) }
            let model = TranslationModel(automaticallyTranslates: true, services: services, remoteProvider: { _, _, partial in
                WorkspaceReviewProvider(source: reviewSource, target: reviewTarget, partial: partial, fragment: scene.contains("partial"))
            })
            workspaceModel = model
            let unresolvedInput = scene.contains("numeric") || scene.contains("uncertain") || scene.contains("same-language")
            model.source = unresolvedInput ? "auto" : "en"
            model.target = "zh-Hans"
            model.sourceName = isQuick ? "Google Chrome" : ""
            let source = scene.contains("numeric") ? "123\n456.78" : scene.contains("same-language") ? "123\n哈哈" : scene.contains("uncertain") ? "今日仕事" : reviewSource
            let translated = reviewTarget
            model.text = scene.contains("long") ? Array(repeating: source, count: 15).joined(separator: "\n\n") : source
            model.submit()
            if !scene.contains("stopped-empty"), !scene.contains("partial"), !scene.contains("requesting"), let request = model.request {
                await model.run(request, provider: FixtureProvider(output: scene.contains("long") ? Array(repeating: translated, count: 15).joined(separator: "\n\n") : translated))
            }
            if scene.contains("swapped") { model.swapLanguages() }
            if scene.contains("edited") || scene.contains("manual") {
                if scene.contains("manual") { model.setAutomaticTranslation(false) }
                model.editingChanged(reviewTarget, isComposing: false, side: .target)
                // Change one character to represent a genuine edit after completion.
                model.editingChanged(reviewTarget + "\n", isComposing: false, side: .target)
                if !scene.contains("manual") {
                    model.submit()
                    if let request = model.request {
                        await model.run(request, provider: WorkspaceReviewProvider(source: reviewSource, target: reviewTarget))
                    }
                }
            }
            if scene.contains("partial") {
                for _ in 0..<100 { if !model.partialText.isEmpty { break }; await Task.yield() }
                model.cancel()
            } else if scene.contains("stopped-empty") { model.cancel() }
            if scene.contains("failed") {
                model.submit()
                if let request = model.request { await model.run(request, provider: ServiceReviewTranslation(scene: "test-error")) }
            }
            if scene == "main-empty" { model.clear() }
            if scene.contains("motion-off") { model.setAutomaticTranslation(false) }
            if scene.contains("capture") {
                let document = try? await ScreenshotReviewFixture.document(menu: scene.contains("menu"), dense: scene.contains("dense"))
                if let document {
                    model.useScreenshotSourceName()
                    model.submitCapturedDocument(document, serviceRevision: model.serviceRevision)
                    if let request = model.request { await model.run(request, provider: ScreenshotReviewProvider()) }
                    if scene.contains("recognizing") { model.beginRecognition(image: document.image) }
                    if scene.contains("failed") { model.fail(L10n.string("Text recognition couldn’t finish. Try selecting the area again.")) }
                }
            }
            // Legacy quick-* scene names remain useful fixtures for captured
            // content, but always render the one shipping translation workspace.
            let main = InputTranslationView(model: model, catalog: LanguageCatalog(), translateSelection: {}, translateScreenshot: {}, openSettings: {})
            if scene.contains("motion") {
                window.contentView = WindowSurface(preferences: preferences, content: ServiceReviewSurface(content: main.environment(\.translationReviewReduceMotion, scene.contains("reduced")), report: { [weak self] in self?.frames = $0 }))
            } else {
                window.contentView = WindowSurface(preferences: preferences, content: ServiceReviewSurface(content: main.environment(\.translationReviewCaptureMode, scene.contains("original") ? "original" : scene.contains("image") ? "image" : "text"), report: { [weak self] in self?.frames = $0 }))
            }
        } else {
            window.contentView = WindowSurface(preferences: preferences, content: ServiceReviewSurface(
                content: content.environment(\.translationServiceReviewUsageState, usageState), report: { [weak self] in self?.frames = $0 }))
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        if let editor = session?.editor {
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                if scene.hasPrefix("catalog-") || scene.hasPrefix("test-") {
                    editor.replacementKey = "constructed-visual-key-never-valid"
                }
                if scene.hasPrefix("catalog-") { editor.fetchModels() }
                if scene.hasPrefix("test-") { editor.configuration.model = "constructed-model-a"; editor.test(using: ServiceReviewTranslation(scene: scene)) }
                if scene == "validation" {
                    editor.configuration.name = ""
                    _ = editor.save()
                }
                if scene == "account-code" || scene == "account-committing" { editor.signInCodex() }
                if scene == "account-ready" { editor.refreshCodexModels() }
            }
        }
    }
}

@MainActor
private struct WorkspaceReviewProvider: TranslationProvider {
    let source: String
    let target: String
    var partial: (@MainActor @Sendable (String) -> Void)? = nil
    var fragment = false
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        if fragment {
            partial?("好的设计，让复杂的事情变得轻松。")
            try await Task.sleep(for: .seconds(60))
        }
        try await Task.sleep(for: .milliseconds(400))
        try Task.checkCancellation()
        return TranslationResult(text: request.target == "en" ? source : target, source: request.source, target: request.target)
    }
}

private enum UpdateDialogReviewState: String {
    case small, large, download, verify, failed
    case failedLong = "failed-long"
    case checking, current
    case checkFailed = "check-failed"
    case checkFailedLong = "check-failed-long"

    init?(scene: String) {
        guard scene.hasPrefix("main-update-state-") else { return nil }
        self.init(rawValue: String(scene.dropFirst("main-update-state-".count))
            .replacingOccurrences(of: "-settings", with: "")
            .replacingOccurrences(of: "-minimum", with: ""))
    }
}

/// Holds each production dialog state for review. All update data and callbacks
/// remain in memory; retries never reach Sparkle or a remote service.
@MainActor
private final class UpdateDialogReviewBackend: AppUpdaterBackend {
    weak var owner: AppUpdateController?
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    private let state: UpdateDialogReviewState
    private var checks = 0
    private var pending: Task<Void, Never>?
    private let publication = Date().addingTimeInterval(-3_600)

    init(state: UpdateDialogReviewState) { self.state = state }

    static func controller(state: UpdateDialogReviewState, defaults: UserDefaults) -> AppUpdateController {
        let backend = UpdateDialogReviewBackend(state: state)
        let chinese = state == .large
            ? (1...18).map { "- **构造改进 \($0)** 改善窗口切换、双栏编辑和更新状态展示，保留当前输入并支持键盘操作。" }.joined(separator: "\n")
            : "- 修复双栏编辑清空后仍保留旧内容的问题。\n- 改善更新窗口的尺寸和键盘操作。"
        let english = state == .large
            ? (1...18).map { "- **Constructed improvement \($0)** Improve window switching, editing and update states while preserving the current draft and keyboard navigation." }.joined(separator: "\n")
            : "- Clear stale content after clearing the other pane.\n- Improve update dialog sizing and keyboard navigation."
        let release = AppRelease(version: "1.3.4", publishedAt: backend.publication,
            notes: "## 中文\n\(chinese)\n## English\n\(english)",
            url: URL(string: "https://example.invalid/constructed-release")!)
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false,
            isReleaseBuild: true, currentVersion: "1.3.3", defaults: defaults, recordsInstalledVersions: false,
            backend: backend, releases: AppReleaseNotesStore(entries: [release], allowsNetworkLoading: false))
        backend.owner = updates
        updates.start()
        return updates
    }

    func start() throws {}
    func checkInformation() {
        owner?.foundUpdate("1.3.4", publishedAt: publication)
        owner?.finishedCheck()
    }
    func checkUpdates() {
        checks += 1
        owner?.showUpdateCheck { [weak self] in
            self?.pending?.cancel()
            self?.owner?.finishedCheck()
        }
        if checks > 1 {
            pending = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                offer()
                owner?.finishedCheck()
            }
            return
        }
        switch state {
        case .checking: return
        case .current: owner?.updateNotFound()
        case .checkFailed: owner?.updateErrored()
        case .checkFailedLong: owner?.updateErrored(URLError(.timedOut))
        default:
            offer()
            switch state {
            case .download: holdDownload()
            case .verify: holdDownload(); owner?.extractionStarted()
            case .failed: holdDownload(); owner?.updateErrored()
            case .failedLong: holdDownload(); owner?.updateErrored(URLError(.timedOut))
            default: break
            }
        }
        owner?.finishedCheck()
    }
    private func offer() {
        owner?.offerUpdate(version: "1.3.4", informationOnly: false, informationURL: nil,
                           publishedAt: publication, userInitiated: true) { [weak self] choice in
            if choice == .install { self?.holdDownload() }
        }
    }
    private func holdDownload() {
        owner?.downloadStarted { [weak self] in self?.owner?.finishedCheck() }
        owner?.downloadExpected(80_000_000)
        owner?.downloadReceived(33_600_000)
    }
}

private struct ReviewWallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.76, green: 0.92, blue: 0.96), Color(red: 0.56, green: 0.7, blue: 0.89),
            Color(red: 0.91, green: 0.78, blue: 0.88)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct ServiceReviewSurface<Content: View>: View {
    let content: Content
    let report: @MainActor ([String: CGRect]) -> Void
    var body: some View {
        content.coordinateSpace(name: "service-design.window")
            .onPreferenceChange(TranslationServiceLayoutFrames.self) { frames in report(frames) }
    }
}

@MainActor
private struct ServiceReviewTranslation: TranslationProvider {
    let scene: String
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try await Task.sleep(for: scene == "test-running" ? .seconds(60) : .milliseconds(200))
        if scene == "test-error" { throw RemoteTranslationError.invalidKey }
        return .init(text: "清晰的句子很容易理解。", source: "en", target: "zh-Hans")
    }
}
