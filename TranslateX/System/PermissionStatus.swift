import AppKit
import Observation

@MainActor @Observable
final class PermissionStatus {
    private(set) var accessibility = false
    private(set) var screenCapture = false

    func refresh() {
        accessibility = SelectionService.isAccessibilityTrusted
        screenCapture = ScreenCaptureService.hasPermission
    }

    func isGranted(_ permission: SystemPermission) -> Bool {
        switch permission {
        case .accessibility: accessibility
        case .screenCapture: screenCapture
        }
    }

    /// Called only by an explicit permission button, never by startup or refresh.
    func request(_ permission: SystemPermission) {
        switch permission {
        case .accessibility: _ = SelectionService.requestAccessibilityPermission()
        case .screenCapture: _ = ScreenCaptureService.requestPermission()
        }
        refresh()
        if !isGranted(permission) { openSettings(permission) }
    }

    func openSettings(_ permission: SystemPermission) {
        let destination = permission == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(destination)") {
            NSWorkspace.shared.open(url)
        }
    }
}
