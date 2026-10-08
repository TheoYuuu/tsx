import Foundation

/// Byte-oriented framing preserves a UTF-8 scalar split across network chunks.
/// A frame is dispatched only after a blank line, never from a truncated tail.
struct RemoteTranslationSSEDecoder {
    static let maximumEventBytes = 1_048_576
    private var line = Data()
    private var event = Data()
    private var skipLF = false
    private var firstLine = true

    mutating func append(_ byte: UInt8) throws -> Data? {
        if skipLF {
            skipLF = false
            if byte == 10 { return nil }
        }
        if byte == 13 || byte == 10 {
            skipLF = byte == 13
            return try finishLine()
        }
        guard line.count + event.count < Self.maximumEventBytes else {
            throw RemoteTranslationError.responseTooLarge
        }
        line.append(byte)
        return nil
    }

    private mutating func finishLine() throws -> Data? {
        defer { line.removeAll(keepingCapacity: true); firstLine = false }
        if firstLine && line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        guard let text = String(data: line, encoding: .utf8) else {
            throw RemoteTranslationError.invalidResponse
        }
        if text.isEmpty {
            guard !event.isEmpty else { return nil }
            let result = event
            event.removeAll(keepingCapacity: true)
            return result
        }
        if text == "data" || text.hasPrefix("data:") {
            var field = text == "data" ? "" : String(text.dropFirst(5))
            if field.hasPrefix(" ") { field.removeFirst() }
            if !event.isEmpty { event.append(10) }
            event.append(contentsOf: field.utf8)
            guard event.count <= Self.maximumEventBytes else { throw RemoteTranslationError.responseTooLarge }
        }
        // Comments, event names, ids and retry directives do not affect the text.
        return nil
    }
}

struct RemoteTranslationResponseParser {
    static let maximumBodyBytes = 4_194_304
    static let maximumOutputBytes = 524_288
    let usesResponses: Bool
    private(set) var isComplete = false
    private(set) var usage: TranslationUsage?
    private var output = ""
    private var outputBytes = 0
    private var sawChatStop = false

    mutating func consume(_ data: Data) throws -> String? {
        guard !isComplete else { throw RemoteTranslationError.invalidResponse }
        if data == Data("[DONE]".utf8) {
            guard !usesResponses, sawChatStop else { throw RemoteTranslationError.incompleteResponse }
            isComplete = true
            return nil
        }
        let object = try dictionary(data)
        if let error = object["error"], !(error is NSNull) {
            throw RemoteTranslationError.http(status: 400, body: data)
        }
        return try usesResponses ? consumeResponses(object) : consumeChat(object)
    }

    mutating func readJSON(_ data: Data) throws -> String {
        guard data.count <= Self.maximumBodyBytes else { throw RemoteTranslationError.responseTooLarge }
        let object = try dictionary(data)
        if let error = object["error"], !(error is NSNull) { throw RemoteTranslationError.http(status: 400, body: data) }
        if usesResponses {
            guard object["status"] as? String == "completed" else { throw RemoteTranslationError.incompleteResponse }
            try replace(with: responseText(object))
            usage = TranslationUsage.reportedTokens(object["usage"], inputKey: "input_tokens", outputKey: "output_tokens")
        } else {
            guard let choices = object["choices"] as? [[String: Any]], choices.count == 1,
                  let choice = choices.first,
                  let message = choice["message"] as? [String: Any] else {
                throw RemoteTranslationError.invalidResponse
            }
            try checkChatFinish(choice["finish_reason"] as? String)
            try checkMessage(message)
            guard let content = message["content"] as? String else { throw RemoteTranslationError.invalidResponse }
            try replace(with: content)
            usage = TranslationUsage.reportedTokens(object["usage"])
        }
        isComplete = true
        return try completedText()
    }

