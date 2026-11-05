import Foundation
import Network
import OSLog

// Everything in Cloud/ talks to providers and knows nothing about dictation.
// scripts/check.sh typechecks this folder on its own to keep it that way.

/// Whether the Mac has a route to the internet. Checked before each dictation so an
/// offline Mac goes straight to the on-device models instead of waiting on timeouts.
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock { self.online = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "sh.taf.flow.network"))
    }

    var isOnline: Bool { lock.withLock { online } }
}

enum CloudError: LocalizedError {
    case invalidURL, invalidResponse, unsupportedAudio, audioTooLarge, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Use an HTTPS base URL, or HTTP on localhost."
        case .invalidResponse: "The provider returned no text."
        case .unsupportedAudio: "Anthropic Messages does not accept audio input."
        case .audioTooLarge: "The recording is too large for inline Gemini audio."
        case .http(401), .http(403): "The provider refused the API key."
        case .http(404): "Not found. Check the base URL and model ID."
        case .http(let status): "Provider returned HTTP \(status)."
        }
    }

    static func isOffline(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dataNotAllowed].contains(error.code)
    }
}

/// What a request belongs to. Saved with its metadata in the request log.
struct CloudRequestScope: Sendable {
    var dictationID: UUID?
    var configID: UUID?
    var label: String
    var stage: CloudRequestRecord.Stage
    func stage(_ stage: CloudRequestRecord.Stage) -> CloudRequestScope {
        var copy = self; copy.stage = stage; return copy
    }
}

