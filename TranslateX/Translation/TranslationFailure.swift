import Foundation
import Translation

enum TranslationFailure: Equatable {
    case cancelled, noText, unsupportedSource, unsupportedTarget, unsupportedPair
    case unidentifiedSource, networkUnavailable, languagePreparation, system

    static func classify(_ error: any Error, preparingLanguages: Bool) -> Self {
        if error is CancellationError { return .cancelled }
        if let cocoa = error as? CocoaError, cocoa.code == .userCancelled { return .cancelled }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled: return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost:
                return .networkUnavailable
            default: break
            }
        }
        if #available(macOS 26, *) {
            if TranslationError.alreadyCancelled ~= error { return .cancelled }
            if TranslationError.notInstalled ~= error { return .languagePreparation }
        }
        switch error {
        case TranslationError.nothingToTranslate: return .noText
        case TranslationError.unsupportedSourceLanguage: return .unsupportedSource
        case TranslationError.unsupportedTargetLanguage: return .unsupportedTarget
        case TranslationError.unsupportedLanguagePairing: return .unsupportedPair
        case TranslationError.unableToIdentifyLanguage: return .unidentifiedSource
        default: return preparingLanguages ? .languagePreparation : .system
        }
    }

    /// Never echo the SDK's error description: it may contain user text.
    var message: String {
        let key: String
        switch self {
        case .cancelled: key = "Translation cancelled"
        case .noText: key = "No translatable text was found"
        case .unsupportedSource: key = "The source language isn’t supported. Choose another source language."
        case .unsupportedTarget: key = "The target language isn’t supported. Choose another target language."
        case .unsupportedPair: key = "This language pair isn’t available. Choose another language."
        case .unidentifiedSource: key = "The source language is unclear. Choose it manually and try again."
        case .networkUnavailable: key = "A network connection is needed to prepare language files. Check your connection and try again."
        case .languagePreparation: key = "Language preparation didn’t finish. Try again to check or download the required files."
        case .system: key = "Translation couldn’t finish. Please try again."
        }
        return L10n.string(key)
    }
}
