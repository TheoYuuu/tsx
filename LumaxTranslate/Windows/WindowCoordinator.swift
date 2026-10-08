import AppKit
import Observation
import SwiftUI

@MainActor
final class QuickPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onClose: (() -> Void)?
    var isTrackingMenu = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {
        guard !isTrackingMenu, (firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        onEscape?()
    }

    // The panel intentionally has no standard close button. Route File > Close
    // through coordinator cleanup instead of NSWindow's
    // default implementation, which requires the .closable style mask.
    override func performClose(_ sender: Any?) { (onClose ?? onEscape)?() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSWindow.performClose(_:)) { return onClose != nil || onEscape != nil }
        return super.validateUserInterfaceItem(item)
    }
}

@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    let preferences: AppPreferences
    let permissions = PermissionStatus()
    let services: TranslationServiceStore
    let inputModel: TranslationModel
    let quickModel: TranslationModel
    let languages = LanguageCatalog()
    var updates: AppUpdateController?
    var onSelection: (() -> Void)?
    var onScreenshot: (() -> Void)?
    var onSettings: (() -> Void)?
    var onPermission: ((SystemPermission) -> Void)?
    var onQuickOperationCancelled: (() -> Void)?
    var onQuickRetry: (() -> Void)?
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    let serviceNavigation = TranslationServiceNavigationCoordinator()
    private var aboutWindow: NSWindow?
    private var settingsShortcuts: ShortcutSettings?
    private weak var inputEditor: TranslationInputTextView?
    private weak var quickEditor: TranslationInputTextView?
    private weak var inputTranslationEditor: TranslationInputTextView?
    private weak var quickTranslationEditor: TranslationInputTextView?
    private var needsInputFocus = false
    private var panel: QuickPanel?
    private var panelPermission: SystemPermission?
    private var automaticPanelSize: NSSize?
    private var automaticMainSize: NSSize?
    private var panelShowsWorkspace = false
    private var presentedLayout: TranslationLayout
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var trackedMenus = Set<ObjectIdentifier>()
    private var sourceApplication: NSRunningApplication?
    private enum TranslationWindow { case main, quick }
    private var lastTranslationWindow = TranslationWindow.main

    override convenience init() { self.init(preferences: AppPreferences()) }

    init(preferences: AppPreferences, services: TranslationServiceStore = TranslationServiceStore()) {
        self.preferences = preferences
        L10n.apply(preferences.interfaceLanguage)
        presentedLayout = preferences.translationLayout
        self.services = services
        inputModel = TranslationModel(automaticallyTranslates: true, services: services)
        quickModel = TranslationModel(automaticallyTranslates: true, services: services)
        super.init()
        inputModel.target = preferences.defaultTarget
        quickModel.target = preferences.defaultTarget
        trackQuickPresentation()
        trackLayout()
        trackInterfaceLanguage()
    }

    private func trackInterfaceLanguage() {
        withObservationTracking { _ = preferences.interfaceLanguage } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyInterfaceLanguage()
                self?.trackInterfaceLanguage()
            }
        }
    }

    func applyInterfaceLanguage() {
        L10n.apply(preferences.interfaceLanguage)
        settingsWindow?.title = L10n.string("Settings")
        aboutWindow?.title = L10n.string("About TSX")
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
        rememberQuickSize()
        presentedLayout = preferences.translationLayout
        if let mainWindow {
            mainWindow.minSize = presentedLayout.minimumSize(for: .main)
            resize(mainWindow, to: preferredSize(for: .main))
            automaticMainSize = mainWindow.frame.size
        }
        if let panel, panel.isVisible, panelPermission == nil, quickModel.showsQuickWorkspace {
            panel.minSize = quickMinimumSize
            resize(panel, to: preferredSize(for: .quick))
            automaticPanelSize = panel.frame.size
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
        } else if window === panel, panelShowsWorkspace {
            preferences.rememberWindowSize(window.frame.size, for: .quick, layout: presentedLayout)
        }
    }

    private func rememberMainSize() {
        guard let mainWindow, mainWindow.frame.size != automaticMainSize else { return }
        preferences.rememberWindowSize(mainWindow.frame.size, for: .main, layout: presentedLayout)
    }

    private func rememberQuickSize() {
        guard let panel, panel.isVisible, panelShowsWorkspace, panel.frame.size != automaticPanelSize else { return }
        preferences.rememberWindowSize(panel.frame.size, for: .quick, layout: presentedLayout)
    }

    private func trackQuickPresentation() {
        withObservationTracking {
            _ = quickModel.phase
            _ = quickModel.displayedResult
            _ = quickModel.showsQuickWorkspace
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.resizeQuickForPresentation()
                self?.trackQuickPresentation()
            }
        }
    }

    private var quickPresentationSize: NSSize {
        if panelPermission != nil { return NSSize(width: 430, height: 365) }
        if quickModel.showsQuickWorkspace { return preferredSize(for: .quick) }
        return NSSize(width: 392, height: 315)
    }

    private var quickMinimumSize: NSSize {
        panelPermission == nil && quickModel.showsQuickWorkspace
            ? presentedLayout.minimumSize(for: .quick) : NSSize(width: 340, height: 300)
    }

    private func resizeQuickForPresentation() {
        guard let panel, panel.isVisible else { return }
        rememberQuickSize()
        panelShowsWorkspace = panelPermission == nil && quickModel.showsQuickWorkspace
        panel.minSize = quickMinimumSize
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        guard let previous = automaticPanelSize, panel.frame.size == previous else {
            // A narrow recognition panel may have been resized before the text
            // arrived. Preserve that choice unless it cannot fit two columns.
            let minimum = NSSize(width: max(panel.frame.width, quickMinimumSize.width),
                                 height: max(panel.frame.height, quickMinimumSize.height))
            if minimum != panel.frame.size {
                panel.setFrame(PanelPlacement.resizingFrame(current: panel.frame, size: minimum, visibleFrame: visible), display: true)
                if panelShowsWorkspace {
                    // Carry the user's narrow OCR-window choice into its valid
                    // reading size, so a later status update cannot expand it.
                    preferences.rememberWindowSize(minimum, for: .quick, layout: presentedLayout)
                }
                automaticPanelSize = panel.frame.size
            }
            return
        }
        let size = quickPresentationSize
        guard size != previous else { return }
        panel.setFrame(PanelPlacement.resizingFrame(current: panel.frame, size: size, visibleFrame: visible), display: true)
        automaticPanelSize = panel.frame.size
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

    func prepareQuickTranslation() {
        rememberQuickSize()
        quickEditor?.finishCompositionForReplacement()
        quickTranslationEditor?.finishCompositionForReplacement()
        quickModel.clear(keepingUndo: false)
        quickModel.source = "auto"
        quickModel.target = preferences.defaultTarget
    }

    var canOpenQuickInMain: Bool {
        !quickModel.isComposing && (quickModel.phase != .recognizing
            || !quickModel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func openQuickInMain() {
        // Recheck at action time: a previously enabled UI action must not abandon
        // OCR before it has produced the passage that the user wants to move.
        guard canOpenQuickInMain else { return }
        // Snapshot before showMain closes the panel and cancels its request.
        showMain(handoff: quickModel.makeHandoff())
    }

    /// Dock, menu and input shortcut resume the most recently used workspace.
    /// Reuse the retained host so image mode, zoom, edits and position survive;
    /// do not replace the main draft or start another provider request.
    func showTranslationWindow() {
        if lastTranslationWindow == .quick, panelPermission == nil, let panel,
           quickModel.screenshot != nil || !(quickModel.text + quickModel.translatedText).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applyTranslationLayout()
            if panel.minSize != quickMinimumSize {
                panel.minSize = quickMinimumSize
                resize(panel, to: preferredSize(for: .quick))
                automaticPanelSize = panel.frame.size
            }
            panel.makeKeyAndOrderFront(nil)
            installOutsideMonitor()
            NSApp.activate(ignoringOtherApps: true)
        } else { showMain() }
    }

    func showMain(handoff: TranslationHandoff? = nil) {
        lastTranslationWindow = .main
        applyTranslationLayout()
        needsInputFocus = true
        closeQuick(restoreFocus: false)
        if let handoff {
            inputEditor?.finishCompositionForReplacement()
            inputTranslationEditor?.finishCompositionForReplacement()
            inputModel.acceptHandoff(handoff)
        }
        if mainWindow == nil {
            let initialSize = preferredSize(for: .main)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: initialSize),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            LumaxWindowChrome.configure(window)
            window.setFrame(NSRect(origin: .zero, size: initialSize), display: false)
            window.minSize = presentedLayout.minimumSize(for: .main)
            window.title = "TSX"
            window.identifier = NSUserInterfaceItemIdentifier("lumax.main")
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("LumaxMainWindow")
            window.delegate = self
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
                translationEditorReady: { [weak self] in self?.inputTranslationEditor = $0 as? TranslationInputTextView }
            ))
        }
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        focusInputWhenReady()
    }

    private func focusInputWhenReady() {
        // SwiftUI attaches the native editor and establishes its own responder chain
        // during layout. Apply the requested focus after that transaction completes.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.needsInputFocus,
                  let window = self.mainWindow,
                  let editor = self.inputEditor, editor.window === window else { return }
            if window.makeFirstResponder(editor) { self.needsInputFocus = false }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if notification.object as? NSWindow === mainWindow {
            // AppKit can give the main window focus automatically when the
            // quick panel disappears. That is not a visit to the main draft.
            let event = NSApp.currentEvent
            let userEnteredMain = event?.window === mainWindow &&
                (event?.type == .leftMouseDown || event?.type == .rightMouseDown || event?.type == .keyDown)
            if lastTranslationWindow == .main || panel?.isVisible == true || userEnteredMain {
                lastTranslationWindow = .main
            }
            focusInputWhenReady()
        }
        if notification.object as? NSWindow === panel { lastTranslationWindow = .quick }
        if notification.object as? NSWindow === settingsWindow { permissions.refresh() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { settingsShortcuts?.endRecording() }
    }

    func showSettings(shortcuts: ShortcutSettings) {
        closeQuick(restoreFocus: false)
        settingsShortcuts = shortcuts
        permissions.refresh()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 610),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            LumaxWindowChrome.configure(window)
            window.setFrame(NSRect(x: 0, y: 0, width: 700, height: 610), display: false)
            window.title = L10n.string("Settings")
            window.identifier = NSUserInterfaceItemIdentifier("lumax.settings")
            window.isReleasedWhenClosed = false
            window.delegate = self
            let content = WindowSurface(preferences: preferences, content: SettingsView(
                preferences: preferences, shortcuts: shortcuts, permissions: permissions, catalog: languages,
                defaultTargetChanged: { [weak self] in self?.applyDefaultTarget() },
                appearanceChanged: { [weak self] in self?.applyAppearance() },
                interfaceLanguageChanged: { [weak self] in self?.applyInterfaceLanguage() }, services: services,
                serviceNavigation: serviceNavigation, updates: updates
            ))
            window.contentView = content
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showTranslationServices() {
        onSettings?()
        serviceNavigation.showServices()
    }

    func showAbout() {
        if aboutWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 325),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            LumaxWindowChrome.configure(window)
            window.title = L10n.string("About TSX")
            window.identifier = NSUserInterfaceItemIdentifier("lumax.about")
            window.isReleasedWhenClosed = false
            window.contentView = WindowSurface(preferences: preferences, content: AboutView())
            window.setFrame(NSRect(x: 0, y: 0, width: 360, height: 325), display: false)
            window.center()
            aboutWindow = window
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showQuick(source: NSRunningApplication?, bounds: CGRect? = nil, permission: SystemPermission? = nil) {
        lastTranslationWindow = .quick
        rememberQuickSize()
        applyTranslationLayout()
        sourceApplication = source
        panelPermission = permission
        panelShowsWorkspace = permission == nil && quickModel.showsQuickWorkspace
        if panel == nil {
            let window = QuickPanel(contentRect: .zero,
                                    styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
                                    backing: .buffered, defer: false)
            window.title = "TSX"
            LumaxWindowChrome.configure(window)
            window.titleVisibility = .hidden
            window.identifier = NSUserInterfaceItemIdentifier("lumax.quick")
            window.titlebarAppearsTransparent = true
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.isFloatingPanel = true
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isMovableByWindowBackground = true
            window.onEscape = { [weak self] in
                guard let self else { return }
                if self.quickModel.isBusy { self.cancelQuickOperation() }
                else { self.closeQuick() }
            }
            window.onClose = { [weak self] in self?.closeQuick() }
            window.delegate = self
            panel = window
        }
        let content = WindowSurface(preferences: preferences, content: QuickTranslationView(
            model: quickModel,
            close: { [weak self] in self?.closeQuick() },
            openInput: { [weak self] in self?.openQuickInMain() },
            canOpenInput: { [weak self] in self?.canOpenQuickInMain ?? false },
            permission: permission,
            requestPermission: { [weak self] in
                if let permission { self?.onPermission?(permission) }
            },
            cancel: { [weak self] in self?.cancelQuickOperation() },
            retry: { [weak self] in
                guard let self else { return }
                if self.quickModel.canTranslate { self.quickModel.submit() }
                else { self.onQuickRetry?() }
            },
            translateSelection: { [weak self] in self?.onSelection?() },
            translateScreenshot: { [weak self] in self?.onScreenshot?() },
            openSettings: { [weak self] in self?.onSettings?() },
            manageServices: { [weak self] in self?.showTranslationServices() },
            catalog: languages,
            editorReady: { [weak self] in self?.quickEditor = $0 as? TranslationInputTextView },
            translationEditorReady: { [weak self] in self?.quickTranslationEditor = $0 as? TranslationInputTextView }
        ))
        // The surface contains a stable host; AppKit retains ownership of resize limits.
        panel?.contentView = content
        panel?.minSize = quickMinimumSize
        var anchor = NSEvent.mouseLocation
        if let bounds, let primary = NSScreen.screens.first, !bounds.isEmpty {
            anchor = CGPoint(x: bounds.midX, y: primary.frame.maxY - bounds.maxY)
        }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        if let screen {
            let size = quickPresentationSize
            panel?.setFrame(PanelPlacement.frame(size: size,
                                                anchor: anchor, visibleFrame: screen.visibleFrame), display: true)
            automaticPanelSize = panel?.frame.size
        }
        // Becoming key enables Escape/copy without activating Lumax or changing the source app.
        panel?.makeKeyAndOrderFront(nil)
        installOutsideMonitor()
    }

    func closeQuick(restoreFocus: Bool = true) {
        rememberQuickSize()
        quickEditor?.finishCompositionForReplacement()
        quickTranslationEditor?.finishCompositionForReplacement()
        cancelQuickOperation()
        let wasKey = panel?.isKeyWindow == true
        panel?.orderOut(nil)
        removeMonitors()
        if restoreFocus, wasKey, let sourceApplication,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            sourceApplication.activate(options: [])
        }
        sourceApplication = nil
    }

    private func cancelQuickOperation() {
        quickModel.cancel()
        onQuickOperationCancelled?()
    }

    /// Hide our content before the user chooses pixels. Restore only the window
    /// the user was working in, without bringing an inactive app to the front.
    func hideForScreenshot() -> ScreenshotRestoration {
        let restoration: ScreenshotRestoration
        if NSApp.isActive, aboutWindow?.isKeyWindow == true {
            restoration = .about
        } else if NSApp.isActive, settingsWindow?.isKeyWindow == true {
            restoration = .settings
        } else if NSApp.isActive, mainWindow?.isKeyWindow == true {
            restoration = .input
        } else {
            restoration = .none
        }
        mainWindow?.orderOut(nil)
        settingsWindow?.orderOut(nil)
        NotificationCenter.default.post(name: .lumaxTranslationSettingsObscured, object: nil)
        aboutWindow?.orderOut(nil)
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
            closeQuick(restoreFocus: false)
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func shutdown() {
        rememberMainSize()
        needsInputFocus = false
        inputModel.cancel()
        closeQuick(restoreFocus: false)
        mainWindow?.orderOut(nil)
        settingsWindow?.orderOut(nil)
        NotificationCenter.default.post(name: .lumaxTranslationSettingsClosed, object: nil)
        aboutWindow?.orderOut(nil)
        settingsShortcuts?.endRecording()
    }

    private func installOutsideMonitor() {
        removeMonitors()
        // Native language and service menus have their own windows. Their mouse
        // events and Escape belong to menu tracking, not the panel's dismissal.
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidBeginTracking(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidEndTracking(_:)),
                                               name: NSMenu.didEndTrackingNotification, object: nil)
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isShowingSystemPrompt else { return }
                self.closeQuick(restoreFocus: false)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown, event.keyCode == 53, event.window === self.panel,
                   self.panel?.isTrackingMenu != true,
                   (self.panel?.firstResponder as? NSTextView)?.hasMarkedText() != true {
                    self.closeQuick()
                    return true
                }
                if event.type != .keyDown, event.window !== self.panel,
                   event.window?.sheetParent !== self.panel, !self.isShowingSystemPrompt {
                    if event.window === self.mainWindow { self.lastTranslationWindow = .main }
                    self.closeQuick(restoreFocus: false)
                }
                return false
            }
            return consumed ? nil : event
        }
    }

    private var isShowingSystemPrompt: Bool {
        panel?.isTrackingMenu == true || panel?.attachedSheet != nil || quickModel.phase == .preparingLanguages
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        trackedMenus.insert(ObjectIdentifier(menu))
        panel?.isTrackingMenu = true
    }

    @objc private func menuDidEndTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        trackedMenus.remove(ObjectIdentifier(menu))
        panel?.isTrackingMenu = !trackedMenus.isEmpty
    }

    private func removeMonitors() {
        NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSMenu.didEndTrackingNotification, object: nil)
        trackedMenus.removeAll()
        panel?.isTrackingMenu = false
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
            inputModel.cancel()
        }
        if notification.object as? NSWindow === settingsWindow {
            settingsShortcuts?.endRecording()
            NotificationCenter.default.post(name: .lumaxTranslationSettingsClosed, object: nil)
        }
    }
}
