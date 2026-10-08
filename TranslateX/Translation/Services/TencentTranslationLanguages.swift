import Foundation

/// The documented Hy-MT2 codes intersected with the app's common languages.
/// In particular, Tencent uses zh-TR, not a BCP-47 region or another API's zh-TW.
/// https://cloud.tencent.com/document/product/1823/132252 (2026-09-26)
nonisolated enum TencentTranslationLanguages {
    static func identifiers(asTarget: Bool = true) -> [String] { mapping.keys.sorted() }

    static func code(for identifier: String, asTarget: Bool = true) -> String? {
        mapping[LanguageCatalog.canonicalIdentifier(identifier)]
    }

    static func detectedSourceIdentifier(from code: String) -> String? {
        // Match the provider's code before Foundation can interpret TR as a region.
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return mapping.first { $0.value.lowercased() == value }?.key
    }

    private static let mapping: [String: String] = {
        let common = [
            "en", "ja", "ko", "fr", "de", "es", "pt", "it", "ru", "ar", "hi", "th", "vi", "id",
            "ms", "nl", "pl", "tr", "uk", "cs", "he", "fa", "bn", "ta", "te", "ur", "fil"
        ]
        var values = Dictionary(uniqueKeysWithValues: common.map { ($0, $0) })
        values["zh-Hans"] = "zh"
        values["zh-Hant"] = "zh-TR"
        return values
    }()
}
