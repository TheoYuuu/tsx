import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = AppPreferences()
    private let updates = AppUpdateController()
    private lazy var windows = WindowCoordinator(preferences: preferences)
    private let selection = SelectionService()
    private let shortcuts = ShortcutManager()
    private lazy var shortcutSettings = ShortcutSettings(
        preferences: preferences, manager: shortcuts,
        onAction: { [weak self] action in
            switch action {
            case .selection: self?.translateSelection()
            case .input: self?.openInput()
            case .ocr: self?.translateScreenshot()
            }
        },
        onBindingsChanged: { [weak self] in self?.updateMenuShortcuts() }
    )
    private lazy var screenshots = ScreenshotTranslationController(windows: windows)
    private lazy var menuBar = MenuBarController(
        onSelection: { [weak self] in self?.translateSelection() },
        onScreenshot: { [weak self] in self?.translateScreenshot() },
        onOpenMain: { [weak self] in self?.openInput() },
        onSettings: { [weak self] in self?.openSettings() },
        onQuit: { NSApp.terminate(nil) }
    )
    private var selectionTask: Task<Void, Never>?
    private var selectionID: UUID?
    private var lastExternalApplication: NSRunningApplication?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSClassFromString("XCTestCase") == nil else { return }
        L10n.apply(preferences.interfaceLanguage)
        NotificationCenter.default.addObserver(self, selector: #selector(interfaceLanguageChanged),
                                               name: L10n.didChangeNotification, object: nil)
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApplication = frontmost
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        windows.onSelection = { [weak self] in self?.translateSelection() }
        windows.onScreenshot = { [weak self] in self?.translateScreenshot() }
        windows.onSettings = { [weak self] in self?.openSettings() }
        windows.onPermission = { [weak self] permission in
            guard let self, !self.isTerminating else { return }
            self.windows.permissions.request(permission)
        }
        windows.onQuickOperationCancelled = { [weak self] in
            self?.selectionTask?.cancel()
            self?.selection.cancel()
            self?.screenshots.cancel()
        }
        windows.applyAppearance()
        windows.updates = updates
        updates.onPresentUpdate = { [weak self] in self?.windows.showMainUpdate() }
        updates.onPresentReleaseNotes = { [weak self] in self?.windows.showMainReleaseNotes() }
        windows.startAccountQueries()
        configureMenus()
        shortcutSettings.start()
        updateMenuShortcuts()
        if ShortcutAction.allCases.contains(where: { shortcutSettings.error(for: $0) != nil }) {
            windows.inputModel.fail(localized: "Some shortcuts are unavailable. Change them in Settings.")
        }
        menuBar.start()
        windows.showMain()
        updates.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isTerminating else { return false }
        windows.showTranslationWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        let needsCleanup = selection.hasActiveCapture || windows.services.codex.isBusy
        stopAcceptingWork()
        guard needsCleanup else { return .terminateNow }
        // A posted Copy owns its restoration until the SelectionService task ends.
        // Waiting for only the most recent caller could miss an older cancelled task.
        Task { [self] in
            await selection.cancelAndWait()
            // Cancelling a view task is not proof that its helper has exited.
            // Wait for the account controller's bounded cancellation/reaping;
            // an uncertain cleanup retains the helper's durable journal.
            _ = await windows.services.codex.shutdownAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopAcceptingWork()
        windows.services.usage.flush()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func interfaceLanguageChanged() {
        configureMenus()
        menuBar.refreshLocalization()
        updateMenuShortcuts()
    }

    private func stopAcceptingWork() {
        windows.accounts.stopAutomaticRefresh()
        windows.services.codex.beginShutdown()
        selectionID = nil
        selectionTask?.cancel()
        selection.cancel()
        screenshots.cancel()
        shortcutSettings.endRecording()
        windows.shutdown()
        menuBar.stop()
        try? shortcuts.unregisterAll()
    }

    @objc private func applicationActivated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalApplication = application
    }

    @objc private func openInput() {
        guard !isTerminating else { return }
        windows.showTranslationWindow()
    }

    @objc private func openSettings() {
        guard !isTerminating else { return }
        windows.showSettings(shortcuts: shortcutSettings)
    }

    @objc private func openAbout() {
        guard !isTerminating else { return }
        windows.showAbout()
    }

    @objc private func translateSelection() {
        guard !isTerminating else { return }
        screenshots.cancel()
        windows.onQuickRetry = { [weak self] in self?.translateSelection() }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let source = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? lastExternalApplication : frontmost
        selectionTask?.cancel()
        selection.cancel()
        windows.closeQuick(restoreFocus: false)
        windows.prepareQuickTranslation()
        let serviceRevision = windows.quickModel.captureServiceIntent()
        windows.quickModel.sourceName = source?.localizedName ?? ""
        guard SelectionService.isAccessibilityTrusted else {
            windows.showQuick(source: source, permission: .accessibility)
            return
        }
        guard let source, !source.isTerminated else {
            windows.quickModel.fail(localized: "Select text in another app, then use the shortcut. You can also type to translate.")
            windows.showQuick(source: source)
            return
        }
        let id = UUID()
        selectionID = id
        selectionTask = Task { [weak self] in
            guard let self, !Task.isCancelled, !self.isTerminating,
                  self.selectionID == id else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != source.processIdentifier {
                source.activate(options: [])
                try? await Task.sleep(for: .milliseconds(160))
            }
            guard !Task.isCancelled else { return }
            do {
                let captured = try await self.selection.capture(from: source)
                guard !Task.isCancelled, self.selectionID == id else { return }
                self.windows.quickModel.sourceName = captured.sourceName
                self.windows.quickModel.submitCapturedText(captured.text, serviceRevision: serviceRevision)
                self.windows.showQuick(source: source, bounds: captured.bounds)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.selectionID == id else { return }
                switch SelectionFailure(error) {
                case .accessibilityPermissionRequired:
                    self.windows.showQuick(source: source, permission: .accessibility)
                case .message(let key):
                    self.windows.quickModel.fail(localized: key)
                    self.windows.showQuick(source: source)
                }
            }
        }
    }

    @objc private func translateScreenshot() {
        guard !isTerminating else { return }
        windows.onQuickRetry = { [weak self] in self?.translateScreenshot() }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let source = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? lastExternalApplication : frontmost
        screenshots.start(source: source)
    }

    private func updateMenuShortcuts() {
        menuBar.updateShortcuts(selection: shortcuts.shortcut(for: .selection), input: shortcuts.shortcut(for: .input), ocr: shortcuts.shortcut(for: .ocr))
    }

    private func configureMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let aboutItem = appMenu.addItem(withTitle: L10n.string("About TSX"), action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        let updateItem = NSMenuItem()
        updates.configureMenuItem(updateItem)
        appMenu.addItem(updateItem)
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: L10n.string("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.string("Hide TSX"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.string("Quit TSX"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem(title: L10n.string("File"), action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: L10n.string("File"))
        let inputItem = fileMenu.addItem(withTitle: L10n.string("Open translation window"), action: #selector(openInput), keyEquivalent: "n")
        inputItem.target = self
        let selectionItem = fileMenu.addItem(withTitle: L10n.string("Translate selection"), action: #selector(translateSelection), keyEquivalent: "")
        selectionItem.target = self
        let screenshotItem = fileMenu.addItem(withTitle: L10n.string("Screenshot Translation"), action: #selector(translateScreenshot), keyEquivalent: "")
        screenshotItem.target = self
        fileMenu.addItem(withTitle: L10n.string("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        let editItem = NSMenuItem(title: L10n.string("Edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L10n.string("Edit"))
        editMenu.addItem(withTitle: L10n.string("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L10n.string("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.string("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.string("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.string("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.string("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
}
