import Foundation

/// Presentation and connection defaults, separate from the persisted transport
/// kind. Adding a brand never changes existing kind raw values or service IDs.
enum TranslationServicePreset: String, CaseIterable, Identifiable, Sendable {
    case openAI, deepSeek, claude, kimi, glm, qwen, gemini, siliconFlow, openRouter
    case xiaomiMiMo, miniMax, doubao, stepfun, xAI, mistral
    case newAPI, custom, ollama, deepL, azureTranslator, qwenMT, googleCloud, tencentTranslation, codex

    var id: String { rawValue }

    init(kind: TranslationServiceKind) {
        switch kind {
        case .openAI: self = .openAI
        case .deepSeek: self = .deepSeek
        case .openAICompatible: self = .custom
        case .ollama: self = .ollama
        case .deepL: self = .deepL
        case .azureTranslator: self = .azureTranslator
        case .claude: self = .claude
        case .qwenMT: self = .qwenMT
        case .googleCloud: self = .googleCloud
        case .tencentTranslation: self = .tencentTranslation
        case .codex: self = .codex
        }
    }

    var kind: TranslationServiceKind {
        switch self {
        case .openAI: .openAI
        case .deepSeek: .deepSeek
        case .claude: .claude
        case .ollama: .ollama
        case .deepL: .deepL
        case .azureTranslator: .azureTranslator
        case .qwenMT: .qwenMT
        case .googleCloud: .googleCloud
        case .tencentTranslation: .tencentTranslation
        case .codex: .codex
        default: .openAICompatible
        }
    }

    var displayName: String {
        switch self {
        case .kimi: "Kimi"
        case .glm: "GLM"
        case .qwen: "Qwen"
        case .gemini: "Gemini"
        case .siliconFlow: "SiliconFlow"
        case .openRouter: "OpenRouter"
        case .xiaomiMiMo: "Xiaomi MiMo"
        case .miniMax: "MiniMax"
        case .doubao: "Doubao"
        case .stepfun: "StepFun"
        case .xAI: "xAI"
        case .mistral: "Mistral"
        case .newAPI: "New API"
        case .custom: L10n.string("Custom service")
        default: kind.displayName
        }
    }

    /// Defaults and their official references are maintained in Docs/ProviderAPIs.md.
    var defaultEndpoint: String {
        switch self {
        case .kimi: "https://api.moonshot.cn/v1"
        case .glm: "https://open.bigmodel.cn/api/paas/v4"
        case .qwen: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .siliconFlow: "https://api.siliconflow.cn/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .xiaomiMiMo: "https://api.xiaomimimo.com/v1"
        case .miniMax: "https://api.minimax.io/v1"
        case .doubao: "https://ark.cn-beijing.volces.com/api/v3"
        case .stepfun: "https://api.stepfun.com/v1"
        case .xAI: "https://api.x.ai/v1"
        case .mistral: "https://api.mistral.ai/v1"
        case .newAPI, .custom: ""
        default: kind.defaultEndpoint
        }
    }

    var defaultWebsite: String {
        switch self {
        case .kimi: "https://platform.moonshot.cn"
        case .glm: "https://open.bigmodel.cn"
        case .qwen: "https://bailian.console.aliyun.com"
        case .gemini: "https://aistudio.google.com"
        case .siliconFlow: "https://cloud.siliconflow.cn"
        case .openRouter: "https://openrouter.ai"
        case .xiaomiMiMo: "https://platform.xiaomimimo.com"
        case .miniMax: "https://platform.minimax.io"
        case .doubao: "https://console.volcengine.com/ark"
        case .stepfun: "https://platform.stepfun.com"
        case .xAI: "https://console.x.ai"
        case .mistral: "https://console.mistral.ai"
        case .newAPI: "https://www.newapi.ai"
        case .custom: ""
        default: kind.defaultWebsite
        }
    }

    /// Fixed-purpose translation APIs retain their documented fixed model;
    /// every configurable model is selected from the fetched directory.
    var defaultModel: String {
        kind == .qwenMT || kind == .tencentTranslation ? kind.defaultModel : ""
    }

    var requiresAPIKey: Bool { self != .ollama && self != .codex }
    var supportsCustomProtocol: Bool { self == .custom || self == .newAPI }
    var defaultAPIFormat: TranslationServiceAPIFormat {
        switch self {
        case .openAI: .responses
        case .claude: .claudeMessages
        default: .chatCompletions
        }
    }

    var searchKeywords: String {
        switch self {
        case .kimi: "Moonshot 月之暗面"
        case .glm: "Zhipu 智谱"
        case .qwen, .qwenMT: "Alibaba DashScope 百炼 通义 千问 阿里云"
        case .gemini: "Google 谷歌"
        case .siliconFlow: "硅基流动"
        case .xiaomiMiMo: "小米"
        case .doubao: "ByteDance Volcengine 豆包 火山引擎"
        case .stepfun: "阶跃星辰"
        case .xAI: "Grok"
        case .custom, .newAPI: "OpenAI compatible 兼容 自定义 网关"
        default: ""
        }
    }
}

enum TranslationServiceAPIFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatCompletions, responses, claudeMessages
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .chatCompletions: "Chat Completions"
        case .responses: "Responses"
        case .claudeMessages: "Claude Messages"
        }
    }
    var operationPath: String {
        switch self {
        case .chatCompletions: "chat/completions"
        case .responses: "responses"
        case .claudeMessages: "messages"
        }
    }
}

enum TranslationServiceEndpointMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case baseURL, requestURL
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .baseURL: L10n.string("API base URL")
        case .requestURL: L10n.string("Full request URL")
        }
    }
}
