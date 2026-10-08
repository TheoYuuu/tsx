import Foundation
@preconcurrency import Translation

/// Read-only resource audit plus synthetic translations using already installed files.
/// Never invokes prepareTranslation, downloads resources, or reads user text.
@main
struct LanguageAudit {
    struct Pair: Codable {
        let source: String
        let target: String
        let status: String
    }
    struct Sample: Codable {
        let source: String
        let target: String
        let outcome: String
    }
    struct Report: Codable {
        let system: String
        let languages: [String]
        let pairs: [Pair]
        let samples: [Sample]
        let failures: Int
    }
    @MainActor static func main() async throws {
        // A stalled system call must not keep an unattended audit running indefinitely.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(55))
            fputs("Language audit exceeded 55 seconds; no completion claimed.\n", stderr)
            exit(2)
        }
        defer { watchdog.cancel() }
        let available = await LanguageAvailability().supportedLanguages
        let languages = LanguageCatalog.normalizedLanguages(available).map(\.id).sorted()
        var pairs: [Pair] = []
        var samples: [Sample] = []
        var failures = 0
        for source in languages {
            for target in languages {
                let status = await LanguageCatalog.status(source: source, target: target)
                let name: String
                switch status {
                case .installed: name = "installed"
                case .supported: name = "requires-resources"
                case .unsupported: name = "unsupported"
                @unknown default: name = "unknown"; failures += 1
                }
                pairs.append(Pair(source: source, target: target, status: name))
            }
        }
        // Fixed finite sample set: six directions, not every possible sentence.
        let texts = [
            ("en", "zh-Hans", "A quiet window helps you focus."),
            ("zh-Hans", "en", "清晰的文字让阅读更轻松。"),
            ("ja", "en", "静かな部屋で本を読みます。"),
            ("fr", "en", "Cette fenêtre laisse entrer la lumière."),
            ("de", "en", "Dieses Fenster lässt viel Licht herein."),
            ("es", "en", "Esta ventana deja entrar la luz.")
        ]
        for (source, target, text) in texts {
            guard await LanguageCatalog.status(source: source, target: target) == .installed else {
                samples.append(Sample(source: source, target: target, outcome: "not-run-resources-not-installed"))
                continue
            }
            guard #available(macOS 26, *) else {
                samples.append(Sample(source: source, target: target, outcome: "not-run-use-product-session-on-macOS15"))
                continue
            }
            let session = TranslationSession(installedSource: .init(identifier: source), target: .init(identifier: target))
            do {
                let response = try await session.translate(text)
                let valid = !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && LanguageCatalog.canonicalIdentifier(response.targetLanguage.minimalIdentifier)
                        == LanguageCatalog.canonicalIdentifier(target)
                samples.append(Sample(source: source, target: target, outcome: valid ? "completed-nonempty-correct-target" : "invalid-response"))
                if !valid { failures += 1 }
            } catch {
                samples.append(Sample(source: source, target: target, outcome: "system-request-failed"))
                failures += 1
            }
        }
        let report = Report(system: ProcessInfo.processInfo.operatingSystemVersionString,
                            languages: languages, pairs: pairs, samples: samples, failures: failures)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        exit(failures == 0 ? 0 : 1)
    }
}
