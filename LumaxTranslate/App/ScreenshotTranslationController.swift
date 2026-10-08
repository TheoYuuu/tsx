import AppKit

/// One user-initiated screenshot intent. Captured pixels stay in the local workspace, never a log, file or provider request.
@MainActor
final class ScreenshotTranslationController {
    private let windows: WindowCoordinator
    private let selector: RegionSelectionController
    private let capture = ScreenCaptureService()
    private let recognizer = OCRService()
    private var task: Task<Void, Never>?
    private var workflow = ScreenshotWorkflowState()

    init(windows: WindowCoordinator) {
        self.windows = windows
        selector = RegionSelectionController(preferences: windows.preferences)
    }

    func start(source: NSRunningApplication?) {
        // Closing the old panel calls back into cancel(). Preserve the origin before
        // either cancellation, so restarting a selector does not forget its hidden window.
        let inheritedRestoration = workflow.restorationForRestart
        cancel()
        windows.closeQuick(restoreFocus: false)
        windows.prepareQuickTranslation()
        let serviceRevision = windows.quickModel.captureServiceIntent()
        windows.quickModel.useScreenshotSourceName()
        guard ScreenCaptureService.hasPermission else {
            windows.showQuick(source: source, permission: .screenCapture)
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
            var resultBounds: CGRect?
            do {
                let layout = try CaptureLayoutGuard.begin()
                defer { layout.stop() }
                let region = try await self.selector.selectRegion()
                guard !Task.isCancelled, self.workflow.requestID == id else { return }
                try layout.validate(referenceTop: region.referenceTop)
                resultBounds = CGRect(x: region.bounds.minX, y: region.referenceTop - region.bounds.maxY,
                                      width: region.bounds.width, height: region.bounds.height)
                // The selector has removed every overlay before this capture starts.
                // Show the result panel only after pixels are captured, so it cannot
                // become part of the user's selected region.
                let image = try await self.capture.capture(
                    region: region.bounds, referenceTop: region.referenceTop,
                    excludingWindowIDs: region.excludingWindowIDs, layout: layout
                )
                guard !Task.isCancelled, self.workflow.requestID == id else { return }
                try layout.validate()
                self.windows.quickModel.beginRecognition(image: image, cancellation: { [weak self] in self?.cancel() })
                self.windows.showQuick(source: source, bounds: resultBounds)
                let document = try await self.recognizer.recognizeDocument(image)
                guard !Task.isCancelled, self.workflow.requestID == id else { return }
                try layout.validate()
                self.windows.quickModel.submitCapturedDocument(document, serviceRevision: serviceRevision)
                self.finish(id)
            } catch is CancellationError {
                guard let restoration = self.finish(id) else { return }
                self.windows.restoreAfterScreenshotCancellation(restoration)
            } catch {
                guard !Task.isCancelled, self.workflow.requestID == id else { return }
                self.finish(id)
                if (error as? CaptureError) == .permissionRequired {
                    self.windows.showQuick(source: source, permission: .screenCapture)
                } else {
                    self.windows.quickModel.fail(localized: ScreenshotFailure.key(for: error))
                    let layoutChanged = (error as? CaptureError) == .screenConfigurationChanged
                        || (error as? RegionSelectionError) == .screenConfigurationChanged
                    self.windows.showQuick(source: source, bounds: layoutChanged ? nil : resultBounds)
                }
            }
        }
    }

    func cancel() {
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
