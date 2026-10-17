import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// A temporary picture, not a second editing workspace. Pixels are retained only
/// until dismissal; only explicit copy/save actions put them outside memory.
@MainActor
final class ScreenshotOverlayController: NSObject {
    let model: TranslationModel
    private let windows: WindowCoordinator
    private let presentation = ScreenshotOverlayPresentation()
    private var panel: ScreenshotResultPanel?
    private var sourceApplication: NSRunningApplication?
    private var renderTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var trackedMenus = Set<ObjectIdentifier>()
    private var generation = UUID()
    private var renderedDocumentID: UUID?
    private let currentScreenLayout: @MainActor () -> [CaptureDisplay]
    private var presentedScreenLayout: [CaptureDisplay] = []
    private var imageDrag: ScreenshotOverlayDrag?
    private var toolbarAbove = false
    var onDismiss: (() -> Void)?
    var onRecapture: (() -> Void)?

    init(windows: WindowCoordinator, model: TranslationModel? = nil,
         currentScreenLayout: @escaping @MainActor () -> [CaptureDisplay] = ScreenshotOverlayController.screenLayout) {
        self.windows = windows
        self.model = model ?? TranslationModel(automaticallyTranslates: true, services: windows.services)
        self.currentScreenLayout = currentScreenLayout
        super.init()
        self.model.target = windows.preferences.defaultTarget
        observeDocument()
    }

    var isVisible: Bool { panel?.isVisible == true }

