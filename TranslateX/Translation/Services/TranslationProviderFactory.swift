import Foundation

/// App and settings share one routing decision; neither silently falls back to
/// another service when a configured destination is unavailable.
@MainActor
enum TranslationProviderFactory {
    static func make(
        configuration: TranslationServiceConfiguration,
        apiKey: String?,
        codex: CodexAccountController? = nil,
        onPartial: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) -> any TranslationProvider {
        switch configuration.kind {
        case .deepL, .azureTranslator:
            DedicatedTranslationProvider(configuration: configuration, apiKey: apiKey)
        case .openAI, .deepSeek, .openAICompatible, .ollama:
            RemoteTranslationProvider(configuration: configuration, apiKey: apiKey, onPartial: onPartial)
        case .claude:
            ClaudeTranslationProvider(configuration: configuration, apiKey: apiKey, onPartial: onPartial)
        case .qwenMT:
            QwenMTTranslationProvider(configuration: configuration, apiKey: apiKey)
        case .googleCloud:
            GoogleCloudTranslationProvider(configuration: configuration, apiKey: apiKey)
        case .tencentTranslation:
            TencentTranslationProvider(configuration: configuration, apiKey: apiKey)
        case .codex:
            CodexTranslationProvider(controller: codex, model: configuration.model, generation: configuration.codexAccountGeneration)
        }
    }
}
