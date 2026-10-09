import Foundation
import CoreFoundation
// Apple's macOS 15 session predates Swift 6 concurrency annotations. It is used
// serially inside its owning translationTask, never cached or shared across tasks.
@preconcurrency import Translation

struct TranslationRequest: Equatable, Sendable {
    let id: UUID
    let text: String
    let source: String?
    let target: String
}

struct TranslationResult: Equatable, Sendable {
    let text: String
    let source: String?
    let target: String
    let usage: TranslationUsage?

    init(text: String, source: String?, target: String, usage: TranslationUsage? = nil) {
        self.text = text
        self.source = source
        self.target = target
        self.usage = usage?.nonempty
    }
}

/// Counts explicitly reported by the service for this request. Missing fields
/// remain unknown; source length is never substituted for billable characters.
nonisolated struct TranslationUsage: Codable, Equatable, Sendable {
    // Far above this app's bounded translation requests, while keeping corrupt
    // provider metadata from overflowing downstream statistics.
    static let maximumReportedCount = 1_000_000_000
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let characters: Int?
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?

    init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil, characters: Int? = nil,
         cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil) {
        self.inputTokens = Self.validated(inputTokens)
        self.outputTokens = Self.validated(outputTokens)
        self.totalTokens = Self.validated(totalTokens)
        self.characters = Self.validated(characters)
        self.cacheReadTokens = Self.validated(cacheReadTokens)
        self.cacheWriteTokens = Self.validated(cacheWriteTokens)
    }

    private enum CodingKeys: String, CodingKey { case inputTokens, outputTokens, totalTokens, characters, cacheReadTokens, cacheWriteTokens }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            inputTokens: try? values.decode(Int.self, forKey: .inputTokens),
            outputTokens: try? values.decode(Int.self, forKey: .outputTokens),
            totalTokens: try? values.decode(Int.self, forKey: .totalTokens),
            characters: try? values.decode(Int.self, forKey: .characters),
            cacheReadTokens: try? values.decode(Int.self, forKey: .cacheReadTokens),
            cacheWriteTokens: try? values.decode(Int.self, forKey: .cacheWriteTokens)
        )
    }

    var reportedTokenTotal: Int? {
        if let totalTokens { return totalTokens }
        guard let inputTokens, let outputTokens else { return nil }
        let total = inputTokens.addingReportingOverflow(outputTokens)
        return total.overflow ? nil : total.partialValue
    }

    var nonempty: Self? {
        inputTokens != nil || outputTokens != nil || totalTokens != nil || characters != nil || cacheReadTokens != nil || cacheWriteTokens != nil ? self : nil
    }

    static func reportedTokens(_ value: Any?, inputKey: String = "prompt_tokens", outputKey: String = "completion_tokens") -> Self? {
        guard let values = value as? [String: Any] else { return nil }
        let details = (values["prompt_tokens_details"] ?? values["input_tokens_details"]) as? [String: Any]
        let read = reportedCount(values["cache_read_input_tokens"] ?? values["prompt_cache_hit_tokens"] ?? details?["cached_tokens"])
        let write = reportedCount(values["cache_creation_input_tokens"])
        var input = reportedCount(values[inputKey])
        // Anthropic reports uncached input separately; normalize to all input
        // tokens while retaining its explicit cache split for price estimation.
        if values["cache_read_input_tokens"] != nil || values["cache_creation_input_tokens"] != nil,
           let uncached = input {
            if (values["cache_read_input_tokens"] != nil && read == nil) || (values["cache_creation_input_tokens"] != nil && write == nil) { input = nil }
            else { input = validated(uncached + (read ?? 0) + (write ?? 0)) }
        }
        return Self(inputTokens: input, outputTokens: reportedCount(values[outputKey]),
                    totalTokens: reportedCount(values["total_tokens"]), cacheReadTokens: read, cacheWriteTokens: write).nonempty
    }

    static func reportedCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let count = number.doubleValue
        guard count.isFinite, count >= 0, count <= Double(maximumReportedCount), count.rounded(.towardZero) == count else { return nil }
        return Int(count)
    }

    private static func validated(_ value: Int?) -> Int? {
        guard let value, (0...maximumReportedCount).contains(value) else { return nil }
        return value
    }
}

@MainActor
protocol TranslationProvider {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult
}

/// Created and used only inside the lifetime of a SwiftUI translationTask.
@MainActor
struct AppleLocalTranslationProvider: TranslationProvider {
    let session: TranslationSession

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let response = try await session.translate(request.text)
        return TranslationResult(
            text: Self.preservingLineBreaks(in: response.targetText, from: request.text),
            source: LanguageCatalog.canonicalIdentifier(response.sourceLanguage.minimalIdentifier),
            target: LanguageCatalog.canonicalIdentifier(response.targetLanguage.minimalIdentifier)
        )
    }

    /// Apple can turn every input line break into a paragraph gap. When the
    /// paragraph boundaries still correspond one-for-one, retain the input's
    /// separators. Never flatten authored blank lines or guess at reflowed text.
    static func preservingLineBreaks(in translation: String, from source: String) -> String {
        let pattern = #"(?:\r\n|[\n\r\u0085\u2028\u2029])(?:[\t ]*(?:\r\n|[\n\r\u0085\u2028\u2029]))*"#
        guard let breaks = try? NSRegularExpression(pattern: pattern) else { return translation }
        let original = source as NSString
        let translated = translation as NSString
        let sourceBreaks = breaks.matches(in: source, range: NSRange(location: 0, length: original.length))
        let resultBreaks = breaks.matches(in: translation, range: NSRange(location: 0, length: translated.length))
        guard !sourceBreaks.isEmpty, sourceBreaks.count == resultBreaks.count else { return translation }
        for (text, matches) in [(original, sourceBreaks), (translated, resultBreaks)] {
            var start = 0
            for end in matches.map(\.range) + [NSRange(location: text.length, length: 0)] {
                guard !text.substring(with: NSRange(location: start, length: end.location - start))
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return translation }
                start = NSMaxRange(end)
            }
        }
        let output = NSMutableString(string: translation)
        for (inputBreak, outputBreak) in zip(sourceBreaks, resultBreaks).reversed() {
            output.replaceCharacters(in: outputBreak.range, with: original.substring(with: inputBreak.range))
        }
        return output as String
    }
}