    func present(source: NSRunningApplication?, selection: CGRect) {
        sourceApplication = source
        presentedScreenLayout = currentScreenLayout()
        generation = UUID()
        presentation.message = nil
        presentation.showsFullText = false
        let screen = NSScreen.screens.max { a, b in
            a.frame.intersection(selection).area < b.frame.intersection(selection).area
        } ?? NSScreen.main
        let placement = ScreenshotOverlayPlacement(selection: selection,
            visibleFrame: screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 900, height: 700))
        imageDrag = nil
        toolbarAbove = placement.toolbarAbove
        let panel = self.panel ?? ScreenshotResultPanel(contentRect: placement.panelFrame,
            styleMask: [.borderless], backing: .buffered, defer: false)
        self.panel = panel
        panel.identifier = NSUserInterfaceItemIdentifier("translatex.screenshotResult")
        panel.title = L10n.string("Screenshot Translation")
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Each surface draws its own light shadow; the system shadow would
        // darken both the image and the transparent gap around the toolbar.
        panel.hasShadow = false
        panel.onClose = { [weak self] in self?.dismiss() }
        panel.onEscape = { [weak self] in self?.handleEscape() }
        // The transparent space around a small selection must remain clear.
        // WindowSurface intentionally paints a whole editor and is unsuitable here.
        let root = ScreenshotOverlayRoot(model: model, catalog: windows.languages,
            preferences: windows.preferences, presentation: presentation, placement: placement,
            onManageServices: { [weak windows] in windows?.showTranslationServices() },
            onClose: { [weak self] in self?.dismiss() },
            onRecapture: { [weak self] in self?.onRecapture?() },
            onEditInMain: { [weak self] in self?.editInMain() },
            onCopy: { [weak self] in self?.copy($0) },
            onSave: { [weak self] in self?.save($0) },
            onRetryRender: { [weak self] in self?.scheduleRender(delay: .zero) },
            onImageDrag: { [weak self] in self?.handleImageDrag($0) })
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.safeAreaRegions = []
        panel.contentView = host
        panel.setFrame(placement.panelFrame, display: false)
        scheduleRender(delay: .zero)
        installObservers()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss(restoreFocus: Bool = true) {
        let shouldRestore = restoreFocus && panel?.isKeyWindow == true && NSApp.isActive
        generation = UUID()
        imageDrag = nil
        renderTask?.cancel(); renderTask = nil
        feedbackTask?.cancel(); feedbackTask = nil
        model.clear(keepingUndo: false)
        if let sheet = panel?.attachedSheet {
            panel?.endSheet(sheet, returnCode: .cancel)
            sheet.orderOut(nil)
        }
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        presentation.rendered = nil
        presentation.isRendering = false
        presentation.renderFailed = false
        renderedDocumentID = nil
        presentation.message = nil
        presentation.showsFullText = false
        removeObservers()
        onDismiss?()
        if shouldRestore, let sourceApplication, !sourceApplication.isTerminated,
           sourceApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            sourceApplication.activate(options: [])
        }
        sourceApplication = nil
    }

    func handleImageDrag(_ event: ScreenshotImageDragEvent) {
        guard let panel, panel.isVisible, panel.attachedSheet == nil,
              trackedMenus.isEmpty, !presentation.showsFullText else {
            imageDrag = nil
            return
        }
        switch event {
        case .began(let pointer):
            imageDrag = ScreenshotOverlayDrag(panelFrame: panel.frame, pointer: pointer, toolbarAbove: toolbarAbove)
        case .moved(let pointer):
            guard let frame = imageDrag?.frame(at: pointer, visibleFrames: NSScreen.screens.map(\.visibleFrame)) else { return }
            panel.setFrameOrigin(frame.origin)
        case .ended:
            imageDrag = nil
        }
    }

    func editInMain() {
        guard model.phase != .recognizing, let handoff = model.makeHandoff() else { return }
        let source = sourceApplication
        dismiss(restoreFocus: false)
        windows.acceptScreenshot(handoff, source: source)
    }

    private func observeDocument() {
        withObservationTracking { _ = model.screenshot; _ = model.phase } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.presentation.message = nil
                self.observeDocument()
                self.scheduleRender()
            }
        }
    }

    private func scheduleRender(delay: Duration = .milliseconds(100)) {
        renderTask?.cancel()
        guard panel != nil, let document = model.screenshot else {
            presentation.rendered = nil
            presentation.isRendering = false
            presentation.renderFailed = false
            return
        }
        if renderedDocumentID != document.id || document.translations.isEmpty { presentation.rendered = nil }
        guard document.translations.values.contains(where: { !$0.isEmpty }) else {
            presentation.isRendering = false
            presentation.renderFailed = false
            return
        }
        presentation.isRendering = true
        presentation.renderFailed = false
        let expected = generation
        renderTask = Task { @MainActor [weak self] in
            // Coalesce completions, then do pixel repair/typesetting away from
            // the UI thread. A discarded document can never replace a new one.
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let rendered = await ScreenshotImageRenderer.renderPreview(document)
            guard !Task.isCancelled, let self, self.generation == expected,
                  self.model.screenshot == document else { return }
            self.presentation.rendered = rendered
            self.renderedDocumentID = document.id
            self.presentation.isRendering = false
            self.presentation.renderFailed = rendered == nil
        }
    }

    /// Resolve from the current document at the time of the action, never from
    /// the debounced preview. Copy/export cannot lag behind the visible text.
    func image(for output: ScreenshotOutput) -> CGImage? {
        guard let document = model.screenshot else { return nil }
        switch output {
        case .originalImage: return document.image
        case .translatedImage: return ScreenshotImageRenderer.render(document)?.image
        case .originalText, .translatedText: return nil
        }
    }

    func copy(_ output: ScreenshotOutput, pasteboard: NSPasteboard = .general) {
        guard let document = model.screenshot else { return }
        let succeeded: Bool
        switch output {
        case .originalText, .translatedText:
            let text = output == .originalText ? document.sourceText : document.translatedText
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            pasteboard.clearContents()
            succeeded = pasteboard.setString(text, forType: .string)
        case .originalImage, .translatedImage:
            guard let image = image(for: output), let data = ScreenshotImageExport.pngData(image) else {
                showFeedback("Unable to prepare the image. Try again.")
                return
            }
            pasteboard.clearContents()
            succeeded = pasteboard.setData(data, forType: .png)
        }
        showFeedback(succeeded ? "Copied" : "Unable to copy. Try again.")
    }

    func save(_ output: ScreenshotOutput) {
        guard let panel, panel.attachedSheet == nil else { return }
        guard let image = image(for: output), let data = ScreenshotImageExport.pngData(image) else {
            showFeedback("Unable to prepare the image. Try again.")
            return
        }
        let save = NSSavePanel()
        save.allowedContentTypes = [.png]
        save.canCreateDirectories = true
        save.nameFieldStringValue = output == .originalImage ? "TSX-original.png" : "TSX-translated.png"
        let expected = generation
        save.beginSheetModal(for: panel) { [weak self] response in
            guard let self, self.generation == expected, response == .OK, let url = save.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                self.showFeedback("Image saved")
            } catch {
                self.showFeedback("Unable to save the image. Choose another location.")
            }
        }
    }

    private func showFeedback(_ key: String) {
        feedbackTask?.cancel()
        presentation.message = L10n.string(key)
        feedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.presentation.message = nil
        }
    }

    private func installObservers() {
        removeObservers()
        NotificationCenter.default.addObserver(self, selector: #selector(menuBegan(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEnded(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.isVisible, event.keyCode == 53,
                      event.window === self.panel || self.presentation.showsFullText,
                      self.trackedMenus.isEmpty,
                      self.panel?.attachedSheet == nil,
                      (event.window?.firstResponder as? NSTextView)?.hasMarkedText() != true,
                      (self.panel?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
                self.handleEscape()
                return true
            }
            return consumed ? nil : event
        }
    }

    private func handleEscape() {
        // Consume the event and update the shared presentation synchronously.
        // Deferring this decision lets AppKit dismiss a popover first and can
        // accidentally dismiss the picture with the very same Escape press.
        if presentation.showsFullText { presentation.showsFullText = false }
        else { dismiss() }
    }

    @objc private func menuBegan(_ note: Notification) {
        imageDrag = nil
        if let menu = note.object as? NSMenu { trackedMenus.insert(ObjectIdentifier(menu)) }
        panel?.isTrackingMenu = !trackedMenus.isEmpty
    }
    @objc private func menuEnded(_ note: Notification) {
        guard let menu = note.object as? NSMenu else { return }
        let identifier = ObjectIdentifier(menu), expected = generation
        // AppKit can end tracking before the Escape event finishes propagating
        // to the panel. Keep this event inside the menu's dismissal boundary.
        Task { @MainActor [weak self] in
            guard let self, self.generation == expected else { return }
            self.trackedMenus.remove(identifier)
            self.panel?.isTrackingMenu = !self.trackedMenus.isEmpty
        }
    }
    @objc private func displaysChanged() {
        // AppKit also sends this when activation/menu-bar state changes. Only
        // actual display geometry changes invalidate a pinned picture.
        guard currentScreenLayout() != presentedScreenLayout else { return }
        dismiss(restoreFocus: false)
    }
    private static func screenLayout() -> [CaptureDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CaptureDisplay(id: id.uint32Value, frame: screen.frame, scale: screen.backingScaleFactor)
        }.sorted { $0.id < $1.id }
    }
    private func removeObservers() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NotificationCenter.default.removeObserver(self)
        trackedMenus.removeAll()
        panel?.isTrackingMenu = false
    }
}

