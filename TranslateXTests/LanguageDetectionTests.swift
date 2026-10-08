import NaturalLanguage
import XCTest
@testable import TranslateX

@MainActor
final class LanguageDetectionTests: XCTestCase {
    private let sharedChinese = "清晰的句子很容易理解。"
    private let splitConfidence: [NLLanguage: Double] = [
        .traditionalChinese: 0.592,
        .simplifiedChinese: 0.404,
        .japanese: 0.004
    ]

    func testRealSharedChineseCreatesAnExplicitSourceRequest() throws {
        let model = TranslationModel()
        model.target = "en"
        model.text = sharedChinese
        model.submit()

        let request = try XCTUnwrap(model.request)
        XCTAssertEqual(request.text, sharedChinese)
        XCTAssertTrue(["zh-Hans", "zh-Hant"].contains(try XCTUnwrap(request.source)))
        XCTAssertNotNil(model.configuration?.source)
        XCTAssertEqual(model.phase, .translating)
    }

    func testRealSharedChineseMatchesTheDefaultSimplifiedTarget() {
        let model = TranslationModel()
        model.text = sharedChinese
        model.submit()

        XCTAssertEqual(model.phase, .unchanged)
        XCTAssertEqual(model.translatedText, sharedChinese)
        XCTAssertNil(model.request)
        XCTAssertNil(model.configuration)
        XCTAssertNil(model.result)
    }

    func testChangingTargetRechecksSharedChineseBeforeCreatingASession() {
        let model = TranslationModel()
        model.text = sharedChinese
        model.target = "zh-Hant"
        model.submit()
        XCTAssertEqual(model.phase, .unchanged)
        XCTAssertEqual(model.translatedText, sharedChinese)
        XCTAssertNil(model.request)
        XCTAssertNil(model.configuration)
    }

    func testSharedChineseCanMatchEitherTargetWithoutInventingAResult() {
        for target in ["zh-Hans", "zh-Hant", "zh-CN", "zh-TW"] {
            XCTAssertEqual(
                resolveSharedChinese(target: target),
                LanguageCatalog.canonicalIdentifier(target)
            )
        }
        XCTAssertEqual(resolveSharedChinese(target: "en"), "zh-Hant")
    }

    func testChineseConfidenceMustBeStrongInAggregate() {
        let uncertain: [NLLanguage: Double] = [
            .traditionalChinese: 0.50, .simplifiedChinese: 0.40, .japanese: 0.10
        ]
        XCTAssertNil(TranslationModel.resolveLanguage(
            sharedChinese, dominant: .traditionalChinese, hypotheses: uncertain, target: "zh-Hans"
        ))
    }

    func testSharedChineseFallbackRequiresAtLeastEightHanCharacters() {
        let sevenCharacters = "清晰句子好理解"
        let eightCharacters = "清晰的句子好理解"
        XCTAssertEqual(sevenCharacters.count, 7)
        XCTAssertEqual(eightCharacters.count, 8)
        for text in [sevenCharacters, sevenCharacters + "。1234567890！"] {
            XCTAssertNil(TranslationModel.resolveLanguage(
                text, dominant: .traditionalChinese, hypotheses: splitConfidence, target: "zh-Hans"
            ))
        }
        XCTAssertEqual(TranslationModel.resolveLanguage(
            eightCharacters, dominant: .traditionalChinese, hypotheses: splitConfidence, target: "zh-Hans"
        ), "zh-Hans")
    }

    func testRealShortJapaneseChineseSharedWordUsesInlineLanguageChoice() {
        let model = TranslationModel()
        model.text = "得意"
        model.submit()
        XCTAssertNil(model.request)
        XCTAssertNil(model.configuration)
        XCTAssertTrue(model.needsSourceLanguage)
        XCTAssertEqual(model.phase, .empty)
    }

    func testConfidenceThresholdForOtherLanguagesIsUnchanged() {
        XCTAssertNil(TranslationModel.resolveLanguage(
            "bonjour hello", dominant: .french, hypotheses: [.french: 0.64, .english: 0.36]
        ))
        XCTAssertEqual(TranslationModel.resolveLanguage(
            "bonjour hello", dominant: .french, hypotheses: [.french: 0.65, .english: 0.35]
        ), "fr")
    }

