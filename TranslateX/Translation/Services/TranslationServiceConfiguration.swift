import Foundation

enum TranslationServiceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI
    case deepSeek
    case openAICompatible
    case ollama
    case deepL
    case azureTranslator
    case claude
    case qwenMT
    case googleCloud
    case tencentTranslation
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        case .openAICompatible: L10n.string("OpenAI-compatible service")
        case .ollama: "Ollama"
        case .deepL: "DeepL"
        case .azureTranslator: "Azure Translator"
        case .claude: "Claude"
        case .qwenMT: "Qwen-MT Flash"
        case .googleCloud: "Google Cloud Translation Basic"
        case .tencentTranslation: "Tencent HY-MT2 Plus"
        case .codex: "Codex / ChatGPT"
        }
    }

    /// Providers append their operation path to an API base URL. Google Basic
    /// uses the complete translation URL, as identified in its settings field.
    var defaultEndpoint: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .deepSeek: "https://api.deepseek.com"
        case .openAICompatible: ""
        case .ollama: "http://localhost:11434/v1"
        case .deepL: DeepLAPIEndpoint.free.rawValue
        case .azureTranslator: "https://api.cognitive.microsofttranslator.com"
        case .claude: "https://api.anthropic.com/v1"
        case .qwenMT: QwenMTEndpoint.beijing.rawValue
        case .googleCloud: "https://translation.googleapis.com/language/translate/v2"
        case .tencentTranslation: TencentTranslationEndpoint.guangzhou.rawValue
        case .codex: "https://chatgpt.com/backend-api"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: "gpt-4.1-mini"
        case .deepSeek: "deepseek-flash"
        case .claude: "claude-haiku-4-5-20251001"
        case .qwenMT: "qwen-mt-flash"
        case .tencentTranslation: "hy-mt2-plus"
        case .openAICompatible, .ollama, .deepL, .azureTranslator, .googleCloud, .codex: ""
        }
    }

    var requiresAPIKey: Bool {
        self != .openAICompatible && self != .ollama && self != .codex
    }

    var defaultWebsite: String {
        switch self {
        case .openAI: "https://platform.openai.com"
        case .deepSeek: "https://platform.deepseek.com"
        case .deepL: "https://www.deepl.com/account"
        case .claude: "https://platform.claude.com"
        case .azureTranslator: "https://portal.azure.com"
        case .googleCloud: "https://console.cloud.google.com"
        case .qwenMT: "https://bailian.console.aliyun.com"
        case .tencentTranslation: "https://console.cloud.tencent.com"
        case .codex: "https://chatgpt.com"
        case .ollama: "https://ollama.com"
        case .openAICompatible: ""
        }
    }

    var requiresModel: Bool {
        switch self {
        case .openAI, .deepSeek, .openAICompatible, .ollama, .claude, .qwenMT, .tencentTranslation, .codex: true
        case .deepL, .azureTranslator, .googleCloud: false
        }
    }

    var supportsAdditionalInstructions: Bool { allowsCustomModel }
    var allowsCustomModel: Bool { requiresModel && self != .qwenMT && self != .tencentTranslation && self != .codex }
}

enum TencentTranslationEndpoint: String, CaseIterable, Identifiable, Sendable {
    case guangzhou = "https://tokenhub.tencentmaas.com"
    case singapore = "https://tokenhub-intl.tencentmaas.com"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .guangzhou: L10n.string("Guangzhou")
        case .singapore: L10n.string("Singapore")
        }
    }
}

enum QwenMTEndpoint: String, CaseIterable, Identifiable, Sendable {
    case beijing = "https://dashscope.aliyuncs.com/compatible-mode/v1"
    case singapore = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .beijing: L10n.string("Beijing")
        case .singapore: L10n.string("Singapore")
        }
    }
}

enum DeepLAPIEndpoint: String, CaseIterable, Identifiable, Sendable {
    case free = "https://api-free.deepl.com"
    case pro = "https://api.deepl.com"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .free: "API Free"
        case .pro: L10n.string("Paid API")
        }
    }
}

