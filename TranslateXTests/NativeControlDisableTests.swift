import AppKit
import SwiftUI
import XCTest
@testable import TranslateX

@MainActor
final class NativeControlDisableTests: XCTestCase {
    func testDisabledEnvironmentReachesNativeControlsAndPreservesTheirOwnRestrictions() async throws {
        _ = NSApplication.shared
        let model = TranslationModel()
        let host = NSHostingView(rootView: NativeControlDisableFixture(model: model))
        let window = NSPanel(contentRect: NSRect(x: -10_000, y: -10_000, width: 500, height: 320),
                             styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return self.find(TranslationInputTextView.self, in: host) != nil
                && self.find(LanguageMenuControl.self, in: host) != nil
                && self.find(TranslationServiceMenuControl.self, in: host) != nil
        }
        let editor = try XCTUnwrap(find(TranslationInputTextView.self, in: host))
        let language = try XCTUnwrap(find(LanguageMenuControl.self, in: host))
        let service = try XCTUnwrap(find(TranslationServiceMenuControl.self, in: host))
        XCTAssertTrue(editor.isEditable && language.isEnabled && service.isEnabled)

        host.rootView = NativeControlDisableFixture(model: model, disabled: true)
        try await waitUntil { !editor.isInteractionEnabled && !language.isEnabled && !service.isEnabled }
        XCTAssertFalse(editor.isEditable)
        XCTAssertFalse(editor.isSelectable)
        XCTAssertFalse(editor.acceptsFirstResponder)
        XCTAssertFalse(language.acceptsFirstResponder)
        XCTAssertFalse(service.acceptsFirstResponder)

        model.editingChanged("Fixture composition", isComposing: true)
        host.rootView = NativeControlDisableFixture(model: model, languageEnabled: false)
        try await waitUntil { editor.isInteractionEnabled }
        XCTAssertFalse(language.isEnabled, "Enabling the container must not override the field's own restriction")
        XCTAssertFalse(service.isEnabled, "Service selection remains unavailable during composition")

        model.editingChanged("Fixture text", isComposing: false)
        host.rootView = NativeControlDisableFixture(model: model)
        try await waitUntil { editor.isEditable && language.isEnabled && service.isEnabled }
        XCTAssertTrue(find(TranslationInputTextView.self, in: host) === editor)
        XCTAssertTrue(find(LanguageMenuControl.self, in: host) === language)
        XCTAssertTrue(find(TranslationServiceMenuControl.self, in: host) === service)
        XCTAssertEqual(editor.string, "Retained editor text")
    }

    func testDisabledEditorBlocksNativeAndWorkspaceActionsWithoutLosingUndo() throws {
        let editor = makeEditor()
        editor.applyExternalText("Saved")
        let undo = try XCTUnwrap(editor.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.insertText(" edit", replacementRange: unspecifiedRange)
        undo.endUndoGrouping()
        let selection = editor.selectedRange()
        var submissions = 0, workspaceUndos = 0, workspaceRedos = 0, cancellations = 0
        editor.onSubmit = { submissions += 1 }
        editor.canUndoWorkspace = { true }
        editor.canRedoWorkspace = { true }
        editor.undoWorkspace = { workspaceUndos += 1 }
        editor.redoWorkspace = { workspaceRedos += 1 }
        editor.onCancel = { cancellations += 1; return true }
        let commandReturn = try submitEvent()

        editor.setInteractionEnabled(false)
        XCTAssertFalse(editor.performKeyEquivalent(with: commandReturn))
        editor.keyDown(with: commandReturn)
        editor.undo(nil)
        editor.redo(nil)
        editor.cancelOperation(nil)
        editor.insertText("Blocked", replacementRange: unspecifiedRange)
        XCTAssertEqual(submissions + workspaceUndos + workspaceRedos + cancellations, 0)
        XCTAssertEqual(editor.string, "Saved edit")
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertTrue(undo.canUndo)
        let undoItem = NSMenuItem(title: "Undo", action: #selector(TranslationInputTextView.undo(_:)), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: #selector(TranslationInputTextView.redo(_:)), keyEquivalent: "Z")
        XCTAssertFalse(editor.validateMenuItem(undoItem))
        XCTAssertFalse(editor.validateMenuItem(redoItem))

        editor.setInteractionEnabled(true)
        XCTAssertTrue(editor.performKeyEquivalent(with: commandReturn))
        editor.undo(nil)
        editor.redo(nil)
        editor.cancelOperation(nil)
        XCTAssertEqual([submissions, workspaceUndos, workspaceRedos, cancellations], [1, 1, 1, 1])
        editor.canUndoWorkspace = nil
        editor.canRedoWorkspace = nil
        editor.undo(nil)
        XCTAssertEqual(editor.string, "Saved")
        editor.redo(nil)
        XCTAssertEqual(editor.string, "Saved edit")
    }

    func testDisablingAndReenablingDoesNotCommitMarkedInput() throws {
        let editor = makeEditor()
        editor.applyExternalText("Hello ")
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecifiedRange)
        var commits = 0, submissions = 0
        editor.onEdit = { _, marked in if !marked { commits += 1 } }
        editor.onSubmit = { submissions += 1 }
        editor.setInteractionEnabled(false)
        editor.unmarkText()
        editor.insertText("你", replacementRange: unspecifiedRange)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "Hello ni")
        XCTAssertEqual(commits, 0)

        editor.setInteractionEnabled(true)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertTrue(editor.performKeyEquivalent(with: try submitEvent()))
        XCTAssertEqual(submissions, 0)
        editor.insertText("你", replacementRange: unspecifiedRange)
        XCTAssertEqual(editor.string, "Hello 你")
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(commits, 1)
        XCTAssertTrue(editor.performKeyEquivalent(with: try submitEvent()))
        XCTAssertEqual(submissions, 1)
    }

    func testExplicitPassageReplacementCanStillEndCompositionWhileCovered() {
        let editor = makeEditor()
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecifiedRange)
        editor.setInteractionEnabled(false)
        editor.finishCompositionForReplacement()
        editor.applyExternalText("New fixture passage", recordsUndo: false)
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "New fixture passage")
        XCTAssertFalse(editor.isInteractionEnabled)
    }

    private func makeEditor() -> TranslationInputTextView {
        _ = NSApplication.shared
        return TranslationInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
    }

    private func submitEvent() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    private var unspecifiedRange: NSRange { NSRange(location: NSNotFound, length: 0) }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match = find(type, in: child) { return match } }
        return nil
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Native control did not reflect the latest environment")
        throw CocoaError(.coderInvalidValue)
    }
}

private struct NativeControlDisableFixture: View {
    let model: TranslationModel
    var disabled = false
    var languageEnabled = true

    var body: some View {
        VStack {
            TranslationTextEditor(text: .constant("Retained editor text"), onEdit: { _, _ in }, onSubmit: {})
                .frame(width: 320, height: 160)
            LanguageMenu(label: "Language fixture", selection: .constant("en"),
                         languages: [.init(id: "en", name: "English")], enabled: languageEnabled)
            TranslationServicePicker(model: model)
        }.disabled(disabled)
    }
}
