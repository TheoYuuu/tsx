import XCTest
@testable import TranslateX

final class ScreenshotFailureTests: XCTestCase {
    func testNoTextAndSizeFailuresHaveDifferentRecoveryMessages() {
        XCTAssertNotEqual(ScreenshotFailure.message(for: OCRError.noText), ScreenshotFailure.message(for: CaptureError.tooLarge))
        XCTAssertNotEqual(ScreenshotFailure.message(for: CaptureError.permissionRequired), ScreenshotFailure.message(for: CaptureError.captureFailed))
        XCTAssertNotEqual(ScreenshotFailure.message(for: RegionSelectionError.screenConfigurationChanged), ScreenshotFailure.message(for: OCRError.recognitionFailed))
    }

    func testUnknownCaptureErrorDoesNotEchoPrivateSystemDescription() {
        let error = NSError(domain: "SyntheticCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "private-window-title"])
        XCTAssertFalse(ScreenshotFailure.message(for: error).contains("private-window-title"))
        XCTAssertEqual(ScreenshotFailure.message(for: error), ScreenshotFailure.message(for: CaptureError.captureFailed))
    }

    func testLayoutChangesBeforeAndAfterSelectionUseTheSameRecoveryMessage() {
        XCTAssertEqual(ScreenshotFailure.message(for: CaptureError.screenConfigurationChanged),
                       ScreenshotFailure.message(for: RegionSelectionError.screenConfigurationChanged))
        XCTAssertNotEqual(ScreenshotFailure.message(for: CaptureError.screenConfigurationChanged),
                          ScreenshotFailure.message(for: CaptureError.captureFailed))
    }
}
