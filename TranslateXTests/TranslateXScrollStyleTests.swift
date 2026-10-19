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
        let scroller = try XCTUnwrap(scroll.horizontalScroller as? TranslateXScroller)
        let initialKnob = scroller.rect(for: .knob)
        XCTAssertGreaterThan(initialKnob.width, initialKnob.height * 4,
                             "A horizontal thumb must retain horizontal native knob geometry.")
        XCTAssertGreaterThanOrEqual(document.frame.width, 900)
        document.scroll(NSPoint(x: 400, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, 300)
        XCTAssertGreaterThan(scroller.rect(for: .knob).minX, initialKnob.minX)
        XCTAssertGreaterThan(scroller.doubleValue, 0)
    }

    func testBothNativeScrollAxesKeepKnobGeometryAcrossPaneSizesAndRemounting() async throws {
        _ = NSApplication.shared
        let preferred = NSScroller.preferredScrollerStyle
        let host = NSHostingView(rootView: ScrollView([.horizontal, .vertical]) {
            Text("Constructed screenshot canvas").frame(width: 1200, height: 1500).translateXScrollContent()
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 378, height: 470),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)

        // Exercise the narrow/tall and wide/short canvas shapes of both layouts.
        for size in [NSSize(width: 378, height: 470), NSSize(width: 740, height: 270)] {
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let scroll = try XCTUnwrap(findScrollView(host))
            for reset in [false, true] {
                if reset {
                    scroll.hasHorizontalScroller = false
                    scroll.hasVerticalScroller = false
                    scroll.scrollerStyle = .legacy
                    scroll.hasHorizontalScroller = true
                    scroll.hasVerticalScroller = true
                    try await Task.sleep(for: .milliseconds(150))
                }
                let horizontal = try XCTUnwrap(scroll.horizontalScroller as? TranslateXScroller)
                let vertical = try XCTUnwrap(scroll.verticalScroller as? TranslateXScroller)
                let horizontalKnob = horizontal.rect(for: .knob)
                let verticalKnob = vertical.rect(for: .knob)
                XCTAssertGreaterThan(horizontalKnob.width, horizontalKnob.height * 4)
                XCTAssertGreaterThan(verticalKnob.height, verticalKnob.width * 4)
                XCTAssertTrue(horizontal.bounds.contains(horizontalKnob))
                XCTAssertTrue(vertical.bounds.contains(verticalKnob))
                XCTAssertEqual(scroll.scrollerStyle, .overlay)
                XCTAssertEqual(scroll.contentSize.width, scroll.bounds.width, accuracy: 0.5)
                XCTAssertEqual(scroll.contentSize.height, scroll.bounds.height, accuracy: 0.5)
                XCTAssertNotNil(horizontal.target)
                XCTAssertNotNil(horizontal.action)
                XCTAssertNotNil(vertical.target)
                XCTAssertNotNil(vertical.action)
                let document = try XCTUnwrap(scroll.documentView)
                document.scroll(NSPoint(x: 350, y: 600))
                scroll.reflectScrolledClipView(scroll.contentView)
                XCTAssertGreaterThan(scroll.contentView.bounds.minX, 300)
                XCTAssertGreaterThan(scroll.contentView.bounds.minY, 500)
                XCTAssertGreaterThan(horizontal.doubleValue, 0)
                XCTAssertGreaterThan(vertical.doubleValue, 0)
            }
        }
        XCTAssertEqual(NSScroller.preferredScrollerStyle, preferred)
    }

    func testScreenshotWorkspaceUsesSharedScrollersOnBothImageAxesAfterNativeReset() async throws {
        _ = NSApplication.shared
        let fixture = try isolatedWindows()
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 3200,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let model = TranslationModel(automaticallyTranslates: false, services: fixture.services)
        model.submitCapturedDocument(ScreenshotDocument(image: try XCTUnwrap(context.makeImage()), regions: []), serviceRevision: 0)
        let host = NSHostingView(rootView: ScreenshotTranslationWorkspace(model: model, catalog: nil)
            .environment(\.translationLayout, .sideBySide))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        for layout in TranslationLayout.allCases {
            host.rootView = ScreenshotTranslationWorkspace(model: model, catalog: nil)
                .environment(\.translationLayout, layout)
            window.setContentSize(layout == .sideBySide ? NSSize(width: 720, height: 480) : NSSize(width: 760, height: 780))
            try await Task.sleep(for: .milliseconds(150))
            let scrolls = findScrollViews(host)
            let canvas = try XCTUnwrap(scrolls.first { $0.hasHorizontalScroller && $0.hasVerticalScroller })
            let regions = try XCTUnwrap(scrolls.first { $0.hasVerticalScroller && !$0.hasHorizontalScroller })
            XCTAssertTrue(canvas.verticalScroller is TranslateXScroller)
            XCTAssertTrue(canvas.horizontalScroller is TranslateXScroller)
            XCTAssertEqual(canvas.scrollerStyle, .overlay)
            XCTAssertTrue(regions.verticalScroller is TranslateXScroller)
            XCTAssertEqual(regions.scrollerStyle, .overlay)
            canvas.scrollerStyle = .legacy
            canvas.verticalScroller = NSScroller(frame: .zero)
            canvas.horizontalScroller = NSScroller(frame: .zero)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(canvas.verticalScroller is TranslateXScroller)
            XCTAssertTrue(canvas.horizontalScroller is TranslateXScroller)
            XCTAssertEqual(canvas.scrollerStyle, .overlay)
        }
    }

    func testServicePickerScrollersSurviveReopeningAndNativeStyleReset() async throws {
        _ = NSApplication.shared
        let preferred = NSScroller.preferredScrollerStyle
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 410),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let configuration = TranslationServiceConfiguration(preset: .openAI)
        for _ in 0..<2 {
            let pickers: [AnyView] = [
                AnyView(TranslationServiceProviderPicker(selected: .openAI, choose: { _ in }, dismiss: {})),
                AnyView(TranslationServiceIconPicker(configuration: configuration, choose: { _ in }, dismiss: {}))
            ]
            for picker in pickers {
                let host = NSHostingView(rootView: picker)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let scroll = try XCTUnwrap(findScrollView(host))
                XCTAssertTrue(scroll.verticalScroller is TranslateXScroller)
                XCTAssertEqual(scroll.scrollerStyle, .overlay)
                XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, scroll.contentSize.height)
                scroll.scrollerStyle = .legacy
                scroll.verticalScroller = NSScroller(frame: .zero)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertTrue(scroll.verticalScroller is TranslateXScroller)
                XCTAssertEqual(scroll.scrollerStyle, .overlay)
                XCTAssertEqual(scroll.contentView.frame.width, scroll.bounds.width, accuracy: 0.5,
                               "Popup scrolling must not reserve a legacy track gutter.")
            }
        }
        XCTAssertEqual(NSScroller.preferredScrollerStyle, preferred)
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
