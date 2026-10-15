import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class QuickPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onClose: (() -> Void)?
    var isTrackingMenu = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {
        guard !isTrackingMenu, attachedSheet == nil,
              (firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        onEscape?()
    }

    // Both the native close button and File > Close need coordinator cleanup.
    override func performClose(_ sender: Any?) { (onClose ?? onEscape)?() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSWindow.performClose(_:)) { return onClose != nil || onEscape != nil }
        return super.validateUserInterfaceItem(item)
    }
}

@MainActor
final class TranslationWindow: NSWindow {
    var onEscape: (() -> Void)?
    var isTrackingMenu = false
    override func cancelOperation(_ sender: Any?) {
        guard !isTrackingMenu, attachedSheet == nil,
              (firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        onEscape?()
    }
}

@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    let preferences: AppPreferences
    let permissions = PermissionStatus()
    let services: TranslationServiceStore
    let inputModel: TranslationModel
    let languages = LanguageCatalog()
    var updates: AppUpdateController? {
        didSet { trackMainModal(); trackSettingsModal() }
    }
    var onSelection: (() -> Void)?
    var onScreenshot: (() -> Void)?
    var onSettings: (() -> Void)?
    var onPermission: ((SystemPermission) -> Void)?
    var onQuickOperationCancelled: (() -> Void)?
    private var mainWindow: TranslationWindow?
    private var settingsWindow: NSWindow?
    let serviceNavigation = TranslationServiceNavigationCoordinator()
    let settingsNavigation = SettingsNavigation()
    lazy var accounts = TranslationAccountUsageController(services: services)
    private var observesAccountQueries = false
    private var settingsShortcuts: ShortcutSettings?
    private weak var inputEditor: TranslationInputTextView?
    private weak var inputTranslationEditor: TranslationInputTextView?
    private var needsInputFocus = false
    private var panel: QuickPanel?
    private var panelPermission: SystemPermission?
    private var permissionSourceApplication: NSRunningApplication?
    private var automaticMainSize: NSSize?
    private var presentedLayout: TranslationLayout
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var trackedMenus = Set<ObjectIdentifier>()
    private var sourceApplication: NSRunningApplication?
    private var previousSourceApplication: NSRunningApplication?
    private var translationKeyMonitor: Any?
    private var observesMenuTracking = false

    override convenience init() { self.init(preferences: AppPreferences()) }

    init(preferences: AppPreferences, services: TranslationServiceStore = TranslationServiceStore()) {
        self.preferences = preferences
        L10n.apply(preferences.interfaceLanguage)
        presentedLayout = preferences.translationLayout
        self.services = services
        inputModel = TranslationModel(automaticallyTranslates: true, services: services)
        super.init()
        inputModel.target = preferences.defaultTarget
        trackLayout()
        trackInterfaceLanguage()
        trackSettingsConfirmation()
    }

