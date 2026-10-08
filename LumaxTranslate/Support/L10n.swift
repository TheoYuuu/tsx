import Foundation
import Observation
import Synchronization

enum AppInterfaceLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    /// Locale.preferredLanguages includes the per-app language chosen in macOS.
    /// Do not use Bundle's development-language fallback to resolve preferences:
    /// an unsupported preferred language must not silently select Chinese.
    func resolvedLanguageIdentifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard self == .system else { return rawValue }
        for identifier in preferredLanguages {
            let language = Locale.Language(identifier: identifier)
            switch language.languageCode?.identifier {
            case "en": return AppInterfaceLanguage.english.rawValue
            case "zh" where language.script?.identifier == "Hans":
                return AppInterfaceLanguage.simplifiedChinese.rawValue
            default: continue
            }
        }
        return AppInterfaceLanguage.english.rawValue
    }
}

enum L10n {
    static let didChangeNotification = Notification.Name("TSXInterfaceLanguageDidChange")

    private static let state = InterfaceLocalizationState()
    private static let bundles: [String: Bundle] = Dictionary(uniqueKeysWithValues:
        [AppInterfaceLanguage.simplifiedChinese.rawValue, AppInterfaceLanguage.english.rawValue].compactMap { identifier in
            guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { return nil }
            return (identifier, bundle)
        }
    )

    static var currentLanguageIdentifier: String { state.languageIdentifier }
    static var currentLocale: Locale { Locale(identifier: currentLanguageIdentifier) }

    /// App assembly applies the persisted preference before constructing UI.
    /// This does not change AppleLanguages, translation targets, or app identity.
    @MainActor @discardableResult
    static func apply(
        _ language: AppInterfaceLanguage, preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Bool {
        let identifier = language.resolvedLanguageIdentifier(preferredLanguages: preferredLanguages)
        guard state.setLanguageIdentifier(identifier) else { return false }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        return true
    }

    static func string(_ key: String) -> String {
        let identifier = currentLanguageIdentifier
        let fallback = bundles[AppInterfaceLanguage.english.rawValue]?
            .localizedString(forKey: key, value: key, table: nil) ?? key
        return bundles[identifier]?.localizedString(forKey: key, value: fallback, table: nil) ?? fallback
    }
}

/// Error descriptions can be read off the main actor. The mutex protects their
/// language snapshot; Observation also tracks L10n.string calls made in a SwiftUI
/// body, so dynamic labels refresh without replacing editors or session hosts.
private final class InterfaceLocalizationState: Observable, Sendable {
    private let registrar = ObservationRegistrar()
    private let storage = Mutex(AppInterfaceLanguage.system.resolvedLanguageIdentifier())

    var languageIdentifier: String {
        registrar.access(self, keyPath: \.languageIdentifier)
        return storage.withLock { $0 }
    }

    @MainActor
    func setLanguageIdentifier(_ identifier: String) -> Bool {
        guard storage.withLock({ $0 != identifier }) else { return false }
        registrar.withMutation(of: self, keyPath: \.languageIdentifier) {
            storage.withLock { $0 = identifier }
        }
        return true
    }
}
