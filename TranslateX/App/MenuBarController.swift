import AppKit

/// AppDelegate retains this controller while TranslateX runs, including when all windows are closed.
@MainActor
final class MenuBarController: NSObject {
    let menu = NSMenu(title: "TSX")
    private let onSelection: @MainActor () -> Void
    private let onScreenshot: @MainActor () -> Void
    private let onOpenMain: @MainActor () -> Void
    private let onSettings: @MainActor () -> Void
    private let onQuit: @MainActor () -> Void
    private(set) var statusItem: NSStatusItem?
    private let selectionItem = NSMenuItem()
    private let screenshotItem = NSMenuItem()
    private let inputItem = NSMenuItem()

    var isRunning: Bool { statusItem != nil }

    init(
        onSelection: @escaping @MainActor () -> Void,
        onScreenshot: @escaping @MainActor () -> Void,
        onOpenMain: @escaping @MainActor () -> Void,
        onSettings: @escaping @MainActor () -> Void,
        onQuit: @escaping @MainActor () -> Void
    ) {
        self.onSelection = onSelection
        self.onScreenshot = onScreenshot
        self.onOpenMain = onOpenMain
        self.onSettings = onSettings
        self.onQuit = onQuit
        super.init()

        menu.autoenablesItems = false
        configure(selectionItem, title: "Translate selection", identifier: "translatex.menu.selection", action: #selector(translateSelection))
        configure(inputItem, title: "Open translation window", identifier: "translatex.menu.input", action: #selector(openMain))
        configure(screenshotItem, title: "Screenshot Translation", identifier: "translatex.menu.screenshot", action: #selector(translateScreenshot))
        selectionItem.image = TranslateXActionSymbol.selection.menuImage()
        screenshotItem.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
        inputItem.image = TranslateXActionSymbol.input.menuImage()
        menu.addItem(selectionItem)
        menu.addItem(screenshotItem)
        menu.addItem(inputItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem()
        configure(settingsItem, title: "Settings…", identifier: "translatex.menu.settings", action: #selector(openSettings))
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)
        let quitItem = NSMenuItem()
        configure(quitItem, title: "Quit TSX", identifier: "translatex.menu.quit", action: #selector(quit))
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)
    }

    func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.menu = menu
        if let button = item.button {
            let image = NSImage(named: "MenuBarIcon")
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
            if image == nil { button.title = "T" }
            button.toolTip = "TSX"
            button.setAccessibilityLabel("TSX")
            button.setAccessibilityIdentifier("translatex.menu.button")
        }
        statusItem = item
    }

    func stop() {
        guard let item = statusItem else { return }
        item.menu = nil
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    func refreshLocalization() {
        let titles = ["translatex.menu.selection": "Translate selection", "translatex.menu.screenshot": "Screenshot Translation",
                      "translatex.menu.input": "Open translation window", "translatex.menu.settings": "Settings…",
                      "translatex.menu.quit": "Quit TSX"]
        for item in menu.items {
            if let identifier = item.identifier?.rawValue, let key = titles[identifier] {
                item.title = L10n.string(key)
            }
        }
    }

    /// Pass only successfully registered bindings. Nil omits a shortcut that is unavailable.
    func updateShortcuts(selection: GlobalShortcut?, input: GlobalShortcut?, ocr: GlobalShortcut? = nil) {
        selectionItem.title = title("Translate selection", shortcut: selection)
        inputItem.title = title("Open translation window", shortcut: input)
        screenshotItem.title = title("Screenshot Translation", shortcut: ocr)
    }

    private func configure(_ item: NSMenuItem, title: String, identifier: String, action: Selector) {
        item.title = L10n.string(title)
        item.identifier = NSUserInterfaceItemIdentifier(identifier)
        item.target = self
        item.action = action
        // Hints describe Carbon registrations; registering duplicate NSMenu equivalents
        // would let menu tracking intercept a shortcut handled by the global service.
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
    }

    private func title(_ label: String, shortcut: GlobalShortcut?) -> String {
        let localized = L10n.string(label)
        guard let shortcut, shortcut.isValid else { return localized }
        return localized + "    " + shortcut.displayString
    }

    @objc private func translateSelection() {
        // Keep the source app active. AppDelegate captures its selection before showing UI.
        onSelection()
    }

    @objc private func openMain() { onOpenMain() }
    @objc private func translateScreenshot() { onScreenshot() }
    @objc private func openSettings() { onSettings() }
    @objc private func quit() { onQuit() }

    isolated deinit {
        if let statusItem {
            statusItem.menu = nil
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }
}
