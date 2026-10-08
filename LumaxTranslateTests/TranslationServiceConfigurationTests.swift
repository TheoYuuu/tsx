import Foundation
import XCTest
@testable import LumaxTranslate

final class TranslationServiceConfigurationTests: XCTestCase {
    func testCodexConfigurationBindsModelToOneAccountAndFixedAddress() throws {
        var config = TranslationServiceConfiguration(kind: .codex)
        XCTAssertFalse(config.kind.requiresAPIKey)
        XCTAssertFalse(config.kind.allowsCustomModel)
        XCTAssertTrue(config.automaticallyTranslates)
        XCTAssertThrowsError(try config.validated())
        config.model = "fixture-model"
        for generation in [nil, "", "wrong", "00000000-0000-0000-0000-000000000000", UUID().uuidString] as [String?] {
            config.codexAccountGeneration = generation
            XCTAssertThrowsError(try config.validated())
        }
        config.codexAccountGeneration = UUID().uuidString.lowercased()
        config.additionalInstructions = "stale instructions"
        let normalized = try config.validated()
        XCTAssertEqual(normalized.additionalInstructions, "")
        XCTAssertEqual(normalized.codexAccountGeneration, config.codexAccountGeneration)
        XCTAssertEqual(try JSONDecoder().decode(TranslationServiceConfiguration.self,
            from: JSONEncoder().encode(normalized)), normalized)
        for endpoint in ["https://another.example", config.endpoint + "/v1", config.endpoint + "?token=fixture"] {
            config.endpoint = endpoint
            XCTAssertThrowsError(try config.validated())
        }
    }

    func testOtherServicesDiscardCodexGenerationAndLegacyDataStillLoads() throws {
        var config = TranslationServiceConfiguration(kind: .deepSeek)
        config.codexAccountGeneration = UUID().uuidString.lowercased()
        XCTAssertNil(try config.validated().codexAccountGeneration)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        object.removeValue(forKey: "codexAccountGeneration")
        let legacy = try JSONDecoder().decode(TranslationServiceConfiguration.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.codexAccountGeneration)
        XCTAssertEqual(try legacy.validated(), try config.validated())
    }

    func testDedicatedServicesValidateWithoutModelAndIgnoreStaleLLMFields() throws {
        for kind in [TranslationServiceKind.deepL, .azureTranslator, .googleCloud] {
            var config = TranslationServiceConfiguration(kind: kind)
            XCTAssertTrue(kind.requiresAPIKey)
            XCTAssertFalse(kind.requiresModel)
            XCTAssertFalse(kind.supportsAdditionalInstructions)
            XCTAssertEqual(try config.validated().model, "")
            config.model = "stale model that must never be sent"
            config.additionalInstructions = String(repeating: "x", count: 8_001)
            let normalized = try config.validated()
            XCTAssertEqual(normalized.model, "")
            XCTAssertEqual(normalized.additionalInstructions, "")
            XCTAssertEqual(config.displayDetail, kind.displayName)
            XCTAssertFalse(config.displayDetail.contains(" · "))
        }
        XCTAssertEqual(TranslationServiceKind.deepL.defaultEndpoint, DeepLAPIEndpoint.free.rawValue)
        XCTAssertEqual(DeepLAPIEndpoint.pro.rawValue, "https://api.deepl.com")
        XCTAssertEqual(TranslationServiceKind.azureTranslator.defaultEndpoint, "https://api.cognitive.microsofttranslator.com")
    }

