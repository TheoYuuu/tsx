import Foundation

/// Flash's documented codes, restricted to the app's common-language choices.
/// Do not silently collapse Portuguese (Portugal), Irish, or Chinese scripts.
/// https://help.aliyun.com/zh/model-studio/machine-translation (2026-09-26)
nonisolated enum QwenMTTranslationLanguages {
    static func identifiers(asTarget: Bool = true) -> [String] { mapping.keys.sorted() }

    static func code(for identifier: String, asTarget: Bool = true) -> String? {
        mapping[LanguageCatalog.canonicalIdentifier(identifier)]
    }

    /// Qwen-MT's documented completion does not report detected source language.
    static func detectedSourceIdentifier(from code: String) -> String? { nil }

    private static let mapping: [String: String] = {
        let common = [
            "en", "ja", "ko", "fr", "de", "es", "pt", "it", "ru", "ar", "hi", "th", "vi", "id", "ms",
            "nl", "pl", "tr", "uk", "sv", "da", "fi", "nb", "cs", "el", "he", "ro", "hu", "bg", "sk",
            "sl", "hr", "sr", "et", "lv", "lt", "fa", "bn", "ta", "te", "ur", "sw", "ca", "eu",
            "gl", "is", "af", "mt", "sq"
        ]
        var values = Dictionary(uniqueKeysWithValues: common.map { ($0, $0) })
        values.merge(["zh-Hans": "zh", "zh-Hant": "zh_tw", "fil": "tl"]) { _, new in new }
        return values
    }()
}
