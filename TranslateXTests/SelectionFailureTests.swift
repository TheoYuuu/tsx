import Foundation
import XCTest
@testable import TranslateX

final class SelectionFailureTests: XCTestCase {
    func testSelectionFailuresExplainTheirDifferentRecoveryActions() {
        let cases: [(SelectionError, String)] = [
            (.shortcutStillPressed, "Release the shortcut keys, then try again."),
            (.sourceUnresponsive, "This app took too long to respond. Try again, or use input translation."),
            (.copyTimedOut, "This app didn’t respond to Copy. Select text and try again, or use input translation."),
            (.clipboardUnavailable, "Your clipboard couldn’t be backed up, so nothing was copied. Use input translation or try again after your next copy."),
            (.clipboardRestoreFailed, "Your previous clipboard couldn’t be restored. Copy the content you want to keep again.")
        ]
        for (error, message) in cases {
            XCTAssertEqual(SelectionFailure(error), .message(message))
            XCTAssertNotEqual(SelectionFailure(error), SelectionFailure(SelectionError.sourceUnavailable))
        }
    }

    func testPermissionFailureUsesPermissionRecoveryInsteadOfAppCompatibilityMessage() {
        XCTAssertEqual(SelectionFailure(SelectionError.accessibilityPermissionRequired), .accessibilityPermissionRequired)
        XCTAssertNotEqual(SelectionFailure(SelectionError.sourceUnavailable), .accessibilityPermissionRequired)
        XCTAssertNotEqual(SelectionFailure(SelectionError.secureInput), .accessibilityPermissionRequired)
    }

    func testClipboardInterferenceAndEmptySelectionHaveDifferentRecoveryMessages() {
        XCTAssertEqual(SelectionFailure(SelectionError.clipboardChanged), SelectionFailure(SelectionError.sourceChanged))
        XCTAssertNotEqual(SelectionFailure(SelectionError.clipboardChanged), SelectionFailure(SelectionError.noSelection))
        XCTAssertNotEqual(SelectionFailure(SelectionError.busy), SelectionFailure(SelectionError.sourceUnavailable))
    }

    func testUnknownErrorNeverIncludesPrivateSystemDescription() {
        let error = NSError(domain: "SyntheticSelection", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "private-selection-value"])
        let failure = SelectionFailure(error)
        XCTAssertEqual(failure, SelectionFailure(SelectionError.sourceUnavailable))
        guard case .message(let key) = failure else { return XCTFail("Unknown errors should offer the input fallback") }
        XCTAssertFalse(key.contains("private-selection-value"))
    }
}

@MainActor
final class PermissionRequestTests: XCTestCase {
    func testGrantedPermissionsNeverPromptAndRefreshRechecksTheSystem() {
        var granted = true
        var requests: [SystemPermission] = []
        var settings: [SystemPermission] = []
        let status = PermissionStatus(check: { _ in granted }, request: { requests.append($0) }, openSettings: { settings.append($0) })
        status.refresh()
        status.request(.accessibility)
        status.request(.screenCapture)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(settings.isEmpty)
        granted = false
        status.refresh()
        XCTAssertFalse(status.accessibility)
        XCTAssertFalse(status.screenCapture)
        XCTAssertTrue(requests.isEmpty, "Checking permission must never request it")
    }

    func testDeniedPermissionOnlyPromptsOncePerLaunchThenOpensSettings() {
        var granted = false
        var requests: [SystemPermission] = []
        var settings: [SystemPermission] = []
        let status = PermissionStatus(check: { _ in granted }, request: { requests.append($0) }, openSettings: { settings.append($0) })
        status.request(.accessibility)
        status.request(.accessibility)
        XCTAssertEqual(requests, [.accessibility])
        XCTAssertEqual(settings, [.accessibility, .accessibility])
        status.request(.screenCapture)
        XCTAssertEqual(requests, [.accessibility, .screenCapture])
        granted = true
        status.request(.accessibility)
        XCTAssertTrue(status.accessibility)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(settings.count, 3)
    }
}
