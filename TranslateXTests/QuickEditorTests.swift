import AppKit
import XCTest
@testable import TranslateX

@MainActor
final class QuickEditorTests: XCTestCase {
    func testSharedNativeEditorKeepsCompositionUndoAndManualRemoteDraftAcrossPresentations() async throws {
        _ = NSApplication.shared
        let inputMonitor = try isolateUnscriptedWindowInput()
        defer { NSEvent.removeMonitor(inputMonitor) }
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let configuration = TranslationServiceConfiguration(kind: .openAI)
        try windows.services.save(configuration, apiKey: "constructed-key-never-valid")
        windows.inputModel.selectService(configuration.id)
        windows.inputModel.text = "Original passage."
        windows.showCapturedTranslation(source: nil)
        try await Task.sleep(for: .milliseconds(150))
        let main = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.main" && $0.isVisible } as? TranslationWindow)
        let editor = try XCTUnwrap(findEditor(try XCTUnwrap(main.contentView)))
        for _ in 0..<50 {
            if editor.enclosingScrollView?.scrollerStyle == .overlay { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(editor.font?.pointSize, 19)
        XCTAssertEqual(editor.enclosingScrollView?.scrollerStyle, .overlay)
        XCTAssertGreaterThan(editor.enclosingScrollView?.frame.height ?? 0, 180)
        XCTAssertEqual(editor.string, windows.inputModel.text)
        main.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(windows.inputModel.isComposing)
        main.cancelOperation(nil)
        XCTAssertTrue(main.isVisible, "The input method owns Escape while text is being composed")
        editor.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(windows.inputModel.isComposing)
        XCTAssertEqual(windows.inputModel.text, "Original passage.你好")
        XCTAssertTrue(try XCTUnwrap(editor.undoManager).canUndo)
        windows.showMain()
        windows.showTranslationWindow()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(findEditor(try XCTUnwrap(main.contentView)) === editor)
        XCTAssertEqual(editor.string, "Original passage.你好")
        XCTAssertTrue(try XCTUnwrap(editor.undoManager).canUndo)
        XCTAssertNil(windows.inputModel.request, "Reopening a manual remote draft must not send it")
    }

    func testCaptureCommitsCompositionAndPreviousDraftCanBeRestoredInTheSameEditor() async throws {
        _ = NSApplication.shared
        let inputMonitor = try isolateUnscriptedWindowInput()
        defer { NSEvent.removeMonitor(inputMonitor) }
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.inputModel.setAutomaticTranslation(false)
        windows.inputModel.text = "Original draft "
        windows.showMain()
        try await Task.sleep(for: .milliseconds(100))
        let main = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.main" && $0.isVisible })
        let editor = try XCTUnwrap(findEditor(try XCTUnwrap(main.contentView)))
        main.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let expected = editor.string
        XCTAssertTrue(editor.hasMarkedText())
        windows.prepareCapturedTranslation()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertTrue(windows.inputModel.text.isEmpty)
        XCTAssertNil(windows.inputModel.request)
        XCTAssertFalse(windows.inputModel.isComposing)
        XCTAssertTrue(windows.inputModel.canRestorePreviousWorkspace)
        windows.inputModel.text = "Replacement draft."
        windows.restorePreviousTranslation()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(windows.inputModel.text, expected)
        XCTAssertEqual(editor.string, expected)
        XCTAssertTrue(findEditor(try XCTUnwrap(main.contentView)) === editor)
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertNil(windows.inputModel.request)
    }

    func testPreviousWorkspaceRestoreWaitsForCurrentCompositionToFinish() async throws {
        _ = NSApplication.shared
        let monitor = try isolateUnscriptedWindowInput()
        defer { NSEvent.removeMonitor(monitor) }
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.inputModel.setAutomaticTranslation(false)
        windows.inputModel.text = "Previous draft."
        windows.prepareCapturedTranslation()
        windows.inputModel.text = "Current draft "
        windows.showMain()
        try await Task.sleep(for: .milliseconds(100))
        let main = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.main" && $0.isVisible })
        let editor = try XCTUnwrap(findEditor(try XCTUnwrap(main.contentView)))
        main.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        windows.restorePreviousTranslation()
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertTrue(windows.inputModel.canRestorePreviousWorkspace)
        XCTAssertTrue(windows.inputModel.text.hasPrefix("Current draft"))
        editor.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        windows.restorePreviousTranslation()
        XCTAssertEqual(windows.inputModel.text, "Previous draft.")
        XCTAssertFalse(windows.inputModel.canRestorePreviousWorkspace)
        XCTAssertNil(windows.inputModel.request)
    }

    private func findEditor(_ view: NSView) -> TranslationInputTextView? {
        if let editor = view as? TranslationInputTextView { return editor }
        return view.subviews.compactMap(findEditor).first
    }
}
