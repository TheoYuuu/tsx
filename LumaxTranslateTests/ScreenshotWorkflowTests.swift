import XCTest
@testable import LumaxTranslate

final class ScreenshotWorkflowTests: XCTestCase {
    func testRepeatedRestartKeepsOriginalInputWindowOriginThroughCloseCallbacks() {
        assertRepeatedRestartPreserves(.input)
    }

    func testRepeatedRestartKeepsOriginalSettingsWindowOriginThroughCloseCallbacks() {
        assertRepeatedRestartPreserves(.settings)
    }

    func testExternalApplicationScreenshotDoesNotAcquireWindowOriginOnRestart() {
        var state = ScreenshotWorkflowState()
        _ = state.begin(restoration: .none, inheritedRestoration: nil)
        let inherited = state.restorationForRestart
        state.cancel()
        // An active .none origin is distinct from having no preceding intent.
        let current = state.begin(restoration: .input, inheritedRestoration: inherited)
        XCTAssertEqual(state.finish(current), ScreenshotRestoration.none)
    }

    func testSwitchingToInputSelectionOrQuitDiscardsRestorationAndLateCompletion() {
        for origin in [ScreenshotRestoration.none, .input, .settings, .about] {
            var state = ScreenshotWorkflowState()
            let abandoned = state.begin(restoration: origin, inheritedRestoration: nil)
            state.cancel() // Explicit entry changes use cancel(), without a restart snapshot.
            XCTAssertNil(state.restorationForRestart)
            XCTAssertNil(state.finish(abandoned))
            let next = state.begin(restoration: .none, inheritedRestoration: state.restorationForRestart)
            XCTAssertEqual(state.finish(next), ScreenshotRestoration.none)
        }
    }

    func testCompletedScreenshotDoesNotLeakOriginIntoAnIndependentIntent() {
        for origin in [ScreenshotRestoration.none, .input, .settings, .about] {
            var state = ScreenshotWorkflowState()
            let completed = state.begin(restoration: origin, inheritedRestoration: nil)
            XCTAssertEqual(state.finish(completed), origin)
            // Success consumes the restoration value without reopening a window.
            XCTAssertNil(state.restorationForRestart)
            let next = state.begin(restoration: .none, inheritedRestoration: state.restorationForRestart)
            XCTAssertEqual(state.finish(next), ScreenshotRestoration.none)
        }
    }

    func testNewIntentUsesItsCurrentWindowAfterAnEarlierCompletion() {
        var state = ScreenshotWorkflowState()
        let first = state.begin(restoration: .input, inheritedRestoration: nil)
        _ = state.finish(first)
        let next = state.begin(restoration: .settings, inheritedRestoration: state.restorationForRestart)
        XCTAssertEqual(state.finish(next), .settings)
    }

    func testStaleCompletionCannotClearAReplacementOrItsOrigin() {
        for origin in [ScreenshotRestoration.none, .input, .settings, .about] {
            var state = ScreenshotWorkflowState()
            let previous = state.begin(restoration: .input, inheritedRestoration: nil)
            state.cancel()
            let current = state.begin(restoration: origin, inheritedRestoration: nil)
            XCTAssertNil(state.finish(previous))
            XCTAssertEqual(state.requestID, current)
            XCTAssertEqual(state.restorationForRestart, origin)
            XCTAssertEqual(state.finish(current), origin)
        }
    }

    private func assertRepeatedRestartPreserves(_ origin: ScreenshotRestoration, file: StaticString = #filePath, line: UInt = #line) {
        var state = ScreenshotWorkflowState()
        var current = state.begin(restoration: origin, inheritedRestoration: nil)
        for _ in 0..<3 {
            let inherited = state.restorationForRestart
            state.cancel() // start() cancels the preceding task.
            state.cancel() // closeQuick() invokes the operation-cancel callback as well.
            XCTAssertNil(state.finish(current), "The preceding task must not restore a window after restart", file: file, line: line)
            current = state.begin(restoration: .none, inheritedRestoration: inherited)
        }
        XCTAssertEqual(state.finish(current), origin, "Escape returns to the original window", file: file, line: line)
        XCTAssertNil(state.requestID, file: file, line: line)
        XCTAssertNil(state.restorationForRestart, file: file, line: line)
    }
}
