import AppKit
import ImageIO
import XCTest
@testable import TranslateX

@MainActor
final class ScreenshotOverlayTests: XCTestCase {
    func testPlacementKeepsOriginalPositionAndMovesToolbarAboveNearBottom() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        for selection in [CGRect(x: 20, y: 400, width: 220, height: 160),
                          CGRect(x: 1190, y: 400, width: 220, height: 160),
                          CGRect(x: 300, y: 12, width: 400, height: 220)] {
            let result = ScreenshotOverlayPlacement(selection: selection, visibleFrame: screen)
            XCTAssertEqual(result.imageFrame, selection)
            XCTAssertTrue(screen.contains(result.frame))
            XCTAssertTrue(result.frame.contains(result.imageFrame))
            XCTAssertEqual(result.toolbarAbove, selection.minY < ScreenshotOverlayPlacement.toolbarHeight + 8)
        }
    }

    func testFullScreenAndCrossDisplaySelectionsFitWithoutCroppingOnNegativeOriginScreen() {
        let screen = CGRect(x: -1280, y: -200, width: 1280, height: 800)
        for selection in [screen, CGRect(x: -1500, y: -300, width: 3000, height: 1400),
                          CGRect(x: -900, y: 0, width: 400, height: 240)] {
            let result = ScreenshotOverlayPlacement(selection: selection, visibleFrame: screen)
            XCTAssertTrue(screen.contains(result.frame))
            XCTAssertEqual(result.imageFrame.width / result.imageFrame.height, selection.width / selection.height, accuracy: 0.00001)
            XCTAssertTrue(result.frame.contains(result.imageFrame))
        }
        let narrow = ScreenshotOverlayPlacement(selection: CGRect(x: 10, y: 100, width: 300, height: 200),
            visibleFrame: CGRect(x: 0, y: 0, width: 320, height: 600))
        XCTAssertEqual(narrow.frame.width, 304)
    }

    func testManualScreenshotRetainsPixelsWithoutStartingARequest() throws {
        let model = TranslationModel()
        model.source = "en"
        let document = try document()
        model.submitCapturedDocument(document, serviceRevision: 0, startAutomatically: false)
        XCTAssertEqual(model.phase, .empty)
        XCTAssertNil(model.request)
        XCTAssertNil(model.configuration)
        XCTAssertTrue(model.screenshot?.image === document.image)
        XCTAssertEqual(model.text, document.sourceText)
        model.submit()
        XCTAssertNotNil(model.request)
        XCTAssertEqual(model.phase, .translating)
    }

    func testDragUsesInitialAnchorAndIgnoresClickJitter() throws {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let frame = CGRect(x: 300, y: 250, width: 768, height: 350)
        let pointer = CGPoint(x: 500, y: 450)
        var drag = ScreenshotOverlayDrag(panelFrame: frame, pointer: pointer, toolbarAbove: false)
        XCTAssertNil(drag.frame(at: CGPoint(x: 501, y: 451), visibleFrames: [screen]))
        XCTAssertEqual(drag.frame(at: CGPoint(x: 570, y: 490), visibleFrames: [screen]), frame.offsetBy(dx: 70, dy: 40))
        XCTAssertEqual(drag.frame(at: CGPoint(x: 590, y: 460), visibleFrames: [screen]), frame.offsetBy(dx: 90, dy: 10))
        XCTAssertEqual(drag.frame(at: pointer, visibleFrames: [screen]), frame, "Returning the mouse restores the initial position without cumulative drift")
    }

    func testDragCrossesDisplaysAndKeepsContentVisibleWithoutConfiningShadows() throws {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: -1280, y: -200, width: 1280, height: 800)]
        let frame = CGRect(x: 100, y: 200, width: 768, height: 350)
        for above in [true, false] {
            var drag = ScreenshotOverlayDrag(panelFrame: frame, pointer: CGPoint(x: 400, y: 400), toolbarAbove: above)
            for pointer in [CGPoint(x: -1000, y: 200), CGPoint(x: -1280, y: -200), CGPoint(x: -1280, y: 600)] {
                let moved = try XCTUnwrap(drag.frame(at: pointer, visibleFrames: screens))
                XCTAssertEqual(moved.size, frame.size)
                XCTAssertTrue(screens[1].insetBy(dx: 8, dy: 8).contains(moved.insetBy(dx: 24, dy: 24)))
            }
            let corner = try XCTUnwrap(drag.frame(at: CGPoint(x: 0, y: 0), visibleFrames: [screens[0]]))
            XCTAssertEqual(corner.minX, -16, "Only visible content, not transparent shadow padding, is constrained")
            XCTAssertEqual(corner.minY, -16)
        }
    }

    func testDragToSmallerScreenKeepsScaleAndToolbarEdgeReachable() throws {
        let screen = CGRect(x: -1024, y: 0, width: 1024, height: 700)
        let frame = CGRect(x: 0, y: 0, width: 1448, height: 948)
        for above in [true, false] {
            var drag = ScreenshotOverlayDrag(panelFrame: frame, pointer: CGPoint(x: 400, y: 400), toolbarAbove: above)
            let moved = try XCTUnwrap(drag.frame(at: CGPoint(x: -700, y: 200), visibleFrames: [screen]))
            let content = moved.insetBy(dx: 24, dy: 24)
            XCTAssertEqual(moved.size, frame.size)
            XCTAssertEqual(content.midX, screen.midX)
            XCTAssertEqual(above ? content.maxY : content.minY, above ? screen.maxY - 8 : screen.minY + 8)
        }
    }

    func testImageMouseEventsMoveWholePanelAndRenderingDoesNotResetPosition() async throws {
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let model = try await completedModel()
        let overlay = ScreenshotOverlayController(windows: windows, model: model)
        defer { overlay.dismiss(restoreFocus: false) }
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let selection = CGRect(x: screen.midX - 180, y: screen.midY, width: 360, height: 216)
        overlay.present(source: nil, selection: selection)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.screenshotResult" && $0.isVisible })
        panel.contentView?.layoutSubtreeIfNeeded()
        let surface = try XCTUnwrap(dragView(in: try XCTUnwrap(panel.contentView)))
        let bounds = panel.convertToScreen(surface.convert(surface.bounds, to: nil))
        XCTAssertEqual(bounds.minX, selection.minX, accuracy: 0.01)
        XCTAssertEqual(bounds.minY, selection.minY, accuracy: 0.01)
        XCTAssertEqual(bounds.width, selection.width, accuracy: 0.01)
        XCTAssertEqual(bounds.height, selection.height, accuracy: 0.01)
        let initial = panel.frame
        let image = try XCTUnwrap(model.screenshot?.image)
        let pointer = CGPoint(x: bounds.midX, y: bounds.midY)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: point),
                modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        surface.mouseDown(with: try event(.leftMouseDown, pointer))
        surface.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: pointer.x + 40, y: pointer.y - 30)))
        XCTAssertEqual(panel.frame, initial.offsetBy(dx: 40, dy: -30))
        // The next event is relative to the moved window; the screen anchor is unchanged.
        surface.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: pointer.x + 70, y: pointer.y - 40)))
        let moved = initial.offsetBy(dx: 70, dy: -40)
        XCTAssertEqual(panel.frame, moved)
        surface.mouseUp(with: try event(.leftMouseUp, pointer))
        overlay.handleImageDrag(.moved(pointer))
        XCTAssertEqual(panel.frame, moved, "Mouse-up ends the drag")
        let region = try XCTUnwrap(model.screenshot?.regions.first)
        model.editScreenshotRegion(region.id, text: "Updated fixture translation.", side: .target)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(panel.frame, moved, "Preview updates must not recreate or reposition the panel")
        XCTAssertTrue(overlay.image(for: .originalImage) === image, "Dragging and the border never modify export pixels")
        XCTAssertEqual(panel.contentView?.bounds.size, initial.size)
    }

    func testImageDragIsBlockedByMenusAndSheetsAndClearedOnDismissal() async throws {
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let overlay = ScreenshotOverlayController(windows: windows, model: try await completedModel())
        defer { overlay.dismiss(restoreFocus: false) }
        overlay.present(source: nil, selection: CGRect(x: 200, y: 300, width: 350, height: 200))
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.screenshotResult" && $0.isVisible })
        let initial = panel.frame
        let pointer = CGPoint(x: initial.midX, y: initial.midY)
        let menu = NSMenu()
        overlay.handleImageDrag(.began(pointer))
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        overlay.handleImageDrag(.moved(CGPoint(x: pointer.x + 50, y: pointer.y)))
        XCTAssertEqual(panel.frame, initial)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        try await Task.sleep(for: .milliseconds(20))
        overlay.handleImageDrag(.moved(CGPoint(x: pointer.x + 50, y: pointer.y)))
        XCTAssertEqual(panel.frame, initial, "Closing a menu cannot resume the previous drag")
        let sheet = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        panel.beginSheet(sheet, completionHandler: nil)
        overlay.handleImageDrag(.began(pointer))
        overlay.handleImageDrag(.moved(CGPoint(x: pointer.x + 50, y: pointer.y)))
        XCTAssertEqual(panel.frame, initial)
        panel.endSheet(sheet)
        sheet.orderOut(nil)
        overlay.handleImageDrag(.began(pointer))
        overlay.dismiss(restoreFocus: false)
        overlay.handleImageDrag(.moved(CGPoint(x: pointer.x + 50, y: pointer.y)))
        XCTAssertFalse(overlay.isVisible)
    }

    private func dragView(in view: NSView) -> ScreenshotImageDragView? {
        if let surface = view as? ScreenshotImageDragView { return surface }
        return view.subviews.lazy.compactMap { self.dragView(in: $0) }.first
    }

    func testShadowDrawingRoomPreservesContentPlacementAndDisablesNativeShadow() async throws {
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let overlay = ScreenshotOverlayController(windows: windows, model: try await completedModel())
        defer { overlay.dismiss(restoreFocus: false) }
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        // Exercise both toolbar positions, including an image close to a screen edge.
        for y in [screen.minY + 12, screen.midY] {
            let selection = CGRect(x: screen.minX + 12, y: y, width: 220, height: 160)
            let placement = ScreenshotOverlayPlacement(selection: selection, visibleFrame: screen)
            overlay.present(source: nil, selection: selection)
            let panel = try XCTUnwrap(NSApp.windows.first {
                $0.identifier?.rawValue == "translatex.screenshotResult" && $0.isVisible
            })
            XCTAssertFalse(panel.hasShadow)
            XCTAssertEqual(placement.imageFrame, selection)
            XCTAssertEqual(panel.frame.insetBy(dx: ScreenshotOverlayPlacement.shadowInset,
                                               dy: ScreenshotOverlayPlacement.shadowInset), placement.frame)
            XCTAssertEqual(panel.contentView?.bounds.size, panel.frame.size)
        }
    }

    func testCaptureReadsAutomaticPreferenceAfterSynchronizingTheService() throws {
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let model = TranslationModel(automaticallyTranslates: true, services: windows.services)
        model.source = "en"
        let revision = model.captureServiceIntent()
        XCTAssertTrue(model.usesAutomaticTranslation)
        // No actor yield: the observation callback has not had time to update
        // the model. OCR completion must honor the store's current preference.
        try windows.services.setAutomaticTranslation(false, for: nil)
        model.submitCapturedDocument(try document(), serviceRevision: revision, respectAutomaticPreference: true)
        XCTAssertNil(model.request)
        XCTAssertFalse(model.usesAutomaticTranslation)
        XCTAssertEqual(model.phase, .empty)
        model.submit()
        XCTAssertNotNil(model.request, "An explicit click still translates in manual mode")
        model.cancel()
    }

    func testChangingOrExchangingScreenshotLanguagesClearsStaleOutputButKeepsPixels() async throws {
        let model = try await completedModel()
        let original = try XCTUnwrap(model.screenshot)
        model.target = "fr"
        XCTAssertEqual(model.screenshot?.id, original.id)
        XCTAssertTrue(model.screenshot?.translations.isEmpty == true)
        XCTAssertTrue(model.translatedText.isEmpty)
        model.swapScreenshotLanguages()
        XCTAssertEqual(model.source, "fr")
        XCTAssertEqual(model.target, "en")
        XCTAssertEqual(model.screenshot?.id, original.id)
        XCTAssertEqual(model.text, original.sourceText)
        XCTAssertTrue(model.screenshot?.image === original.image)
    }

    func testCopyAndExportUseOriginalPixelsAndLatestCorrectionWithoutToolbar() async throws {
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let model = try await completedModel()
        let overlay = ScreenshotOverlayController(windows: windows, model: model)
        defer { overlay.dismiss(restoreFocus: false) }
        let document = try XCTUnwrap(model.screenshot)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        overlay.copy(.originalText, pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), document.sourceText)
        model.editScreenshotRegion(document.regions[0].id, text: "更正后的完整译文", side: .target)
        overlay.copy(.translatedText, pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "更正后的完整译文")
        for output in [ScreenshotOutput.originalImage, .translatedImage] {
            overlay.copy(output, pasteboard: pasteboard)
            let data = try XCTUnwrap(pasteboard.data(forType: .png))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let pixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(pixels.width, document.image.width)
            XCTAssertEqual(pixels.height, document.image.height)
        }
        XCTAssertTrue(overlay.image(for: .originalImage) === document.image)
    }

    func testTemporaryOverlayDoesNotReplaceDraftUntilExplicitHandoffAndRestoresPrevious() async throws {
        _ = NSApplication.shared
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.inputModel.text = "A draft before the screenshot."
        let model = try await completedModel()
        let screenshot = model.screenshot
        let overlay = ScreenshotOverlayController(windows: windows, model: model)
        defer { overlay.dismiss(restoreFocus: false) }
        overlay.present(source: nil, selection: CGRect(x: 200, y: 200, width: 350, height: 200))
        XCTAssertTrue(overlay.isVisible)
        XCTAssertEqual(windows.inputModel.text, "A draft before the screenshot.")
        XCTAssertFalse(windows.inputModel.canRestorePreviousWorkspace)
        overlay.editInMain()
        XCTAssertFalse(overlay.isVisible)
        XCTAssertNil(model.screenshot, "Closing the temporary picture releases its pixels")
        XCTAssertEqual(windows.inputModel.screenshot, screenshot)
        XCTAssertNil(windows.inputModel.request, "Moving a result must not resend content")
        windows.restorePreviousTranslation()
        XCTAssertEqual(windows.inputModel.text, "A draft before the screenshot.")
        XCTAssertNil(windows.inputModel.screenshot)
    }

    func testClosingOverlayCancelsRecognitionAndReleasesItsPixelsWithoutTouchingMain() throws {
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        windows.inputModel.text = "The main draft stays here."
        let model = TranslationModel()
        var cancelled = 0
        model.beginRecognition(image: try document().image, cancellation: { cancelled += 1 })
        let overlay = ScreenshotOverlayController(windows: windows, model: model)
        overlay.editInMain()
        XCTAssertEqual(cancelled, 0, "Opening the editor cannot interrupt unfinished OCR")
        XCTAssertEqual(model.phase, .recognizing)
        XCTAssertNotNil(model.screenshot)
        XCTAssertNil(windows.inputModel.screenshot)
        overlay.dismiss(restoreFocus: false)
        overlay.dismiss(restoreFocus: false)
        XCTAssertEqual(cancelled, 1)
        XCTAssertNil(model.screenshot)
        XCTAssertNil(model.request)
        XCTAssertEqual(windows.inputModel.text, "The main draft stays here.")
    }

    func testScreenNotificationOnlyDismissesWhenDisplayGeometryActuallyChanges() async throws {
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let model = try await completedModel()
        let layout = OverlayLayoutFixture()
        let overlay = ScreenshotOverlayController(windows: windows, model: model, currentScreenLayout: { layout.displays })
        defer { overlay.dismiss(restoreFocus: false) }
        overlay.present(source: nil, selection: CGRect(x: 200, y: 200, width: 350, height: 200))
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertTrue(overlay.isVisible, "Activation or menu-bar notifications must not discard the result")
        XCTAssertNotNil(model.screenshot)
        layout.displays = [CaptureDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1)]
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertFalse(overlay.isVisible)
        XCTAssertNil(model.screenshot)
    }

    func testEscapeEndingAMenuDoesNotAlsoDismissTheScreenshot() async throws {
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let overlay = ScreenshotOverlayController(windows: windows, model: try await completedModel())
        defer { overlay.dismiss(restoreFocus: false) }
        overlay.present(source: nil, selection: CGRect(x: 200, y: 200, width: 350, height: 200))
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "translatex.screenshotResult" && $0.isVisible })
        let menu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        panel.cancelOperation(nil)
        XCTAssertTrue(overlay.isVisible)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        panel.cancelOperation(nil)
        XCTAssertTrue(overlay.isVisible, "The event that dismisses a menu still belongs to that menu")
        try await Task.sleep(for: .milliseconds(20))
        panel.cancelOperation(nil)
        XCTAssertFalse(overlay.isVisible, "A subsequent Escape closes the screenshot normally")
    }

    func testNativeIconMenuKeepsImagesAndRejectsAnActionDisabledWhileTracking() throws {
        let control = ScreenshotActionMenuControl()
        var copies = 0
        control.configure([ScreenshotMenuItem(title: "Copy original", symbol: "list.clipboard") { copies += 1 }])
        let menu = try XCTUnwrap(control.menu)
        let item = try XCTUnwrap(menu.items.last)
        XCTAssertTrue(menu.items[0].isHidden, "The display item is separate from the first real action")
        XCTAssertNotNil(item.image, "Native rows retain the action's icon")
        control.menuWillOpen(menu)
        control.configure([ScreenshotMenuItem(title: "Copy original", symbol: "list.clipboard", enabled: false) { copies += 1 }])
        menu.performActionForItem(at: 1)
        XCTAssertEqual(copies, 0, "A menu opened before the model changed must use the current enabled state")
        control.menuDidClose(menu)
        XCTAssertEqual(control.menu?.items.last?.isEnabled, false)
        control.configure([ScreenshotMenuItem(title: "Copy original", symbol: "list.clipboard") { copies += 1 }])
        control.menu?.performActionForItem(at: 1)
        XCTAssertEqual(copies, 1)
    }

    private func completedModel() async throws -> TranslationModel {
        let model = TranslationModel()
        model.source = "en"
        model.submitCapturedDocument(try document(), serviceRevision: 0)
        await model.run(try XCTUnwrap(model.request), provider: OverlayTestProvider())
        model.cancel() // No live Apple session belongs in this native fixture.
        return model
    }

    private func document() throws -> ScreenshotDocument {
        let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 360, bitsPerComponent: 8, bytesPerRow: 2400,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 360))
        let region = ScreenshotRegion(id: UUID(), text: "A clear passage for translation.",
            bounds: CGRect(x: 0.1, y: 0.6, width: 0.8, height: 0.15), confidence: 1, role: .paragraph, separator: "")
        return ScreenshotDocument(image: try XCTUnwrap(context.makeImage()), regions: [region])
    }
}

@MainActor
private final class OverlayLayoutFixture {
    var displays = [CaptureDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)]
}

@MainActor
private struct OverlayTestProvider: TranslationProvider {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        TranslationResult(text: "一段清晰的文字。", source: request.source, target: request.target)
    }
}
