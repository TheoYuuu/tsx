import Translation
import XCTest
@testable import TranslateX

final class TranslationFailureTests: XCTestCase {
    func testKnownLanguageErrorsHaveSpecificGuidance() {
        XCTAssertEqual(TranslationFailure.classify(TranslationError.unsupportedSourceLanguage, preparingLanguages: false), .unsupportedSource)
        XCTAssertEqual(TranslationFailure.classify(TranslationError.unsupportedTargetLanguage, preparingLanguages: false), .unsupportedTarget)
        XCTAssertEqual(TranslationFailure.classify(TranslationError.unsupportedLanguagePairing, preparingLanguages: false), .unsupportedPair)
        XCTAssertEqual(TranslationFailure.classify(TranslationError.unableToIdentifyLanguage, preparingLanguages: false), .unidentifiedSource)
        XCTAssertEqual(TranslationFailure.classify(TranslationError.nothingToTranslate, preparingLanguages: false), .noText)
    }

    func testUserCancellationIsNotPresentedAsSystemFailure() {
        for error in [CancellationError(), CocoaError(.userCancelled), URLError(.cancelled)] as [any Error] {
            XCTAssertEqual(TranslationFailure.classify(error, preparingLanguages: true), .cancelled)
        }
    }

    func testUnknownFailureIsNotAssumedToBeNetworkOrCancellation() {
        XCTAssertEqual(TranslationFailure.classify(TranslationError.internalError, preparingLanguages: false), .system)
        XCTAssertEqual(TranslationFailure.classify(TranslationError.internalError, preparingLanguages: true), .languagePreparation)
        XCTAssertEqual(TranslationFailure.classify(URLError(.notConnectedToInternet), preparingLanguages: true), .networkUnavailable)
    }

    func testArbitraryErrorDescriptionNeverBecomesUserFacingText() {
        let error = NSError(domain: "synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: "PRIVATE-SAMPLE-MARKER"])
        let failure = TranslationFailure.classify(error, preparingLanguages: false)
        XCTAssertFalse(failure.message.contains("PRIVATE-SAMPLE-MARKER"))
    }
}
