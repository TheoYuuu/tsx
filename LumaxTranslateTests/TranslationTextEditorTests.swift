import AppKit
import SwiftUI
import XCTest
@testable import LumaxTranslate

@MainActor
final class TranslationTextEditorTests: XCTestCase {
    func testRenderedLineIntervalsMatchForWrappingNewlinesAndMixedWritingSystems() throws {
        for size: CGFloat in [19, 16] {
            let view = makeTextView()
            view.configureReadingStyle(fontSize: size)
            let sample = "Good design makes complex things feel effortless.\n好的设计，让复杂的事情变得轻松。\n\n日常の翻訳を読みやすく\n😀🚀\nlet value = 1"
            view.applyExternalText(sample)
            let manager = try XCTUnwrap(view.layoutManager)
            let container = try XCTUnwrap(view.textContainer)
            container.containerSize = NSSize(width: 220, height: 2_000)
            manager.ensureLayout(for: container)
            var rows: [CGRect] = []
            manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { rect, _, _, _, _ in rows.append(rect) }
            XCTAssertGreaterThan(rows.count, sample.components(separatedBy: "\n").count, "Includes automatic wrapping as well as hard and empty lines")
            for (next, previous) in zip(rows.dropFirst(), rows) {
                XCTAssertEqual(next.minY - previous.minY, size * 1.3, accuracy: 0.5)
            }
            XCTAssertEqual(view.string, sample, "Reading style must never remove the user's blank lines")
        }
    }

