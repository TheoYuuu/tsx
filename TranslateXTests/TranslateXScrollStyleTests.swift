import AppKit
import SwiftUI
import XCTest
@testable import TranslateX

@MainActor
final class TranslateXScrollStyleTests: XCTestCase {
    func testOverlayKeepsDocumentWidthAndReflectsNativeScrollingAcrossUpdates() async throws {
        _ = NSApplication.shared
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        scroll.hasVerticalScroller = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 1200))
        scroll.documentView = document
        TranslateXScrollStyle.apply(to: scroll)
        scroll.tile()
        let scroller = try XCTUnwrap(scroll.verticalScroller as? TranslateXScroller)
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        XCTAssertEqual(scroll.contentSize.width, 320, accuracy: 0.1)
        XCTAssertNotNil(scroller.target)
        XCTAssertNotNil(scroller.action)
        document.scroll(NSPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        XCTAssertGreaterThan(scroller.doubleValue, 0, "The shared thumb must track native document scrolling")
        let origin = scroll.contentView.bounds.origin
        TranslateXScrollStyle.apply(to: scroll)
        XCTAssertTrue(scroll.verticalScroller === scroller)
        XCTAssertTrue(scroll.documentView === document)
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
    }

    func testSwiftUIContentAnchorInstallsTheSameScrollerWithoutChangingSystemPreference() async throws {
        _ = NSApplication.shared
        let preferred = NSScroller.preferredScrollerStyle
        let host = NSHostingView(rootView: ScrollView {
            Text(String(repeating: "Constructed scroll content\n", count: 100)).translateXScrollContent()
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let scroll = try XCTUnwrap(findScrollView(host))
        XCTAssertTrue(scroll.verticalScroller is TranslateXScroller)
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        XCTAssertEqual(NSScroller.preferredScrollerStyle, preferred)
    }

    func testUsagePageKeepsSharedOverlayAfterResizingAndMaterialChange() async throws {
        _ = NSApplication.shared
        let fixture = try isolatedWindows()
        let host = NSHostingView(rootView: TranslateXThemeHost(preferences: fixture.preferences) {
            UsageDashboardView(store: fixture.services)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host

        for (width, material) in [(850.0, AppMaterial.light), (670.0, .glass), (920.0, .light)] {
            fixture.preferences.material = material
            window.setContentSize(NSSize(width: width, height: 500))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let scrolls = findScrollViews(host)
            let outer = try XCTUnwrap(scrolls.first)
            XCTAssertTrue(outer.hasVerticalScroller)
            XCTAssertGreaterThan(outer.documentView?.frame.height ?? 0, outer.contentSize.height)
            for scroll in scrolls {
                XCTAssertEqual(scroll.scrollerStyle, .overlay)
                if scroll.hasVerticalScroller { XCTAssertTrue(scroll.verticalScroller is TranslateXScroller) }
                if scroll.hasHorizontalScroller { XCTAssertTrue(scroll.horizontalScroller is TranslateXScroller) }
            }
            XCTAssertEqual(outer.contentView.frame.width, outer.bounds.width, accuracy: 0.5,
                           "A page scrollbar must not reserve a gutter inside the table.")
        }
    }

    func testUsagePageContentDoesNotReserveScrollbarSpaceWhenEnabled() async throws {
        _ = NSApplication.shared
        let fixture = try isolatedWindows()
        let host = NSHostingView(rootView: UsageDashboardView(store: fixture.services).disabled(false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 715, height: 551),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        for disabled in [false, true, false] {
            host.rootView = UsageDashboardView(store: fixture.services).disabled(disabled)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let scroll = try XCTUnwrap(findScrollView(host))
            let service = try XCTUnwrap(findServiceMenu(host))
            let frame = service.convert(service.bounds, to: scroll)
            XCTAssertEqual(scroll.scrollerStyle, .overlay)
            XCTAssertEqual(scroll.bounds.width, host.bounds.width, accuracy: 0.5)
            XCTAssertEqual(scroll.bounds.maxX - frame.maxX, 24, accuracy: 4,
                           "Enabling or disabling the date picker must not reserve an extra scrollbar gutter.")
        }
        let scroll = try XCTUnwrap(findScrollView(host))
        scroll.scrollerStyle = .legacy
        scroll.verticalScroller = NSScroller(frame: .zero)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(scroll.scrollerStyle, .overlay, "Style ownership must survive a later native reset.")
        XCTAssertTrue(scroll.verticalScroller is TranslateXScroller)
        let service = try XCTUnwrap(findServiceMenu(host))
        XCTAssertEqual(scroll.bounds.maxX - service.convert(service.bounds, to: scroll).maxX, 24, accuracy: 4)
    }

    func testHorizontalDocumentsKeepTheirScrollableWidth() async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ScrollView(.horizontal) {
            Text("Constructed wide table").frame(width: 900, height: 80).translateXScrollContent()
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        let scroll = try XCTUnwrap(findScrollView(host))
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertTrue(scroll.horizontalScroller is TranslateXScroller)
        XCTAssertGreaterThanOrEqual(document.frame.width, 900)
        document.scroll(NSPoint(x: 400, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, 300)
    }

    private func findServiceMenu(_ view: NSView) -> LanguageMenuControl? {
        if let menu = view as? LanguageMenuControl, menu.selection == "all" { return menu }
        return view.subviews.compactMap(findServiceMenu).first
    }

    private func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.compactMap(findScrollView).first
    }

    private func findScrollViews(_ view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(findScrollViews)
    }
}
