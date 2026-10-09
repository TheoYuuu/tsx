import AppKit
import SwiftUI
import XCTest
@testable import TranslateX

/// Uses the shipping workspace without AppleTranslationHost, so changing the
/// interface language cannot contact a service or request a language download.
@MainActor
final class LanguageSwitchingWindowTests: XCTestCase {
    func testBothNativeEditorsKeepIdentitySelectionAndUndoAcrossLanguageChanges() async throws {
        try await withPreferences { preferences in
            for theme in ["light", "dark", "glass"] {
                preferences.appearance = theme == "dark" ? .dark : .light
                preferences.material = theme == "glass" ? .glass : .light
                let model = TranslationModel()
                model.source = "en"
                model.text = "A quiet desk"
                model.editingChanged("安静的书桌", isComposing: false, side: .target)
                let fixture = WorkspaceFixture(preferences: preferences, model: model)
                defer { fixture.panel.close() }
                let source = try await fixture.editor("translation.input")
                let target = try await fixture.editor("translation.output")
                let host = fixture.surface.hostingView
                let parent = try XCTUnwrap(host.superview)
                let sourceUndo = try XCTUnwrap(source.undoManager)
                let targetUndo = try XCTUnwrap(target.undoManager)
                sourceUndo.groupsByEvent = false
                targetUndo.groupsByEvent = false
                for (editor, suffix) in [(source, " helps focus"), (target, "让人专注")] {
                    XCTAssertTrue(fixture.panel.makeFirstResponder(editor))
                    editor.undoManager?.beginUndoGrouping()
                    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                    editor.insertText(suffix, replacementRange: unspecifiedRange)
                    editor.undoManager?.endUndoGrouping()
                }
                let sourceSelection = NSRange(location: 2, length: 5)
                let targetSelection = NSRange(location: 0, length: 2)
                source.setSelectedRange(sourceSelection)
                target.setSelectedRange(targetSelection)
                let sourceText = source.string
                let targetText = target.string
                let attachments = fixture.attachments

                for language in [AppInterfaceLanguage.english, .simplifiedChinese, .system, .english] {
                    await change(language, preferences: preferences, fixture: fixture)
                    let currentSource = try await fixture.editor("translation.input")
                    let currentTarget = try await fixture.editor("translation.output")
                    XCTAssertTrue(currentSource === source)
                    XCTAssertTrue(currentTarget === target)
                    XCTAssertTrue(fixture.surface.hostingView === host)
                    XCTAssertTrue(host.superview === parent)
                    XCTAssertEqual(fixture.attachments, attachments, "Language changes must not remount either native editor")
                    XCTAssertTrue(fixture.panel.firstResponder === target)
                    XCTAssertEqual(source.string, sourceText)
                    XCTAssertEqual(target.string, targetText)
                    XCTAssertEqual(model.text, sourceText)
                    XCTAssertEqual(model.translatedText, targetText)
                    XCTAssertEqual(source.selectedRange(), sourceSelection)
                    XCTAssertEqual(target.selectedRange(), targetSelection)
                    XCTAssertTrue(source.undoManager === sourceUndo)
                    XCTAssertTrue(target.undoManager === targetUndo)
                    XCTAssertEqual(source.accessibilityLabel(), L10n.string("Original text"))
                    XCTAssertEqual(target.accessibilityLabel(), L10n.string("Translation, editable"))
                    XCTAssertNil(model.request)
                }
                sourceUndo.undo()
                targetUndo.undo()
                XCTAssertEqual(source.string, "A quiet desk")
                XCTAssertEqual(target.string, "安静的书桌")
                sourceUndo.redo()
                targetUndo.redo()
                XCTAssertEqual(source.string, sourceText)
                XCTAssertEqual(target.string, targetText)
            }
        }
    }

