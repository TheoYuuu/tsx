import XCTest
@testable import TranslateX

final class ReleaseNotesPresentationTests: XCTestCase {
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