    func testLowConfidenceDistinctChineseFormsKeepTheSelectionFallback() {
        for text in ["这里有简体汉字。", "這裡有繁體漢字。", "这里有繁體漢字。"] {
            XCTAssertNil(TranslationModel.resolveLanguage(
                text, dominant: .traditionalChinese, hypotheses: splitConfidence, target: "zh-Hans"
            ))
        }
    }

    func testRealDistinctChineseScriptsRemainDifferent() {
        let simplified = "今天的天气很好，我们一起出去散步吧。"
        let traditional = "今天的天氣很好，我們一起出去散步吧。"
        XCTAssertEqual(TranslationModel.detectLanguage(simplified, target: "zh-Hant"), "zh-Hans")
        XCTAssertEqual(TranslationModel.detectLanguage(traditional, target: "zh-Hans"), "zh-Hant")

        let model = TranslationModel()
        model.text = traditional
        model.submit()
        XCTAssertEqual(model.request?.source, "zh-Hant")
        XCTAssertEqual(model.phase, .translating)
    }

    func testMixedAlphabeticTextCannotBecomeASameLanguageShortcut() {
        for suffix in ["Hello world.", "かな", "한국어", "Привет"] {
            XCTAssertNil(TranslationModel.resolveLanguage(
                sharedChinese + suffix,
                dominant: .traditionalChinese,
                hypotheses: splitConfidence,
                target: "zh-Hans"
            ))
        }
    }

    func testChineseDominantMixedTextStillCreatesAnEnglishTranslationRequest() {
        let model = TranslationModel()
        model.text = sharedChinese + "Hello world."
        model.submit()
        XCTAssertEqual(model.request?.text, model.text)
        XCTAssertEqual(model.request?.source, "en")
        XCTAssertEqual(model.request?.target, "zh-Hans")
        XCTAssertNotNil(model.configuration?.source)
        XCTAssertFalse(model.needsSourceLanguage)
        XCTAssertEqual(model.phase, .translating)
    }

    func testNumbersOrSymbolsCannotGainAnInventedLanguageEvenAtHighConfidence() {
        for text in ["123123", "1234567890", "１２３", "١٢٣", "😀 🌷", "...", " "] {
            XCTAssertNil(TranslationModel.detectLanguage(text))
            XCTAssertNil(TranslationModel.resolveLanguage(
                text, dominant: .traditionalChinese, hypotheses: splitConfidence, target: "zh-Hans"
            ))
            XCTAssertNil(TranslationModel.resolveLanguage(text, dominant: .english, hypotheses: [.english: 1]))
        }
    }

    func testAmbiguousAlphabeticTextAsksForAChoiceWithoutStartingAnAppleSession() {
        for text in ["今日仕事"] {
            let model = TranslationModel()
            model.text = text
            model.submit()
            XCTAssertNil(model.request)
            XCTAssertNil(model.configuration)
            XCTAssertTrue(model.needsSourceLanguage)
            XCTAssertEqual(model.phase, .empty)
        }
    }

    func testNumbersWithinTextAndWrittenNumbersRemainTranslatable() {
        for (text, source) in [("There are 123 apples.", "en"), ("一百二十三", "zh-Hans"), ("百二十三", "ja")] {
            let model = TranslationModel()
            model.source = source
            model.target = source == "en" ? "zh-Hans" : "en"
            model.text = text
            model.submit()
            XCTAssertTrue(model.canTranslate)
            XCTAssertEqual(model.request?.text, text)
            XCTAssertEqual(model.request?.source, source)
        }
    }

    func testHighConfidenceEnglishAndJapaneseDetectionRemainUnchanged() {
        XCTAssertEqual(TranslationModel.detectLanguage("A clear sentence is easy to understand."), "en")
        XCTAssertEqual(TranslationModel.detectLanguage("漢字の文章です。", target: "zh-Hans"), "ja")
    }