    func testCompositionOnEitherSideSurvivesLanguageRoundTripUntilExplicitCommit() async throws {
        try await withPreferences { preferences in
            for side in [TranslationSide.source, .target] {
                let model = TranslationModel()
                model.source = "en"
                model.text = "Hello "
                model.editingChanged("你好 ", isComposing: false, side: .target)
                let fixture = WorkspaceFixture(preferences: preferences, model: model)
                defer { fixture.panel.close() }
                let identifier = side == .source ? "translation.input" : "translation.output"
                let editor = try await fixture.editor(identifier)
                XCTAssertTrue(fixture.panel.makeFirstResponder(editor))
                let original = editor.string
                editor.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
                editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecifiedRange)
                let selectedRange = editor.selectedRange()
                let markedRange = editor.markedRange()
                let attachments = fixture.attachments
                for language in [AppInterfaceLanguage.english, .simplifiedChinese] {
                    await change(language, preferences: preferences, fixture: fixture)
                    let currentEditor = try await fixture.editor(identifier)
                    XCTAssertTrue(currentEditor === editor)
                    XCTAssertTrue(editor.hasMarkedText())
                    XCTAssertTrue(model.isComposing)
                    XCTAssertEqual(editor.markedRange(), markedRange)
                    XCTAssertEqual(editor.selectedRange(), selectedRange)
                    XCTAssertEqual(editor.string, original + "ni")
                    XCTAssertEqual(fixture.attachments, attachments)
                    XCTAssertTrue(fixture.panel.firstResponder === editor)
                    XCTAssertNil(model.request)
                }
                editor.insertText("你", replacementRange: unspecifiedRange)
                XCTAssertFalse(editor.hasMarkedText())
                XCTAssertFalse(model.isComposing)
                XCTAssertEqual(model.text(on: side), original + "你")
            }
        }
    }

    func testCompletedTranslationAndWorkspaceUndoSurviveLanguageChanges() async throws {
        try await withPreferences { preferences in
            let model = TranslationModel()
            model.source = "en"
            model.text = "Keep the completed translation."
            model.submit()
            let provider = ConstructedProvider()
            await model.run(try XCTUnwrap(model.request), provider: provider)
            let result = try XCTUnwrap(model.result)
            let request = model.request
            let revision = model.serviceRevision
            let fixture = WorkspaceFixture(preferences: preferences, model: model)
            defer { fixture.panel.close() }
            _ = try await fixture.editor("translation.input")
            for language in [AppInterfaceLanguage.english, .simplifiedChinese, .system] {
                await change(language, preferences: preferences, fixture: fixture)
                XCTAssertEqual(model.result, result)
                XCTAssertEqual(model.translatedText, result.text)
                XCTAssertEqual(model.text, "Keep the completed translation.")
                XCTAssertEqual(model.request, request)
                XCTAssertEqual(model.phase, .completed)
                XCTAssertEqual(model.serviceRevision, revision)
                XCTAssertTrue(model.canUndoWorkspaceChange)
                XCTAssertEqual(provider.calls, 1)
                XCTAssertEqual(model.statusMessage, L10n.string("Updated"))
            }
            model.undoWorkspaceChange()
            XCTAssertTrue(model.translatedText.isEmpty)
            XCTAssertTrue(model.canRedoWorkspaceChange)
            model.redoWorkspaceChange()
            XCTAssertEqual(model.translatedText, result.text)
            XCTAssertEqual(provider.calls, 1)
        }
    }

    func testPendingTranslationIsNeitherCancelledNorResubmittedByLanguageChanges() async throws {
        try await withPreferences { preferences in
            let model = TranslationModel()
            model.source = "en"
            model.text = "An already pending request."
            model.submit()
            let request = try XCTUnwrap(model.request)
            let configuration = model.configuration
            let fixture = WorkspaceFixture(preferences: preferences, model: model)
            defer { fixture.panel.close() }
            _ = try await fixture.editor("translation.input")
            for language in [AppInterfaceLanguage.english, .simplifiedChinese] {
                await change(language, preferences: preferences, fixture: fixture)
                XCTAssertEqual(model.request, request)
                XCTAssertEqual(model.phase, .translating)
                XCTAssertEqual(model.configuration, configuration)
                XCTAssertNil(model.result)
            }
            let provider = ConstructedProvider()
            await model.run(request, provider: provider)
            XCTAssertEqual(model.phase, .completed)
            XCTAssertEqual(provider.calls, 1)
        }
    }

    func testAboutUsesSettingsWindowAndLanguageChangesKeepItsHost() async throws {
        try await withPreferences { preferences in
            let windows = try isolatedWindows(preferences: preferences)
            defer { windows.shutdown() }
            let shortcuts = ShortcutSettings(preferences: preferences, manager: ShortcutManager(), onAction: { _ in }, onBindingsChanged: {})
            windows.showSettings(shortcuts: shortcuts)
            windows.showAbout()
            let settings = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.settings" })
            let settingsContent = settings.contentView
            XCTAssertFalse(NSApp.windows.contains { $0.identifier?.rawValue == "translatex.about" && $0.isVisible })
            for language in [AppInterfaceLanguage.english, .simplifiedChinese] {
                preferences.interfaceLanguage = language
                L10n.apply(language)
                try await Task.sleep(for: .milliseconds(80))
                XCTAssertEqual(settings.title, L10n.string("Settings"))
                XCTAssertTrue(settings.contentView === settingsContent)
                XCTAssertNil(windows.inputModel.request)
                XCTAssertNil(windows.quickModel.request)
            }
        }
    }

    private func withPreferences(_ body: @MainActor (AppPreferences) async throws -> Void) async throws {
        _ = NSApplication.shared
        let inputMonitor = try isolateUnscriptedWindowInput()
        let originalLanguage = L10n.currentLanguageIdentifier
        let originalAppearance = NSApp.appearance
        let suite = "TranslateXTests.InterfaceLanguage.Windows.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            NSEvent.removeMonitor(inputMonitor)
            defaults.removePersistentDomain(forName: suite)
            L10n.apply(originalLanguage == "zh-Hans" ? .simplifiedChinese : .english)
            NSApp.appearance = originalAppearance
        }
        let preferences = AppPreferences(defaults: defaults)
        preferences.interfaceLanguage = .simplifiedChinese
        L10n.apply(.simplifiedChinese)
        try await body(preferences)
    }

    private func change(_ language: AppInterfaceLanguage, preferences: AppPreferences, fixture: WorkspaceFixture) async {
        preferences.interfaceLanguage = language
        L10n.apply(language)
        try? await Task.sleep(for: .milliseconds(80))
        fixture.surface.layoutSubtreeIfNeeded()
    }

    private var unspecifiedRange: NSRange { NSRange(location: NSNotFound, length: 0) }

    @MainActor
    private final class ConstructedProvider: TranslationProvider {
        var calls = 0
        func translate(_ request: TranslationRequest) async throws -> TranslationResult {
            calls += 1
            return TranslationResult(text: "保留已完成的译文。", source: request.source, target: request.target)
        }
    }

    @MainActor
    private final class WorkspaceFixture {
        let panel: NSPanel
        let surface: WindowSurface<TranslationWorkspace>
        private let capture: AttachmentCapture
        var attachments: Int { capture.count }

        init(preferences: AppPreferences, model: TranslationModel) {
            let capture = AttachmentCapture()
            self.capture = capture
            surface = WindowSurface(preferences: preferences, content: TranslationWorkspace(
                model: model, catalog: nil, editorReady: { _ in capture.count += 1 },
                translationEditorReady: { _ in capture.count += 1 }
            ), reduceTransparency: { false })
            panel = NSPanel(contentRect: NSRect(x: -10_000, y: -10_000, width: 660, height: 440),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.appearance = NSAppearance(named: preferences.appearance == .dark ? .darkAqua : .aqua)
            panel.contentView = surface
            panel.orderFront(nil)
            surface.layoutSubtreeIfNeeded()
        }

        func editor(_ identifier: String) async throws -> TranslationInputTextView {
            for _ in 0..<50 {
                surface.layoutSubtreeIfNeeded()
                if let editor = findEditor(in: surface, identifier: identifier), editor.window != nil { return editor }
                try await Task.sleep(for: .milliseconds(10))
            }
            return try XCTUnwrap(findEditor(in: surface, identifier: identifier))
        }

        private func findEditor(in view: NSView, identifier: String) -> TranslationInputTextView? {
            if let editor = view as? TranslationInputTextView, editor.accessibilityIdentifier() == identifier { return editor }
            return view.subviews.compactMap { findEditor(in: $0, identifier: identifier) }.first
        }
    }

    @MainActor
    private final class AttachmentCapture { var count = 0 }
}