/// Sends requests to OpenAI, Gemini and Anthropic compatible APIs. Handles auth,
/// streaming with JSON fallback, reasoning settings, usage, pricing and the request log.
actor CloudClient {
    /// Cumulative text snapshots while a response streams.
    typealias Preview = @Sendable (String) async -> Void
    typealias RecordRequest = @Sendable (CloudRequestRecord) -> Void

    private struct StreamingKey: Hashable {
        var providerID: UUID
        var api: CloudAPI
        var baseURL: String
        var modelID: String
        var path: String
        var reasoning: CloudReasoning
    }
    private var streamingSupport: [StreamingKey: Bool] = [:]
    private var usageOptionsSupport: [StreamingKey: Bool] = [:]
    private let recordRequest: RecordRequest
    private let pricing: ModelPricing
    private nonisolated let log = Logger(subsystem: "sh.taf.flow", category: "cloud")
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }()

    /// `recordRequest` gets each request twice or three times: when it starts, when it
    /// ends, and again once its price is known.
    init(recordRequest: @escaping RecordRequest, pricing: ModelPricing = .shared) {
        self.recordRequest = recordRequest
        self.pricing = pricing
    }

    func resetStreamingSupport(providerID: UUID) {
        streamingSupport = streamingSupport.filter { $0.key.providerID != providerID }
        usageOptionsSupport = usageOptionsSupport.filter { $0.key.providerID != providerID }
    }

    // MARK: - Model listing

    /// The model IDs a provider serves, for the model picker and as a connection test.
    func listModels(_ provider: CloudProvider) async throws -> [String] {
        let json: [String: Any]
        switch provider.api {
        case .openAI, .anthropic:
            json = try await get(provider, path: "models", query: provider.api == .anthropic ? [("limit", "1000")] : [])
            let data = json["data"] as? [[String: Any]] ?? []
            return data.compactMap { $0["id"] as? String }.sorted()
        case .google:
            json = try await get(provider, path: "models", query: [("pageSize", "1000")])
            let models = json["models"] as? [[String: Any]] ?? []
            return models.compactMap { model in
                (model["name"] as? String).map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
            }.sorted()
        }
    }

    // MARK: - Payloads and replies

    static func generatePath(_ model: CloudModel) -> String {
        "models/\(model.modelID):generateContent"
    }

    static func audioChatPayload(audio: Data, modelID: String, instruction: String) -> [String: Any] {
        ["model": modelID, "modalities": ["text"], "messages": [["role": "user", "content": [
            ["type": "text", "text": instruction],
            ["type": "input_audio", "input_audio": ["data": audio.base64EncodedString(), "format": "wav"]],
        ]]]]
    }

    /// Adds the model's reasoning setting in the shape its API expects.
    static func applyReasoning(_ model: CloudModel, api: CloudAPI, to payload: inout [String: Any]) {
        let level = model.reasoning
        guard level != .automatic else { return }
        switch api {
        case .openAI:
            payload["reasoning_effort"] = level == .off ? "minimal" : level.rawValue
        case .google:
            if model.modelID.contains("2.5") {
                let budgets: [CloudReasoning: Int] = [.off: 0, .low: 1024, .medium: 4096, .high: 8192]
                payload["generationConfig"] = ["thinkingConfig": ["thinkingBudget": budgets[level] ?? -1]]
            } else {
                payload["generationConfig"] = ["thinkingConfig": ["thinkingLevel": level == .off ? "minimal" : level.rawValue]]
            }
        case .anthropic:
            // Current Claude models reject disabled thinking. Low effort is the floor.
            payload["output_config"] = ["effort": level == .off ? "low" : level.rawValue]
        }
    }

    /// Trimmed reply text from an OpenAI chat completion.
    static func chatText(_ json: [String: Any]) throws -> String {
        let choices = json["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        if let text = message?["content"] as? String { return try nonempty(text) }
        let parts = message?["content"] as? [[String: Any]]
        return try nonempty(parts?.compactMap { $0["text"] as? String }.joined())
    }

    /// Trimmed reply text from a Gemini response, without thought parts.
    static func geminiText(_ json: [String: Any]) throws -> String {
        let candidates = json["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        return try nonempty(parts?.filter { $0["thought"] as? Bool != true }
            .compactMap { $0["text"] as? String }.joined())
    }

    /// Trimmed reply text from an Anthropic message, without thinking blocks.
    static func anthropicText(_ json: [String: Any]) throws -> String {
        let blocks = json["content"] as? [[String: Any]]
        return try nonempty(blocks?.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined())
    }

    static func nonempty(_ text: String?) throws -> String {
        guard let result = text?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else {
            throw CloudError.invalidResponse
        }
        return result
    }

    static func outputWordCount(_ json: [String: Any], api: CloudAPI) -> Int? {
        let text: String?
        if let transcript = json["text"] as? String {
            text = transcript
        } else {
            switch api {
            case .openAI:
                let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
                text = message?["content"] as? String
                    ?? (message?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
            case .google:
                let content = (json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any]
                text = (content?["parts"] as? [[String: Any]])?.filter { $0["thought"] as? Bool != true }
                    .compactMap { $0["text"] as? String }.joined()
            case .anthropic:
                text = (json["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }.joined()
            }
        }
        return text.map { $0.split(whereSeparator: \.isWhitespace).count }
    }

    // MARK: - Requests

    /// Posts a JSON payload. Every retry is a separate measured request. Streaming
    /// falls back to JSON for compatible servers that reject streaming parameters.
    func sendJSON(
        _ account: CloudProvider, _ model: CloudModel, path: String, payload: [String: Any],
        scope: CloudRequestScope, preview: @escaping Preview = { _ in }
    ) async throws -> sending [String: Any] {
        let key = StreamingKey(providerID: account.id, api: account.api, baseURL: account.baseURL,
                               modelID: model.modelID, path: path, reasoning: model.reasoning)
        var streaming = account.streaming == .automatic && streamingSupport[key] != false
        var usageOptions = usageOptionsSupport[key] != false
        var reasoning = model.reasoning != .automatic
        while true {
            var tuned = payload
            if reasoning { Self.applyReasoning(model, api: account.api, to: &tuned) }
            var endpoint = path
            var query: [(String, String)] = []
            if account.api != .google { tuned["stream"] = streaming }
            if streaming {
                switch account.api {
                case .openAI:
                    tuned["stream"] = true
                    if usageOptions { tuned["stream_options"] = ["include_usage": true] }
                case .anthropic: tuned["stream"] = true
                case .google:
                    endpoint = path.replacingOccurrences(of: ":generateContent", with: ":streamGenerateContent")
                    query = [("alt", "sse")]
                }
            }
            do {
                var request = try request(account, path: endpoint, query: query)
                request.httpMethod = "POST"
                request.httpBody = try JSONSerialization.data(withJSONObject: tuned)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if streaming { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
                let json = try await perform(request, provider: account, modelID: model.modelID, scope: scope,
                                             preview: preview, allowStreaming: streaming,
                                             streamingKey: account.streaming == .automatic ? key : nil)
                if streaming, !usageOptions { usageOptionsSupport[key] = false }
                return json
            } catch CloudError.http(let status) where [400, 404, 405, 406, 415, 422, 501].contains(status) {
                if streaming, usageOptions, account.api == .openAI, [400, 422].contains(status) {
                    // Older compatible servers stream text but reject optional usage.
                    usageOptions = false
                } else if reasoning && [400, 422].contains(status) {
                    reasoning = false
                    log.notice("\(account.name, privacy: .public) rejected reasoning; retrying with model defaults")
                } else if streaming {
                    streaming = false
                    log.notice("\(account.name, privacy: .public) rejected streaming; retrying as JSON")
                } else { throw CloudError.http(status) }
            }
        }
    }

    /// Posts a prebuilt body, such as a multipart form for a transcription endpoint.
    func send(_ account: CloudProvider, path: String, body: Data, contentType: String,
              modelID: String, scope: CloudRequestScope) async throws -> sending [String: Any] {
        var request = try request(account, path: path)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return try await perform(request, provider: account, modelID: modelID, scope: scope)
    }

    private func request(_ account: CloudProvider, path: String, query: [(String, String)] = []) throws -> URLRequest {
        guard let base = URL(string: account.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = base.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && account.isLocalhost) else {
            throw CloudError.invalidURL
        }
        var url = base.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query.map { URLQueryItem(name: $0.0, value: $0.1) }) }
        var request = URLRequest(url: url)
        switch account.api {
        case .openAI:
            if !account.apiKey.isEmpty { request.setValue("Bearer \(account.apiKey)", forHTTPHeaderField: "Authorization") }
        case .google:
            if !account.apiKey.isEmpty { request.setValue(account.apiKey, forHTTPHeaderField: "x-goog-api-key") }
        case .anthropic:
            if !account.apiKey.isEmpty { request.setValue(account.apiKey, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return request
    }

    private func get(_ account: CloudProvider, path: String, query: [(String, String)]) async throws -> [String: Any] {
        var request = try request(account, path: path, query: query)
        request.timeoutInterval = 10
        return try await perform(request, provider: account, modelID: "",
                                 scope: CloudRequestScope(label: "Model listing", stage: .models))
    }

    private func perform(_ request: URLRequest, provider: CloudProvider,
                         modelID: String, scope: CloudRequestScope, preview: @escaping Preview = { _ in },
                         allowStreaming: Bool = false, streamingKey: StreamingKey? = nil) async throws -> sending [String: Any] {
        var record = CloudRequestRecord(dictationID: scope.dictationID, configID: scope.configID,
                                        configLabel: scope.label, providerID: provider.id,
                                        providerName: provider.name, modelID: modelID, stage: scope.stage)
        let start = ContinuousClock.now
        recordRequest(record)
        var stream = CloudStream(api: provider.api)
        defer {
            record.elapsed = (ContinuousClock.now - start).timeInterval
            record.firstTokenLatency = stream.firstOutput
            if let first = stream.firstOutput, let last = stream.lastOutput, last > first {
                record.generationDuration = last - first
            }
            if stream.usage.input != nil || stream.usage.output != nil { record.usage = stream.usage }
            recordRequest(record)
            if record.isInference {
                let completed = record
                let report = recordRequest
                let pricing = pricing
                Task {
                    if let price = await pricing.price(provider: provider, modelID: modelID,
                                                       inputTokens: completed.usage.input) {
                        var priced = completed
                        priced.price = price
                        report(priced)
                    }
                }
            }
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            record.httpStatus = (response as? HTTPURLResponse)?.statusCode
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw CloudError.http(record.httpStatus ?? 0)
            }
            let json: [String: Any]
            let isStream = http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
            if isStream {
                var count = 0
                var visibleCount = 0
                var lastPreview = start
                for try await byte in bytes {
                    try Task.checkCancellation()
                    count += 1
                    if count > 16_000_000 { throw CloudError.invalidResponse }
                    try stream.byte(byte, elapsed: (ContinuousClock.now - start).timeInterval)
                    if allowStreaming, stream.text.utf8.count != visibleCount,
                       visibleCount == 0 || ContinuousClock.now - lastPreview >= .milliseconds(50) {
                        visibleCount = stream.text.utf8.count
                        lastPreview = .now
                        await preview(stream.text)
                    }
                }
                try stream.finish(elapsed: (ContinuousClock.now - start).timeInterval)
                json = try stream.responseJSON()
                if allowStreaming { await preview(stream.text) }
            } else {
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    data.append(byte)
                    if data.count > 16_000_000 { throw CloudError.invalidResponse }
                }
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] == nil else {
                    throw CloudError.invalidResponse
                }
                json = object
                record.usage = TokenUsage.parse(json, api: provider.api)
            }
            if let streamingKey { streamingSupport[streamingKey] = allowStreaming && isStream }
            if scope.stage == .models { record.usage = TokenUsage(input: 0, output: 0) }
            if record.isInference { record.outputWords = Self.outputWordCount(json, api: provider.api) }
            record.status = .succeeded
            return json
        } catch {
            record.status = Task.isCancelled || error is CancellationError ? .cancelled : .failed
            // Keep request metadata, not payloads, response text, URLs, or credentials.
            record.error = error is CloudError ? error.localizedDescription : String(describing: type(of: error))
            throw error
        }
    }
}