/// Preferences only: secrets live in TranslationCredentialStore, never Codable
/// configuration data. Saving a service does not make it the active service.
struct TranslationServiceConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var kind: TranslationServiceKind
    var endpoint: String
    var website: String
    var model: String
    var additionalInstructions: String = ""
    var automaticallyTranslates: Bool = true
    var region: String = ""
    var maximumOutputTokens: Int = 8_192
    /// Public local generation identifier, never an OAuth token or account ID.
    var codexAccountGeneration: String?

    init(
        id: UUID = UUID(),
        name: String,
        kind: TranslationServiceKind,
        endpoint: String,
        model: String,
        additionalInstructions: String = "",
        automaticallyTranslates: Bool = true,
        region: String = "",
        maximumOutputTokens: Int = 8_192,
        codexAccountGeneration: String? = nil,
        website: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endpoint = endpoint
        self.website = website ?? kind.defaultWebsite
        self.model = model
        self.additionalInstructions = additionalInstructions
        self.automaticallyTranslates = automaticallyTranslates
        self.region = region
        self.maximumOutputTokens = maximumOutputTokens
        self.codexAccountGeneration = codexAccountGeneration
    }

    init(kind: TranslationServiceKind) {
        self.init(name: kind.displayName, kind: kind, endpoint: kind.defaultEndpoint, model: kind.defaultModel)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, endpoint, model, additionalInstructions, automaticallyTranslates, region
        case maximumOutputTokens
        case codexAccountGeneration, website
    }

    /// Keep saved services readable when later optional fields are absent.
    /// Existing required fields retain their validation/decode behavior.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(TranslationServiceKind.self, forKey: .kind)
        website = try values.decodeIfPresent(String.self, forKey: .website) ?? kind.defaultWebsite
        endpoint = try values.decode(String.self, forKey: .endpoint)
        model = try values.decode(String.self, forKey: .model)
        additionalInstructions = try values.decode(String.self, forKey: .additionalInstructions)
        automaticallyTranslates = try values.decode(Bool.self, forKey: .automaticallyTranslates)
        region = try values.decodeIfPresent(String.self, forKey: .region) ?? ""
        maximumOutputTokens = try values.decodeIfPresent(Int.self, forKey: .maximumOutputTokens) ?? 8_192
        codexAccountGeneration = try values.decodeIfPresent(String.self, forKey: .codexAccountGeneration)
    }

    var displayDetail: String {
        (kind.allowsCustomModel || kind == .codex) && !model.isEmpty ? kind.displayName + " · " + model : kind.displayName
    }

    func validated() throws -> Self {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.website = website.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.website.isEmpty || value.websiteURL != nil else {
            throw TranslationServiceConfigurationError.invalidWebsite
        }
        value.model = kind.requiresModel ? model.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        value.additionalInstructions = kind.supportsAdditionalInstructions
            ? additionalInstructions.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        value.region = kind == .azureTranslator ? region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
        value.maximumOutputTokens = kind == .claude ? maximumOutputTokens : 8_192
        value.codexAccountGeneration = kind == .codex ? codexAccountGeneration : nil
        guard !value.name.isEmpty, value.name.count <= 120,
              !value.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw TranslationServiceConfigurationError.invalidName
        }
        if kind.requiresModel {
            guard !value.model.isEmpty, value.model.count <= 256,
              !value.model.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !value.model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw TranslationServiceConfigurationError.invalidModel
            }
        }
        if kind == .qwenMT, value.model != kind.defaultModel {
            throw TranslationServiceConfigurationError.unsupportedQwenMTModel
        }
        if kind == .tencentTranslation, value.model != kind.defaultModel {
            throw TranslationServiceConfigurationError.unsupportedTencentModel
        }
        if kind == .codex {
            guard value.model.utf8.count <= 256, let generation = value.codexAccountGeneration,
                  UUID(uuidString: generation)?.uuidString.lowercased() == generation,
                  generation != "00000000-0000-0000-0000-000000000000" else {
                throw TranslationServiceConfigurationError.codexLoginRequired
            }
        }
        guard (1...131_072).contains(value.maximumOutputTokens) else {
            throw TranslationServiceConfigurationError.invalidOutputTokenLimit
        }
        guard value.additionalInstructions.count <= 8_000 else {
            throw TranslationServiceConfigurationError.instructionsTooLong
        }
        if !value.region.isEmpty {
            guard value.region.utf8.count <= 64,
                  value.region.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }),
                  let first = value.region.utf8.first, (97...122).contains(first) else {
                throw TranslationServiceConfigurationError.invalidRegion
            }
        }
        value.endpoint = try validatedEndpoint().absoluteString
        return value
    }

    func validatedEndpoint() throws -> URL {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .codex, trimmed != kind.defaultEndpoint {
            throw TranslationServiceConfigurationError.invalidEndpoint
        }
        guard !trimmed.isEmpty, trimmed.count <= 2_048,
              !trimmed.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw TranslationServiceConfigurationError.invalidEndpoint
        }
        guard scheme == "https" || scheme == "http" && Self.isLoopbackHost(host) else {
            throw TranslationServiceConfigurationError.insecureEndpoint
        }
        // Decoded traversal and separators are rejected as well, so a path cannot
        // change meaning when Foundation or an upstream proxy normalizes it.
        let pathParts = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !pathParts.contains("."), !pathParts.contains(".."),
              !components.path.contains("\\"),
              !components.percentEncodedPath.lowercased().contains("%2f"),
              !components.percentEncodedPath.lowercased().contains("%5c"),
              !components.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw TranslationServiceConfigurationError.invalidEndpoint
        }
        components.scheme = scheme
        components.host = host
        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        guard let url = components.url else { throw TranslationServiceConfigurationError.invalidEndpoint }
        return url
    }

    /// A separate public browser destination; API endpoints are never opened
    /// or transformed into links, and credential-bearing URLs are rejected.
    var websiteURL: URL? {
        let value = website.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 2_048,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        return parts.url
    }

    /// `path` is an internal relative operation such as "chat/completions".
    /// The supplied base path is preserved, including an explicit version or
    /// reverse-proxy prefix. A full operation URL is not treated as a base URL.
    func endpointURL(appending path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ part in
            !part.isEmpty && part != "." && part != ".."
                && part.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
        }) else { throw TranslationServiceConfigurationError.invalidEndpoint }
        var url = try validatedEndpoint()
        for part in parts { url.appendPathComponent(String(part)) }
        return url
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        if host == "localhost" || host == "[::1]" || host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(part), (0...255).contains(number) else { return false }
            return String(number) == part
        }
    }
}

