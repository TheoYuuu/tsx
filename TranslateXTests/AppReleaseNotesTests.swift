import XCTest
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

    func testOnlyPublishedStableReleasesBecomeNotes() throws {
        let data = Data("""
        [
          {"tag_name":"v1.0.0","published_at":"2026-01-01T00:00:00Z","body":"- Public feature","html_url":"https://github.com/TheoYuuu/tsx/releases/tag/v1.0.0","draft":false,"prerelease":false},
          {"tag_name":"v2.0.0","published_at":null,"body":"draft","html_url":"https://github.com/TheoYuuu/tsx/releases/tag/v2.0.0","draft":true,"prerelease":false},
          {"tag_name":"v2.0.0-beta","published_at":"2026-02-01T00:00:00Z","body":"beta","html_url":"https://github.com/TheoYuuu/tsx/releases/tag/v2.0.0-beta","draft":false,"prerelease":true}
        ]
        """.utf8)
        let result = try AppReleaseNotesClient.decodePage(data)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.releases.map(\.version), ["1.0.0"])
        XCTAssertEqual(result.releases.first?.notes, "- Public feature")
    }

    func testForeignReleaseLinksAndOversizedNotesAreRejected() {
        for link in ["https://example.invalid/releases/v1.0.0", "file:///installer", "https://github.com/another/project/releases/tag/v1.0.0"] {
            let data = Data("""
            [{"tag_name":"v1.0.0","published_at":"2026-01-01T00:00:00Z","body":"text","html_url":"\(link)","draft":false,"prerelease":false}]
            """.utf8)
            XCTAssertThrowsError(try AppReleaseNotesClient.decodePage(data))
        }
        XCTAssertThrowsError(try AppReleaseNotesClient.decodePage(Data(repeating: 32, count: 2 * 1_024 * 1_024 + 1)))
    }

    @MainActor
    func testNetworkFailurePreservesShippedNotesAndAllowsRetry() async {
        enum FixtureError: Error { case unavailable }
        let entry = AppRelease(version: "1.0.0", publishedAt: .distantPast, notes: "Published note",
                               url: URL(string: "https://github.com/TheoYuuu/tsx/releases/tag/v1.0.0")!)
        let store = AppReleaseNotesStore(entries: [entry], loader: { throw FixtureError.unavailable })
        await store.load()
        XCTAssertTrue(store.failed)
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.hasLoaded)
        XCTAssertEqual(store.entries, [entry])
    }

    @MainActor
    func testAllFetchedVersionsRemainAvailable() async {
        let entries = ["1.2.0", "1.1.0", "1.0.0"].map { version in
            AppRelease(version: version, publishedAt: .distantPast, notes: "Published \(version)",
                       url: URL(string: "https://github.com/TheoYuuu/tsx/releases/tag/v\(version)")!)
        }
        let store = AppReleaseNotesStore(entries: [], loader: { entries })
        await store.load()
        XCTAssertEqual(store.entries.map(\.version), ["1.2.0", "1.1.0", "1.0.0"])
        XCTAssertTrue(store.hasLoaded)
    }

    @MainActor
    func testIsolatedPreviewNeverInvokesNetworkLoaderEvenWhenForced() async {
        actor Counter {
            var calls = 0
            func increment() { calls += 1 }
        }
        let counter = Counter()
        let store = AppReleaseNotesStore(entries: [], allowsNetworkLoading: false, loader: {
            await counter.increment()
            return []
        })
        await store.load()
        await store.load(force: true)
        let calls = await counter.calls
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(store.hasLoaded)
        XCTAssertFalse(store.failed)
    }
}
