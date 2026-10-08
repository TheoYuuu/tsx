import AppKit
import Observation
import SwiftUI
import XCTest
@testable import TranslateX

@MainActor
final class TranslationServiceSecretInputTests: XCTestCase {
    func testSecureAndPlainSwitchesPreserveEditingAndFocusWithoutFalseBlur() async throws {
        let fixture = SecretInputFixture()
        defer { fixture.close() }
        try await fixture.waitFor { fixture.field != nil }
        let secure = try XCTUnwrap(fixture.field)
        XCTAssertTrue(secure is NSSecureTextField)
        XCTAssertTrue(fixture.window.makeFirstResponder(secure))
        try fixture.insert("constructed")
        try await fixture.waitFor { fixture.state.text == "constructed" }
        XCTAssertEqual(fixture.state.focusEvents, [true])

        fixture.state.visible = true
        try await fixture.waitFor {
            fixture.field !== secure && fixture.field?.currentEditor() != nil
        }
        XCTAssertFalse(fixture.field is NSSecureTextField)
        XCTAssertTrue(fixture.state.visible)
        try fixture.insert("-plain")
        try await fixture.waitFor { fixture.state.text == "constructed-plain" }

        let plain = fixture.field
        fixture.state.visible = false
        try await fixture.waitFor {
            fixture.field !== plain && fixture.field?.currentEditor() != nil
        }
        XCTAssertTrue(fixture.field is NSSecureTextField)
        try fixture.insert("-secure")
        try await fixture.waitFor { fixture.state.text == "constructed-plain-secure" }
        XCTAssertEqual(fixture.state.focusEvents, [true], "Changing visibility must not flash the focus outline.")
        XCTAssertEqual(fixture.state.blurCount, 0)
    }

    func testLateOldControlBlurIsIgnoredButMovingToAnotherFieldClearsShownText() async throws {
        let fixture = SecretInputFixture()
        defer { fixture.close() }
        try await fixture.waitFor { fixture.field != nil }
        let oldSecure = try XCTUnwrap(fixture.field)
        XCTAssertTrue(fixture.window.makeFirstResponder(oldSecure))
        fixture.state.text = "constructed-visible-value"
        fixture.state.visible = true
        try await fixture.waitFor {
            fixture.field !== oldSecure && fixture.field?.currentEditor() != nil
        }

        // Exercise a delayed native delegate event from the removed control.
        // The active text control and its real AppKit field editor stay in use.
        oldSecure.delegate?.controlTextDidEndEditing?(
            Notification(name: NSControl.textDidEndEditingNotification, object: oldSecure)
        )
        try await fixture.settle()
        XCTAssertTrue(fixture.state.visible)
        XCTAssertEqual(fixture.state.text, "constructed-visible-value")
        XCTAssertEqual(fixture.state.blurCount, 0)
        XCTAssertEqual(fixture.state.focusEvents, [true])

        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.otherField))
        try await fixture.waitFor { !fixture.state.visible && fixture.field is NSSecureTextField }
        XCTAssertEqual(fixture.state.text, "")
        XCTAssertEqual(fixture.state.blurCount, 1)
        XCTAssertEqual(fixture.state.focusEvents, [true, false])
        XCTAssertNil(fixture.field?.currentEditor())
        XCTAssertNotNil(fixture.otherField.currentEditor())
    }

    func testDisablingBackgroundClearsShownTextAndFocusThenAllowsSecureEditingAgain() async throws {
        let fixture = SecretInputFixture()
        defer { fixture.close() }
        try await fixture.waitFor { fixture.field != nil }
        fixture.state.text = "constructed-visible-value"
        fixture.state.visible = true
        try await fixture.waitFor {
            fixture.field?.currentEditor() != nil && !(fixture.field is NSSecureTextField)
        }
        XCTAssertEqual(fixture.state.focusEvents, [true])

        fixture.state.enabled = false
        try await fixture.waitFor {
            !fixture.state.visible && fixture.field is NSSecureTextField && fixture.field?.isEnabled == false
        }
        XCTAssertEqual(fixture.state.text, "")
        XCTAssertNil(fixture.field?.currentEditor())
        XCTAssertEqual(fixture.state.focusEvents, [true, false])

        fixture.state.enabled = true
        try await fixture.waitFor { fixture.field?.isEnabled == true }
        XCTAssertTrue(fixture.window.makeFirstResponder(try XCTUnwrap(fixture.field)))
        try fixture.insert("constructed-new-value")
        try await fixture.waitFor { fixture.state.text == "constructed-new-value" }
        XCTAssertTrue(fixture.field is NSSecureTextField)
        XCTAssertFalse(fixture.state.visible)
        XCTAssertEqual(fixture.state.focusEvents, [true, false, true])
    }

    func testTabAndShiftTabMoveFromSecureAndPlainControlsToSwiftUINeighbors() async throws {
        for visible in [false, true] {
            for backward in [false, true] {
                let fixture = SecretInputFixture()
                defer { fixture.close() }
                try await fixture.waitFor { fixture.field != nil }
                fixture.state.text = "constructed-navigation-value"
                fixture.state.visible = visible
                try await fixture.settle()
                XCTAssertTrue(fixture.window.makeFirstResponder(try XCTUnwrap(fixture.field)))
                let editor = try XCTUnwrap(fixture.field?.currentEditor() as? NSTextView)
                let event = try XCTUnwrap(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: backward ? .shift : [],
                    timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
                    characters: backward ? "\u{19}" : "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
                ))
                if backward {
                    // A hidden window has no system Shift-key state. Dispatch
                    // AppKit's standard Shift-Tab command through its real text
                    // editor; do not call the coordinator callback directly.
                    editor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
                } else {
                    editor.keyDown(with: event)
                }
                try await fixture.waitFor {
                    fixture.neighbor(backward: backward)?.currentEditor() != nil && !fixture.state.visible
                }
                XCTAssertEqual(fixture.state.tabDirections, [backward])
                XCTAssertNil(fixture.field?.currentEditor())
                XCTAssertTrue(fixture.field is NSSecureTextField)
                XCTAssertEqual(fixture.state.focusEvents, [true, false])
            }
        }
    }
}

