import CoreGraphics
import Foundation
import ScreenCaptureKit

enum CaptureError: Error, Equatable, Sendable {
    case permissionRequired
    case noDisplays
    case invalidRegion
    case tooLarge
    case captureFailed
    case busy
    case screenConfigurationChanged
}

/// A user-triggered still capture. Screenshots, filters and source metadata are kept
/// only for the duration of this operation; no streams, audio or persistence are used.
actor ScreenCaptureService {
    private var isCapturing = false

    nonisolated static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Only a permission button or other explicit confirmation may call this method.
    /// A prior denial may require the person to change access in System Settings.
    @MainActor @discardableResult
    static func requestPermission() -> Bool {
        guard !hasPermission else { return true }
        return CGRequestScreenCaptureAccess()
    }

    /// `region` is AppKit global bottom-left points. `referenceTop` is the primary
    /// screen's frame.maxY, captured by the UI along with the selection coordinates.
    /// The caller closes all selection overlays before invoking this method.
    func capture(
        region: CGRect, referenceTop: CGFloat, excludingWindowIDs: [CGWindowID], layout: CaptureLayoutGuard
    ) async throws -> CGImage {
        try Task.checkCancellation()
        try await layout.validate(referenceTop: referenceTop)
        _ = try CaptureGeometry.quartzRect(fromAppKit: region, referenceTop: referenceTop)
        guard !isCapturing else { throw CaptureError.busy }
        guard Self.hasPermission else { throw CaptureError.permissionRequired }
        isCapturing = true
        defer { isCapturing = false }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            try Task.checkCancellation()
            try await layout.validate()
            guard !content.displays.isEmpty else { throw CaptureError.noDisplays }
            let excludedIDs = Set(excludingWindowIDs)
            let excludedWindows = content.windows.filter { excludedIDs.contains($0.windowID) }
            var filters: [CGDirectDisplayID: SCContentFilter] = [:]
            let candidateDisplays = content.displays.map { display in
                let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
                filters[display.displayID] = filter
                return CaptureDisplay(id: display.displayID, frame: display.frame, scale: CGFloat(filter.pointPixelScale))
            }
            let displays = try await layout.validatedDisplays(candidateDisplays)
            let plan = try CaptureGeometry.plan(region: region, referenceTop: referenceTop, displays: displays)
            var images: [CGDirectDisplayID: CGImage] = [:]
            for tile in plan.tiles {
                try Task.checkCancellation()
                try await layout.validate()
                guard Self.hasPermission else { throw CaptureError.permissionRequired }
                guard let filter = filters[tile.displayID] else { throw CaptureError.captureFailed }
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = tile.sourceRect
                configuration.width = tile.pixelWidth
                configuration.height = tile.pixelHeight
                configuration.scalesToFit = true
                configuration.preservesAspectRatio = true
                configuration.captureResolution = .best
                configuration.captureDynamicRange = .SDR
                configuration.colorSpaceName = CGColorSpace.sRGB
                configuration.showsCursor = false
                configuration.showMouseClicks = false
                configuration.capturesAudio = false
                configuration.captureMicrophone = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                try Task.checkCancellation()
                try await layout.validate()
                // Never partially return a cross-display selection if one tile fails.
                images[tile.displayID] = image
            }
            let image = try CaptureGeometry.composite(plan: plan, images: images)
            try await layout.validate()
            return image
        } catch {
            try Task.checkCancellation()
            try await layout.validate()
            if let known = error as? CaptureError { throw known }
            let systemError = error as NSError
            if systemError.domain == SCStreamErrorDomain,
               systemError.code == SCStreamError.Code.userDeclined.rawValue {
                throw CaptureError.permissionRequired
            }
            if !Self.hasPermission { throw CaptureError.permissionRequired }
            // System error descriptions may include source window/app metadata.
            throw CaptureError.captureFailed
        }
    }
}
