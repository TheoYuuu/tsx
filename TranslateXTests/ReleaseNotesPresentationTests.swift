import AppKit
import SwiftUI
import XCTest
@testable import TranslateX

final class ReleaseNotesPresentationTests: XCTestCase {
    func testAvailableUpdateDialogFitsMinimumDefaultAndLargeWindowSizes() {
        XCTAssertEqual(UpdateDialogLayout.size(in: TranslationLayout.sideBySide.minimumSize(for: .main)),
                       CGSize(width: 520, height: 360))
        for layout in TranslationLayout.allCases {
            XCTAssertEqual(UpdateDialogLayout.size(in: layout.defaultSize(for: .main)),
                           CGSize(width: 620, height: layout == .sideBySide ? 518 : 520))
        }
        XCTAssertEqual(UpdateDialogLayout.size(in: CGSize(width: 2_000, height: 1_200)),
                       CGSize(width: 620, height: 520))
    }

    func testAvailableUpdateDialogResizesEachAxisWithinTheWindow() {
        let sizes = [CGSize(width: 660, height: 440), CGSize(width: 710, height: 500),
                     CGSize(width: 760, height: 560), CGSize(width: 980, height: 598)]
        let dialogs = sizes.map { UpdateDialogLayout.size(in: $0) }
        XCTAssertEqual(dialogs[1], CGSize(width: 570, height: 420))
        for (window, dialog) in zip(sizes, dialogs) {
            XCTAssertLessThanOrEqual(dialog.width, window.width - 40)
            XCTAssertLessThanOrEqual(dialog.height, window.height - 80)
        }
        XCTAssertEqual(UpdateDialogLayout.size(in: CGSize(width: 980, height: 440)),
                       CGSize(width: 620, height: 360))
        XCTAssertEqual(UpdateDialogLayout.size(in: CGSize(width: 660, height: 780)),
                       CGSize(width: 520, height: 520))
        XCTAssertEqual(UpdateDialogLayout.size(in: CGSize(width: 500, height: 350)),
                       CGSize(width: 460, height: 270))
    }

    func testReleaseNotesHeightCapsAt520AndKeepsVerticalMargins() {
        for height: CGFloat in [0, 60, 350, 440, 598, 600, 700, 1200, 2160] {
            let window = CGSize(width: 1100, height: height)
            let limit = UpdateDialogLayout.maximumHeight(in: window)
            XCTAssertGreaterThanOrEqual(limit, 0)
            XCTAssertLessThanOrEqual(limit, 520)
            XCTAssertLessThanOrEqual(limit, max(0, height - 80))
            if height >= 600 { XCTAssertEqual(limit, 520) }
        }
    }

    private let now = Date(timeIntervalSince1970: 1_791_662_400) // A fixed instant, independent of the test machine.
    private var utc: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    func testRelativeTimeBoundaries() {
        let cases: [(Double, ReleasePublicationTime.Age)] = [
            (0, .justNow), (59, .justNow), (60, .minutes(1)), (3_599, .minutes(59)),
            (3_600, .hours(1)), (86_399, .hours(23)), (86_400, .yesterday),
            (172_800, .days(2)), (30 * 86_400, .days(30)), (31 * 86_400, .absolute)
        ]
        for (elapsed, expected) in cases {
            XCTAssertEqual(ReleasePublicationTime.age(of: now.addingTimeInterval(-elapsed), now: now, calendar: utc), expected)
        }
        XCTAssertEqual(ReleasePublicationTime.age(of: now.addingTimeInterval(30), now: now, calendar: utc), .justNow)
        XCTAssertEqual(ReleasePublicationTime.age(of: now.addingTimeInterval(120), now: now, calendar: utc), .absolute)
    }

    func testLocalCalendarDaysRatherThanRoundedDurations() throws {
        let iso = ISO8601DateFormatter()
        let current = try XCTUnwrap(iso.date(from: "2026-10-10T05:30:00Z"))
        let date = try XCTUnwrap(iso.date(from: "2026-10-09T03:30:00Z"))
        var newYork = utc; newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        XCTAssertEqual(ReleasePublicationTime.age(of: date, now: current, calendar: newYork), .days(2))
        XCTAssertEqual(ReleasePublicationTime.age(of: date, now: current, calendar: utc), .yesterday)
        XCTAssertEqual(ReleasePublicationTime.age(of: current.addingTimeInterval(-7_200), now: current, calendar: newYork), .hours(2))
    }