@MainActor @Observable
private final class SecretInputState {
    var visible = false
    var text = ""
    var enabled = true
    var blurCount = 0
    var focusEvents: [Bool] = []
    var tabDirections: [Bool] = []

    func blur() {
        blurCount += 1
        visible = false
        text = ""
    }
}

@MainActor
private struct SecretInputFixtureView: View {
    @Bindable var state: SecretInputState
    @FocusState private var adjacentFocus: Neighbor?
    private enum Neighbor { case previous, next }
    var body: some View {
        VStack(spacing: 8) {
            TextField("Previous input", text: .constant("constructed-before"))
                .focused($adjacentFocus, equals: .previous)
            TranslationServiceSecretInput(
                text: $state.text, visible: state.visible,
                placeholder: "Constructed sample", ink: .black, muted: .gray,
                blur: state.blur, focusChanged: { state.focusEvents.append($0) },
                moveFocus: { backward in
                    state.tabDirections.append(backward)
                    state.visible = false
                    state.text = ""
                    adjacentFocus = backward ? .previous : .next
                }
            )
            .frame(width: 300, height: 32)
            .disabled(!state.enabled)
            TextField("Next input", text: .constant("constructed-after"))
                .focused($adjacentFocus, equals: .next)
        }
        .frame(width: 400, height: 120)
    }
}

/// A hidden, owned window exercises AppKit's real field editor without opening
/// user settings, reading credentials, or taking focus from another app.
@MainActor
private final class SecretInputFixture {
    let state = SecretInputState()
    let window: NSWindow
    let otherField = NSTextField(frame: NSRect(x: 20, y: 8, width: 300, height: 24))
    private let host: NSHostingView<SecretInputFixtureView>

    init() {
        _ = NSApplication.shared
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: SecretInputFixtureView(state: state))
        host.frame = NSRect(x: 0, y: 40, width: 400, height: 120)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 160))
        content.addSubview(host)
        content.addSubview(otherField)
        window.contentView = content
    }

    var field: NSTextField? { findField(in: host) { $0.accessibilityLabel() == L10n.string("API Key") } }

    func neighbor(backward: Bool) -> NSTextField? {
        findField(in: host) { $0.stringValue == (backward ? "constructed-before" : "constructed-after") }
    }

    func insert(_ text: String) throws {
        let editor = try XCTUnwrap(field?.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
    }

    func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Native secret input did not settle within one second.", file: file, line: line)
        throw FixtureError.timedOut
    }

    func settle() async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
    }

    func close() {
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.close()
    }

    private func findField(in view: NSView, matching predicate: (NSTextField) -> Bool) -> NSTextField? {
        if let field = view as? NSTextField, predicate(field) { return field }
        for child in view.subviews {
            if let field = findField(in: child, matching: predicate) { return field }
        }
        return nil
    }

    private enum FixtureError: Error { case timedOut }
}
