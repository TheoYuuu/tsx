import AppKit
import SwiftUI
import XCTest
@testable import TranslateX

@MainActor
final class TranslationToolbarTests: XCTestCase {
    func testServiceMenuHasOneCheckmarkAndManagementIsIndependentOfSelection() throws {
        _ = NSApplication.shared
        let control = TranslationServiceMenuControl()
        let service = TranslationServiceConfiguration(kind: .deepSeek)
        var choices: [UUID?] = []; var managed = 0
        control.configure(title: service.name, selectedID: service.id, services: [service], select: { choices.append($0) }, manage: { managed += 1 })
        let menu = try XCTUnwrap(control.menu)
        let visible = menu.items.filter { !$0.isHidden && !$0.isSeparatorItem }
        XCTAssertEqual(visible.count, 3)
        XCTAssertEqual(visible.filter { $0.state == .on }.map(\.title), [service.name])
        XCTAssertTrue(visible.allSatisfy { $0.image == nil })
        XCTAssertEqual(menu.font, NSFont.systemFont(ofSize: 13))
        XCTAssertTrue(control.pullsDown)
        XCTAssertEqual(menu.items.first?.isHidden, true)
        menu.performActionForItem(at: menu.index(of: visible[0]))
        XCTAssertEqual(choices.count, 1); XCTAssertNil(choices[0])
        menu.performActionForItem(at: menu.index(of: visible[2]))
        XCTAssertEqual(managed, 1); XCTAssertEqual(choices.count, 1)
        control.isEnabled = false
        menu.performActionForItem(at: menu.index(of: visible[1]))
        menu.performActionForItem(at: menu.index(of: visible[2]))
        XCTAssertEqual(managed, 1); XCTAssertEqual(choices.count, 1)
    }

    func testTooltipPlacementAvoidsScreenEdgesAndSourceControl() {
        let screen = NSRect(x: -1400, y: -700, width: 1400, height: 900)
        for anchor in [NSRect(x: -1395, y: -690, width: 28, height: 28), NSRect(x: -40, y: 145, width: 28, height: 28), NSRect(x: -720, y: -100, width: 28, height: 28)] {
            let frame = TooltipAnchorView.placement(anchor: anchor, size: NSSize(width: 210, height: 48), visibleFrame: screen)
            XCTAssertTrue(screen.contains(frame)); XCTAssertFalse(anchor.intersects(frame))
        }
    }

    func testLongServiceNameKeepsTheArrowAndFullAccessibleValue() throws {
        let control = TranslationServiceMenuControl()
        let name = "A long translation service name with several words"
        control.frame = NSRect(x: 0, y: 0, width: 92, height: 28)
        control.configure(title: name, selectedID: nil, services: [], select: { _ in }, manage: {})
        control.layout()
        let title = try XCTUnwrap(control.menu?.items.first?.attributedTitle)
        XCTAssertTrue(title.string.contains("…"))
        XCTAssertNotNil(title.attribute(.attachment, at: title.length - 1, effectiveRange: nil))
        XCTAssertEqual(control.accessibilityValue() as? String, name)
        XCTAssertLessThanOrEqual(title.size().width, control.frame.width)
    }

    func testTooltipAppearsImmediatelyWithoutTakingFocusAndCleansUpOnMenu() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = TooltipAnchorView(frame: NSRect(x: 30, y: 30, width: 28, height: 28))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        defer { anchor.dismiss(); window.close() }
        let keyBefore = NSApp.keyWindow
        anchor.update(text: "Constructed tooltip", dark: false, presented: true)
        let hint = try XCTUnwrap(window.childWindows?.first as? NSPanel)
        XCTAssertTrue(hint.isVisible)
        XCTAssertTrue(hint.ignoresMouseEvents)
        XCTAssertTrue(hint.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(NSApp.keyWindow === keyBefore)
        XCTAssertNil(anchor.hitTest(.zero))
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        anchor.update(text: "Constructed tooltip", dark: true, presented: false)
        anchor.update(text: "Constructed tooltip", dark: true, presented: true)
        XCTAssertEqual(window.childWindows?.count, 1)
        anchor.dismiss()
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
    }