    func testTranslatedParagraphsKeepCompactLineHeightAfterRepeatedSwapsAndEditing() throws {
        for size: CGFloat in [19, 16] {
            let source = makeTextView(), target = makeTextView()
            source.configureReadingStyle(fontSize: size)
            target.configureReadingStyle(fontSize: size)
            let passages = [
                "Good design makes complex things feel effortless.\n123\n\nContinue reading.",
                "好的设计，让复杂的事情变得轻松。\n123\n\n继续阅读。"
            ]
            for index in 0..<4 {
                source.applyExternalText(passages[index % 2], recordsUndo: false)
                target.applyExternalText(passages[(index + 1) % 2], recordsUndo: false)
                for view in [source, target] {
                    view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
                    view.insertText("\n下一行 next line", replacementRange: unspecifiedRange)
                    let storage = try XCTUnwrap(view.textStorage)
                    storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                        let style = value as? NSParagraphStyle
                        XCTAssertEqual(style?.paragraphSpacing, 0)
                        XCTAssertEqual(style?.paragraphSpacingBefore, 0)
                    }
                    let manager = try XCTUnwrap(view.layoutManager)
                    let container = try XCTUnwrap(view.textContainer)
                    container.containerSize = NSSize(width: 220, height: 2_000)
                    manager.ensureLayout(for: container)
                    var rows: [CGRect] = []
                    manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { rect, _, _, _, _ in rows.append(rect) }
                    for (next, previous) in zip(rows.dropFirst(), rows) {
                        XCTAssertEqual(next.minY - previous.minY, size * 1.3, accuracy: 0.5, "Swap and typing must not accumulate paragraph spacing")
                    }
                    XCTAssertTrue(view.string.contains("\n123\n\n"), "Explicit blank lines remain intact")
                }
            }
        }
    }

    func testClearingAndReplacingAPassagePreservesReadingTypographyAndUndo() async throws {
        let view = makeTextView()
        view.applyExternalText("First passage")
        view.applyExternalText("")
        view.applyExternalText("Replacement passage")
        let storage = try XCTUnwrap(view.textStorage)
        XCTAssertEqual((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 19)
        XCTAssertEqual((storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing, max(0, 24.7 - NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 19))))
        view.applyExternalText("")
        view.insertText("Typed again", replacementRange: unspecifiedRange)
        XCTAssertEqual((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 19)
        XCTAssertEqual((storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing, max(0, 24.7 - NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 19))))
        XCTAssertTrue(try XCTUnwrap(view.undoManager).canUndo)
    }

    func testExternalRefreshDoesNotReplaceMarkedTextAndCommitPublishesFinalValue() async {
        let textView = makeTextView()
        textView.applyExternalText("Hello ")
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        var edits: [Edit] = []
        textView.onEdit = { edits.append(Edit(text: $0, marked: $1)) }

        textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecifiedRange)
        let selection = textView.selectedRange()
        textView.applyExternalText("Hello ")
        textView.applyExternalText("Unrelated external refresh")

        XCTAssertEqual(textView.string, "Hello ni")
        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertEqual(edits, [Edit(text: "Hello ni", marked: true)])

        textView.insertText("你", replacementRange: unspecifiedRange)
        XCTAssertEqual(textView.string, "Hello 你")
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(edits.last, Edit(text: "Hello 你", marked: false))
    }

    func testCompositionEndingWithoutTextChangeStillReportsCommittedState() async {
        let textView = makeTextView()
        var edits: [Edit] = []
        textView.onEdit = { edits.append(Edit(text: $0, marked: $1)) }
        textView.setMarkedText("你好", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecifiedRange)
        textView.unmarkText()

        XCTAssertEqual(edits, [Edit(text: "你好", marked: true), Edit(text: "你好", marked: false)])
    }

    func testCancellingCompositionRestoresTextAndPublishesUnmarkedState() async {
        let textView = makeTextView()
        textView.applyExternalText("Existing")
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        var edits: [Edit] = []
        textView.onEdit = { edits.append(Edit(text: $0, marked: $1)) }
        textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecifiedRange)
        // An input client discards its candidate by replacing the marked range with empty text.
        textView.insertText("", replacementRange: unspecifiedRange)

        XCTAssertEqual(textView.string, "Existing")
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(edits.last, Edit(text: "Existing", marked: false))
    }

    func testBindingEchoPreservesCaretAndDoesNotPublishAnotherEdit() async {
        let textView = makeTextView()
        textView.applyExternalText("Some text")
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        var editCount = 0
        textView.onEdit = { _, _ in editCount += 1 }
        textView.applyExternalText("Some text")

        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertEqual(editCount, 0)
    }

    func testExplicitNewPassageEndsCompositionBeforeReplacingModelAndEditor() async {
        let model = TranslationModel()
        let binding = Binding(get: { model.text }, set: { model.text = $0 })
        let editor = TranslationTextEditor(text: binding, onEdit: {
            model.editingChanged($0, isComposing: $1)
        }, onSubmit: { model.submit() })
        let coordinator = editor.makeCoordinator()
        let textView = makeTextView()
        coordinator.connect(textView)
        coordinator.synchronize(textView)
        textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecifiedRange)
        XCTAssertTrue(model.isComposing)

        textView.finishCompositionForReplacement()
        model.text = "A newly selected passage."
        model.submit()
        coordinator.synchronize(textView)

        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertFalse(model.isComposing)
        XCTAssertEqual(textView.string, "A newly selected passage.")
        XCTAssertEqual(model.request?.text, textView.string)
    }

    func testExternalReplacementClampsCaretAtComposedCharacterBoundary() async {
        let textView = makeTextView()
        textView.applyExternalText("abc")
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.applyExternalText("😀")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
        textView.applyExternalText("")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testCommandReturnSubmitsOnlyAfterCompositionEnds() async throws {
        let textView = makeTextView()
        var submits = 0
        textView.onSubmit = { submits += 1 }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))
        textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecifiedRange)

        XCTAssertTrue(textView.performKeyEquivalent(with: event))
        XCTAssertEqual(submits, 0)
        XCTAssertTrue(textView.hasMarkedText())
        textView.insertText("你", replacementRange: unspecifiedRange)
        XCTAssertTrue(textView.performKeyEquivalent(with: event))
        XCTAssertEqual(submits, 1)
        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "你\n")
        XCTAssertEqual(submits, 1)
    }

    func testNativeUndoAndRedoPublishEditedText() async throws {
        let textView = makeTextView()
        var edits: [Edit] = []
        textView.onEdit = { edits.append(Edit(text: $0, marked: $1)) }
        let undo = try XCTUnwrap(textView.undoManager)
        undo.beginUndoGrouping()
        textView.insertText("Hello", replacementRange: unspecifiedRange)
        undo.endUndoGrouping()
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(textView.string, "")
        XCTAssertEqual(edits.last, Edit(text: "", marked: false))
        undo.redo()
        XCTAssertEqual(textView.string, "Hello")
        XCTAssertEqual(edits.last, Edit(text: "Hello", marked: false))
    }

    func testExternalClearCanBeUndoneAndRedoneWithoutPublishingDuringSynchronization() async throws {
        let textView = makeTextView()
        textView.applyExternalText("An existing sentence")
        let undo = try XCTUnwrap(textView.undoManager)
        XCTAssertFalse(undo.canUndo, "Initial model content is not a user edit")
        var edits: [Edit] = []
        textView.onEdit = { edits.append(Edit(text: $0, marked: $1)) }

        undo.beginUndoGrouping()
        textView.applyExternalText("")
        undo.endUndoGrouping()
        XCTAssertEqual(textView.string, "")
        XCTAssertTrue(edits.isEmpty)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(textView.string, "An existing sentence")
        XCTAssertEqual(edits.last, Edit(text: "An existing sentence", marked: false))
        undo.redo()
        XCTAssertEqual(textView.string, "")
        XCTAssertEqual(edits.last, Edit(text: "", marked: false))
    }

    func testFullReplacementKeepsTypingHistoryRangesValidAndSeparatesEdits() async throws {
        let textView = makeTextView()
        textView.applyExternalText("Original")
        let undo = try XCTUnwrap(textView.undoManager)
        // Separate event groups model three independent user actions: typing,
        // a model-driven replacement, and typing into the replacement.
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        textView.insertText(" first", replacementRange: unspecifiedRange)
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        textView.applyExternalText("新")
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.insertText("文本", replacementRange: unspecifiedRange)
        undo.endUndoGrouping()

        XCTAssertEqual(textView.string, "新文本")
        undo.undo()
        XCTAssertEqual(textView.string, "新")
        undo.undo()
        XCTAssertEqual(textView.string, "Original first")
        undo.undo()
        XCTAssertEqual(textView.string, "Original")
        undo.redo()
        XCTAssertEqual(textView.string, "Original first")
        undo.redo()
        XCTAssertEqual(textView.string, "新")
        undo.redo()
        XCTAssertEqual(textView.string, "新文本")
    }

    func testCoordinatorReportsInputBeforeBindingFallbackAndUsesLatestCallbacks() async {
        var value = ""
        var reported: [String] = []
        let binding = Binding(get: { value }, set: { value = $0 })
        let first = TranslationTextEditor(text: binding, onEdit: { _, _ in reported.append("old") }, onSubmit: {})
        let coordinator = first.makeCoordinator()
        let textView = makeTextView()
        coordinator.connect(textView)
        coordinator.parent = TranslationTextEditor(text: binding, onEdit: { text, marked in
            XCTAssertEqual(value, "")
            XCTAssertEqual(text, "Hello")
            reported.append(marked ? "candidate" : "committed")
        }, onSubmit: {})

        textView.insertText("Hello", replacementRange: unspecifiedRange)
        XCTAssertEqual(value, "Hello")
        XCTAssertEqual(reported, ["committed"])
        coordinator.synchronize(textView)
        XCTAssertEqual(reported, ["committed"])
    }

    func testMenuUndoAndRedoUseEditorsHistoryThroughApplicationResponderChain() async throws {
        let textView = makeTextView()
        let panel = NSPanel(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 240),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.contentView = textView
        panel.makeFirstResponder(textView)
        panel.makeKeyAndOrderFront(nil)
        defer { panel.close() }
        XCTAssertTrue(NSApp.keyWindow === panel)
        XCTAssertTrue(panel.firstResponder === textView)

        let menu = NSMenu()
        let undoItem = menu.addItem(withTitle: "Undo", action: #selector(TranslationInputTextView.undo(_:)), keyEquivalent: "z")
        let redoItem = menu.addItem(withTitle: "Redo", action: #selector(TranslationInputTextView.redo(_:)), keyEquivalent: "Z")
        textView.applyExternalText("Existing")
        let undo = try XCTUnwrap(textView.undoManager)
        undo.groupsByEvent = false
        menu.update()
        XCTAssertFalse(undoItem.isEnabled)
        XCTAssertFalse(redoItem.isEnabled)

        undo.beginUndoGrouping()
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        textView.insertText(" typed", replacementRange: unspecifiedRange)
        undo.endUndoGrouping()
        menu.update()
        XCTAssertTrue(undoItem.isEnabled, "Typing must enable the ordinary Edit menu item")
        XCTAssertTrue(NSApp.target(forAction: undoItem.action!) as AnyObject? === textView)
        XCTAssertTrue(NSApp.sendAction(undoItem.action!, to: nil, from: undoItem))
        XCTAssertEqual(textView.string, "Existing")
        menu.update()
        XCTAssertTrue(redoItem.isEnabled)
        XCTAssertTrue(NSApp.sendAction(redoItem.action!, to: nil, from: redoItem))
        XCTAssertEqual(textView.string, "Existing typed")

        undo.beginUndoGrouping()
        textView.applyExternalText("")
        undo.endUndoGrouping()
        menu.update()
        XCTAssertTrue(undoItem.isEnabled, "Clear must enable the ordinary Edit menu item")
        XCTAssertTrue(NSApp.sendAction(undoItem.action!, to: nil, from: undoItem))
        XCTAssertEqual(textView.string, "Existing typed")
        menu.update()
        XCTAssertTrue(redoItem.isEnabled)
        XCTAssertTrue(NSApp.sendAction(redoItem.action!, to: nil, from: redoItem))
        XCTAssertEqual(textView.string, "")
    }

    private func makeTextView() -> TranslationInputTextView {
        _ = NSApplication.shared
        return TranslationInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
    }

    private var unspecifiedRange: NSRange { NSRange(location: NSNotFound, length: 0) }

    private struct Edit: Equatable {
        let text: String
        let marked: Bool
    }
}
