import AppKit
import SwiftUI

/// Native plain-text editing. The caller owns placeholder presentation and translation scheduling.
struct TranslationTextEditor: NSViewRepresentable {
    @Environment(\.locale) private var locale
    @Environment(\.translateXTheme) private var theme
    @Binding var text: String
    var onEdit: (String, Bool) -> Void
    var onSubmit: () -> Void
    var onReady: (NSTextView) -> Void = { _ in }
    var fontSize: CGFloat = 19
    var lineSpacing: CGFloat? = nil
    var accessibilityID = "translation.input"
    var accessibilityName = "Original text"
    var managesWorkspaceUndo = false
    var canUndoWorkspace: () -> Bool = { false }
    var canRedoWorkspace: () -> Bool = { false }
    var undoWorkspace: () -> Void = {}
    var redoWorkspace: () -> Void = {}
    var onCancel: () -> Bool = { false }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = TranslationEditorScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        TranslateXScrollStyle.apply(to: scrollView)
        let textView = TranslationInputTextView(frame: .zero)
        textView.configureReadingStyle(fontSize: fontSize, lineSpacing: lineSpacing)
        textView.setAccessibilityIdentifier(accessibilityID)
        textView.setAccessibilityLabel(L10n.string(accessibilityName))
        textView.textColor = editorColor
        textView.onWindowAttachment = { onReady($0) }
        context.coordinator.connect(textView)
        scrollView.documentView = textView
        context.coordinator.synchronize(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        TranslateXScrollStyle.apply(to: scrollView)
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? TranslationInputTextView else { return }
        _ = locale
        textView.setAccessibilityLabel(L10n.string(accessibilityName))
        if textView.textColor != editorColor { textView.textColor = editorColor }
        context.coordinator.synchronize(textView)
    }

    private var editorColor: NSColor {
        theme.isDark ? NSColor(calibratedWhite: 0.94, alpha: 1) : NSColor(red: 0.204, green: 0.255, blue: 0.333, alpha: 1)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? TranslationInputTextView else { return }
        textView.onEdit = nil
        textView.onSubmit = nil
        textView.onWindowAttachment = nil
        textView.canUndoWorkspace = nil
        textView.canRedoWorkspace = nil
        textView.undoWorkspace = nil
        textView.redoWorkspace = nil
        textView.onCancel = nil
    }

    @MainActor
    final class Coordinator {
        var parent: TranslationTextEditor

        init(_ parent: TranslationTextEditor) { self.parent = parent }

        func connect(_ textView: TranslationInputTextView) {
            textView.onEdit = { [weak self] text, hasMarkedText in
                guard let self else { return }
                // Read and write through the latest binding, rather than a captured initial value.
                self.parent.onEdit(text, hasMarkedText)
                if self.parent.text != text { self.parent.text = text }
            }
            textView.onSubmit = { [weak self] in self?.parent.onSubmit() }
            textView.canUndoWorkspace = { [weak self] in self?.parent.canUndoWorkspace() ?? false }
            textView.canRedoWorkspace = { [weak self] in self?.parent.canRedoWorkspace() ?? false }
            textView.undoWorkspace = { [weak self] in self?.parent.undoWorkspace() }
            textView.redoWorkspace = { [weak self] in self?.parent.redoWorkspace() }
            textView.onCancel = { [weak self] in self?.parent.onCancel() ?? false }
        }

        func synchronize(_ textView: TranslationInputTextView) {
            textView.applyExternalText(parent.text, recordsUndo: !parent.managesWorkspaceUndo)
        }
    }
}

@MainActor
private final class TranslationEditorScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let textView = documentView as? NSTextView else { return }
        let width = max(0, contentSize.width)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        if textView.frame.width != width {
            textView.setFrameSize(NSSize(width: width, height: max(textView.frame.height, contentSize.height)))
        }
    }
}

