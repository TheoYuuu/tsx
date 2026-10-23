import XCTest
import Sparkle
@testable import TranslateX

final class AppReleaseNotesTests: XCTestCase {
    func testReleaseHeaderDoesNotRepeatVersionFromMarkdown() {
        XCTAssertEqual(ReleaseNotesLocalization.removingRedundantTitle("# TSX 1.0.0\n\n## Fixes\n- A fix", version: "1.0.0"), "## Fixes\n- A fix")
        XCTAssertEqual(ReleaseNotesLocalization.removingRedundantTitle("# v1.0.0\nChanges", version: "1.0.0"), "Changes")
        XCTAssertEqual(ReleaseNotesLocalization.removingRedundantTitle("# New translation features\nDetails", version: "1.0.0"), "# New translation features\nDetails")
    }

    func testProductPageMatchesSupportedInterfaceLanguage() {
        XCTAssertEqual(AppUpdateLinks.productPage(languageIdentifier: "zh-Hans").absoluteString, "https://lumaxspace.com/zh/products/tsx/")
        XCTAssertEqual(AppUpdateLinks.productPage(languageIdentifier: "en").absoluteString, "https://lumaxspace.com/products/tsx/")
        XCTAssertEqual(AppUpdateLinks.productPage(languageIdentifier: "fr").absoluteString, "https://lumaxspace.com/products/tsx/")
    }

    func testLegacyBilingualNotesKeepOnlySelectedLanguage() throws {
        let notes = "# TSX 1.0.0\n\n## 功能\n- 改进翻译\n\n---\n\n## Features\n- Improved translation\n\n---\n\nRelease maintenance note.\n\n---\n"
        let chinese = try XCTUnwrap(ReleaseNotesLocalization.content(notes, languageIdentifier: "zh-Hans"))
        let english = try XCTUnwrap(ReleaseNotesLocalization.content(notes, languageIdentifier: "en"))
        XCTAssertTrue(chinese.contains("改进翻译"))
        XCTAssertFalse(chinese.contains("Improved translation"))
        XCTAssertFalse(chinese.contains("Release maintenance"))
        XCTAssertTrue(english.hasPrefix("# TSX 1.0.0"))
        XCTAssertTrue(english.contains("Improved translation"))
        XCTAssertTrue(english.contains("Release maintenance"))
        XCTAssertFalse(english.contains("改进翻译"))
    }

    func testExplicitLanguageSectionsAndMissingLanguageDoNotFallBackToMixedText() throws {
        let notes = "# TSX 1.0.0\n\n## 简体中文\n### 修复\n修复设置\n\n## English\n### Fixes\nFixed Settings"
        let english = try XCTUnwrap(ReleaseNotesLocalization.content(notes, languageIdentifier: "en"))
        XCTAssertTrue(english.contains("Fixed Settings"))
        XCTAssertFalse(english.contains("修复设置"))
        XCTAssertNil(ReleaseNotesLocalization.content("## English\nPublished note", languageIdentifier: "zh-Hans"))
        XCTAssertNil(ReleaseNotesLocalization.content("# TSX 1.0.0\n中文说明\n---\n", languageIdentifier: "en"))
    }

