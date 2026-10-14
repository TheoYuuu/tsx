import AppKit

/// One user-initiated screenshot intent. Capture/OCR keep pixels in memory;
/// only the result layer's explicit copy/save actions may export them.
@MainActor
final class ScreenshotTranslationController {
    private let windows: WindowCoordinator
    private let selector: RegionSelectionController
    private let capture = ScreenCaptureService()
    private let recognizer = OCRService()
    private var task: Task<Void, Never>?
    private var workflow = ScreenshotWorkflowState()
    private lazy var overlay: ScreenshotOverlayController = {
        let overlay = ScreenshotOverlayController(windows: windows)
        overlay.onDismiss = { [weak self] in self?.cancelCapture() }
        overlay.onRecapture = { [weak self] in
            guard let self else { return }
            self.start(source: self.sourceApplication)
        }
        return overlay
    }()
    private var sourceApplication: NSRunningApplication?

    init(windows: WindowCoordinator) {
        self.windows = windows
        selector = RegionSelectionController(preferences: windows.preferences)
    }

    func start(source: NSRunningApplication?) {
        // Cancelling the previous capture calls back into cancel(). Preserve the origin before
        // either cancellation, so restarting a selector does not forget its hidden window.
        let inheritedRestoration = workflow.restorationForRestart
        cancel()
        windows.cancelExternalCapture()
        sourceApplication = source
        let serviceRevision = overlay.model.captureServiceIntent()
        guard ScreenCaptureService.hasPermission else {
            windows.showPermission(.screenCapture, source: source)
            return
        }
        let restoration = windows.hideForScreenshot()
        let id = workflow.begin(restoration: restoration, inheritedRestoration: inheritedRestoration)
        task = Task { [weak self] in
            guard let self, !Task.isCancelled, self.workflow.requestID == id else { return }
            if let source, !source.isTerminated,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != source.processIdentifier {
                source.activate(options: [])
            }
            var hasPresentedCapture = false
            do {
                let layout = try CaptureLayoutGuard.begin()
                defer { layout.stop() }
                let region = try await self.selector.selectRegion()
                guard !Task.isCancelled, self.workflow.requestID == id else { return }
                try layout.validate(referenceTop: region.referenceTop)
                // The selector has removed every overlay before this capture starts.
                // Show the temporary image only after pixels are captured, so it cannot
                // become part of the user's selected region.
                let image = try await self.capture.capture(
                    region: region.bounds, referenceTop: region.referenceTop,
                    excludingWindowIDs: region.excludingWindowIDs, layout: layout
                )
                guard !Task.isCancelled, self.workflow.requestID == id else { return }
                try layout.validate()
                // The selected pixels are now immutable. Activating the result
                // can itself send a screen-parameters notification; OCR no
                // longer depends on live capture coordinates.
                layout.stop()
                self.overlay.model.source = "auto"
                self.overlay.model.target = self.windows.inputModel.target
                self.overlay.model.useScreenshotSourceName()
                hasPresentedCapture = true
                self.overlay.model.beginRecognition(image: image, cancellation: { [weak self] in self?.cancelCapture() })
                self.overlay.present(source: source, selection: region.bounds)
                let document = try await self.recognizer.recognizeDocument(image)
                guard !Task.isCancelled, self.workflow.requestID == id else { return }
                self.overlay.model.submitCapturedDocument(document, serviceRevision: serviceRevision,
                    respectAutomaticPreference: true)
                self.finish(id)
            } catch is CancellationError {
                guard let restoration = self.finish(id) else { return }
                self.windows.restoreAfterScreenshotCancellation(restoration)
            } catch {
                guard !Task.isCancelled, self.workflow.requestID == id else { return }
                self.finish(id)
                if (error as? CaptureError) == .permissionRequired {
                    self.windows.showPermission(.screenCapture, source: source)
                } else {
                    if hasPresentedCapture {
                        self.overlay.model.fail(localized: ScreenshotFailure.key(for: error))
                    } else {
                        self.windows.restoreAfterScreenshotCancellation(restoration)
                        let alert = NSAlert()
                        alert.messageText = L10n.string("Screenshot Translation")
                        alert.informativeText = ScreenshotFailure.message(for: error)
                        alert.addButton(withTitle: L10n.string("OK"))
                        alert.runModal()
                    }
                }
            }
        }
    }

    func cancel() {
        cancelCapture()
        overlay.dismiss(restoreFocus: false)
    }

    private func cancelCapture() {
        workflow.cancel()
        task?.cancel()
        task = nil
        selector.cancel()
    }

    @discardableResult
    private func finish(_ id: UUID) -> ScreenshotRestoration? {
        guard let restoration = workflow.finish(id) else { return nil }
        task = nil
        return restoration
    }
}

enum ScreenshotRestoration: Equatable {
    case none, input, settings, about
}

/// Only an active screenshot intent may carry its window origin across a restart.
/// A completed or explicitly abandoned intent must not reopen that window later.
struct ScreenshotWorkflowState {
    private(set) var requestID: UUID?
    private var restorationOnCancel: ScreenshotRestoration = .none

    var restorationForRestart: ScreenshotRestoration? {
        requestID == nil ? nil : restorationOnCancel
    }

    mutating func begin(restoration: ScreenshotRestoration, inheritedRestoration: ScreenshotRestoration?) -> UUID {
        let id = UUID()
        requestID = id
        restorationOnCancel = inheritedRestoration ?? restoration
        return id
    }

    /// nil means this completion belongs to an older, already discarded intent.
    mutating func finish(_ id: UUID) -> ScreenshotRestoration? {
        guard requestID == id else { return nil }
        let restoration = restorationOnCancel
        cancel()
        return restoration
    }

    mutating func cancel() {
        requestID = nil
        restorationOnCancel = .none
    }
}

enum ScreenshotFailure {
    static func message(for error: any Error) -> String { L10n.string(key(for: error)) }

    static func key(for error: any Error) -> String {
        let key: String
        if let error = error as? OCRError {
            switch error {
            case .noText: key = "No text was found in this area. Select a clearer or larger passage."
            case .tooMuchText: key = "This area contains too much text. Select a smaller passage."
            case .recognitionFailed: key = "Text recognition couldn’t finish. Try selecting the area again."
            }
        } else if let error = error as? CaptureError {
            switch error {
            case .permissionRequired: key = "Screen Recording access is required. Enable it in System Settings and try again."
            case .tooLarge: key = "This area is too large to capture. Select a smaller area."
            case .invalidRegion: key = "Select an area that includes part of a screen."
            case .noDisplays: key = "No display is available. Connect a display and try again."
            case .busy: key = "A capture is still finishing. Try again shortly."
            case .captureFailed: key = "The screenshot couldn’t be captured. Try selecting the area again."
            case .screenConfigurationChanged: key = "Displays changed. Start a new screenshot."
            }
        } else if let error = error as? RegionSelectionError {
            switch error {
            case .busy: key = "A capture is still finishing. Try again shortly."
            case .noScreens: key = "No display is available. Connect a display and try again."
            case .screenConfigurationChanged: key = "Displays changed. Start a new screenshot."
            }
        } else {
            key = "The screenshot couldn’t be captured. Try selecting the area again."
        }
        return key
    }
}