@MainActor
final class TranslationInputTextView: NSTextView {
    var onEdit: ((String, Bool) -> Void)?
    var onSubmit: (() -> Void)?
    var onWindowAttachment: ((TranslationInputTextView) -> Void)?
    var canUndoWorkspace: (() -> Bool)?
    var canRedoWorkspace: (() -> Bool)?
    var undoWorkspace: (() -> Void)?
    var redoWorkspace: (() -> Void)?
    var onCancel: (() -> Bool)?
    private let localUndoManager = UndoManager()
    private var ownedTextStorage: NSTextStorage?
    private var inputMutationDepth = 0
    private var applyingExternalText = false
    private var hasSynchronizedInitialText = false
    private var lastReportedText = ""
    private var lastReportedMarked = false
    private var readingFont = NSFont.systemFont(ofSize: 19)
    private var readingParagraph: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = max(0, 19 * 1.3 - NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 19)))
        return paragraph
    }()

    private var readingAttributes: [NSAttributedString.Key: Any] {
        [.font: readingFont, .paragraphStyle: readingParagraph,
         .foregroundColor: textColor ?? NSColor.textColor]
    }

    override var undoManager: UndoManager? { localUndoManager }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer? = nil) {
        let editingContainer: NSTextContainer
        let storage: NSTextStorage?
        if let container {
            editingContainer = container
            storage = nil
        } else {
            let newStorage = NSTextStorage()
            storage = newStorage
            let manager = NSLayoutManager()
            editingContainer = NSTextContainer(size: NSSize(width: frameRect.width, height: CGFloat.greatestFiniteMagnitude))
            newStorage.addLayoutManager(manager)
            manager.addTextContainer(editingContainer)
        }
        super.init(frame: frameRect, textContainer: editingContainer)
        ownedTextStorage = storage
        isRichText = false
        importsGraphics = false
        isEditable = true
        isSelectable = true
        allowsUndo = true
        usesFindPanel = true
        isContinuousSpellCheckingEnabled = true
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: frameRect.width, height: .greatestFiniteMagnitude)
        textContainer?.lineFragmentPadding = 0
        textContainerInset = NSSize(width: 0, height: 2)
        drawsBackground = false
        font = readingFont
        defaultParagraphStyle = readingParagraph
        textColor = .textColor
        insertionPointColor = .textColor
        typingAttributes = readingAttributes
        setAccessibilityIdentifier("translation.input")
        setAccessibilityLabel(L10n.string("Original text"))
    }

    /// Set once before synchronization. Theme/size changes never replace the
    /// native editor, its text storage, selection, composition or Undo history.
    func configureReadingStyle(fontSize: CGFloat, lineSpacing: CGFloat? = nil) {
        readingFont = .systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing ?? max(0, fontSize * 1.3 - NSLayoutManager().defaultLineHeight(for: readingFont))
        paragraph.paragraphSpacing = 0
        paragraph.paragraphSpacingBefore = 0
        readingParagraph = paragraph
        font = readingFont
        defaultParagraphStyle = paragraph
        typingAttributes = readingAttributes
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindowAttachment?(self) }
    }

    /// An explicit new passage supersedes the current conversion session. Ordinary
    /// SwiftUI refreshes still go through the marked-text guard below.
    func finishCompositionForReplacement() {
        guard hasMarkedText() else { return }
        unmarkText()
        inputContext?.discardMarkedText()
    }

    /// Composition takes precedence over external refreshes. Its final commit/cancel
    /// publishes the actual editor value again, so a stale render cannot destroy an IME session.
    func applyExternalText(_ text: String, recordsUndo: Bool = true) {
        guard !hasMarkedText() else { return }
        let isInitialText = !hasSynchronizedInitialText
        hasSynchronizedInitialText = true
        guard string != text else { return }
        let previousSelections = selectedRanges
        applyingExternalText = true
        defer { applyingExternalText = false }
        if isInitialText || !recordsUndo {
            // Pair operations are owned by the workspace. Clear obsolete range
            // operations only in the editor being replaced, not in the input side.
            localUndoManager.removeAllActions()
            textStorage?.setAttributedString(NSAttributedString(string: text, attributes: readingAttributes))
        } else {
            // A model-driven Clear/Swap is an ordinary text edit. Let NSTextView
            // record its replacement range so Undo restores it without corrupting
            // the ranges belonging to preceding or subsequent typing operations.
            breakUndoCoalescing()
            let range = NSRange(location: 0, length: (string as NSString).length)
            guard shouldChangeText(in: range, replacementString: text) else { return }
            textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: readingAttributes))
            didChangeText()
            breakUndoCoalescing()
        }
        let length = (text as NSString).length
        selectedRanges = previousSelections.map { value in
            let range = value.rangeValue
            let location = min(range.location, length)
            let count = min(range.length, length - location)
            return NSValue(range: Self.validSelection(NSRange(location: location, length: count), in: text))
        }
        lastReportedText = text
        lastReportedMarked = false
        typingAttributes = readingAttributes
    }

    override func didChangeText() {
        super.didChangeText()
        // NSTextStorage loses inherited attributes after its last character is
        // removed. The next typed or handed-off passage must retain reading size.
        if string.isEmpty { typingAttributes = readingAttributes }
        reportEditIfNeeded()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        withInputMutation {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        withInputMutation { super.insertText(insertString, replacementRange: replacementRange) }
    }

    override func unmarkText() {
        withInputMutation { super.unmarkText() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleSubmitKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleSubmitKey(event) { return }
        super.keyDown(with: event)
    }

    // NSTextView's default responder chain forwards these selectors to NSWindow.
    // Our editor has its own undo stack, so both actions and validation must resolve
    // here instead of using the unrelated window undo manager.
    @objc func undo(_ sender: Any?) {
        if !hasMarkedText(), canUndoWorkspace?() == true { undoWorkspace?(); return }
        guard !hasMarkedText(), localUndoManager.canUndo else { return }
        breakUndoCoalescing()
        localUndoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        if !hasMarkedText(), canRedoWorkspace?() == true { redoWorkspace?(); return }
        guard !hasMarkedText(), localUndoManager.canRedo else { return }
        breakUndoCoalescing()
        localUndoManager.redo()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let result = validateUndoAction(menuItem.action) { return result }
        return super.validateMenuItem(menuItem)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if let result = validateUndoAction(item.action) { return result }
        return super.validateUserInterfaceItem(item)
    }

    private func validateUndoAction(_ action: Selector?) -> Bool? {
        if action == #selector(undo(_:)) { return !hasMarkedText() && (canUndoWorkspace?() == true || localUndoManager.canUndo) }
        if action == #selector(redo(_:)) { return !hasMarkedText() && (canRedoWorkspace?() == true || localUndoManager.canRedo) }
        return nil
    }

    override func cancelOperation(_ sender: Any?) {
        if !hasMarkedText(), onCancel?() == true { return }
        super.cancelOperation(sender)
    }

    private func handleSubmitKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard event.type == .keyDown, modifiers == .command,
              event.keyCode == 36 || event.keyCode == 76 else { return false }
        // Consume the shortcut during composition as well, so a parent SwiftUI button
        // cannot translate the unfinished candidate via its own keyboard shortcut.
        if !hasMarkedText() { onSubmit?() }
        return true
    }

    private func withInputMutation(_ body: () -> Void) {
        inputMutationDepth += 1
        body()
        inputMutationDepth -= 1
        reportEditIfNeeded()
    }

    private func reportEditIfNeeded() {
        guard !applyingExternalText, inputMutationDepth == 0 else { return }
        let marked = hasMarkedText()
        guard string != lastReportedText || marked != lastReportedMarked else { return }
        lastReportedText = string
        lastReportedMarked = marked
        onEdit?(string, marked)
    }

    private static func validSelection(_ range: NSRange, in text: String) -> NSRange {
        let characters = text as NSString
        guard range.location < characters.length else { return range }
        if range.length == 0 {
            return NSRange(location: characters.rangeOfComposedCharacterSequence(at: range.location).location, length: 0)
        }
        return characters.rangeOfComposedCharacterSequences(for: range)
    }
}
