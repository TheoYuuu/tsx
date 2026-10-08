import AppKit
import XCTest
@testable import LumaxTranslate

@MainActor
final class QuickEditorTests: XCTestCase {
    func testNativeQuickEditorSupportsCompositionUndoAndManualRemoteHandoff() async throws {
        _ = NSApplication.shared
        let inputMonitor = try isolateUnscriptedWindowInput()
        defer { NSEvent.removeMonitor(inputMonitor) }
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let configuration = TranslationServiceConfiguration(kind: .openAI)
        try windows.services.save(configuration, apiKey: "constructed-key-never-valid")
        windows.quickModel.selectService(configuration.id)
        windows.quickModel.text = "Original passage."
        windows.showQuick(source: nil)
        try await Task.sleep(for: .milliseconds(150))
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "lumax.quick" && $0.isVisible } as? QuickPanel)
        let editor = try XCTUnwrap(findEditor(try XCTUnwrap(panel.contentView)))
        // AppKit can apply its preferred scroller style while the window is
        // attaching. Wait for the production view's next update, without setting
        // the style in the fixture or weakening the overlay assertion below.
        for _ in 0..<50 {
            if editor.enclosingScrollView?.scrollerStyle == .overlay { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(panel.frame.size, NSSize(width: 720, height: 430))
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(editor.font?.pointSize, 16)
        XCTAssertEqual(editor.enclosingScrollView?.scrollerStyle, .overlay)
        XCTAssertGreaterThan(editor.enclosingScrollView?.frame.height ?? 0, 180)
        XCTAssertEqual(editor.string, windows.quickModel.text)
        panel.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(windows.quickModel.isComposing)
        XCTAssertFalse(windows.canOpenQuickInMain)
        panel.cancelOperation(nil)
        XCTAssertTrue(panel.isVisible, "Escape belongs to the input method while text is being composed")
        editor.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(windows.quickModel.isComposing)
        XCTAssertEqual(windows.quickModel.text, "Original passage.你好")
        XCTAssertTrue(try XCTUnwrap(editor.undoManager).canUndo)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(windows.quickModel.request, "Editing cannot send text to a service without automatic translation opt-in")
        let handoff = try XCTUnwrap(windows.quickModel.makeHandoff())
        XCTAssertEqual(handoff.text, editor.string)
        XCTAssertNil(handoff.completedResult)
        windows.openQuickInMain()
        XCTAssertEqual(windows.inputModel.text, handoff.text)
        XCTAssertNil(windows.inputModel.request, "Expanding an unsubmitted remote draft must not send it")
    }

    func testStartingANewCaptureClearsCompositionAndThePreviousEditablePassage() async throws {
        _ = NSApplication.shared
        let inputMonitor = try isolateUnscriptedWindowInput()
        defer { NSEvent.removeMonitor(inputMonitor) }
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.showQuick(source: nil)
        try await Task.sleep(for: .milliseconds(100))
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "lumax.quick" && $0.isVisible })
        let editor = try XCTUnwrap(findEditor(try XCTUnwrap(panel.contentView)))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        windows.prepareQuickTranslation()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertTrue(windows.quickModel.text.isEmpty)
        XCTAssertNil(windows.quickModel.request)
        XCTAssertFalse(windows.quickModel.isComposing)
    }

    private func findEditor(_ view: NSView) -> TranslationInputTextView? {
        if let editor = view as? TranslationInputTextView { return editor }
        return view.subviews.compactMap(findEditor).first
    }
}