    func testTooltipFitsChineseLatinAndWrappedTextWithoutClipping() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = TooltipAnchorView(frame: NSRect(x: 180, y: 130, width: 28, height: 28))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        defer { anchor.dismiss(); window.close() }
        let samples = ["截图翻译", "翻译选中文字", "设置", "Screenshot Translation", "Nothing to undo",
                       "撤销上次替换 · 恢复两侧文字\n保留输入内容，可以继续编辑。",
                       "After you edit either side, automatically update the other. Turning this off keeps both sides editable."]
        for dark in [false, true] {
            for (index, text) in samples.enumerated() {
                anchor.update(text: text, dark: dark, presented: true)
                let panel = try XCTUnwrap(window.childWindows?.first as? NSPanel)
                let body = try XCTUnwrap(panel.contentView)
                let label = try XCTUnwrap(body.subviews.first as? NSTextField)
                let cell = try XCTUnwrap(label.cell)
                let required = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: CGFloat.greatestFiniteMagnitude))
                XCTAssertEqual(label.stringValue, text)
                XCTAssertLessThanOrEqual(required.width, label.bounds.width, text)
                XCTAssertLessThanOrEqual(required.height, label.bounds.height, text)
                XCTAssertTrue(body.bounds.contains(label.frame), text)
                XCTAssertEqual(label.lineBreakMode, .byWordWrapping)
                XCTAssertLessThanOrEqual(panel.frame.width, 314)
                if text.contains("\n") || index == samples.count - 1 { XCTAssertGreaterThan(label.bounds.height, 20) }
                // Keep the actual AppKit rendering, including the final glyph,
                // for visual review rather than only checking the stored string.
                let bitmap = try XCTUnwrap(body.bitmapImageRepForCachingDisplay(in: body.bounds))
                body.cacheDisplay(in: body.bounds, to: bitmap)
                let image = NSImage(size: body.bounds.size); image.addRepresentation(bitmap)
                let attachment = XCTAttachment(image: image)
                attachment.name = "tooltip-\(dark ? "dark" : "light")-\(index)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testDisabledButtonShowsImmediateNativeHoverHintWithoutTakingFocus() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 220, y: 220, width: 180, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = Button("Undo") { XCTFail("Disabled undo must remain inert") }
            .disabled(true).frame(width: 28, height: 28).translateXTooltip("暂无可撤销内容")
        let host = NSHostingView(rootView: button)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        // Allow AppKit to mount the real disabled SwiftUI button's native anchor.
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            if tooltipAnchor(in: host) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let anchor = try XCTUnwrap(tooltipAnchor(in: host))
        anchor.updateTrackingAreas()
        XCTAssertEqual(anchor.trackingAreas.count, 1)
        XCTAssertTrue(anchor.trackingAreas[0].options.contains(.activeAlways))
        XCTAssertNil(anchor.hitTest(NSPoint(x: 14, y: 14)))
        let firstResponder = window.firstResponder
        let entered = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        anchor.mouseEntered(with: entered)
        let panel = try XCTUnwrap(window.childWindows?.first as? NSPanel)
        let label = try XCTUnwrap(panel.contentView?.subviews.first as? NSTextField)
        XCTAssertEqual(label.stringValue, "暂无可撤销内容")
        XCTAssertTrue(panel.isVisible); XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(window.firstResponder === firstResponder)
        anchor.update(text: "撤销", dark: false, presented: false)
        XCTAssertEqual((window.childWindows?.first?.contentView?.subviews.first as? NSTextField)?.stringValue, "撤销")
        let exited = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        anchor.mouseExited(with: exited)
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
    }

    func testAnimationVisibilityFollowsNativeWindowShowAndHide() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 160, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Keep this owned probe above unrelated desktop windows. Occlusion by
        // another app is valid behavior, but not the show/hide transition tested.
        window.level = .floating
        let probe = WindowVisibilityProbe(frame: NSRect(x: 10, y: 10, width: 84, height: 28))
        var visible: Bool?
        probe.changed = { visible = $0 }
        window.contentView?.addSubview(probe)
        window.makeKeyAndOrderFront(nil)
        defer { probe.stop(); window.close() }
        for _ in 0..<100 {
            if visible == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(visible, true)
        window.orderOut(nil)
        for _ in 0..<100 {
            if visible == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(visible, false)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<100 {
            if visible == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(visible, true)
    }

    private func tooltipAnchor(in view: NSView) -> TooltipAnchorView? {
        if let anchor = view as? TooltipAnchorView { return anchor }
        return view.subviews.compactMap(tooltipAnchor).first
    }

    func testTestDateUsesCalendarDayAndYearRatherThanElapsedHours() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 0, minute: 10))!
        let recent = now.addingTimeInterval(-20 * 60)
        let string = ServiceTestDate.compact(recent, now: now, calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertTrue(string.hasPrefix(L10n.string("Yesterday %@").replacingOccurrences(of: "%@", with: "")))
        let lastYear = calendar.date(from: DateComponents(year: 2025, month: 3, day: 1))!
        XCTAssertTrue(ServiceTestDate.compact(lastYear, now: now, calendar: calendar, locale: Locale(identifier: "en_US_POSIX")).contains("2025"))
    }
}
