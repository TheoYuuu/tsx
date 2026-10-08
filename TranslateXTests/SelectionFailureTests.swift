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
