import Foundation

/// Compiled with the production provider and request/result types by
/// remote-translation-network.py. It uses generated fixtures only and never
/// loads application preferences, Keychain, or a provider account.
@main
struct RemoteTranslationNetworkProbe {
    private static let sample = "A clear sentence is easy to understand."
    private static let expected = "清晰的句子很容易理解。 🌍"

    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 2,
              let base = URL(string: CommandLine.arguments[1]),
              base.scheme == "http", base.host == "127.0.0.1", base.port != nil else {
            throw ProbeFailure("The probe requires its generated loopback fixture URL.")
        }
        for (name, kind) in [
            ("chat-sse", TranslationServiceKind.openAICompatible),
            ("responses-sse", .openAI),
            ("chat-json", .openAICompatible),
            ("responses-json", .openAI),
            ("claude-sse", .claude),
            ("claude-json", .claude)
        ] {
            var partials: [String] = []
            let provider = provider(base, fixture: name, kind: kind) { partials.append($0) }
            let result = try await provider.translate(request())
            try require(result.text == expected, "Incorrect fixture translation: \(name)")
            try require(result.source == nil && result.target == "zh-Hans", "Incorrect language identity: \(name)")
            try require(partials.last == expected, "Missing final partial: \(name)")
            if name.hasSuffix("sse") { try require(partials.count >= 2, "Streaming was not observed: \(name)") }
            print("PASS \(name)")
        }
        for (name, kind, detected) in [("qwen-json", TranslationServiceKind.qwenMT, nil as String?), ("google-json", .googleCloud, "en"), ("tencent-json", .tencentTranslation, "en")] {
            let result = try await provider(base, fixture: name, kind: kind).translate(request())
            try require(result.text == expected && result.source == detected && result.target == "zh-Hans",
                        "Incorrect native translation result: \(name)")
            print("PASS \(name)")
        }
        for (name, kind) in [("deepl-json", TranslationServiceKind.deepL), ("azure-json", .azureTranslator)] {
            let result = try await provider(base, fixture: name, kind: kind).translate(request())
            try require(result.text == expected && result.source == "en" && result.target == "zh-Hans",
                        "Incorrect dedicated result or source identity: \(name)")
            print("PASS \(name)")
        }
        for name in ["redirect-same", "redirect-other"] {
            do {
                _ = try await provider(base, fixture: name).translate(request())
                throw ProbeFailure("A redirected translation unexpectedly succeeded.")
            } catch let error as RemoteTranslationError {
                try require(error == .redirected, "Wrong redirect error: \(name)")
            }
            print("PASS \(name)")
        }
        for (name, kind) in [
            ("chat-truncated", TranslationServiceKind.openAICompatible),
            ("responses-truncated", .openAI),
            ("claude-truncated", .claude),
            ("tencent-truncated-json", .tencentTranslation)
        ] {
            do {
                _ = try await provider(base, fixture: name, kind: kind).translate(request())
                throw ProbeFailure("A truncated translation unexpectedly succeeded.")
            } catch let error as RemoteTranslationError {
                try require(error == .incompleteResponse, "Wrong truncation error: \(name)")
            }
            print("PASS \(name)")
        }
        for (name, kind) in [
            ("cancel-before-headers", TranslationServiceKind.openAICompatible), ("cancel-during-body", .openAICompatible),
            ("claude-cancel-before-headers", .claude), ("claude-cancel-during-body", .claude),
            ("dedicated-cancel-before-headers", .googleCloud), ("dedicated-cancel-during-body", .googleCloud)
        ] {
            var partials: [String] = []
            let provider = provider(base, fixture: name, kind: kind) { partials.append($0) }
            let task = Task { try await provider.translate(request()) }
            do {
                try await waitUntilStarted(base, fixture: name)
                if name.hasSuffix("cancel-during-body") && kind != .googleCloud {
                    for _ in 0..<60 where partials.isEmpty {
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    try require(!partials.isEmpty, "Cancellation did not exercise an active partial stream.")
                }
            } catch {
                task.cancel()
                throw error
            }
            task.cancel()
            let partialCount = partials.count
            do {
                _ = try await task.value
                throw ProbeFailure("Cancelled translation unexpectedly succeeded: \(name)")
            } catch is CancellationError {
                try require(partials.count == partialCount, "A partial arrived after cancellation: \(name)")
            }
            print("PASS \(name)")
        }
        // Every successful fixture sets a cookie. This additional production
        // request must still arrive without Cookie or shared HTTP credentials.
        let result = try await provider(base, fixture: "cookie-followup", apiKey: nil).translate(request())
        try require(result.text == expected, "Cookie follow-up failed.")
        print("PASS cookie-followup")
    }

    @MainActor
    private static func provider(
        _ base: URL,
        fixture: String,
        kind: TranslationServiceKind = .openAICompatible,
        apiKey: String? = "translatex-network-fixture-key",
        onPartial: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) -> any TranslationProvider {
        let endpoint = kind.requiresModel && kind != .tencentTranslation ? base.appendingPathComponent(fixture).appendingPathComponent("v1")
            : base.appendingPathComponent(fixture)
        let configuration = TranslationServiceConfiguration(
            name: "Network fixture", kind: kind,
            endpoint: endpoint.absoluteString,
            model: kind.requiresModel && !kind.allowsCustomModel ? kind.defaultModel : (kind.requiresModel ? "fixture-model" : "")
        )
        // No injected URLSession or URLProtocol: exercise the production stack.
        return TranslationProviderFactory.make(configuration: configuration, apiKey: apiKey, onPartial: onPartial)
    }

    private static func request() -> TranslationRequest {
        .init(id: UUID(), text: sample, source: nil, target: "zh-Hans")
    }

    private static func waitUntilStarted(_ base: URL, fixture: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for _ in 0..<60 {
            let (data, _) = try await session.data(from: base.appendingPathComponent("status").appendingPathComponent(fixture))
            if String(decoding: data, as: UTF8.self) == "started" { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ProbeFailure("Cancellation fixture did not start: \(fixture)")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ProbeFailure(message) }
    }

    private struct ProbeFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