    func testActualBundledReleaseSeparatesChineseAndEnglish() throws {
        let resource = try XCTUnwrap(Bundle.main.url(forResource: "PublishedReleaseNotes", withExtension: "json"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let releases = try decoder.decode([AppRelease].self, from: Data(contentsOf: resource))
        XCTAssertTrue(releases.contains { $0.version == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String })
        for release in releases {
            let chinese = try XCTUnwrap(release.localizedNotes(languageIdentifier: "zh-Hans"))
            let english = try XCTUnwrap(release.localizedNotes(languageIdentifier: "en"))
            XCTAssertTrue(chinese.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }, release.version)
            XCTAssertFalse(english.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }, release.version)
            XCTAssertFalse(chinese.contains("Repository migration"))
            XCTAssertFalse(english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @MainActor
    func testOnlyVerifiedAppcastContentIsAcceptedAndFailurePreservesNotes() {
        let bundled = AppRelease(version: "1.0.0", publishedAt: nil, notes: "Bundled", url: nil)
        let store = AppReleaseNotesStore(entries: [bundled])
        let remote = AppcastReleaseNotes(version: "1.0.0", build: "2", publishedAt: Date(timeIntervalSince1970: 42), notes: "Verified")
        for status in [SPUAppcastSigningValidationStatus.skipped, .failed] {
            store.beginLoading(force: true)
            store.receive([remote], status: status)
            XCTAssertTrue(store.failed)
            XCTAssertEqual(store.entries, [bundled])
        }
        store.receive([remote], status: .succeeded)
        XCTAssertEqual(store.entries.first?.notes, "Verified")
        XCTAssertEqual(store.entries.first?.publishedAt, Date(timeIntervalSince1970: 42))
        store.beginLoading(force: true)
        store.loadingFailed()
        XCTAssertEqual(store.entries.first?.notes, "Verified")
        XCTAssertTrue(store.failed)
    }

    @MainActor
    func testMergeUsesHighestBuildKeepsOlderBundledNotesAndRejectsEmptyOrHTMLReplacement() {
        let url = URL(string: "https://github.com/TheoYuuu/tsx/releases/tag/v1.0.0")!
        let store = AppReleaseNotesStore(entries: [
            .init(version: "1.0.0", publishedAt: nil, notes: "Bundled", url: url),
            .init(version: "0.9.0", publishedAt: nil, notes: "Older", url: nil)
        ])
        store.receive([
            .init(version: "2.0.0", build: "9", notes: "Old build"),
            .init(version: "2.0.0", build: "10", notes: "Newest build"),
            .init(version: "1.0.0", build: "2", notes: "<script>untrusted markup</script>", format: "html"),
            .init(version: "3.0.0-beta", build: "20", notes: "Beta"),
            .init(version: "3.0.0", build: "21", notes: "Beta", channel: "beta"),
            .init(version: "4.0.0", build: "invalid", notes: "Bad build")
        ], status: .succeeded)
        XCTAssertEqual(store.entries.map(\.version), ["2.0.0", "1.0.0", "0.9.0"])
        XCTAssertEqual(store.entries[0].notes, "Newest build")
        XCTAssertEqual(store.entries[1].notes, "Bundled")
        XCTAssertEqual(store.entries[1].url, url)
        store.receive([.init(version: "1.0.0", build: "3", notes: "  ")], status: .succeeded)
        XCTAssertEqual(store.entries[1].notes, "Bundled")
    }

    @MainActor
    func testSignedFullReleaseNotesLinkStillRequiresAllowedHTTPSHostAndPath() {
        let allowed = URL(string: "https://github.com/uuthings/tsx/releases/tag/v1.0.0")!
        let store = AppReleaseNotesStore(entries: [])
        store.receive([.init(version: "1.0.0", build: "1", notes: "Text", url: allowed)], status: .succeeded)
        XCTAssertEqual(store.entries.first?.url, allowed)
        for raw in ["http://github.com/uuthings/tsx/releases", "https://example.invalid/releases/v1.0.0",
                    "file:///installer", "https://github.com/another/project/releases/tag/v1.0.0",
                    "https://user@github.com/uuthings/tsx/releases", "https://github.com:444/uuthings/tsx/releases",
                    "https://github.com/uuthings/tsx/releases/../settings", "https://github.com/uuthings/tsx/releases?redirect=bad"] {
            XCTAssertNil(AppUpdateLinks.allowedReleaseURL(URL(string: raw)), raw)
        }
        store.receive([.init(version: "1.0.0", build: "2", url: URL(string: "https://example.invalid"))], status: .succeeded)
        XCTAssertEqual(store.entries.first?.url, allowed)
    }

    @MainActor
    func testBoundsRejectOversizedFeedAndSkipOversizedIndividualNotes() {
        let store = AppReleaseNotesStore(entries: [])
        store.receive(Array(repeating: .init(version: "1.0.0", build: "1"), count: 201), status: .succeeded)
        XCTAssertTrue(store.failed)
        store.receive([.init(version: "1.0.0", build: "1", notes: String(repeating: "x", count: 128 * 1024 + 1))], status: .succeeded)
        XCTAssertTrue(store.entries.isEmpty)
    }

    @MainActor
    func testPreviewDoesNotStartNetworkLoadingEvenWhenForced() {
        let store = AppReleaseNotesStore(entries: [], allowsNetworkLoading: false)
        XCTAssertFalse(store.beginLoading(force: true))
        XCTAssertFalse(store.isLoading)
    }
}