@MainActor
private final class ScreenshotResultPanel: NSPanel {
    var onClose: (() -> Void)?
    var onEscape: (() -> Void)?
    var isTrackingMenu = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {
        guard !isTrackingMenu, attachedSheet == nil,
              (firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        onEscape?()
    }
    override func performClose(_ sender: Any?) { if attachedSheet == nil { onClose?() } }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSWindow.performClose(_:)) { return attachedSheet == nil }
        return super.validateUserInterfaceItem(item)
    }
}

@MainActor @Observable
private final class ScreenshotOverlayPresentation {
    var rendered: ScreenshotRenderedImage?
    var message: String?
    var isRendering = false
    var renderFailed = false
    var showsFullText = false
}

private struct ScreenshotOverlayRoot: View {
    let model: TranslationModel
    let catalog: LanguageCatalog
    let preferences: AppPreferences
    @Bindable var presentation: ScreenshotOverlayPresentation
    let placement: ScreenshotOverlayPlacement
    let onManageServices: () -> Void
    let onClose: () -> Void
    let onRecapture: () -> Void
    let onEditInMain: () -> Void
    let onCopy: (ScreenshotOutput) -> Void
    let onSave: (ScreenshotOutput) -> Void
    let onRetryRender: () -> Void
    let onImageDrag: (ScreenshotImageDragEvent) -> Void
    var body: some View {
        TranslateXThemeHost(preferences: preferences) {
            ScreenshotOverlayView(model: model, catalog: catalog, rendered: presentation.rendered,
                imageSize: placement.imageFrame.size, toolbarWidth: placement.frame.width,
                toolbarAbove: placement.toolbarAbove, imageOffsetX: placement.imageFrame.minX - placement.frame.minX,
                operationMessage: presentation.message,
                isRendering: presentation.isRendering, renderFailed: presentation.renderFailed, onRetryRender: onRetryRender,
                onImageDrag: onImageDrag,
                showsFullText: $presentation.showsFullText, onManageServices: onManageServices,
                onClose: onClose, onRecapture: onRecapture, onEditInMain: onEditInMain, onCopy: onCopy, onSave: onSave)
                .background { AppleTranslationHost(model: model) }
                .padding(ScreenshotOverlayPlacement.shadowInset)
        }
    }
}

