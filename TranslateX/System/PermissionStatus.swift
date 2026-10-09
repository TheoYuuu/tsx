import AppKit
import Observation

@MainActor @Observable
final class PermissionStatus {
    private(set) var accessibility = false
    private(set) var screenCapture = false

    @ObservationIgnored private let checkPermission: (SystemPermission) -> Bool
    @ObservationIgnored private let requestPermission: (SystemPermission) -> Void
    @ObservationIgnored private let showSettings: (SystemPermission) -> Void
    @ObservationIgnored private var requested: [SystemPermission] = []

    init(check: @escaping (SystemPermission) -> Bool = {
        $0 == .accessibility ? SelectionService.isAccessibilityTrusted : ScreenCaptureService.hasPermission
    }, request: @escaping (SystemPermission) -> Void = {
        switch $0 {
        case .accessibility: _ = SelectionService.requestAccessibilityPermission()
        case .screenCapture: _ = ScreenCaptureService.requestPermission()
        }
    }, openSettings: @escaping (SystemPermission) -> Void = { permission in
        let destination = permission == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(destination)") {
            NSWorkspace.shared.open(url)
        }
    }) {
        checkPermission = check
        requestPermission = request
        showSettings = openSettings
    }

    func refresh() {
        accessibility = checkPermission(.accessibility)
        screenCapture = checkPermission(.screenCapture)
    }

    func isGranted(_ permission: SystemPermission) -> Bool {
        switch permission {
        case .accessibility: accessibility
        case .screenCapture: screenCapture
        }
    }

    /// Called only by an explicit permission button, never by startup or refresh.
    func request(_ permission: SystemPermission) {
        refresh()
        guard !isGranted(permission) else { return }
        // A declined request is changed in System Settings; repeated clicks
        // during this launch must not repeatedly invoke the system prompt.
        if !requested.contains(permission) {
            requested.append(permission)
            requestPermission(permission)
        }
        refresh()
        if !isGranted(permission) { openSettings(permission) }
    }

    func openSettings(_ permission: SystemPermission) {
        showSettings(permission)
    }
}
