import Foundation
import Observation
import Synchronization
import Translation
import XCTest
@testable import TranslateX

@MainActor
final class LocalizationMessageTests: XCTestCase {
    func testAppOwnedFailureRemainsLocalizableAcrossWindowHandoff() async throws {
        let original = AppInterfaceLanguage(rawValue: L10n.currentLanguageIdentifier)!
        defer { L10n.apply(original) }
        L10n.apply(.english)
        let key = "Some shortcuts are unavailable. Change them in Settings."
        let source = TranslationModel()
        source.text = "Settings"
        source.fail(localized: key)
        let handoff = try XCTUnwrap(source.makeHandoff())
        let destination = TranslationModel()
        destination.acceptHandoff(handoff)
        XCTAssertEqual(source.phase, .failed(key))
        XCTAssertEqual(destination.phase, .failed(key))

        let changes = Mutex(0)
        withObservationTracking {
            _ = destination.phase
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        L10n.apply(.simplifiedChinese)
        XCTAssertEqual(source.phase, .failed("部分快捷键暂不可用，请在设置中更换组合。"))
        XCTAssertEqual(destination.phase, source.phase)
        XCTAssertEqual(changes.withLock { $0 }, 1)
        XCTAssertEqual(destination.text, "Settings")
        XCTAssertNil(destination.request)
        XCTAssertNil(destination.configuration)

        destination.fail("Settings")
        L10n.apply(.english)
        L10n.apply(.simplifiedChinese)
        XCTAssertEqual(destination.phase, .failed("Settings"), "Literal failures must not be guessed to be localization keys")
        let literalReceiver = TranslationModel()
        literalReceiver.acceptHandoff(destination.makeHandoff())
        XCTAssertEqual(literalReceiver.phase, .failed("Settings"))
    }

    func testAppleRemoteAndAccountFailuresRelocalizeWithoutRerunningProviders() async throws {
        let original = AppInterfaceLanguage(rawValue: L10n.currentLanguageIdentifier)!
        defer { L10n.apply(original) }
        let cases: [(any Error, String)] = [
            (TranslationError.unsupportedSourceLanguage, "The source language isn’t supported. Choose another source language."),
            (RemoteTranslationError.offline, "translationService.error.offline"),
            (CodexAccountError.networkUnavailable, "codexAccount.error.networkUnavailable")
        ]
        for (error, key) in cases {
            L10n.apply(.english)
            let model = pendingModel()
            let provider = LocalizationMessageProvider(error: error)
            await model.run(try XCTUnwrap(model.request), provider: provider)
            let englishFailure = model.phase
            XCTAssertEqual(englishFailure, .failed(L10n.string(key)))
            XCTAssertEqual(provider.calls, 1)
            let receiver = TranslationModel()
            receiver.acceptHandoff(try XCTUnwrap(model.makeHandoff()))

            L10n.apply(.simplifiedChinese)
            XCTAssertEqual(model.phase, .failed(L10n.string(key)))
            XCTAssertNotEqual(model.phase, englishFailure)
            XCTAssertEqual(receiver.phase, model.phase)
            XCTAssertEqual(provider.calls, 1)
            XCTAssertEqual(model.text, "A constructed localization test passage.")
            XCTAssertNil(model.request)
            XCTAssertNil(receiver.request)
        }
    }

    func testCompletedContentAndUserApplicationNameNeverBecomeLocalizedLabels() async throws {
        let original = AppInterfaceLanguage(rawValue: L10n.currentLanguageIdentifier)!
        defer { L10n.apply(original) }
        L10n.apply(.english)
        let model = pendingModel(text: "Settings")
        model.sourceName = "Screenshot"
        let provider = LocalizationMessageProvider(result: TranslationResult(text: "Follow System", source: "en", target: "fr"))
        let request = try XCTUnwrap(model.request)
        await model.run(request, provider: provider)
        let configuration = model.configuration
        let result = model.result
        XCTAssertEqual(model.statusMessage, "Updated")

        L10n.apply(.simplifiedChinese)
        XCTAssertEqual(model.statusMessage, "已更新")
        XCTAssertEqual(model.text, "Settings")
        XCTAssertEqual(model.translatedText, "Follow System")
        XCTAssertEqual(model.sourceName, "Screenshot")
        XCTAssertEqual(model.result, result)
        XCTAssertEqual(model.phase, .completed)
        XCTAssertEqual(model.request, request)
        XCTAssertEqual(model.configuration, configuration)
        XCTAssertEqual(model.source, "en")
        XCTAssertEqual(model.target, "fr")
        XCTAssertEqual(provider.calls, 1)

        model.setAutomaticTranslation(false)
        let chineseStatus = model.statusMessage
        L10n.apply(.english)
        XCTAssertEqual(model.statusMessage, "Automatic translation off · Both sides remain editable")
        XCTAssertNotEqual(model.statusMessage, chineseStatus)
        XCTAssertEqual(model.translatedText, "Follow System")
        XCTAssertEqual(provider.calls, 1)
    }

    func testScreenshotSourceLabelHasExplicitIdentitySeparateFromApplicationNames() async {
        let original = AppInterfaceLanguage(rawValue: L10n.currentLanguageIdentifier)!
        defer { L10n.apply(original) }
        L10n.apply(.english)
        let model = TranslationModel()
        model.useScreenshotSourceName()
        XCTAssertEqual(model.sourceName, "Screenshot")
        L10n.apply(.simplifiedChinese)
        XCTAssertEqual(model.sourceName, "截图")

        for applicationName in ["Screenshot", "截图", "Settings", "Follow System"] {
            model.sourceName = applicationName
            L10n.apply(.english)
            XCTAssertEqual(model.sourceName, applicationName)
            L10n.apply(.simplifiedChinese)
            XCTAssertEqual(model.sourceName, applicationName)
        }
    }

    private func pendingModel(text: String = "A constructed localization test passage.") -> TranslationModel {
        let model = TranslationModel()
        model.source = "en"
        model.target = "fr"
        model.text = text
        model.submit()
        return model
    }
}

@MainActor
private final class LocalizationMessageProvider: TranslationProvider {
    private let error: (any Error)?
    private let result: TranslationResult?
    private(set) var calls = 0

    init(error: any Error) { self.error = error; result = nil }
    init(result: TranslationResult) { self.result = result; error = nil }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        calls += 1
        if let error { throw error }
        return try XCTUnwrap(result)
    }
}