enum ScreenshotImageDragEvent {
    case began(CGPoint), moved(CGPoint), ended
}

/// Keep a screen-space anchor: converting each event using the already-moved
/// window must not accumulate offsets or make the image jump during rendering.
struct ScreenshotOverlayDrag {
    let panelFrame: CGRect
    let pointer: CGPoint
    let toolbarAbove: Bool
    private var hasMoved = false

    init(panelFrame: CGRect, pointer: CGPoint, toolbarAbove: Bool) {
        self.panelFrame = panelFrame
        self.pointer = pointer
        self.toolbarAbove = toolbarAbove
    }

    mutating func frame(at location: CGPoint, visibleFrames: [CGRect]) -> CGRect? {
        let dx = location.x - pointer.x, dy = location.y - pointer.y
        hasMoved = hasMoved || hypot(dx, dy) >= 3
        guard hasMoved else { return nil }
        let proposed = panelFrame.offsetBy(dx: dx, dy: dy)
        // Choose by the pointer, so dragging across a display boundary can
        // leave the original screen. Negative display origins are valid.
        guard let screen = visibleFrames.min(by: { $0.distanceSquared(to: location) < $1.distanceSquared(to: location) }) else {
            return proposed
        }
        let safe = screen.insetBy(dx: 8, dy: 8)
        var content = proposed.insetBy(dx: ScreenshotOverlayPlacement.shadowInset, dy: ScreenshotOverlayPlacement.shadowInset)
        content.origin.x = content.width <= safe.width
            ? min(max(content.minX, safe.minX), safe.maxX - content.width)
            : safe.midX - content.width / 2
        content.origin.y = content.height <= safe.height
            ? min(max(content.minY, safe.minY), safe.maxY - content.height)
            : toolbarAbove ? safe.maxY - content.height : safe.minY
        // A smaller destination screen must not rescale the picture mid-drag.
        // If it cannot all fit, retain the toolbar at the visible edge.
        return content.insetBy(dx: -ScreenshotOverlayPlacement.shadowInset, dy: -ScreenshotOverlayPlacement.shadowInset)
    }
}

/// Preserve the selected screen position whenever the image and toolbar fit.
/// For a full-screen/oversized selection, fit the whole image without cropping.
struct ScreenshotOverlayPlacement {
    let frame: CGRect
    let imageFrame: CGRect
    let toolbarAbove: Bool
    static let toolbarHeight: CGFloat = 52
    static let shadowInset: CGFloat = 24

    /// Transparent drawing room for the soft shadows, without moving or
    /// resizing the selected image or the existing controls.
    var panelFrame: CGRect { frame.insetBy(dx: -Self.shadowInset, dy: -Self.shadowInset) }

    init(selection: CGRect, visibleFrame: CGRect) {
        let safe = visibleFrame.insetBy(dx: 8, dy: 8)
        let availableHeight = max(1, safe.height - Self.toolbarHeight)
        let scale = min(1, safe.width / max(1, selection.width), availableHeight / max(1, selection.height))
        let size = CGSize(width: max(1, selection.width * scale), height: max(1, selection.height * scale))
        let x = min(max(selection.minX, safe.minX), safe.maxX - size.width)
        let y = min(max(selection.minY, safe.minY), safe.maxY - size.height)
        let above = y - Self.toolbarHeight < safe.minY && y + size.height + Self.toolbarHeight <= safe.maxY
        let imageY = above ? y : max(y, safe.minY + Self.toolbarHeight)
        imageFrame = CGRect(origin: CGPoint(x: x, y: imageY), size: size)
        let width = min(max(720, size.width), safe.width)
        let windowX = min(max(imageFrame.midX - width / 2, safe.minX), safe.maxX - width)
        toolbarAbove = above
        frame = CGRect(x: windowX, y: above ? imageY : imageY - Self.toolbarHeight,
            width: width, height: size.height + Self.toolbarHeight)
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isInfinite ? 0 : width * height }
    func distanceSquared(to point: CGPoint) -> CGFloat {
        let dx = max(minX - point.x, 0, point.x - maxX)
        let dy = max(minY - point.y, 0, point.y - maxY)
        return dx * dx + dy * dy
    }
}
