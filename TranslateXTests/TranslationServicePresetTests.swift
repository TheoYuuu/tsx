import Foundation
import XCTest
@testable import TranslateX

@MainActor
final class TranslationServicePresetTests: XCTestCase {
    private let input = TranslationRequest(id: UUID(), text: "Hello", source: "en", target: "zh-Hans")

    func testLegacyKindsAndAnonymousCompatibleConfigurationRemainReadable() throws {
        XCTAssertEqual(Set(TranslationServiceKind.allCases.map(\.rawValue)), Set([
            "openAI", "deepSeek", "openAICompatible", "ollama", "deepL", "azureTranslator", "claude",
            "qwenMT", "googleCloud", "tencentTranslation", "codex"
        ]))
        let original = TranslationServiceConfiguration(name: "Existing", kind: .openAICompatible,
            endpoint: "https://gateway.test/v1", model: "saved-model")
        let loaded = try JSONDecoder().decode(TranslationServiceConfiguration.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(loaded, original)
        XCTAssertNil(loaded.presetID)
        XCTAssertEqual(loaded.providerPreset, .custom)
        XCTAssertFalse(loaded.requiresAPIKey)
        let request = try RemoteTranslationProvider.makeRequest(configuration: loaded, apiKey: nil, request: input)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.url?.absoluteString, "https://gateway.test/v1/chat/completions")
    }

    func testUnknownPresentationMetadataFallsBackWithoutDiscardingSavedModelOrIdentity() throws {
        var config = TranslationServiceConfiguration(preset: .kimi)
        config.model = "saved-model"
        config.presetID = "future-provider"
        config.iconID = "future-icon"
        let loaded = try JSONDecoder().decode(TranslationServiceConfiguration.self, from: JSONEncoder().encode(config)).validated()
        XCTAssertEqual(loaded.id, config.id)
        XCTAssertEqual(loaded.model, config.model)
        XCTAssertEqual(loaded.iconID, config.iconID)
        XCTAssertEqual(loaded.providerPreset, .custom)
        XCTAssertTrue(loaded.requiresAPIKey)
        config.presetID = TranslationServicePreset.codex.rawValue
        XCTAssertEqual(config.providerPreset, .custom)
        XCTAssertEqual(config.kind, .openAICompatible)
    }

    func testConfigurablePresetsStartWithoutModelAndUseRealCatalogRequests() throws {
        for preset in TranslationServicePreset.allCases where preset.kind.allowsCustomModel {
            var config = TranslationServiceConfiguration(preset: preset)
            XCTAssertEqual(config.model, "", preset.rawValue)
            if preset.supportsCustomProtocol { config.endpoint = "https://gateway.test/prefix/v1" }
            let request = try TranslationServiceModelCatalog.makeRequest(configuration: config, apiKey: "fixture")
            XCTAssertEqual(request.httpMethod, "GET", preset.rawValue)
            XCTAssertEqual(request.url?.host, try config.validatedEndpoint().host, preset.rawValue)
            XCTAssertEqual(request.url?.path, try config.validatedEndpoint().path + "/models", preset.rawValue)
            XCTAssertNil(request.httpBody)
            XCTAssertThrowsError(try config.validated()) { XCTAssertEqual($0 as? TranslationServiceConfigurationError, .invalidModel) }
        }
    }

