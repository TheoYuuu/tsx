import Foundation

/// Native Messages lifecycle, independent of Chat Completions. Only complete
/// text-only assistant turns are translations; EOF and a text delta are not.
/// https://platform.claude.com/docs/en/build-with-claude/streaming
struct ClaudeTranslationResponseParser {
    static let maximumBodyBytes = 4_194_304
    static let maximumOutputBytes = 524_288
    private(set) var isComplete = false
    private(set) var usage: TranslationUsage?
    private var started = false
    private var activeIndex: Int?
    private var nextIndex = 0
    private var sawMessageDelta = false
    private var stopReason: String?
    private var output = ""
    private var outputBytes = 0

    mutating func consume(_ data: Data) throws -> String? {
        guard !isComplete else { throw RemoteTranslationError.invalidResponse }
        guard data.count <= RemoteTranslationSSEDecoder.maximumEventBytes else {
            throw RemoteTranslationError.responseTooLarge
        }
        let event = try Self.decode(ClaudeStreamEvent.self, from: data)
        switch event.type {
        case "error":
            throw Self.failure(status: 400, body: data)
        case "ping":
            return nil
        case "message_start":
            guard !started, let message = event.message,
                  message.type == "message", message.role == "assistant",
                  message.content.isEmpty, message.stop_reason == nil,
                  message.stop_sequence == nil, message.stop_details == nil else {
                throw RemoteTranslationError.invalidResponse
            }
            started = true
            let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let messageObject = envelope?["message"] as? [String: Any]
            let reported = TranslationUsage.reportedTokens(messageObject?["usage"], inputKey: "input_tokens", outputKey: "output_tokens")
            // The start event's output count is provisional. Output usage is
            // taken from later cumulative message_delta snapshots.
            usage = TranslationUsage(inputTokens: reported?.inputTokens).nonempty
        case "content_block_start":
            guard started, !sawMessageDelta, activeIndex == nil,
                  event.index == nextIndex, let block = event.content_block else {
                throw RemoteTranslationError.invalidResponse
            }
            let text = try Self.text(in: block)
            activeIndex = nextIndex
            return try append(text)
        case "content_block_delta":
            guard started, !sawMessageDelta, let activeIndex,
                  event.index == activeIndex, let delta = event.delta else {
                throw RemoteTranslationError.invalidResponse
            }
            if delta.type == "refusal_delta" { throw RemoteTranslationError.refused }
            guard delta.type == "text_delta", let text = delta.text,
                  delta.stop_reason == nil, delta.stop_sequence == nil, delta.stop_details == nil else {
                throw RemoteTranslationError.invalidResponse
            }
            return try append(text)
        case "content_block_stop":
            guard started, !sawMessageDelta, let activeIndex, event.index == activeIndex else {
                throw RemoteTranslationError.invalidResponse
            }
            self.activeIndex = nil
            nextIndex += 1
        case "message_delta":
            guard started, activeIndex == nil, let delta = event.delta else {
                throw RemoteTranslationError.invalidResponse
            }
            sawMessageDelta = true
            if delta.stop_details?.type == "refusal" { throw RemoteTranslationError.refused }
            guard delta.type == nil, delta.text == nil,
                  delta.stop_sequence == nil, delta.stop_details == nil else {
                throw RemoteTranslationError.invalidResponse
            }
            if let reason = delta.stop_reason {
                guard stopReason == nil else { throw RemoteTranslationError.invalidResponse }
                try Self.validateStop(reason)
                stopReason = reason
            }
            let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let reported = TranslationUsage.reportedTokens(envelope?["usage"], inputKey: "input_tokens", outputKey: "output_tokens")
            // These are cumulative snapshots, never amounts to add together.
            usage = TranslationUsage(
                inputTokens: reported?.inputTokens ?? usage?.inputTokens,
                outputTokens: reported?.outputTokens ?? usage?.outputTokens
            ).nonempty
        case "message_stop":
            guard started, activeIndex == nil, sawMessageDelta, stopReason == "end_turn" else {
                throw RemoteTranslationError.incompleteResponse
            }
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RemoteTranslationError.invalidResponse
            }
            isComplete = true
        default:
            // New top-level metadata events may be added by the API. They do
            // not advance completion or contribute text. New content block or
            // delta types are rejected above rather than rendered as text.
            return nil
        }
        return nil
    }

    mutating func readJSON(_ data: Data) throws -> String {
        guard !started, !isComplete else { throw RemoteTranslationError.invalidResponse }
        guard data.count <= Self.maximumBodyBytes else { throw RemoteTranslationError.responseTooLarge }
        let envelope = try Self.decode(ClaudeStreamEvent.self, from: data)
        if envelope.type == "error" { throw Self.failure(status: 400, body: data) }
        let message = try Self.decode(ClaudeMessage.self, from: data)
        guard message.type == "message", message.role == "assistant" else {
            throw RemoteTranslationError.invalidResponse
        }
        if message.stop_details?.type == "refusal" { throw RemoteTranslationError.refused }
        try Self.validateStop(message.stop_reason)
        guard message.stop_sequence == nil, message.stop_details == nil else {
            throw RemoteTranslationError.invalidResponse
        }
        for block in message.content { _ = try append(Self.text(in: block)) }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteTranslationError.invalidResponse
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        usage = TranslationUsage.reportedTokens(object?["usage"], inputKey: "input_tokens", outputKey: "output_tokens")
        isComplete = true
        return output
    }

    func completedText() throws -> String {
        guard isComplete else { throw RemoteTranslationError.incompleteResponse }
        return output
    }

    /// Never expose error.message or decoding descriptions. A stream error has
    /// HTTP 200, so the native error type must take precedence over HTTP status.
    static func failure(status: Int, body: Data) -> RemoteTranslationError {
        if let envelope = try? JSONDecoder().decode(ClaudeErrorEnvelope.self, from: body) {
            switch envelope.error.type {
            case "invalid_request_error": return .invalidRequest
            case "authentication_error": return .invalidKey
            case "billing_error": return .quotaExceeded
            case "permission_error": return .forbidden
            case "not_found_error": return .modelUnavailable
            case "request_too_large": return .inputTooLarge
            case "rate_limit_error": return .rateLimited
            case "api_error", "overloaded_error": return .serviceUnavailable
            case "timeout_error": return .timedOut
            default: break
            }
        }
        return RemoteTranslationError.http(status: status, body: body)
    }

    private static func validateStop(_ reason: String?) throws {
        if reason == "refusal" { throw RemoteTranslationError.refused }
        guard reason == "end_turn" else { throw RemoteTranslationError.incompleteResponse }
    }

    private static func text(in block: ClaudeContentBlock) throws -> String {
        if block.type == "refusal" { throw RemoteTranslationError.refused }
        guard block.type == "text", let text = block.text else { throw RemoteTranslationError.invalidResponse }
        return text
    }

    private mutating func append(_ text: String) throws -> String? {
        guard text.utf8.count <= Self.maximumOutputBytes - outputBytes else {
            throw RemoteTranslationError.responseTooLarge
        }
        guard !text.isEmpty else { return nil }
        outputBytes += text.utf8.count
        output += text
        return output
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw RemoteTranslationError.invalidResponse }
    }
}

private struct ClaudeStreamEvent: Decodable {
    let type: String
    let index: Int?
    let message: ClaudeMessage?
    let content_block: ClaudeContentBlock?
    let delta: ClaudeDelta?
}

private struct ClaudeMessage: Decodable {
    let type: String
    let role: String
    let content: [ClaudeContentBlock]
    let stop_reason: String?
    let stop_sequence: String?
    let stop_details: ClaudeStopDetails?
}

private struct ClaudeContentBlock: Decodable {
    let type: String
    let text: String?
}

private struct ClaudeDelta: Decodable {
    let type: String?
    let text: String?
    let stop_reason: String?
    let stop_sequence: String?
    let stop_details: ClaudeStopDetails?
}

private struct ClaudeStopDetails: Decodable {
    let type: String
}

private struct ClaudeErrorEnvelope: Decodable {
    let error: ClaudeErrorType
}

private struct ClaudeErrorType: Decodable {
    let type: String
}