    func testDaylightSavingUsesElapsedHoursAndCalendarDates() throws {
        let iso = ISO8601DateFormatter()
        var calendar = utc; calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let current = try XCTUnwrap(iso.date(from: "2026-03-09T04:30:00Z"))
        let yesterday = try XCTUnwrap(iso.date(from: "2026-03-08T05:30:00Z"))
        XCTAssertEqual(ReleasePublicationTime.age(of: yesterday, now: current, calendar: calendar), .hours(23))
        XCTAssertEqual(ReleasePublicationTime.age(of: yesterday, now: current.addingTimeInterval(3_600), calendar: calendar), .yesterday)
    }

    func testPreciseDateIncludesYearMinutesAndActualOffset() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-10T17:00:42Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let result = ReleasePublicationTime.precise(date, locale: Locale(identifier: "en"), timeZone: zone)
        XCTAssertEqual(result, "Oct 10, 2026 13:00 (UTC−04:00)")
        let chinese = ReleasePublicationTime.precise(date, locale: Locale(identifier: "zh-Hans"), timeZone: TimeZone(secondsFromGMT: 19_800)!)
        XCTAssertTrue(chinese.contains("2026年10月10日"))
        XCTAssertTrue(chinese.contains("22:30 (UTC+05:30)"))
        XCTAssertFalse(chinese.contains(":42"))
    }

    func testInstallationSectionIsRemovedWithoutLosingLaterReleaseChanges() {
        let notes = """
        # TSX 1.2.0
        ## Improvements
        - Keep this change.
        ## Installation and notes
        Installer instructions.
        ### Requirements
        More installer text.
        ## Fixes
        - Keep this fix and [its link](https://example.invalid).
        """
        XCTAssertEqual(ReleaseNotesPresentation.content(notes, version: "1.2.0"), """
        ## Improvements
        - Keep this change.
        ## Fixes
        - Keep this fix and [its link](https://example.invalid).
        """)
    }

    func testInstallationNamesInProseDoNotRemoveChanges() {
        let notes = "## 修复\n- 修复安装与说明布局\n\n### 安装与说明\n不要显示\n#### 下载\n也不显示\n### 其他修复\n- 保留"
        XCTAssertEqual(ReleaseNotesPresentation.content(notes, version: "1.2.0"), "## 修复\n- 修复安装与说明布局\n\n### 其他修复\n- 保留")
        let upgrade = "## 安装与说明\n固定安装步骤\n## 重要升级提醒\n请先迁移配置。\n## 系统、权限与已知限制\n此版本调整了最低系统要求。"
        XCTAssertEqual(ReleaseNotesPresentation.content(upgrade, version: "2.0.0"), "## 重要升级提醒\n请先迁移配置。\n## 系统、权限与已知限制\n此版本调整了最低系统要求。")
    }

    func testDownloadVerificationSectionsPreserveUpgradeActionsInBothLanguages() {
        for (heading, warning) in [("下载与验证", "升级前须知"), ("Download and verification", "Before upgrading")] {
            let notes = "## Changes\n- Keep this change.\n## \(heading)\nDownload installer and SHA256SUMS.txt.\n## \(warning)\nMigrate the configuration first."
            XCTAssertEqual(ReleaseNotesPresentation.content(notes, version: "1.2.0"),
                           "## Changes\n- Keep this change.\n## \(warning)\nMigrate the configuration first.")
        }
    }

    func testBundledReleaseCanDecodeWithoutInventingPublicationTime() throws {
        let data = Data(#"{"version":"1.2.0","notes":"Prepared release notes","url":"https://github.com/TheoYuuu/tsx/releases/tag/v1.2.0"}"#.utf8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(AppRelease.self, from: data)
        XCTAssertNil(release.publishedAt)
        XCTAssertEqual(release.notes, "Prepared release notes")
    }

    func testBundledNotesHideInstallationInBothLanguagesAndPreserveSource() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PublishedReleaseNotes", withExtension: "json"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for release in try decoder.decode([AppRelease].self, from: Data(contentsOf: url)) {
            let original = release.notes
            for language in ["zh-Hans", "en"] {
                let notes = try XCTUnwrap(release.localizedNotes(languageIdentifier: language))
                let displayed = ReleaseNotesPresentation.content(notes, version: release.version)
                XCTAssertFalse(displayed.contains("### 安装与说明"))
                XCTAssertFalse(displayed.contains("### Installation and notes"))
                XCTAssertFalse(displayed.contains("## 下载与安装"))
                XCTAssertFalse(displayed.contains("SHA256SUMS"))
                XCTAssertFalse(displayed.contains(".dmg"))
                XCTAssertFalse(displayed.isEmpty)
            }
            XCTAssertEqual(release.notes, original)
        }
    }

    func testExplicitTitlesAndLegacyTextKeepTheirMeaning() {
        let item = ReleaseNotesPresentation.item("**窗口切换更稳定**：关闭弹窗后保留内容。")
        XCTAssertEqual(item.title, "窗口切换更稳定")
        XCTAssertEqual(item.detail, "关闭弹窗后保留内容。")
        for plain in ["旧版本的完整说明，不截断。", "**Unclosed emphasis", "Read [details](https://example.invalid)."] {
            XCTAssertNil(ReleaseNotesPresentation.item(plain).title)
            XCTAssertEqual(ReleaseNotesPresentation.item(plain).detail, plain)
        }
    }

    @MainActor
    func testResumedReadyUpdateRetainsAppcastDateWithoutFetchingNotes() {
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: true,
                                          recordsInstalledVersions: false,
                                          releases: AppReleaseNotesStore(entries: [], allowsNetworkLoading: false))
        updates.foundUpdate("2.0.0", publishedAt: now)
        updates.readyToInstall { _ in }
        XCTAssertEqual(updates.updatePresentation?.publishedAt, now)
        updates.dismissUpdate()
        updates.foundNoUpdate()
        updates.foundUpdate("2.1.0")
        updates.readyToInstall { _ in }
        XCTAssertNil(updates.updatePresentation?.publishedAt)
    }

    @MainActor
    func testAppcastPublicationDateSurvivesDownloadAndReadyPhases() {
        let updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: true,
                                          recordsInstalledVersions: false,
                                          releases: AppReleaseNotesStore(entries: [], allowsNetworkLoading: false))
        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            publishedAt: now, userInitiated: true) { _ in }
        XCTAssertEqual(updates.updatePresentation?.publishedAt, now)
        updates.downloadStarted {}
        updates.downloadExpected(100)
        updates.downloadReceived(50)
        XCTAssertEqual(updates.updatePresentation?.publishedAt, now)
        updates.readyToInstall { _ in }
        XCTAssertEqual(updates.updatePresentation?.publishedAt, now)
        updates.dismissUpdate()
        updates.offerUpdate(version: "2.1.0", informationOnly: false, informationURL: nil, userInitiated: true) { _ in }
        XCTAssertNil(updates.updatePresentation?.publishedAt, "An undated release must not inherit the previous date.")
    }
}