    func testNewCompatiblePresetsRequireKeyForDiscoveryAndTranslation() throws {
        for preset in TranslationServicePreset.allCases where preset.kind == .openAICompatible {
            var config = TranslationServiceConfiguration(preset: preset)
            config.model = "chosen-model"
            if preset.supportsCustomProtocol { config.endpoint = "https://gateway.test/v1" }
            XCTAssertTrue(config.requiresAPIKey)
            XCTAssertThrowsError(try TranslationServiceModelCatalog.makeRequest(configuration: config, apiKey: nil)) {
                XCTAssertEqual($0 as? RemoteTranslationError, .missingKey)
            }
            XCTAssertThrowsError(try RemoteTranslationProvider.makeRequest(configuration: config, apiKey: nil, request: input)) {
                XCTAssertEqual($0 as? RemoteTranslationError, .missingKey)
            }
            let request = try RemoteTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: input)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            XCTAssertEqual(request.url?.path, try config.validatedEndpoint().path + "/chat/completions")
        }
    }

    func testCustomBaseURLFormatsRouteToMatchingBodyHeadersAndParser() throws {
        for preset: TranslationServicePreset in [.custom, .newAPI] {
            for format in TranslationServiceAPIFormat.allCases {
                var config = TranslationServiceConfiguration(preset: preset)
                config.endpoint = "https://gateway.test/reverse-proxy/v2/"
                config.model = "chosen-model"
                config.apiFormat = format
                config.maximumOutputTokens = 123
                let provider = TranslationProviderFactory.make(configuration: config, apiKey: "fixture")
                XCTAssertEqual(provider is ClaudeTranslationProvider, format == .claudeMessages)
                let request = try translationRequest(config)
                XCTAssertEqual(request.url?.absoluteString, "https://gateway.test/reverse-proxy/v2/" + format.operationPath)
                let body = try object(request)
                XCTAssertEqual(body["model"] as? String, "chosen-model")
                XCTAssertEqual(body["stream"] as? Bool, true)
                if format == .claudeMessages {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture")
                    XCTAssertEqual(body["max_tokens"] as? Int, 123)
                    XCTAssertNotNil(body["system"])
                    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                } else {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
                    XCTAssertNotNil(body[format == .responses ? "input" : "messages"])
                    if format == .responses { XCTAssertEqual(body["store"] as? Bool, false) }
                }
                let directory = try TranslationServiceModelCatalog.makeRequest(configuration: config, apiKey: "fixture")
                XCTAssertEqual(directory.url?.path, "/reverse-proxy/v2/models")
                XCTAssertEqual(directory.value(forHTTPHeaderField: "x-api-key") != nil, format == .claudeMessages)
            }
        }
    }

    func testFullRequestURLKeepsExactPathAndUsesExplicitModelDirectory() throws {
        for format in TranslationServiceAPIFormat.allCases {
            var config = customRequestConfiguration()
            config.apiFormat = format
            let request = try translationRequest(config)
            XCTAssertEqual(request.url?.absoluteString, "https://gateway.test/custom/translate/")
            let catalog = try TranslationServiceModelCatalog.makeRequest(configuration: config, apiKey: "fixture")
            let catalogURL = try XCTUnwrap(catalog.url)
            XCTAssertEqual(URLComponents(url: catalogURL, resolvingAgainstBaseURL: false)?.percentEncodedPath, "/available-models/")
            XCTAssertEqual(catalogURL.absoluteString, "https://gateway.test/available-models/" + (format == .claudeMessages ? "?limit=100" : ""))
            XCTAssertEqual(catalog.url?.query, format == .claudeMessages ? "limit=100" : nil)
            XCTAssertEqual(try config.validated().endpoint, config.endpoint)
        }
    }

    func testFullRequestDirectoryRejectsMissingCrossOriginAndCredentialBearingURLs() throws {
        var config = customRequestConfiguration()
        for address in [nil, "", "https://other.test/models", "http://gateway.test/models",
                        "https://gateway.test:8443/models", "https://name:secret@gateway.test/models",
                        "https://gateway.test/models?key=fixture", "https://gateway.test/a/../models"] as [String?] {
            config.modelsEndpoint = address
            XCTAssertThrowsError(try config.modelCatalogURL()) {
                XCTAssertEqual($0 as? TranslationServiceConfigurationError, .invalidModelsEndpoint)
            }
            XCTAssertThrowsError(try TranslationServiceModelCatalog.makeRequest(configuration: config, apiKey: "fixture"))
        }
        config.modelsEndpoint = "https://GATEWAY.test:443/models"
        XCTAssertEqual(try config.modelCatalogURL().host, "gateway.test")
        config.endpoint = "http://127.0.0.1:11434/generate"
        config.modelsEndpoint = "http://127.0.0.1:11434/models"
        XCTAssertEqual(try config.modelCatalogURL().scheme, "http")
        config.modelsEndpoint = "http://localhost:11434/models"
        XCTAssertThrowsError(try config.modelCatalogURL())
    }

    func testBuiltInPresetDoesNotAcceptCustomProtocolMetadata() throws {
        var config = TranslationServiceConfiguration(preset: .openAI)
        config.model = "chosen-model"
        config.apiFormat = .claudeMessages
        config.endpointMode = .requestURL
        config.modelsEndpoint = "https://other.test/models"
        XCTAssertEqual(config.effectiveAPIFormat, .responses)
        XCTAssertEqual(config.effectiveEndpointMode, .baseURL)
        XCTAssertEqual(try config.translationRequestURL().absoluteString, "https://api.openai.com/v1/responses")
        let saved = try config.validated()
        XCTAssertNil(saved.apiFormat)
        XCTAssertNil(saved.endpointMode)
        XCTAssertNil(saved.modelsEndpoint)
    }

    func testMiniMaxRequestsSeparateReasoningWithoutChangingOtherCompatibleServices() throws {
        for preset: TranslationServicePreset in [.miniMax, .kimi, .xiaomiMiMo] {
            var config = TranslationServiceConfiguration(preset: preset)
            config.model = "chosen-model"
            let body = try object(translationRequest(config))
            XCTAssertEqual(body["reasoning_split"] as? Bool, preset == .miniMax ? true : nil)
            XCTAssertNil(body["thinking"])
        }
    }

    private func customRequestConfiguration() -> TranslationServiceConfiguration {
        var config = TranslationServiceConfiguration(preset: .custom)
        config.model = "chosen-model"
        config.endpointMode = .requestURL
        config.endpoint = "https://gateway.test/custom/translate/"
        config.modelsEndpoint = "https://gateway.test/available-models/"
        return config
    }

    private func translationRequest(_ config: TranslationServiceConfiguration) throws -> URLRequest {
        if config.effectiveAPIFormat == .claudeMessages {
            return try ClaudeTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: input)
        }
        return try RemoteTranslationProvider.makeRequest(configuration: config, apiKey: "fixture", request: input)
    }

    private func object(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
}
