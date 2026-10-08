import Foundation

/// Deliberately bounded initial support, not a claim to implement each vendor's
/// entire current catalogue. No network request is made by opening a picker.
/// DeepL catalogue: https://developers.deepl.com/docs/getting-started/supported-languages
/// Core/variant reference: https://github.com/DeepL/deepl-cli/blob/e6aa435b20279769f9c27ab63fca47e07679560e/src/data/language-entries.ts
/// Azure facts: GET https://api.cognitive.microsofttranslator.com/languages?api-version=3.0&scope=translation (2026-09-26).
/// Source/target variants: https://developers.deepl.com/docs/languages/using-the-languages-api
/// https://learn.microsoft.com/en-us/azure/ai-services/translator/text-translation/reference/v3/languages
nonisolated enum DedicatedTranslationLanguages {
    static func identifiers(for kind: TranslationServiceKind, asTarget: Bool) -> [String] {
        Array(mapping(for: kind, asTarget: asTarget).keys).sorted()
    }

    static func code(for identifier: String, kind: TranslationServiceKind, asTarget: Bool) -> String? {
        mapping(for: kind, asTarget: asTarget)[LanguageCatalog.canonicalIdentifier(identifier)]
    }

    static func detectedSourceIdentifier(from code: String, kind: TranslationServiceKind) -> String? {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // DeepL's ZH does not identify the script. Foundation would infer Hans,
        // which could label traditional Chinese incorrectly and enable a bad swap.
        if kind == .deepL && code.caseInsensitiveCompare("ZH") == .orderedSame { return nil }
        let matches = mapping(for: kind, asTarget: false).filter {
            $0.value.caseInsensitiveCompare(code) == .orderedSame
        }.map(\.key)
        let canonical = LanguageCatalog.canonicalIdentifier(code)
        if matches.contains(canonical) { return canonical }
        return matches.count == 1 ? matches.first : nil
    }

    private static func mapping(for kind: TranslationServiceKind, asTarget: Bool) -> [String: String] {
        switch kind {
        case .deepL: return asTarget ? deepLTargets : deepLSources
        case .azureTranslator: return azure
        default: return [:]
        }
    }

    private static let deepLCommon = [
        "ar", "bg", "cs", "da", "de", "el", "es", "et", "fi", "fr", "he", "hu", "id", "it",
        "ja", "ko", "lt", "lv", "nb", "nl", "pl", "ro", "ru", "sk", "sl", "sv", "tr", "uk", "vi"
    ]

    private static let deepLSources: [String: String] = {
        var values = Dictionary(uniqueKeysWithValues: deepLCommon.map { ($0, $0.uppercased()) })
        // DeepL accepts base source codes; regional targets have no distinct
        // source engine. Known app variants explicitly map to that base code.
        values.merge([
            "en": "EN", "en-GB": "EN", "pt": "PT", "pt-PT": "PT",
            "zh-Hans": "ZH", "zh-Hant": "ZH", "de-CH": "DE", "es-419": "ES", "fr-CA": "FR"
        ]) { _, new in new }
        return values
    }()

    private static let deepLTargets: [String: String] = {
        var values = Dictionary(uniqueKeysWithValues: deepLCommon.map { ($0, $0.uppercased()) })
        // The app's en and pt identifiers are also Foundation's canonical
        // identities for en-US and pt-BR. Keep GB/PT alternatives explicit.
        values.merge([
            "en": "EN-US", "en-GB": "EN-GB", "pt": "PT-BR", "pt-PT": "PT-PT",
            "zh-Hans": "ZH-HANS", "zh-Hant": "ZH-HANT", "de-CH": "DE-CH", "es-419": "ES-419", "fr-CA": "FR-CA"
        ]) { _, new in new }
        return values
    }()

    private static let azure: [String: String] = {
        let codes = [
            "af", "ar", "bg", "bn", "ca", "cs", "da", "de", "el", "en", "es", "et", "eu",
            "fa", "fi", "fil", "fr", "fr-CA", "ga", "gl", "he", "hi", "hr", "hu", "id", "is",
            "it", "ja", "ko", "lt", "lv", "ms", "mt", "nb", "nl", "pl", "pt", "pt-PT", "ro", "ru",
            "sk", "sl", "sq", "sr-Cyrl", "sr-Latn", "sv", "sw", "ta", "te", "th", "tr", "uk", "ur", "vi",
            "zh-Hans", "zh-Hant"
        ]
        return Dictionary(uniqueKeysWithValues: codes.map { (LanguageCatalog.canonicalIdentifier($0), $0) })
    }()
}
