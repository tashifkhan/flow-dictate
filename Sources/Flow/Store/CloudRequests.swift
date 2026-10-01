import Foundation

struct TokenUsage: Codable, Equatable, Sendable {
    var input: Int?
    /// Includes separately reported reasoning tokens, which are billed as output.
    var output: Int?
    var reasoning = 0
    var cachedInput = 0
    var cacheWrite = 0
    var audioInput = 0
    var audioOutput = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var unseparatedThinking = false

    var visibleOutput: Int? { unseparatedThinking ? nil : output.map { max(0, $0 - reasoning) } }

    static func parse(_ json: [String: Any], api: CloudAPI) -> TokenUsage {
        var result = TokenUsage()
        func count(_ object: [String: Any], _ key: String) -> Int? {
            (object[key] as? NSNumber).map { max(0, $0.intValue) }
        }
        switch api {
        case .openAI:
            let usage = json["usage"] as? [String: Any] ?? [:]
            result.input = count(usage, "prompt_tokens") ?? count(usage, "input_tokens")
            result.output = count(usage, "completion_tokens") ?? count(usage, "output_tokens")
            let input = usage["prompt_tokens_details"] as? [String: Any] ?? usage["input_token_details"] as? [String: Any] ?? [:]
            let output = usage["completion_tokens_details"] as? [String: Any] ?? [:]
            result.cachedInput = count(input, "cached_tokens") ?? 0
            result.audioInput = count(input, "audio_tokens") ?? 0
            result.audioOutput = count(output, "audio_tokens") ?? 0
            result.reasoning = count(output, "reasoning_tokens") ?? 0
        case .google:
            if let usage = json["usage"] as? [String: Any] {
                result.input = count(usage, "total_input_tokens")
                result.reasoning = count(usage, "total_thought_tokens") ?? 0
                if let output = count(usage, "total_output_tokens") { result.output = output + result.reasoning }
                result.cachedInput = count(usage, "total_cached_tokens") ?? 0
                let details = usage["input_tokens_by_modality"] as? [[String: Any]] ?? []
                result.audioInput = details.filter { ($0["modality"] as? String)?.lowercased() == "audio" }
                    .reduce(0) { $0 + (count($1, "tokens") ?? 0) }
                return result
            }
            let usage = json["usageMetadata"] as? [String: Any] ?? [:]
            result.input = count(usage, "promptTokenCount")
            result.reasoning = count(usage, "thoughtsTokenCount") ?? 0
            if let candidates = count(usage, "candidatesTokenCount") { result.output = candidates + result.reasoning }
            result.cachedInput = count(usage, "cachedContentTokenCount") ?? 0
            let details = usage["promptTokensDetails"] as? [[String: Any]] ?? []
            result.audioInput = details.filter { $0["modality"] as? String == "AUDIO" }
                .reduce(0) { $0 + (count($1, "tokenCount") ?? 0) }
        case .anthropic:
            let message = json["message"] as? [String: Any] ?? json
            let usage = message["usage"] as? [String: Any] ?? [:]
            result.cachedInput = count(usage, "cache_read_input_tokens") ?? 0
            result.cacheWrite = count(usage, "cache_creation_input_tokens") ?? 0
            let cache = usage["cache_creation"] as? [String: Any] ?? [:]
            result.cacheWrite5m = count(cache, "ephemeral_5m_input_tokens") ?? 0
            result.cacheWrite1h = count(cache, "ephemeral_1h_input_tokens") ?? 0
            if let input = count(usage, "input_tokens") {
                result.input = input + result.cachedInput + result.cacheWrite
            }
            result.output = count(usage, "output_tokens")
        }
        return result
    }
}

struct CloudRequestRecord: Codable, Identifiable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable { case onePass, transcription, refinement, models }
    enum Status: String, Codable, Sendable { case running, succeeded, failed, cancelled, interrupted }
    var id = UUID()
    var dictationID: UUID?
    var configID: UUID?
    var configLabel: String
    var providerID: UUID
    var providerName: String
    var modelID: String
    var stage: Stage
    var startedAt = Date.now
    var elapsed: TimeInterval?
    /// First visible output chunk, rather than headers or a thinking event.
    var firstTokenLatency: TimeInterval?
    var generationDuration: TimeInterval?
    var status: Status = .running
    var httpStatus: Int?
    var error: String?
    var usage = TokenUsage()
    var price: ModelPrice?

    var isInference: Bool { stage != .models }
    var inputCost: Double? { price?.inputCost(usage) }
    var outputCost: Double? { price?.outputCost(usage) }
    var estimatedCost: Double? {
        guard isInference else { return 0 }
        guard let inputCost, let outputCost else { return nil }
        return inputCost + outputCost
    }
    /// Generation throughput is unavailable for one-chunk or non-streamed replies.
    var tokensPerSecond: Double? {
        guard let tokens = usage.visibleOutput, let generationDuration, generationDuration > 0 else { return nil }
        return Double(tokens) / generationDuration
    }
    var effectiveTokensPerSecond: Double? {
        guard let tokens = usage.visibleOutput, let elapsed, elapsed > 0 else { return nil }
        return Double(tokens) / elapsed
    }
    var stageLabel: String {
        switch stage {
        case .onePass: "Audio and cleanup"
        case .transcription: "Transcription"
        case .refinement: "Cleanup"
        case .models: "Model listing"
        }
    }
}

enum RequestDisplay {
    static func money(_ value: Double?) -> String {
        guard let value else { return "Unknown" }
        return String(format: "$%.6f", value)
    }
    static func seconds(_ value: Double?) -> String {
        value.map { String(format: "%.2fs", $0) } ?? "Unavailable"
    }
    static func tokens(_ value: Int?) -> String { value.map(String.init) ?? "Not reported" }
    static func speed(_ value: Double?) -> String {
        value.map { String(format: "%.1f tokens/s", $0) } ?? "Unavailable"
    }
}

struct CloudCostSummary {
    let requests: [CloudRequestRecord]
    var calls: Int { requests.filter(\.isInference).count }
    var knownCost: Double { requests.compactMap(\.estimatedCost).reduce(0, +) }
    var unpricedCalls: Int { requests.filter { $0.isInference && $0.estimatedCost == nil }.count }
    var inputTokens: Int { requests.compactMap(\.usage.input).reduce(0, +) }
    var outputTokens: Int { requests.compactMap(\.usage.output).reduce(0, +) }
    var completed: Int { requests.filter { $0.status == .succeeded }.count }
}

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