    func testClaudeOutputLimitPersistsAndOlderConfigurationsReceiveDefault() throws {
        var config = TranslationServiceConfiguration(kind: .claude)
        XCTAssertEqual(config.model, "claude-haiku-4-5-20251001")
        XCTAssertEqual(config.maximumOutputTokens, 8_192)
        for validLimit in [1, 4_096, 131_072] {
            config.maximumOutputTokens = validLimit
            XCTAssertEqual(try config.validated().maximumOutputTokens, validLimit)
            XCTAssertEqual(try JSONDecoder().decode(TranslationServiceConfiguration.self, from: JSONEncoder().encode(config)), config)
        }
        for invalidLimit in [0, -1, 131_073, Int.max] {
            config.maximumOutputTokens = invalidLimit
            XCTAssertThrowsError(try config.validated()) {
                XCTAssertEqual($0 as? TranslationServiceConfigurationError, .invalidOutputTokenLimit)
            }
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        object.removeValue(forKey: "maximumOutputTokens")
        let older = try JSONDecoder().decode(TranslationServiceConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(older.maximumOutputTokens, 8_192)
        XCTAssertEqual(older.id, config.id)
        object["maximumOutputTokens"] = true
        XCTAssertThrowsError(try JSONDecoder().decode(TranslationServiceConfiguration.self, from: JSONSerialization.data(withJSONObject: object)))
        config.kind = .openAI
        XCTAssertEqual(try config.validated().maximumOutputTokens, 8_192, "A stale Claude-only option must not affect another provider.")
    }

    func testQwenMTRequiresItsSupportedModelAndStripsGeneralPromptInstructions() throws {
        var config = TranslationServiceConfiguration(kind: .qwenMT)
        config.additionalInstructions = String(repeating: "stale prompt", count: 1_000)
        XCTAssertEqual(try config.validated().additionalInstructions, "")
        XCTAssertFalse(config.kind.allowsCustomModel)
        XCTAssertFalse(config.kind.supportsAdditionalInstructions)
        XCTAssertEqual(config.displayDetail, config.kind.displayName)
        for model in ["qwen-plus", "qwen-mt-plus", "qwen-mt-turbo", "future-unknown"] {
            config.model = model
            XCTAssertThrowsError(try config.validated()) {
                XCTAssertEqual($0 as? TranslationServiceConfigurationError, .unsupportedQwenMTModel)
            }
        }
    }

    func testAzureRegionAllowsGlobalAndCanonicalizesSafeResourceNames() throws {
        var config = TranslationServiceConfiguration(kind: .azureTranslator)
        XCTAssertEqual(try config.validated().region, "")
        for region in ["eastus", "westus2", "swedencentral", "usgovvirginia"] {
            config.region = " \(region.uppercased()) \n"
            XCTAssertEqual(try config.validated().region, region)
        }
        for region in ["East US", "eastus\r\nInjected", "eastus.example", "east/us", "east_us", "地域", "123", String(repeating: "a", count: 65)] {
            config.region = region
            XCTAssertThrowsError(try config.validated(), region) {
                XCTAssertEqual($0 as? TranslationServiceConfigurationError, .invalidRegion)
            }
        }
        config.kind = .deepL
        XCTAssertEqual(try config.validated().region, "", "An unrelated stale region must not influence another API.")
    }

    func testTencentUsesFixedTranslationModelAndIndependentRegionEndpoints() throws {
        var config = TranslationServiceConfiguration(kind: .tencentTranslation)
        XCTAssertEqual(try config.validated().model, "hy-mt2-plus")
        XCTAssertEqual(config.endpoint, TencentTranslationEndpoint.guangzhou.rawValue)
        XCTAssertFalse(config.kind.allowsCustomModel)
        XCTAssertFalse(config.kind.supportsAdditionalInstructions)
        config.additionalInstructions = String(repeating: "stale prompt", count: 1_000)
        XCTAssertEqual(try config.validated().additionalInstructions, "")
        XCTAssertEqual(config.displayDetail, config.kind.displayName)
        config.endpoint = TencentTranslationEndpoint.singapore.rawValue
        XCTAssertEqual(try config.validatedEndpoint().host, "tokenhub-intl.tencentmaas.com")
        for model in ["hy-mt2-pro", "hy-mt2-lite", "hunyuan", "future-model"] {
            config.model = model
            XCTAssertThrowsError(try config.validated()) {
                XCTAssertEqual($0 as? TranslationServiceConfigurationError, .unsupportedTencentModel)
            }
        }
    }

    func testS1ConfigurationWithoutRegionDecodesWithoutLosingFields() throws {
        let id = UUID()
        let object: [String: Any] = [
            "id": id.uuidString, "name": "Existing service", "kind": "deepSeek",
            "endpoint": "https://api.deepseek.com", "model": "deepseek-flash",
            "additionalInstructions": "Keep paragraphs.", "automaticallyTranslates": true
        ]
        let value = try JSONDecoder().decode(TranslationServiceConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(value.id, id)
        XCTAssertEqual(value.name, "Existing service")
        XCTAssertEqual(value.kind, .deepSeek)
        XCTAssertEqual(value.region, "")
        XCTAssertEqual(value.additionalInstructions, "Keep paragraphs.")
        XCTAssertTrue(value.automaticallyTranslates)
        XCTAssertEqual(try value.validated(), value)
    }

    func testRegionRoundTripsAndWrongTypedRegionStillFailsDecode() throws {
        var config = TranslationServiceConfiguration(kind: .azureTranslator)
        config.region = "eastus"
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(TranslationServiceConfiguration.self, from: data), config)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["region"] = 42
        XCTAssertThrowsError(try JSONDecoder().decode(TranslationServiceConfiguration.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testBaseURLPreservesVersionAndProxyPrefixWhenAppendingOperation() throws {
        for (endpoint, expected) in [
            ("https://api.example", "https://api.example/chat/completions"),
            ("https://api.example/v1/", "https://api.example/v1/chat/completions"),
            ("https://api.example/proxy/v2", "https://api.example/proxy/v2/chat/completions"),
            ("http://localhost:11434/v1", "http://localhost:11434/v1/chat/completions")
        ] {
            let config = configuration(endpoint: endpoint)
            XCTAssertEqual(try config.endpointURL(appending: "chat/completions").absoluteString, expected)
        }
    }

    func testRemoteHTTPAndAmbiguousLocalAddressesAreRejected() {
        for endpoint in [
            "http://api.example/v1", "http://192.168.1.10:8000/v1", "http://0.0.0.0:8000/v1",
            "http://localhost.example/v1", "http://127.0.0.1.example/v1", "http://127.1/v1",
            "http://127.000.000.001/v1", "http://2130706433/v1", "ftp://localhost/v1"
        ] {
            XCTAssertThrowsError(try configuration(endpoint: endpoint).validatedEndpoint(), endpoint)
        }
    }

    func testOnlyExplicitLoopbackAllowsHTTP() throws {
        for endpoint in ["http://localhost:11434/v1", "http://127.0.0.1:8000", "http://127.2.3.4/v1", "http://[::1]:11434/v1"] {
            XCTAssertNoThrow(try configuration(endpoint: endpoint).validatedEndpoint(), endpoint)
        }
    }

    func testCredentialsQueriesFragmentsAndMalformedPathsAreRejected() {
        for endpoint in [
            "", "api.example", "https:///v1", "https://user:password@api.example/v1",
            "https://user@api.example/v1", "https://api.example/v1?key=fixture", "https://api.example/v1?",
            "https://api.example/v1#fragment", "https://api.example/v1#", "https://api.example:0/v1",
            "https://api.example:65536/v1", "https://api.example/a/../v1", "https://api.example/a/%2e%2e/v1",
            "https://api.example/a%2fb/v1", "https://api.example/a%5cb/v1", "https://api.example/v1\nInjected",
            "https://api.example/a b/v1", "https://api.example/%00/v1"
        ] {
            XCTAssertThrowsError(try configuration(endpoint: endpoint).validatedEndpoint(), endpoint)
        }
    }

    func testOperationCannotReplaceAuthorityOrTraverseBasePath() {
        let config = configuration(endpoint: "https://api.example/v1")
        for path in ["", "/responses", "//other.example", "https://other.example", "../responses", "chat//completions", "responses?key=x"] {
            XCTAssertThrowsError(try config.endpointURL(appending: path), path)
        }
    }

    func testNormalizationAndInvalidMetadata() throws {
        var config = configuration(endpoint: " HTTPS://API.EXAMPLE/v1/// \n")
        config.name = " My service \n"
        config.model = " fixture-model \n"
        config.additionalInstructions = " Keep paragraphs. \n"
        let normalized = try config.validated()
        XCTAssertEqual(normalized.name, "My service")
        XCTAssertEqual(normalized.model, "fixture-model")
        XCTAssertEqual(normalized.endpoint, "https://api.example/v1")
        XCTAssertEqual(normalized.additionalInstructions, "Keep paragraphs.")
        config.name = " "
        XCTAssertThrowsError(try config.validated())
        config.name = "Valid"
        for model in ["", " ", "two models", "a\nb", String(repeating: "m", count: 257)] {
            config.model = model
            XCTAssertThrowsError(try config.validated())
        }
        config.model = "fixture-model"
        config.additionalInstructions = String(repeating: "x", count: 8_001)
        XCTAssertThrowsError(try config.validated())
    }

    private func configuration(endpoint: String) -> TranslationServiceConfiguration {
        .init(name: "Fixture", kind: .openAICompatible, endpoint: endpoint, model: "fixture-model")
    }
}