    private func trackInterfaceLanguage() {
        withObservationTracking { _ = preferences.interfaceLanguage } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyInterfaceLanguage()
                self?.trackInterfaceLanguage()
            }
        }
    }

    func startAccountQueries() {
        guard !observesAccountQueries else { return }
        observesAccountQueries = true
        accounts.startAutomaticRefresh()
        trackAccountConfigurations()
    }

    private func trackAccountConfigurations() {
        guard observesAccountQueries else { return }
        withObservationTracking {
            _ = services.configurations
            _ = services.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observesAccountQueries else { return }
                self.accounts.configurationDidChange()
                self.trackAccountConfigurations()
            }
        }
    }

    func applyInterfaceLanguage() {
        L10n.apply(preferences.interfaceLanguage)
        settingsWindow?.title = L10n.string("Settings")
        if let panelPermission { panel?.title = panelPermission.name }
    }

    private func trackLayout() {
        withObservationTracking {
            _ = preferences.translationLayout
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyTranslationLayout()
                self?.trackLayout()
            }
        }
    }

    private func preferredSize(for kind: TranslationWindowKind) -> NSSize {
        let preferred = preferences.windowSize(for: kind, layout: presentedLayout)
            ?? presentedLayout.defaultSize(for: kind)
        let minimum = presentedLayout.minimumSize(for: kind)
        return NSSize(width: max(preferred.width, minimum.width), height: max(preferred.height, minimum.height))
    }

    private func applyTranslationLayout() {
        guard presentedLayout != preferences.translationLayout else { return }
        // Native zoom changes geometry without an end-live-resize callback.
        // Our host never resizes the window from SwiftUI's content dimensions.
        rememberMainSize()
        presentedLayout = preferences.translationLayout
        if let mainWindow {
            mainWindow.minSize = presentedLayout.minimumSize(for: .main)
            resize(mainWindow, to: preferredSize(for: .main))
            automaticMainSize = mainWindow.frame.size
        }
    }

    private func resize(_ window: NSWindow, to size: NSSize) {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        window.setFrame(PanelPlacement.resizingFrame(current: window.frame, size: size, visibleFrame: visible), display: true)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === mainWindow {
            preferences.rememberWindowSize(window.frame.size, for: .main, layout: presentedLayout)
        }
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        guard window === panel else { return defaultFrame }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? defaultFrame
        let maximum = PermissionPromptView.maximumWindowSize
        let size = NSSize(width: min(defaultFrame.width, maximum.width),
                          height: min(defaultFrame.height, maximum.height))
        // Native zoom may use the display's standard frame even when maxSize
        // constrains manual resizing. Keep zoom compact and let AppKit retain
        // its normal second-click restoration of the user's previous frame.
        return PanelPlacement.resizingFrame(current: window.frame, size: size, visibleFrame: visible)
    }

    private func rememberMainSize() {
        guard let mainWindow, mainWindow.frame.size != automaticMainSize else { return }
        preferences.rememberWindowSize(mainWindow.frame.size, for: .main, layout: presentedLayout)
    }

    func applyAppearance() {
        switch preferences.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func applyDefaultTarget() {
        if inputModel.text.isEmpty { inputModel.target = preferences.defaultTarget }
    }

    /// Replace content only after a capture has succeeded. Failed permission
    /// checks and cancelled region selection leave the existing workspace intact.
    func prepareCapturedTranslation() {
        inputEditor?.finishCompositionForReplacement()
        inputTranslationEditor?.finishCompositionForReplacement()
        if inputModel.beginExternalReplacement() { previousSourceApplication = sourceApplication }
        inputModel.source = "auto"
    }

    func restorePreviousTranslation() {
        guard inputModel.canRestorePreviousWorkspace, !inputModel.isComposing else { return }
        onQuickOperationCancelled?()
        inputEditor?.finishCompositionForReplacement()
        inputTranslationEditor?.finishCompositionForReplacement()
        if inputModel.restorePreviousWorkspace() {
            sourceApplication = previousSourceApplication
            previousSourceApplication = nil
        }
    }

    func showTranslationWindow() { showMain() }

    func acceptScreenshot(_ handoff: TranslationHandoff, source: NSRunningApplication?) {
        prepareCapturedTranslation()
        inputModel.acceptHandoff(handoff)
        inputModel.useScreenshotSourceName()
        sourceApplication = source
        presentMain(focusEditor: false)
    }

    func showMain(handoff: TranslationHandoff? = nil) {
        presentMain(handoff: handoff, focusEditor: true)
    }

    private func presentMain(handoff: TranslationHandoff? = nil, focusEditor: Bool, captureAnchor: CGPoint? = nil) {
        applyTranslationLayout()
        needsInputFocus = focusEditor && updates?.isPresentingMainModal != true
        closePermission()
        if let handoff {
            inputEditor?.finishCompositionForReplacement()
            inputTranslationEditor?.finishCompositionForReplacement()
            inputModel.acceptHandoff(handoff)
        }
        if mainWindow == nil {
            let initialSize = preferredSize(for: .main)
            let window = TranslationWindow(contentRect: NSRect(origin: .zero, size: initialSize),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            TranslateXWindowChrome.configure(window)
            window.setFrame(NSRect(origin: .zero, size: initialSize), display: false)
            window.minSize = presentedLayout.minimumSize(for: .main)
            window.title = "TSX"
            window.identifier = NSUserInterfaceItemIdentifier("translatex.main")
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
            // Preserve the released autosave key so an engineering rename keeps window placement.
            window.setFrameAutosaveName("LumaxMainWindow")
            window.delegate = self
            window.onEscape = { [weak self] in self?.dismissTranslation() }
            if !window.setFrameUsingName("LumaxMainWindow") { window.center() }
            // Keep the legacy position. A saved size belongs to its own layout;
            // a first vertical window must not inherit a short horizontal frame.
            if preferences.windowSize(for: .main, layout: presentedLayout) != nil || presentedLayout == .stacked {
                resize(window, to: initialSize)
            }
            automaticMainSize = window.frame.size
            mainWindow = window
            window.contentView = WindowSurface(preferences: preferences, content: InputTranslationView(
                model: inputModel, catalog: languages,
                translateSelection: { [weak self] in self?.onSelection?() },
                translateScreenshot: { [weak self] in self?.onScreenshot?() },
                openSettings: { [weak self] in self?.onSettings?() },
                manageServices: { [weak self] in self?.showTranslationServices() },
                editorReady: { [weak self] editor in
                    self?.inputEditor = editor as? TranslationInputTextView
                    self?.mainWindow?.initialFirstResponder = editor
                    self?.focusInputWhenReady()
                },
                translationEditorReady: { [weak self] in self?.inputTranslationEditor = $0 as? TranslationInputTextView },
                updates: updates, restorePrevious: { [weak self] in self?.restorePreviousTranslation() },
                saveScreenshot: { [weak self] in self?.saveScreenshot($0) }
            ))
        }
        syncMainModal()
        if let anchor = captureAnchor, let window = mainWindow, !window.styleMask.contains(.fullScreen),
           let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main {
            window.setFrame(PanelPlacement.frame(size: window.frame.size, anchor: anchor,
                                                 visibleFrame: screen.visibleFrame), display: false)
            automaticMainSize = window.frame.size
        }
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installTranslationKeyMonitor()
        focusInputWhenReady()
    }

    private func focusInputWhenReady() {
        // SwiftUI attaches the native editor and establishes its own responder chain
        // during layout. Apply the requested focus after that transaction completes.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.needsInputFocus, self.updates?.isPresentingMainModal != true,
                  let window = self.mainWindow, window.isKeyWindow,
                  let editor = self.inputEditor, editor.window === window else { return }
            if window.makeFirstResponder(editor) { self.needsInputFocus = false }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if notification.object as? NSWindow === mainWindow { focusInputWhenReady() }
        if notification.object as? NSWindow === settingsWindow { permissions.refresh() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === mainWindow { needsInputFocus = false }
        if notification.object as? NSWindow === settingsWindow { settingsShortcuts?.endRecording() }
    }

    func showSettings(shortcuts: ShortcutSettings) {
        closePermission()
        // The settings action supersedes any editor attachment/focus callback
        // still queued by the translation window.
        needsInputFocus = false
        settingsShortcuts = shortcuts
        permissions.refresh()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            TranslateXWindowChrome.configure(window)
            window.minSize = NSSize(width: 900, height: 600)
            window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 700), display: false)
            window.title = L10n.string("Settings")
            window.identifier = NSUserInterfaceItemIdentifier("translatex.settings")
            window.isReleasedWhenClosed = false
            window.delegate = self
            let content = WindowSurface(preferences: preferences, content: SettingsView(
                preferences: preferences, shortcuts: shortcuts, permissions: permissions, catalog: languages,
                defaultTargetChanged: { [weak self] in self?.applyDefaultTarget() },
                appearanceChanged: { [weak self] in self?.applyAppearance() },
                interfaceLanguageChanged: { [weak self] in self?.applyInterfaceLanguage() }, services: services,
                serviceNavigation: serviceNavigation, updates: updates, accounts: accounts,
                navigation: settingsNavigation
            ))
            window.contentView = content
            window.center()
            settingsWindow = window
        }
        syncSettingsModal()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func saveScreenshot(_ output: ScreenshotOutput) {
        guard let mainWindow, mainWindow.attachedSheet == nil, let document = inputModel.screenshot else { return }
        let image: CGImage?
        switch output {
        case .originalImage: image = document.image
        case .translatedImage: image = ScreenshotImageRenderer.render(document)?.image
        case .originalText, .translatedText: return
        }
        guard let image, let data = ScreenshotImageExport.pngData(image) else {
            showScreenshotSaveError(in: mainWindow)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = output == .originalImage ? "TSX-original.png" : "TSX-translated.png"
        panel.beginSheetModal(for: mainWindow) { [weak self, weak mainWindow] response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) }
            catch { if let mainWindow { self?.showScreenshotSaveError(in: mainWindow) } }
        }
    }

    private func showScreenshotSaveError(in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = L10n.string("Unable to save. Try again.")
        alert.addButton(withTitle: L10n.string("OK"))
        alert.beginSheetModal(for: window)
    }

    func showTranslationServices() {
        onSettings?()
        serviceNavigation.showServices()
    }

    func showAbout() {
        if let settingsShortcuts { showSettings(shortcuts: settingsShortcuts) }
        else { onSettings?() }
        settingsNavigation.showAbout()
    }

    func showUpdate() {
        guard let updates, updates.updatePresentation != nil else { return }
        if updates.showsSettingsUpdate { showAbout(); return }
        if updates.showsMainUpdate { showMain(); return }
        // Keep an outstanding draft confirmation visible and do not replace
        // its pending action when Sparkle requests focus more than once.
        if serviceNavigation.isPresentingConfirmation {
            settingsWindow?.makeKeyAndOrderFront(nil)
            return
        }
        serviceNavigation.requestExit { [weak self, weak updates] in
            guard let self, let updates, updates === self.updates,
                  updates.updatePresentation != nil, updates.updateLocation == .mainWindow else { return }
            updates.presentUpdateInMainWindow()
            self.showMain()
        }
    }

    private func trackSettingsConfirmation() {
        withObservationTracking { _ = serviceNavigation.isPresentingConfirmation } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // SwiftUI publishes this after requestExit returns. Bring the
                // actual confirmation forward only when it is presented.
                if self.serviceNavigation.isPresentingConfirmation,
                   self.updates?.updatePresentation != nil, self.updates?.showsMainUpdate == false,
                   let settingsWindow = self.settingsWindow {
                    if settingsWindow.isMiniaturized { settingsWindow.deminiaturize(nil) }
                    settingsWindow.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                self.trackSettingsConfirmation()
            }
        }
    }

    private func trackSettingsModal() {
        guard let updates else { return }
        withObservationTracking { _ = updates.isPresentingSettingsModal } onChange: { [weak self, weak updates] in
            Task { @MainActor [weak self, weak updates] in
                guard let self, let updates, updates === self.updates else { return }
                self.syncSettingsModal()
                self.trackSettingsModal()
            }
        }
    }

    private func syncSettingsModal() {
        guard let surface = settingsWindow?.contentView as? WindowSurface<SettingsView> else { return }
        if let updates, updates.isPresentingSettingsModal {
            if surface.modalHostingView == nil { settingsWindow?.makeFirstResponder(nil) }
            // Match the main window: dim above the glass and its edge lighting.
            surface.presentModal { SettingsUpdateOverlay(updates: updates) }
        } else {
            surface.dismissModal()
        }
    }

    private func trackMainModal() {
        guard let updates else { return }
        withObservationTracking { _ = updates.isPresentingMainModal } onChange: { [weak self, weak updates] in
            Task { @MainActor [weak self, weak updates] in
                guard let self, let updates, updates === self.updates else { return }
                self.syncMainModal()
                self.trackMainModal()
            }
        }
    }

    private func syncMainModal() {
        guard let surface = mainWindow?.contentView as? WindowSurface<InputTranslationView> else { return }
        let presenting = updates?.isPresentingMainModal == true
        inputEditor?.setInteractionEnabled(!presenting)
        inputTranslationEditor?.setInteractionEnabled(!presenting)
        if presenting, let updates {
            needsInputFocus = false
            if mainWindow?.firstResponder === inputEditor || mainWindow?.firstResponder === inputTranslationEditor {
                mainWindow?.makeFirstResponder(nil)
            }
            surface.presentModal { [weak self] in
                MainReleaseNotesOverlay(updates: updates) { [weak self] in self?.dismissMainReleaseNotes() }
            }
        } else if surface.modalHostingView != nil {
            surface.dismissModal()
            needsInputFocus = true
            focusInputWhenReady()
        }
    }

    /// Startup notes are part of the existing translation workspace. Keep its
    /// native editors mounted so dismissing the overlay preserves the draft.
    func showMainReleaseNotes() {
        guard updates?.mainReleaseNotesPresentation != nil else { return }
        inputEditor?.setInteractionEnabled(false)
        inputTranslationEditor?.setInteractionEnabled(false)
        showMain()
        if mainWindow?.firstResponder === inputEditor || mainWindow?.firstResponder === inputTranslationEditor {
            mainWindow?.makeFirstResponder(nil)
        }
    }

    func dismissMainReleaseNotes() {
        guard updates?.mainReleaseNotesPresentation != nil else { return }
        updates?.dismissReleaseNotes(in: .mainWindow)
        syncMainModal()
    }

    /// Selection, screenshot and ordinary input share this window and its host.
    func showCapturedTranslation(source: NSRunningApplication?, bounds: CGRect? = nil) {
        let wasVisibleHere = mainWindow?.isVisible == true && mainWindow?.isOnActiveSpace == true
        sourceApplication = source
        var anchor: CGPoint?
        if !wasVisibleHere {
            anchor = NSEvent.mouseLocation
            if let bounds, let primary = NSScreen.screens.first, !bounds.isEmpty {
                anchor = CGPoint(x: bounds.midX, y: primary.frame.maxY - bounds.maxY)
            }
        }
        presentMain(focusEditor: false, captureAnchor: anchor)
    }

    func showPermission(_ permission: SystemPermission, source: NSRunningApplication?) {
        panelPermission = permission
        permissionSourceApplication = source
        if panel == nil {
            let window = QuickPanel(contentRect: .zero,
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                    backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("translatex.permission")
            window.delegate = self
            window.isFloatingPanel = true
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.onEscape = { [weak self] in self?.closePermission(restoreFocus: true) }
            window.onClose = { [weak self] in self?.closePermission(restoreFocus: true) }
            panel = window
        }
        // Keep SwiftUI inside the native content rect; the system owns the
        // titlebar, traffic lights and outer window corners.
        let content = PermissionPromptView(openInput: { [weak self] in self?.showMain() },
                                           permission: permission,
                                           requestPermission: { [weak self] in self?.onPermission?(permission) })
        let host = NSHostingView(rootView: TranslateXThemeHost(preferences: preferences) { content })
        host.sizingOptions = []
        // A root NSHostingView can still publish window size limits after its
        // first layout. An ordinary content view keeps those limits owned by
        // AppKit while the SwiftUI child follows the native content rectangle.
        let container = NSView(frame: .zero)
        host.autoresizingMask = [.width, .height]
        host.frame = container.bounds
        container.addSubview(host)
        panel?.contentView = container
        panel?.title = permission.name
        panel?.minSize = PermissionPromptView.minimumWindowSize
        panel?.maxSize = PermissionPromptView.maximumWindowSize
        let anchor = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main {
            panel?.setFrame(PanelPlacement.frame(size: PermissionPromptView.permissionWindowSize,
                                                anchor: anchor, visibleFrame: screen.visibleFrame), display: true)
        }
        if panel?.isMiniaturized == true { panel?.deminiaturize(nil) }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installOutsideMonitor()
    }

    func closePermission(restoreFocus: Bool = false) {
        let shouldRestoreFocus = restoreFocus && panel?.isKeyWindow == true && NSApp.isActive
        let source = permissionSourceApplication
        panel?.orderOut(nil)
        panelPermission = nil
        permissionSourceApplication = nil
        removeMonitors()
        if shouldRestoreFocus, let source, !source.isTerminated,
           source.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            source.activate(options: [])
        }
    }

    /// Abandon selection/OCR without interrupting a translation already in the
    /// shared workspace. Detach an old OCR cancellation before its successor
    /// creates a workflow, or replacement could cancel that new workflow.
    func cancelExternalCapture() {
        closePermission()
        if inputModel.phase == .recognizing { inputModel.cancel() }
        onQuickOperationCancelled?()
    }

    func cancelCapturedOperation() {
        inputModel.cancel()
        onQuickOperationCancelled?()
    }

    func dismissTranslation(restoreFocus: Bool = true) {
        guard updates?.isPresentingMainModal != true, mainWindow?.attachedSheet == nil else { return }
        rememberMainSize()
        needsInputFocus = false
        let shouldRestoreFocus = restoreFocus && mainWindow?.isKeyWindow == true && NSApp.isActive
        cancelCapturedOperation()
        mainWindow?.orderOut(nil)
        if shouldRestoreFocus, let sourceApplication, !sourceApplication.isTerminated,
           sourceApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            sourceApplication.activate(options: [])
        }
    }

    private func installTranslationKeyMonitor() {
        guard translationKeyMonitor == nil else { return }
        translationKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, event.keyCode == 53, event.window === self.mainWindow,
                      self.mainWindow?.isTrackingMenu != true, self.mainWindow?.attachedSheet == nil,
                      (self.mainWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true,
                      self.updates?.isPresentingMainModal != true else { return false }
                self.dismissTranslation()
                return true
            }
            return consumed ? nil : event
        }
        observeMenuTracking()
    }

    /// Hide our content before the user chooses pixels. Restore only the window
    /// the user was working in, without bringing an inactive app to the front.
    func hideForScreenshot() -> ScreenshotRestoration {
        let restoration: ScreenshotRestoration
        if NSApp.isActive, settingsWindow?.isKeyWindow == true {
            restoration = .settings
        } else if NSApp.isActive, mainWindow?.isKeyWindow == true {
            restoration = .input
        } else {
            restoration = .none
        }
        mainWindow?.orderOut(nil)
        settingsWindow?.orderOut(nil)
        NotificationCenter.default.post(name: .translateXTranslationSettingsObscured, object: nil)
        settingsShortcuts?.endRecording()
        return restoration
    }

    func restoreAfterScreenshotCancellation(_ restoration: ScreenshotRestoration) {
        switch restoration {
        case .none:
            break
        case .input:
            showMain()
        case .about:
            showAbout()
        case .settings:
            guard let settingsWindow else { return }
            closePermission()
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func shutdown() {
        observesAccountQueries = false
        accounts.stopAutomaticRefresh()
        rememberMainSize()
        needsInputFocus = false
        cancelCapturedOperation()
        closePermission()
        if let translationKeyMonitor { NSEvent.removeMonitor(translationKeyMonitor) }
        translationKeyMonitor = nil
        NotificationCenter.default.removeObserver(self)
        observesMenuTracking = false
        trackedMenus.removeAll()
        mainWindow?.isTrackingMenu = false
        panel?.isTrackingMenu = false
        mainWindow?.orderOut(nil)
        settingsWindow?.orderOut(nil)
        NotificationCenter.default.post(name: .translateXTranslationSettingsClosed, object: nil)
        settingsShortcuts?.endRecording()
    }

    private func installOutsideMonitor() {
        removeMonitors()
        // Native language and service menus have their own windows. Their mouse
        // events and Escape belong to menu tracking, not the panel's dismissal.
        observeMenuTracking()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel?.isVisible == true, self.panel?.isMiniaturized != true,
                      !self.isShowingSystemPrompt else { return }
                self.closePermission()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.panel?.isVisible == true, self.panel?.isMiniaturized != true else { return false }
                if event.type == .keyDown, event.keyCode == 53, event.window === self.panel,
                   self.panel?.isTrackingMenu != true, self.panel?.attachedSheet == nil,
                   (self.panel?.firstResponder as? NSTextView)?.hasMarkedText() != true {
                    self.closePermission(restoreFocus: true)
                    return true
                }
                if event.type != .keyDown, event.window !== self.panel,
                   event.window?.sheetParent !== self.panel, !self.isShowingSystemPrompt {
                    self.closePermission()
                }
                return false
            }
            return consumed ? nil : event
        }
    }

    private var isShowingSystemPrompt: Bool {
        panel?.isTrackingMenu == true || panel?.attachedSheet != nil || inputModel.phase == .preparingLanguages
    }

    private func observeMenuTracking() {
        guard !observesMenuTracking else { return }
        observesMenuTracking = true
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidBeginTracking(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidEndTracking(_:)),
                                               name: NSMenu.didEndTrackingNotification, object: nil)
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        trackedMenus.insert(ObjectIdentifier(menu))
        panel?.isTrackingMenu = true
        mainWindow?.isTrackingMenu = true
    }

    @objc private func menuDidEndTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        trackedMenus.remove(ObjectIdentifier(menu))
        panel?.isTrackingMenu = !trackedMenus.isEmpty
        mainWindow?.isTrackingMenu = !trackedMenus.isEmpty
    }

    private func removeMonitors() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        outsideMonitor = nil
        localMonitor = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === settingsWindow else { return true }
        serviceNavigation.requestExit { [weak sender] in sender?.close() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === mainWindow {
            rememberMainSize()
            cancelCapturedOperation()
            needsInputFocus = false
        }
        if notification.object as? NSWindow === settingsWindow {
            settingsShortcuts?.endRecording()
            NotificationCenter.default.post(name: .translateXTranslationSettingsClosed, object: nil)
        }
    }
}
