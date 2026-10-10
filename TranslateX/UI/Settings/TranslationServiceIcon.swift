import AppKit

/// Display-only artwork. Choosing a mark never changes a service's protocol.
enum TranslationServiceIcon: String, CaseIterable, Identifiable {
    case openai, deepseek, claude, kimi, glm, qwen, gemini, siliconflow, openrouter
    case xiaomi, minimax, doubao, stepfun, xai, mistral, newapi
    case ollama, deepl, azure, googlecloud, tencentcloud
    case network, cloud, server, cpu

    var id: String { rawValue }
    var isBrand: Bool { assetName != nil }
    static var brandIcons: [Self] { allCases.filter(\.isBrand) }
    static var genericIcons: [Self] { allCases.filter { !$0.isBrand } }

    var displayName: String {
        switch self {
        case .openai: "OpenAI"
        case .deepseek: "DeepSeek"
        case .claude: "Claude"
        case .kimi: "Kimi"
        case .glm: "GLM"
        case .qwen: "Qwen"
        case .gemini: "Gemini"
        case .siliconflow: "SiliconFlow"
        case .openrouter: "OpenRouter"
        case .xiaomi: "Xiaomi MiMo"
        case .minimax: "MiniMax"
        case .doubao: "Doubao"
        case .stepfun: "Stepfun"
        case .xai: "xAI"
        case .mistral: "Mistral"
        case .newapi: "New API"
        case .ollama: "Ollama"
        case .deepl: "DeepL"
        case .azure: "Azure"
        case .googlecloud: "Google Cloud"
        case .tencentcloud: "Tencent Cloud"
        case .network: L10n.string("Network icon")
        case .cloud: L10n.string("Cloud icon")
        case .server: L10n.string("Server icon")
        case .cpu: L10n.string("Chip icon")
        }
    }

    var assetName: String? {
        switch self {
        case .openai: "ProviderOpenAI"
        case .deepseek: "ProviderDeepSeek"
        case .claude: "ProviderClaude"
        case .kimi: "ProviderKimi"
        case .glm: "ProviderGLM"
        case .qwen: "ProviderQwen"
        case .gemini: "ProviderGemini"
        case .siliconflow: "ProviderSiliconFlow"
        case .openrouter: "ProviderOpenRouter"
        case .xiaomi: "ProviderXiaomiMiMo"
        case .minimax: "ProviderMiniMax"
        case .doubao: "ProviderDoubao"
        case .stepfun: "ProviderStepfun"
        case .xai: "ProviderXAI"
        case .mistral: "ProviderMistral"
        case .newapi: "ProviderNewAPI"
        case .ollama: "ProviderOllama"
        case .deepl: "ProviderDeepL"
        case .azure: "ProviderAzure"
        case .googlecloud: "ProviderGoogleCloud"
        case .tencentcloud: "ProviderTencentCloud"
        case .network, .cloud, .server, .cpu: nil
        }
    }

    var systemName: String? {
        switch self {
        case .network: "network"
        case .cloud: "cloud"
        case .server: "server.rack"
        case .cpu: "cpu"
        default: nil
        }
    }

    var usesTemplate: Bool {
        [.openai, .kimi, .openrouter, .xiaomi, .xai, .ollama, .deepl].contains(self) || !isBrand
    }

    static func defaultIcon(for kind: TranslationServiceKind) -> Self {
        switch kind {
        case .openAI, .codex: .openai
        case .deepSeek: .deepseek
        case .claude: .claude
        case .openAICompatible: .network
        case .ollama: .ollama
        case .deepL: .deepl
        case .azureTranslator: .azure
        case .qwenMT: .qwen
        case .googleCloud: .googlecloud
        case .tencentTranslation: .tencentcloud
        }
    }

    @MainActor
    func menuImage(size: CGFloat = 16) -> NSImage? {
        let source: NSImage?
        if let assetName { source = NSImage(named: assetName) }
        else if let systemName { source = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) }
        else { source = nil }
        guard let image = source?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = usesTemplate
        return image
    }
}

extension TranslationServicePreset {
    var defaultIconID: String {
        switch self {
        case .openAI, .codex: TranslationServiceIcon.openai.rawValue
        case .deepSeek: TranslationServiceIcon.deepseek.rawValue
        case .claude: TranslationServiceIcon.claude.rawValue
        case .custom: TranslationServiceIcon.network.rawValue
        case .newAPI: TranslationServiceIcon.newapi.rawValue
        case .kimi: TranslationServiceIcon.kimi.rawValue
        case .glm: TranslationServiceIcon.glm.rawValue
        case .qwen, .qwenMT: TranslationServiceIcon.qwen.rawValue
        case .gemini: TranslationServiceIcon.gemini.rawValue
        case .siliconFlow: TranslationServiceIcon.siliconflow.rawValue
        case .openRouter: TranslationServiceIcon.openrouter.rawValue
        case .xiaomiMiMo: TranslationServiceIcon.xiaomi.rawValue
        case .miniMax: TranslationServiceIcon.minimax.rawValue
        case .doubao: TranslationServiceIcon.doubao.rawValue
        case .stepfun: TranslationServiceIcon.stepfun.rawValue
        case .xAI: TranslationServiceIcon.xai.rawValue
        case .mistral: TranslationServiceIcon.mistral.rawValue
        case .ollama: TranslationServiceIcon.ollama.rawValue
        case .deepL: TranslationServiceIcon.deepl.rawValue
        case .azureTranslator: TranslationServiceIcon.azure.rawValue
        case .googleCloud: TranslationServiceIcon.googlecloud.rawValue
        case .tencentTranslation: TranslationServiceIcon.tencentcloud.rawValue
        }
    }
}

extension TranslationServiceConfiguration {
    var serviceIcon: TranslationServiceIcon {
        iconID.flatMap(TranslationServiceIcon.init(rawValue:))
            ?? TranslationServiceIcon(rawValue: providerPreset.defaultIconID)
            ?? TranslationServiceIcon.defaultIcon(for: kind)
    }
}
