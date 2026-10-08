import Foundation

/// The app's common-language intersection with Google's NMT table, not its
/// Translation LLM table. Snapshot: 2026-09-26.
/// https://docs.cloud.google.com/translate/docs/languages#nmt
nonisolated enum GoogleTranslationLanguages {
    static func identifiers(asTarget: Bool = true) -> [String] { mapping.keys.sorted() }

    static func code(for identifier: String, asTarget: Bool = true) -> String? {
        mapping[LanguageCatalog.canonicalIdentifier(identifier)]
    }

    static func detectedSourceIdentifier(from code: String) -> String? {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unscripted response cannot distinguish Simplified/Traditional.
        if code.caseInsensitiveCompare("zh") == .orderedSame { return nil }
        let canonical = LanguageCatalog.canonicalIdentifier(code)
        return mapping[canonical] == nil ? nil : canonical
    }

    private static let mapping: [String: String] = {
        let common = [
            "en", "ja", "ko", "fr", "de", "es", "it", "ru", "ar", "hi", "th", "vi", "id", "ms",
            "nl", "pl", "tr", "uk", "sv", "da", "fi", "cs", "el", "he", "ro", "hu", "bg", "sk",
            "sl", "hr", "sr", "et", "lv", "lt", "fa", "bn", "ta", "te", "ur", "sw", "fil", "ca",
            "eu", "gl", "is", "ga", "af", "mt", "sq"
        ]
        var values = Dictionary(uniqueKeysWithValues: common.map { ($0, $0) })
        values.merge(["zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "pt": "pt-BR", "pt-PT": "pt-PT"]) { _, new in new }
        return values
    }()
}