    func completedText() throws -> String {
        guard isComplete else { throw RemoteTranslationError.incompleteResponse }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteTranslationError.invalidResponse
        }
        return output
    }

    private mutating func consumeChat(_ object: [String: Any]) throws -> String? {
        guard let choices = object["choices"] as? [[String: Any]] else {
            throw RemoteTranslationError.invalidResponse
        }
        // A usage-only event has no choices. It does not complete the stream;
        // the existing stop and [DONE] requirements still apply.
        if let reported = TranslationUsage.reportedTokens(object["usage"]) { usage = reported }
        if choices.isEmpty { return nil }
        guard choices.count == 1, let choice = choices.first,
              (choice["index"] as? Int ?? 0) == 0,
              let delta = choice["delta"] as? [String: Any] else {
            throw RemoteTranslationError.invalidResponse
        }
        try checkMessage(delta)
        var changed = false
        if let content = delta["content"] as? String, !content.isEmpty {
            guard !sawChatStop else { throw RemoteTranslationError.invalidResponse }
            try append(content)
            changed = true
        }
        if let reason = choice["finish_reason"] as? String {
            try checkChatFinish(reason)
            sawChatStop = true
        }
        return changed ? output : nil
    }

    private mutating func consumeResponses(_ object: [String: Any]) throws -> String? {
        guard let type = object["type"] as? String else { throw RemoteTranslationError.invalidResponse }
        switch type {
        case "response.output_text.delta":
            guard let delta = object["delta"] as? String else { throw RemoteTranslationError.invalidResponse }
            try append(delta)
            return delta.isEmpty ? nil : output
        case "response.refusal.delta", "response.refusal.done":
            throw RemoteTranslationError.refused
        case "response.completed":
            guard let response = object["response"] as? [String: Any],
                  response["status"] as? String == "completed" else {
                throw RemoteTranslationError.incompleteResponse
            }
            let finalText = try responseText(response)
            let changed = output != finalText
            try replace(with: finalText)
            usage = TranslationUsage.reportedTokens(response["usage"], inputKey: "input_tokens", outputKey: "output_tokens")
            isComplete = true
            return changed ? output : nil
        case "response.incomplete":
            throw RemoteTranslationError.incompleteResponse
        case "response.failed", "error":
            if let response = object["response"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: response) {
                throw RemoteTranslationError.http(status: 400, body: data)
            }
            let wrapped: [String: Any] = ["error": object]
            let data = (try? JSONSerialization.data(withJSONObject: wrapped)) ?? Data()
            throw RemoteTranslationError.http(status: 400, body: data)
        default:
            // Lifecycle, usage and reasoning events contain no user-facing text.
            return nil
        }
    }

    private func responseText(_ response: [String: Any]) throws -> String {
        guard let items = response["output"] as? [[String: Any]] else { throw RemoteTranslationError.invalidResponse }
        var parts: [String] = []
        var count = 0
        for item in items {
            if item["type"] as? String == "reasoning" { continue }
            guard item["type"] as? String == "message", item["role"] as? String == "assistant",
                  let content = item["content"] as? [[String: Any]] else {
                throw RemoteTranslationError.invalidResponse
            }
            if let status = item["status"] as? String, status != "completed" {
                throw RemoteTranslationError.incompleteResponse
            }
            for part in content {
                if part["type"] as? String == "refusal" { throw RemoteTranslationError.refused }
                guard part["type"] as? String == "output_text", let text = part["text"] as? String else {
                    throw RemoteTranslationError.invalidResponse
                }
                count += text.utf8.count
                guard count <= Self.maximumOutputBytes else { throw RemoteTranslationError.responseTooLarge }
                parts.append(text)
            }
        }
        return parts.joined()
    }

    private func checkMessage(_ message: [String: Any]) throws {
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw RemoteTranslationError.refused }
        if let calls = message["tool_calls"] as? [Any], !calls.isEmpty { throw RemoteTranslationError.invalidResponse }
        if message["function_call"] is [String: Any] { throw RemoteTranslationError.invalidResponse }
        if let role = message["role"] as? String, role != "assistant" { throw RemoteTranslationError.invalidResponse }
        if let content = message["content"], !(content is NSNull) && !(content is String) {
            throw RemoteTranslationError.invalidResponse
        }
    }

    private func checkChatFinish(_ reason: String?) throws {
        switch reason {
        case "stop": return
        case "content_filter": throw RemoteTranslationError.refused
        default: throw RemoteTranslationError.incompleteResponse
        }
    }

    private mutating func append(_ text: String) throws {
        let count = text.utf8.count
        guard outputBytes + count <= Self.maximumOutputBytes else { throw RemoteTranslationError.responseTooLarge }
        output += text
        outputBytes += count
    }

    private mutating func replace(with text: String) throws {
        guard text.utf8.count <= Self.maximumOutputBytes else { throw RemoteTranslationError.responseTooLarge }
        output = text
        outputBytes = text.utf8.count
    }

    private func dictionary(_ data: Data) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RemoteTranslationError.invalidResponse
        }
        return object
    }
}
