import Foundation
import XCTest
@testable import LumaxTranslate

final class LanguageCatalogTests: XCTestCase {
    func testSimplifiedChineseAliasesShareTheDefaultPickerIdentity() {
        for identifier in ["zh", "zh-CN", "zh-SG", "zh-Hans", "zh-Hans-CN", "zh_Hans"] {
            XCTAssertEqual(LanguageCatalog.canonicalIdentifier(identifier), "zh-Hans", identifier)
        }
    }

    func testTraditionalChineseRemainsDistinctFromSimplified() {
        for identifier in ["zh-TW", "zh-HK", "zh-MO", "zh-Hant", "zh-Hant-TW"] {
            XCTAssertEqual(LanguageCatalog.canonicalIdentifier(identifier), "zh-Hant", identifier)
        }
        XCTAssertNotEqual(LanguageCatalog.canonicalIdentifier("zh"), LanguageCatalog.canonicalIdentifier("zh-TW"))
    }

    func testExplicitChineseScriptTakesPrecedenceOverRegion() {
        XCTAssertEqual(LanguageCatalog.canonicalIdentifier("zh-Hans-TW"), "zh-Hans")
        XCTAssertEqual(LanguageCatalog.canonicalIdentifier("zh-Hant-CN"), "zh-Hant")
        XCTAssertNotEqual(LanguageCatalog.canonicalIdentifier("yue"), "zh-Hant")
    }

    func testEnglishAliasesCollapseWithoutLosingDifferentRegions() {
        XCTAssertEqual(LanguageCatalog.canonicalIdentifier("en-US"), LanguageCatalog.canonicalIdentifier("en"))
        XCTAssertEqual(LanguageCatalog.canonicalIdentifier("en-Latn-US"), LanguageCatalog.canonicalIdentifier("en"))
        XCTAssertEqual(LanguageCatalog.canonicalIdentifier("en_GB"), "en-GB")
        XCTAssertEqual(LanguageCatalog.canonicalIdentifier("en-AU"), "en-AU")
        XCTAssertNotEqual(LanguageCatalog.canonicalIdentifier("en-US"), LanguageCatalog.canonicalIdentifier("en-GB"))
        XCTAssertNotEqual(LanguageCatalog.canonicalIdentifier("en-GB"), LanguageCatalog.canonicalIdentifier("en-AU"))
    }

    func testDynamicCatalogueDeduplicatesOnlyEquivalentIdentities() {
        let source = ["zh", "zh-Hans", "zh-TW", "zh-Hant", "en", "en-US", "en-GB"]
            .map { Locale.Language(identifier: $0) }
        let languages = LanguageCatalog.normalizedLanguages(source, locale: Locale(identifier: "en"))
        XCTAssertEqual(Set(languages.map(\.id)), ["zh-Hans", "zh-Hant", "en", "en-GB"])
        XCTAssertEqual(languages.count, 4)
    }

    func testCatalogueNeverAddsAnUnsupportedDefault() {
        XCTAssertTrue(LanguageCatalog.normalizedLanguages([]).isEmpty)
        let languages = LanguageCatalog.normalizedLanguages([Locale.Language(identifier: "fr")])
        XCTAssertEqual(languages.map(\.id), ["fr"])
    }

    func testChineseDisplayNamesIdentifyScriptsInBothUILanguages() {
        let chinese = Locale(identifier: "zh-Hans")
        let english = Locale(identifier: "en")
        XCTAssertTrue(LanguageCatalog.displayName(for: "zh", locale: chinese).contains("简体"))
        XCTAssertTrue(LanguageCatalog.displayName(for: "zh-TW", locale: chinese).contains("繁体"))
        XCTAssertTrue(LanguageCatalog.displayName(for: "zh", locale: english).contains("Simplified"))
        XCTAssertTrue(LanguageCatalog.displayName(for: "zh-TW", locale: english).contains("Traditional"))
        XCTAssertNotEqual(
            LanguageCatalog.displayName(for: "zh", locale: chinese),
            LanguageCatalog.displayName(for: "zh", locale: english)
        )
    }

    func testRegionalEnglishDisplayNamesStayDistinct() {
        let locale = Locale(identifier: "en")
        XCTAssertNotEqual(
            LanguageCatalog.displayName(for: "en-US", locale: locale),
            LanguageCatalog.displayName(for: "en-GB", locale: locale)
        )
        XCTAssertTrue(LanguageCatalog.displayName(for: "en-GB", locale: locale).contains("United Kingdom"))
    }

    func testRepeatedNormalizationIsStableForSourceAndResponseValues() {
        for identifier in ["zh", "zh-TW", "zh-Hans", "zh-Hant", "en-US", "en-GB", "pt-BR", "iw"] {
            let canonical = LanguageCatalog.canonicalIdentifier(identifier)
            XCTAssertEqual(LanguageCatalog.canonicalIdentifier(canonical), canonical, identifier)
        }
    }

    func testAutomaticAndEmptyInputAreNotReinterpretedAsLanguages() {
        XCTAssertEqual(LanguageCatalog.canonicalIdentifier("auto"), "auto")
        XCTAssertEqual(LanguageCatalog.canonicalIdentifier(" \n"), "")
    }
}
