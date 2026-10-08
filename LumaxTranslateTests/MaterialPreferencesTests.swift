import AppKit
import Carbon
import Observation
import SwiftUI
import XCTest
@testable import LumaxTranslate

@MainActor
final class MaterialPreferencesTests: XCTestCase {
    func testFreshMaterialIsLightWithoutCreatingStoredPreferences() async throws {
        try await withDefaults { defaults, suite in
            let preferences = AppPreferences(defaults: defaults)
            XCTAssertEqual(preferences.material, .light)
            XCTAssertTrue(defaults.persistentDomain(forName: suite)?.isEmpty ?? true)
        }
    }

    func testEachMaterialSurvivesRestartWithoutChangingOtherPreferences() async throws {
        try await withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            preferences.appearance = .dark
            preferences.setDefaultTarget("ja")
            preferences.setShortcut(nil, for: .ocr)
            for material in [AppMaterial.glass, .light] {
                preferences.material = material
                let restored = AppPreferences(defaults: defaults)
                XCTAssertEqual(restored.material, material)
                XCTAssertEqual(restored.appearance, .dark)
                XCTAssertEqual(restored.defaultTarget, "ja")
                XCTAssertNil(restored.shortcut(for: .ocr))
                XCTAssertEqual(restored.shortcut(for: .input), ShortcutAction.input.defaultShortcut)
            }
        }
    }

    func testInvalidMaterialFallsBackIndependentlyAndPreservesUnrelatedData() async throws {
        try await withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            let customShortcut = GlobalShortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | cmdKey))
            preferences.appearance = .dark
            preferences.setDefaultTarget("fr")
            preferences.setShortcut(customShortcut, for: .selection)
            preferences.setShortcut(nil, for: .ocr)
            defaults.set("keep", forKey: "unrelated.preference")

            let invalidValues: [Any] = ["future-material", "", 42, true, ["bad": "type"]]
            for invalid in invalidValues {
                defaults.set(invalid, forKey: AppPreferences.StorageKey.material)
                let restored = AppPreferences(defaults: defaults)
                XCTAssertEqual(restored.material, .light)
                XCTAssertEqual(restored.appearance, .dark)
                XCTAssertEqual(restored.defaultTarget, "fr")
                XCTAssertEqual(restored.shortcut(for: .selection), customShortcut)
                XCTAssertEqual(restored.shortcut(for: .input), ShortcutAction.input.defaultShortcut)
                XCTAssertNil(restored.shortcut(for: .ocr))
                XCTAssertEqual(defaults.string(forKey: "unrelated.preference"), "keep")
                restored.material = .glass
                XCTAssertEqual(AppPreferences(defaults: defaults).material, .glass,
                               "A recovered preference must still be writable")
            }
        }
    }

    func testMaterialRoundTripPreservesNativeEditorFocusSelectionAndUndo() async throws {
        try await withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            let state = EditorState(text: "A quiet desk")
            let capture = EditorCapture()
            let surface = makeSurface(preferences: preferences, state: state, capture: capture)
            let panel = makePanel(surface: surface)
            defer { panel.close() }
            let editor = try await mountedEditor(in: surface)
            XCTAssertTrue(panel.makeFirstResponder(editor))
            let host = surface.hostingView
            let hostParent = try XCTUnwrap(host.superview)
            let materialView = try materialOwner(in: surface)
            let attachments = capture.attachmentCount
            XCTAssertGreaterThan(attachments, 0)
            try assertMaterialPresentation(surface, glass: false)
            let undo = try XCTUnwrap(editor.undoManager)
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            editor.insertText(" helps focus", replacementRange: unspecifiedRange)
            undo.endUndoGrouping()
            let editedText = "A quiet desk helps focus"
            let selectedRange = NSRange(location: 2, length: 5)
            editor.setSelectedRange(selectedRange)
            XCTAssertEqual(state.text, editedText)
            XCTAssertTrue(undo.canUndo)

            for material in [AppMaterial.glass, .light] {
                preferences.material = material
                try await waitForMaterial(material, in: surface)
                XCTAssertTrue(surface.hostingView === host)
                XCTAssertTrue(host.superview === hostParent)
                XCTAssertTrue(try materialOwner(in: surface) === materialView, "Material changes keep the native content owner alive")
                XCTAssertTrue(try XCTUnwrap(findEditor(in: host)) === editor)
                XCTAssertTrue(panel.firstResponder === editor)
                XCTAssertEqual(capture.attachmentCount, attachments, "Changing the background must never detach the editor")
                XCTAssertEqual(editor.string, editedText)
                XCTAssertEqual(state.text, editedText)
                XCTAssertEqual(editor.selectedRange(), selectedRange)
                XCTAssertTrue(editor.undoManager === undo)
                XCTAssertTrue(undo.canUndo)
            }

            undo.undo()
            XCTAssertEqual(editor.string, "A quiet desk")
            XCTAssertEqual(state.text, "A quiet desk")
            XCTAssertTrue(undo.canRedo)
            undo.redo()
            XCTAssertEqual(editor.string, editedText)
            XCTAssertEqual(state.text, editedText)
        }
    }

    func testMaterialRoundTripKeepsMarkedTextUntilTheInputClientCommitsIt() async throws {
        try await withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            let state = EditorState(text: "Hello ")
            let capture = EditorCapture()
            let surface = makeSurface(preferences: preferences, state: state, capture: capture)
            let panel = makePanel(surface: surface)
            defer { panel.close() }
            let editor = try await mountedEditor(in: surface)
            XCTAssertTrue(panel.makeFirstResponder(editor))
            editor.setSelectedRange(NSRange(location: 6, length: 0))
            editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecifiedRange)
            let selectedRange = editor.selectedRange()
            let markedRange = editor.markedRange()
            let attachments = capture.attachmentCount
            let contentContainer = surface.contentContainer
            let materialView = try materialOwner(in: surface)
            XCTAssertTrue(editor.hasMarkedText())
            XCTAssertTrue(state.isComposing)

            for material in [AppMaterial.glass, .light] {
                preferences.material = material
                try await waitForMaterial(material, in: surface)
                XCTAssertTrue(try XCTUnwrap(findEditor(in: surface.hostingView)) === editor)
                XCTAssertTrue(surface.hostingView.superview === contentContainer)
                XCTAssertTrue(try materialOwner(in: surface) === materialView)
                XCTAssertTrue(panel.firstResponder === editor)
                XCTAssertEqual(capture.attachmentCount, attachments)
                XCTAssertTrue(editor.hasMarkedText())
                XCTAssertEqual(editor.markedRange(), markedRange)
                XCTAssertEqual(editor.selectedRange(), selectedRange)
                XCTAssertEqual(editor.string, "Hello ni")
                XCTAssertTrue(state.isComposing)
            }

            editor.insertText("你", replacementRange: unspecifiedRange)
            XCTAssertFalse(editor.hasMarkedText())
            XCTAssertFalse(state.isComposing)
            XCTAssertEqual(editor.string, "Hello 你")
            XCTAssertEqual(state.text, "Hello 你")
        }
    }

    func testReduceTransparencyUsesOpaqueFallbackWithoutRemountingEditor() async throws {
        try await withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            preferences.material = .glass
            let state = EditorState(text: "The same passage stays in place.")
            let capture = EditorCapture()
            let accessibility = AccessibilityState()
            let surface = makeSurface(preferences: preferences, state: state, capture: capture,
                                      reduceTransparency: { accessibility.reduceTransparency })
            let panel = makePanel(surface: surface)
            defer { panel.close() }
            let editor = try await mountedEditor(in: surface)
            XCTAssertTrue(panel.makeFirstResponder(editor))
            let host = surface.hostingView
            let parent = try XCTUnwrap(host.superview)
            let materialView = try materialOwner(in: surface)
            let attachments = capture.attachmentCount
            let selection = NSRange(location: 4, length: 4)
            editor.setSelectedRange(selection)
            try assertMaterialPresentation(surface, glass: true)

            accessibility.reduceTransparency = true
            surface.refreshMaterial()
            try await settleLayout(surface)
            try assertMaterialPresentation(surface, glass: false)
            XCTAssertEqual(preferences.material, .glass, "Accessibility does not overwrite the user's saved material")
            XCTAssertTrue(surface.hostingView === host)
            XCTAssertTrue(host.superview === parent)
            XCTAssertTrue(try materialOwner(in: surface) === materialView)
            XCTAssertTrue(try XCTUnwrap(findEditor(in: host)) === editor)
            XCTAssertTrue(panel.firstResponder === editor)
            XCTAssertEqual(capture.attachmentCount, attachments)
            XCTAssertEqual(editor.string, state.text)
            XCTAssertEqual(editor.selectedRange(), selection)

            accessibility.reduceTransparency = false
            surface.refreshMaterial()
            try await settleLayout(surface)
            try assertMaterialPresentation(surface, glass: true)
            XCTAssertTrue(try materialOwner(in: surface) === materialView)
            XCTAssertTrue(try XCTUnwrap(findEditor(in: host)) === editor)
            XCTAssertEqual(capture.attachmentCount, attachments)
            XCTAssertEqual(editor.selectedRange(), selection)
        }
    }

    func testSingleBackdropAndStableContentCoverWindowAcrossResize() async throws {
        try await withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            preferences.material = .glass
            let state = EditorState(text: "Native content stays inside its material.")
            let capture = EditorCapture()
            let surface = makeSurface(preferences: preferences, state: state, capture: capture)
            let panel = makePanel(surface: surface)
            defer { panel.close() }
            let editor = try await mountedEditor(in: surface)
            XCTAssertTrue(panel.makeFirstResponder(editor))
            let materialView = try materialOwner(in: surface)
            let contentContainer = surface.contentContainer
            let host = surface.hostingView
            let attachments = capture.attachmentCount

            for size in [NSSize(width: 620, height: 410), NSSize(width: 360, height: 300)] {
                panel.setContentSize(size)
                try await settleLayout(surface)
                try assertMaterialPresentation(surface, glass: true)
                XCTAssertTrue(try materialOwner(in: surface) === materialView)
                XCTAssertTrue(surface.contentContainer === contentContainer)
                XCTAssertTrue(surface.hostingView === host)
                XCTAssertEqual(materialView.frame.size, surface.bounds.size)
                XCTAssertEqual(contentContainer.bounds.size, surface.bounds.size)
                XCTAssertEqual(host.frame, contentContainer.bounds,
                               "The editor's host must follow its content container after resizing")
                XCTAssertTrue(try XCTUnwrap(findEditor(in: host)) === editor)
                XCTAssertTrue(panel.firstResponder === editor)
                XCTAssertEqual(capture.attachmentCount, attachments)
                XCTAssertEqual(editor.string, state.text)
            }
        }
    }

    func testTwoWindowsKeepNativeGlassAndEditorWhenKeyWindowChanges() async throws {
        let inputMonitor = try isolateUnscriptedWindowInput()
        defer { NSEvent.removeMonitor(inputMonitor) }
        try await withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            preferences.material = .glass
            let firstCapture = EditorCapture()
            let secondCapture = EditorCapture()
            let first = makeSurface(preferences: preferences, state: EditorState(text: "Translation window"), capture: firstCapture)
            let second = makeSurface(preferences: preferences, state: EditorState(text: "Settings window"), capture: secondCapture)
            let firstPanel = makePanel(surface: first)
            let secondPanel = makePanel(surface: second)
            defer { firstPanel.close(); secondPanel.close() }
            // Window-server focus needs real on-screen windows. The other
            // editor tests can use off-screen panels because they test the
            // first responder, not a compositor key-window transition.
            let screen = try XCTUnwrap(NSScreen.main)
            firstPanel.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 30, y: screen.visibleFrame.minY + 30))
            secondPanel.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 470, y: screen.visibleFrame.minY + 30))
            let editor = try await mountedEditor(in: first)
            _ = try await mountedEditor(in: second)
            firstPanel.makeKeyAndOrderFront(nil)
            XCTAssertTrue(firstPanel.makeFirstResponder(editor))
            try await settleLayout(first)
            let attachments = firstCapture.attachmentCount
            let selection = NSRange(location: 0, length: 11)
            editor.setSelectedRange(selection)
            let firstBackdrop = try materialOwner(in: first)
            let secondBackdrop = try materialOwner(in: second)

            for panel in [secondPanel, firstPanel, secondPanel, firstPanel] {
                panel.makeKeyAndOrderFront(nil)
                try await settleLayout(first)
                // Window-server key transitions can arrive after SwiftUI layout.
                // Wait for the real state, without faking key-window properties.
                for _ in 0..<50 {
                    if panel.isKeyWindow { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let state = "active=\(NSApp.isActive), policy=\(NSApp.activationPolicy().rawValue), key=\(String(describing: NSApp.keyWindow?.windowNumber)), expected=\(panel.windowNumber), visible=\(panel.isVisible), canKey=\(panel.canBecomeKey)"
                XCTAssertTrue(panel.isKeyWindow, "The test must actually change native key-window state: \(state)")
                XCTAssertFalse((panel === firstPanel ? secondPanel : firstPanel).isKeyWindow)
                for surface in [first, second] { try assertMaterialPresentation(surface, glass: true) }
                XCTAssertTrue(try materialOwner(in: first) === firstBackdrop)
                XCTAssertTrue(try materialOwner(in: second) === secondBackdrop)
                XCTAssertTrue(try XCTUnwrap(findEditor(in: first.hostingView)) === editor)
                XCTAssertEqual(editor.selectedRange(), selection)
                XCTAssertEqual(firstCapture.attachmentCount, attachments)
            }
        }
    }

    func testInitiallyReducedTransparencyKeepsOpaqueBackingUntilPreferenceChanges() async throws {
        try await withDefaults { defaults, _ in
            let preferences = AppPreferences(defaults: defaults)
            preferences.material = .glass
            let state = EditorState(text: "The first window must respect reduced transparency.")
            let capture = EditorCapture()
            let accessibility = AccessibilityState()
            accessibility.reduceTransparency = true
            let surface = makeSurface(preferences: preferences, state: state, capture: capture,
                                      reduceTransparency: { accessibility.reduceTransparency })
            let panel = makePanel(surface: surface)
            defer { panel.close() }
            let editor = try await mountedEditor(in: surface)
            XCTAssertTrue(panel.makeFirstResponder(editor))
            let materialView = try materialOwner(in: surface)
            let parent = surface.contentContainer
            let attachments = capture.attachmentCount
            let selection = NSRange(location: 4, length: 5)
            editor.setSelectedRange(selection)
            try assertMaterialPresentation(surface, glass: false)

            for reduced in [false, true] {
                accessibility.reduceTransparency = reduced
                surface.refreshMaterial()
                try await settleLayout(surface)
                try assertMaterialPresentation(surface, glass: !reduced)
                XCTAssertEqual(preferences.material, .glass)
                XCTAssertTrue(try materialOwner(in: surface) === materialView)
                XCTAssertTrue(surface.hostingView.superview === parent)
                XCTAssertTrue(try XCTUnwrap(findEditor(in: surface.hostingView)) === editor)
                XCTAssertTrue(panel.firstResponder === editor)
                XCTAssertEqual(capture.attachmentCount, attachments)
                XCTAssertEqual(editor.selectedRange(), selection)
                XCTAssertEqual(editor.string, state.text)
            }
        }
    }

    private func withDefaults(_ body: @MainActor (UserDefaults, String) async throws -> Void) async throws {
        let suite = "LumaxTranslateTests.MaterialPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(defaults, suite)
    }

    private func makeSurface(
        preferences: AppPreferences, state: EditorState, capture: EditorCapture,
        reduceTransparency: @escaping @MainActor () -> Bool = { false }
    ) -> WindowSurface<TranslationTextEditor> {
        let editor = TranslationTextEditor(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            onEdit: { _, marked in state.isComposing = marked },
            onSubmit: {},
            onReady: { _ in capture.attachmentCount += 1 }
        )
        return WindowSurface(preferences: preferences, content: editor, reduceTransparency: reduceTransparency)
    }

    private func makePanel(surface: WindowSurface<TranslationTextEditor>) -> NSPanel {
        _ = NSApplication.shared
        let panel = NSPanel(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 420, height: 260),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.contentView = surface
        surface.frame = NSRect(origin: .zero, size: panel.contentLayoutRect.size)
        panel.orderFront(nil)
        surface.layoutSubtreeIfNeeded()
        return panel
    }

    private func mountedEditor(in surface: WindowSurface<TranslationTextEditor>) async throws -> TranslationInputTextView {
        for _ in 0..<50 {
            surface.layoutSubtreeIfNeeded()
            if let editor = findEditor(in: surface.hostingView), editor.window != nil {
                return editor
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(findEditor(in: surface.hostingView), "The real SwiftUI editor did not mount")
    }

    private func findEditor(in view: NSView) -> TranslationInputTextView? {
        if let editor = view as? TranslationInputTextView { return editor }
        for child in view.subviews {
            if let editor = findEditor(in: child) { return editor }
        }
        return nil
    }

    private func waitForMaterial(_ material: AppMaterial, in surface: WindowSurface<TranslationTextEditor>) async throws {
        let expectsGlass = material == .glass
        let expectedAlpha: CGFloat = expectsGlass ? 0 : 1
        for _ in 0..<50 {
            if surface.isGlassActive == expectsGlass,
               surface.contentContainer.layer?.backgroundColor?.alpha == expectedAlpha {
                try await settleLayout(surface)
                try assertMaterialPresentation(surface, glass: expectsGlass)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The observed material preference never reached the window surface")
    }

    private func settleLayout(_ surface: WindowSurface<TranslationTextEditor>) async throws {
        // WindowSurface's Observation callback and SwiftUI schedule their updates
        // independently. Let both run before checking identity and editing state.
        try await Task.sleep(for: .milliseconds(30))
        surface.layoutSubtreeIfNeeded()
    }

    /// These are native composition and fallback contracts, not a measurement of
    /// the optical effect or the pixels composited against another window.
    private func assertMaterialPresentation(
        _ surface: WindowSurface<TranslationTextEditor>, glass: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let container = surface.contentContainer
        XCTAssertEqual(surface.isGlassActive, glass, file: file, line: line)
        XCTAssertEqual(container.isGlass, glass, file: file, line: line)
        XCTAssertTrue(surface.hostingView.superview === container, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(container.layer?.backgroundColor, file: file, line: line).alpha,
                       glass ? 0 : 1, file: file, line: line)
        XCTAssertEqual(container.layer?.opacity, 1, "An opaque fallback cannot itself be translucent", file: file, line: line)
        XCTAssertFalse(container.isHidden, file: file, line: line)
        XCTAssertFalse(surface.hostingView.isHidden, file: file, line: line)
        let effects = surface.subviews.compactMap { $0 as? NSVisualEffectView }
        if #available(macOS 26, *) {
            let glasses = surface.subviews.compactMap { $0 as? NSGlassEffectView }
            XCTAssertEqual(glasses.count, 1, file: file, line: line)
            XCTAssertTrue(effects.isEmpty, "Do not replace or stack native glass with legacy blur", file: file, line: line)
            let effect = try XCTUnwrap(glasses.first, file: file, line: line)
            XCTAssertEqual(effect.style, .clear, file: file, line: line)
            XCTAssertTrue(effect.contentView === container, "The native glass must own the real content", file: file, line: line)
            XCTAssertFalse(effect.isHidden, "Opaque modes cover glass without hiding its editor", file: file, line: line)
        } else {
            XCTAssertTrue(container.superview === surface, file: file, line: line)
            XCTAssertEqual(effects.count, 1, "Use one backdrop, never stacked blur materials", file: file, line: line)
            let effect = try XCTUnwrap(effects.first, file: file, line: line)
            XCTAssertEqual(effect.state, .active, file: file, line: line)
            XCTAssertEqual(effect.blendingMode, .behindWindow, file: file, line: line)
            XCTAssertEqual(effect.material, .underWindowBackground, file: file, line: line)
            XCTAssertEqual(effect.isHidden, !glass, file: file, line: line)
        }
    }

    private func materialOwner(in surface: WindowSurface<TranslationTextEditor>) throws -> NSView {
        if #available(macOS 26, *) {
            return try XCTUnwrap(surface.subviews.first { $0 is NSGlassEffectView })
        }
        return try XCTUnwrap(surface.subviews.first { $0 is NSVisualEffectView })
    }

    private var unspecifiedRange: NSRange { NSRange(location: NSNotFound, length: 0) }

    @MainActor @Observable
    fileprivate final class EditorState {
        var text: String
        var isComposing = false
        init(text: String) { self.text = text }
    }

    @MainActor
    private final class EditorCapture {
        var attachmentCount = 0
    }

    @MainActor
    private final class AccessibilityState {
        var reduceTransparency = false
    }
}