@MainActor
extension ReleaseNotesPresentationTests {
    func testOpeningUpdateAtEachInstallationPhaseDoesNotShowDateHint() async throws {
        for phase in [AppUpdatePresentation.Phase.available, .downloading, .extracting, .ready, .installing] {
            let updates = tooltipUpdates()
            updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                                publishedAt: now, userInitiated: true, reply: { _ in })
            switch phase {
            case .downloading: updates.downloadStarted {}
            case .extracting: updates.extractionStarted()
            case .ready: updates.readyToInstall { _ in }
            case .installing: updates.installing()
            default: break
            }
            let window = tooltipWindow(content: UpdateTooltipTestContent(updates: updates))
            defer { window.close() }
            try await assertNoAutomaticDateHint(in: window)
            XCTAssertFalse(tooltipAnchors(in: try XCTUnwrap(window.contentView)).isEmpty)
        }
    }

    func testCheckAndInstallationTransitionsDoNotShowDateHint() async throws {
        let updates = tooltipUpdates()
        updates.showUpdateCheck(cancellation: {})
        let window = tooltipWindow(content: UpdateTooltipTestContent(updates: updates))
        defer { window.close() }
        try await assertNoAutomaticDateHint(in: window)
        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            publishedAt: now, userInitiated: true, reply: { _ in })
        try await assertNoAutomaticDateHint(in: window)
        updates.downloadStarted {}
        try await assertNoAutomaticDateHint(in: window)
        updates.downloadExpected(100)
        updates.downloadReceived(50)
        try await assertNoAutomaticDateHint(in: window)
        updates.extractionStarted()
        try await assertNoAutomaticDateHint(in: window)
        updates.extractionProgress(1)
        try await assertNoAutomaticDateHint(in: window)
        updates.readyToInstall { _ in }
        try await assertNoAutomaticDateHint(in: window)
        updates.installing()
        try await assertNoAutomaticDateHint(in: window)
        updates.updateErrored()
        try await assertNoAutomaticDateHint(in: window)
        updates.dismissUpdate()
        try await assertNoAutomaticDateHint(in: window)
        updates.offerUpdate(version: "2.0.0", informationOnly: false, informationURL: nil,
                            publishedAt: now, userInitiated: true, reply: { _ in })
        try await assertNoAutomaticDateHint(in: window)
    }

    func testPublicationHintOnlyAppearsOnHoverAndLeavesWithPointer() async throws {
        let window = tooltipWindow(content: ReleaseVersionHeading(version: "2.0.0", publishedAt: now))
        defer { window.close() }
        try await assertNoAutomaticDateHint(in: window)
        let anchor = try XCTUnwrap(tooltipAnchors(in: try XCTUnwrap(window.contentView)).first)
        // Keyboard traversal must not turn descriptive publication text into
        // a focused control, even when it is the only content in the host.
        for _ in 0..<3 {
            window.selectNextKeyView(nil)
            try await assertNoAutomaticDateHint(in: window)
        }
        let responder = window.firstResponder
        let entered = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        let exited = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, trackingNumber: 0, userData: nil))
        for _ in 0..<2 {
            anchor.mouseEntered(with: entered)
            let hint = try XCTUnwrap(window.childWindows?.first)
            let label = try XCTUnwrap(hint.contentView?.subviews.first as? NSTextField)
            XCTAssertEqual(label.stringValue, ReleasePublicationTime.precise(now, locale: L10n.currentLocale,
                                                                           timeZone: .autoupdatingCurrent))
            XCTAssertTrue(window.firstResponder === responder)
            anchor.mouseExited(with: exited)
            try await assertNoAutomaticDateHint(in: window)
        }
    }

    private func tooltipUpdates() -> AppUpdateController {
        AppUpdateController(bundleIdentifier: "preview", isTesting: true, recordsInstalledVersions: false,
                            releases: AppReleaseNotesStore(entries: [], allowsNetworkLoading: false))
    }

    private func tooltipWindow<Content: View>(content: Content) -> QuickPanel {
        _ = NSApplication.shared
        let window = QuickPanel(contentRect: NSRect(x: 80, y: 80, width: 800, height: 600),
                                styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func assertNoAutomaticDateHint(in window: NSWindow,
                                         file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertTrue(window.isKeyWindow, file: file, line: line)
        // Observe multiple render/focus passes, not just the final state: an
        // automatically shown hint is a regression even if it later disappears.
        for _ in 0..<15 {
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertTrue(window.childWindows?.isEmpty ?? true, "Date hint appeared without hover", file: file, line: line)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func tooltipAnchors(in view: NSView) -> [TooltipAnchorView] {
        if let anchor = view as? TooltipAnchorView { return [anchor] }
        return view.subviews.flatMap(tooltipAnchors)
    }
}

private struct UpdateTooltipTestContent: View {
    let updates: AppUpdateController
    var body: some View {
        if let presentation = updates.updatePresentation {
            AppUpdateDialogView(updates: updates, presentation: presentation,
                                dialogSize: CGSize(width: 620, height: 520))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
