import Foundation

/// Combines provider SSE events without exposing partial text to the destination.
/// Token counts come from usage events, never from counting characters or words.
struct CloudStream {
    let api: CloudAPI
    private(set) var text = ""
    private(set) var usage = TokenUsage()
    private(set) var firstOutput: TimeInterval?
    private(set) var lastOutput: TimeInterval?
    private(set) var ended = false
    private(set) var providerError = false
    private var dataLines: [String] = []
    private var thinkingSeen = false
    private var lineBytes = Data()

    /// AsyncBytes.lines omits empty lines. SSE needs those separators, so retain them.
    mutating func byte(_ byte: UInt8, elapsed: TimeInterval) throws {
        if byte == 10 {
            if lineBytes.last == 13 { lineBytes.removeLast() }
            guard let value = String(data: lineBytes, encoding: .utf8) else { throw CloudService.CloudError.invalidResponse }
            lineBytes.removeAll(keepingCapacity: true)
            try line(value, elapsed: elapsed)
        } else {
            lineBytes.append(byte)
            if lineBytes.count > 4_000_000 { throw CloudService.CloudError.invalidResponse }
        }
    }

    mutating func finish(elapsed: TimeInterval) throws {
        if !lineBytes.isEmpty {
            guard let value = String(data: lineBytes, encoding: .utf8) else { throw CloudService.CloudError.invalidResponse }
            try line(value, elapsed: elapsed)
            lineBytes.removeAll()
        }
        try flush(elapsed: elapsed)
    }

    mutating func line(_ line: String, elapsed: TimeInterval) throws {
        if line.isEmpty { try flush(elapsed: elapsed) }
        else if line.hasPrefix("data:") {
            let value = line.dropFirst(5)
            dataLines.append(value.first == " " ? String(value.dropFirst()) : String(value))
        }
    }

    mutating func flush(elapsed: TimeInterval) throws {
        guard !dataLines.isEmpty else { return }
        let value = dataLines.joined(separator: "\n")
        dataLines = []
        if value == "[DONE]" { ended = true; return }
        guard let data = value.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudService.CloudError.invalidResponse
        }
        consume(json, elapsed: elapsed)
    }

    mutating func consume(_ json: [String: Any], elapsed: TimeInterval) {
        if json["error"] != nil || json["type"] as? String == "error" { providerError = true }
        var fragment = ""
        let parsed = TokenUsage.parse(json, api: api)
        switch api {
        case .openAI:
            let choices = json["choices"] as? [[String: Any]] ?? []
            let delta = choices.first?["delta"] as? [String: Any] ?? [:]
            fragment = delta["content"] as? String ?? ""
            if let reason = choices.first?["finish_reason"] as? String {
                ended = true
                if reason != "stop" { providerError = true }
            }
            if parsed.input != nil || parsed.output != nil { usage = parsed }
        case .google:
            let candidates = json["candidates"] as? [[String: Any]] ?? []
            let content = candidates.first?["content"] as? [String: Any] ?? [:]
            let parts = content["parts"] as? [[String: Any]] ?? []
            fragment = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
            if let reason = candidates.first?["finishReason"] as? String {
                ended = true
                if reason != "STOP" { providerError = true }
            }
            if parsed.input != nil { usage.input = parsed.input; usage.audioInput = parsed.audioInput; usage.cachedInput = parsed.cachedInput }
            if parsed.output != nil { usage.output = parsed.output; usage.reasoning = parsed.reasoning }
        case .anthropic:
            let type = json["type"] as? String
            if type == "message_start" { usage = parsed }
            if type == "message_delta", parsed.output != nil { usage.output = parsed.output }
            if type == "message_delta", let delta = json["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String, !["end_turn", "stop_sequence"].contains(reason) {
                providerError = true
            }
            if type == "content_block_delta", let delta = json["delta"] as? [String: Any] {
                if delta["type"] as? String == "text_delta" { fragment = delta["text"] as? String ?? "" }
                if delta["type"] as? String == "thinking_delta" { thinkingSeen = true }
            }
            if type == "message_stop" { ended = true }
            usage.unseparatedThinking = thinkingSeen
        }
        if !fragment.isEmpty {
            text += fragment
            if !fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if firstOutput == nil { firstOutput = elapsed }
                lastOutput = elapsed
            }
        }
    }

    func responseJSON() throws -> [String: Any] {
        guard ended, !providerError, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudService.CloudError.invalidResponse
        }
        switch api {
        case .openAI: return ["choices": [["message": ["content": text]]]]
        case .google: return ["candidates": [["content": ["parts": [["text": text]]]]]]
        case .anthropic: return ["content": [["type": "text", "text": text]]]
        }
    }
}
