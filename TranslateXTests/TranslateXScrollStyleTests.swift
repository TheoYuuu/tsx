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

    private func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.compactMap(findScrollView).first
    }
}