enum TranslationServiceConfigurationError: Error, LocalizedError, Equatable {
    case codexLoginRequired
    case invalidName
    case invalidModel
    case invalidRegion
    case unsupportedQwenMTModel
    case unsupportedTencentModel
    case invalidOutputTokenLimit
    case invalidEndpoint
    case invalidWebsite
    case insecureEndpoint
    case instructionsTooLong
    case missingAPIKey
    case invalidAPIKey
    case endpointChanged
    case unknownService
    case credentialUnavailable
    case storageUnavailable

    var errorDescription: String? {
        let key: String
        switch self {
        case .codexLoginRequired: key = "Sign in to ChatGPT and choose an available model before saving."
        case .invalidName: key = "Enter a service name of 1–120 characters."
        case .invalidModel: key = "Enter a model identifier without spaces, up to 256 characters."
        case .invalidRegion: key = "Enter the Azure resource region, such as eastus, using only letters and numbers. Leave it blank for a global resource."
        case .unsupportedQwenMTModel: key = "This Qwen-MT connection currently supports qwen-mt-flash. Use an OpenAI-compatible connection for general Qwen models."
        case .unsupportedTencentModel: key = "This Tencent translation connection currently supports hy-mt2-plus."
        case .invalidOutputTokenLimit: key = "Choose an output limit from 1 to 131,072 tokens that your Claude model supports."
        case .invalidEndpoint: key = "Enter an API base URL without a username, password, query, or fragment."
        case .invalidWebsite: key = "Enter an HTTP or HTTPS website without credentials, a query, or a fragment."
        case .insecureEndpoint: key = "Remote services require HTTPS. HTTP is allowed only for a loopback address."
        case .instructionsTooLong: key = "Additional translation instructions must be no longer than 8,000 characters."
        case .missingAPIKey: key = "Enter an API key for this service."
        case .invalidAPIKey: key = "Enter an API key without spaces or control characters."
        case .endpointChanged: key = "The service address changed. Re-enter the API key for this address."
        case .unknownService: key = "This translation service is no longer available. Select another service."
        case .credentialUnavailable: key = "The API key could not be accessed in Keychain. Unlock Keychain or enter the key again."
        case .storageUnavailable: key = "The translation service could not be saved. Try again."
        }
        return L10n.string(key)
    }
}