    func testMixedChineseEnglishKeepsFullContextRegardlessOfOrderOrLineBreaks() {
        for text in [
            "789哈哈\nHelloKitty\nhello, where?", "hello, where?\nHelloKitty\n789哈哈",
            "789哈哈\nhellokitty\nhello, where?", "789哈哈\nHELLOKITTY\nhello, where?",
            "789哈哈\nHELLOKITTY ☀️\nhello, where?",
            "请点击 Save 后继续。", "你好，hello", "你好，hello ☀️ 1️⃣", "Hello 世界", "HelloKitty", "a",
            "预约成功。\r\n\r\nBring a blue notebook.\r\n费用 25 元。"
        ] {
            let model = TranslationModel()
            model.text = text
            model.submit()
            XCTAssertEqual(model.request?.text, text, "Recognition must never rewrite the submitted passage")
            XCTAssertEqual(model.request?.source, "en", text)
            XCTAssertEqual(model.request?.target, "zh-Hans")
            XCTAssertEqual(model.source, "auto")
            XCTAssertEqual(model.target, "zh-Hans")
            XCTAssertFalse(model.needsSourceLanguage)
            XCTAssertEqual(model.phase, .translating)
        }
    }

    func testMixedTextCanTranslateTowardsEnglishAndRetargetWithoutStaleDetection() {
        let model = TranslationModel()
        model.text = "会议在九点开始。Please bring a blue notebook."
        model.submit()
        XCTAssertEqual(model.request?.source, "en")
        model.target = "en"
        model.submit()
        XCTAssertTrue(["zh-Hans", "zh-Hant"].contains(model.request?.source ?? ""))
        XCTAssertEqual(model.request?.target, "en")
        XCTAssertEqual(model.request?.text, model.text)
        model.target = "zh-Hans"
        model.submit()
        XCTAssertEqual(model.request?.source, "en")
    }

    func testMixedLatinLanguagesDoNotBecomeASameLanguageCopy() {
        let model = TranslationModel()
        model.target = "en"
        model.text = "The workshop begins on Monday. Please bring a blue notebook and a pen.\nBonjour, comment allez-vous ?"
        model.submit()
        XCTAssertEqual(model.request?.source, "fr")
        XCTAssertEqual(model.request?.text, model.text)
        XCTAssertEqual(model.phase, .translating)
    }

    func testClearNonEnglishDetectionIsNotForcedToEnglishOrInstalledLanguages() {
        for (text, language) in [
            ("你好，Bonjour", "fr"), ("你好，Hallo", "de"),
            ("你好，Olen suomalainen ja puhun suomea.", "fi"),
            ("你好，hallo waar ben je", "nl"), ("你好，漢字の文章です。", "ja")
        ] {
            XCTAssertEqual(TranslationModel.detectLanguage(text, target: "zh-Hans"), language, text)
        }
    }

    func testAmbiguousEnglishInterfaceLabelsDoNotSelectAnUnrelatedLanguage() {
        for text in ["Datacenter\nMobile\nWeb Unblocker", "Web Unblocker", "Search\nSettings\nAccount"] {
            let model = TranslationModel()
            model.text = text
            model.submit()
            XCTAssertEqual(model.request?.source, "en", text)
            XCTAssertEqual(model.request?.text, text)
            XCTAssertEqual(model.source, "auto")
        }
        for (text, language) in [
            ("Bonjour", "fr"), ("Hallo", "de"),
            ("Ini adalah contoh kalimat dalam bahasa Indonesia.", "id")
        ] {
            XCTAssertEqual(TranslationModel.detectLanguage(text, target: "zh-Hans"), language)
        }
    }

    func testExplicitSourcePairRemainsAuthoritativeForMixedContent() {
        let model = TranslationModel()
        model.source = "de"
        model.text = "你好，hello"
        model.submit()
        XCTAssertEqual(model.request?.source, "de")
        XCTAssertEqual(model.request?.text, model.text)
    }

    func testSameSelectedLanguagesDoNotSuppressForeignWordsOnEitherSide() {
        for side in [TranslationSide.source, .target] {
            let model = TranslationModel()
            model.source = "zh-Hans"
            model.editingChanged("请点击 Save 后继续。", isComposing: false, side: side)
            model.submit()
            XCTAssertEqual(model.phase, .translating)
            XCTAssertEqual(model.request?.source, "en")
            XCTAssertEqual(model.request?.target, "zh-Hans")
            XCTAssertEqual(model.request?.text, "请点击 Save 后继续。")
        }
    }

    private func resolveSharedChinese(target: String) -> String? {
        TranslationModel.resolveLanguage(
            sharedChinese, dominant: .traditionalChinese, hypotheses: splitConfidence, target: target
        )
    }
}
