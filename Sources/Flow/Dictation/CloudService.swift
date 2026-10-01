import Foundation
import Network
import OSLog

struct CloudResult: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let text: String
    var source: DictationVersion.Source = .cloud
    var configID: UUID?
}

/// What one ladder rung produced.
struct RungOutcome: Sendable {
    let label: String
    /// The transcript, for spoken lists and history.
    let raw: String
    /// Finished text, or nil when this Mac still has to refine `raw`.
    let text: String?
    /// False when refinement is off and the config only used the local transcript.
    let usesCloud: Bool
    let configID: UUID
}

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

actor CloudService {
    private let recordRequest: @Sendable (CloudRequestRecord) -> Void
    init(recordRequest: @escaping @Sendable (CloudRequestRecord) -> Void = { request in
        Task { @MainActor in AppEnvironment.shared.library.recordRequest(request) }
    }) { self.recordRequest = recordRequest }

    private struct Scope: Sendable {
        var dictationID: UUID?
        var configID: UUID?
        var label: String
        var stage: CloudRequestRecord.Stage
        func stage(_ stage: CloudRequestRecord.Stage) -> Scope {
            var copy = self; copy.stage = stage; return copy
        }
    }
    private nonisolated let log = Logger(subsystem: "sh.taf.flow", category: "cloud")
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }()

    /// Called with "Refining with Anthropic · Sonnet" as work starts.
    typealias Progress = @Sendable (String) -> Void
    /// Parallel results that finish after the pasted one, for the menu bar.
    typealias Late = @Sendable (CloudResult) -> Void
    /// Builds the cleanup prompt's context for a transcript, on the main actor.
    typealias MakeContext = @Sendable (String) async -> CleanupContext

    struct Job: Sendable {
        var dictationID: UUID? = nil
        var audio: Data
        /// What this Mac heard. Two-pass configs with a local transcriber refine this.
        var localRaw: String
        var refine: Bool
        var language: TranscriptionLanguage
        var parallel: Bool
    }

    /// Walks the configs top to bottom and returns the first that succeeds.
    ///
    /// In parallel every config starts at once, but the answer is still the
    /// highest-ranked success: Flow waits for config 1 before taking config 2's. It
    /// never waits on configs below the winner; those report through `late`.
    func run(
        _ all: [CloudRung], job: Job, makeContext: @escaping MakeContext,
        progress: @escaping Progress, late: @escaping Late
    ) async -> RungOutcome? {
        // Offline, only servers on this Mac can answer. Skip the rest without waiting.
        let rungs = NetworkStatus.shared.isOnline ? all : all.filter { $0.routes.allSatisfy(\.provider.isLocalhost) }
        if rungs.count < all.count { log.notice("offline, skipping \(all.count - rungs.count) cloud config(s)") }
        guard !rungs.isEmpty else { return nil }

        if !job.parallel || rungs.count == 1 {
            for (index, rung) in rungs.enumerated() {
                do {
                    return try await attempt(rung, number: index + 1, job: job, makeContext: makeContext, progress: progress)
                } catch {
                    // Cancelled requests fail fast; without this, Escape would walk the
                    // whole ladder and hand back to this Mac.
                    if Task.isCancelled { return nil }
                    log.error("config \(index + 1) (\(rung.label, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
                    if Self.isOffline(error) { break }
                }
            }
            return nil
        }

        let quiet: Progress = { _ in }
        let tasks = rungs.enumerated().map { index, rung in
            Task<RungOutcome?, Never> {
                do {
                    return try await self.attempt(rung, number: index + 1, job: job, makeContext: makeContext, progress: quiet)
                } catch {
                    self.log.error("config \(index + 1) (\(rung.label, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
        }
        // These tasks are unstructured, so cancelling the dictation does not reach them
        // on its own.
        return await withTaskCancellationHandler {
            for (index, task) in tasks.enumerated() {
                progress("Waiting for config \(index + 1): \(rungs[index].label)")
                guard let outcome = await task.value else { continue }
                guard !Task.isCancelled else { return nil }
                let rest = Array(tasks.dropFirst(index + 1))
                Task {
                    for task in rest {
                        guard let outcome = await task.value, outcome.usesCloud else { continue }
                        let label = outcome.text == nil ? outcome.label + ", unrefined" : outcome.label
                        late(CloudResult(label: label, text: outcome.text ?? outcome.raw, configID: outcome.configID))
                    }
                }
                return outcome
            }
            return nil
        } onCancel: {
            for task in tasks { task.cancel() }
        }
    }

    private func attempt(
        _ rung: CloudRung, number: Int, job: Job, makeContext: MakeContext, progress: Progress
    ) async throws -> RungOutcome {
        let label = "\(number). \(rung.label)"
        let scope = Scope(dictationID: job.dictationID, configID: rung.id, label: label, stage: .onePass)
        switch rung.step {
        case .onePass(let route):
            // Spoken commands ("scratch that") need this Mac's cleanup to act on them.
            guard job.refine, !CleanupService.soundsLikeCommand(job.localRaw) else { throw CloudError.skipped }
            guard job.audio.count > 44 else { throw CloudError.noAudio }
            progress("Writing with \(route.label)")
            let context = await makeContext(job.localRaw)
            let text = try await onePass(job.audio, route: route, context: context, scope: scope)
            guard job.localRaw.isEmpty || Self.faithful(text, to: job.localRaw, language: job.language) else {
                throw CloudError.strayed
            }
            return RungOutcome(label: label, raw: job.localRaw.isEmpty ? text : job.localRaw, text: text,
                               usesCloud: true, configID: rung.id)

        case .twoPass(let transcriber, let refiner):
            var raw = job.localRaw
            if let transcriber {
                guard job.audio.count > 44 else { throw CloudError.noAudio }
                progress("Transcribing with \(transcriber.label)")
                raw = try await transcribe(job.audio, route: transcriber, language: job.language, scope: scope.stage(.transcription))
            }
            guard !raw.isEmpty else { throw CloudError.invalidResponse }
            guard job.refine, let refiner, !CleanupService.soundsLikeCommand(raw) else {
                return RungOutcome(label: label, raw: raw, text: nil, usesCloud: transcriber != nil, configID: rung.id)
            }
            progress("Refining with \(refiner.label)")
            let context = await makeContext(raw)
            let text = try await refine(raw, route: refiner, context: context, scope: scope.stage(.refinement))
            guard Self.faithful(text, to: raw, language: job.language) else { throw CloudError.strayed }
            return RungOutcome(label: label, raw: raw, text: text, usesCloud: true, configID: rung.id)
        }
    }

    /// The same guard this Mac's cleanup uses: no dropped facts, no invented answers.
    private static func faithful(_ text: String, to spoken: String, language: TranscriptionLanguage) -> Bool {
        CleanupService.isFaithful(text, to: spoken)
            && (language == .hinglish || CleanupService.drawsFromSpeech(text, spoken: spoken))
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

    // MARK: - Requests

    private func transcribe(_ audio: Data, route: CloudRoute, language: TranscriptionLanguage, scope: Scope) async throws -> String {
        let account = route.provider
        switch account.api {
        case .openAI:
            if route.model.audioInput == .multimodal {
                let instruction = language == .hinglish
                    ? "Transcribe this speech exactly. Keep Hindi and English words as spoken. Return only the transcript."
                    : "Transcribe this speech exactly. Return only the transcript."
                let payload = Self.audioChatPayload(audio: audio, modelID: route.model.modelID, instruction: instruction)
                return try chatText(try await sendJSON(account, route.model, path: "chat/completions", payload: payload, scope: scope))
            }
            let boundary = UUID().uuidString
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            field("model", route.model.modelID)
            if language == .hinglish { field("language", "hi") }
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
            body.append(audio)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            let json = try await send(account, path: "audio/transcriptions", body: body,
                                      contentType: "multipart/form-data; boundary=\(boundary)", modelID: route.model.modelID, scope: scope)
            return try nonempty(json["text"] as? String)
        case .google:
            guard ((audio.count + 2) / 3) * 4 < 19_000_000 else { throw CloudError.audioTooLarge }
            let prompt = language == .hinglish
                ? "Transcribe this speech exactly. Keep Hindi and English words as spoken. Return only the transcript."
                : "Transcribe this speech exactly. Return only the transcript."
            let payload: [String: Any] = ["contents": [["parts": [
                ["text": prompt],
                ["inlineData": ["mimeType": "audio/wav", "data": audio.base64EncodedString()]],
            ]]]]
            return try geminiText(try await sendJSON(account, route.model, path: generatePath(route), payload: payload, scope: scope))
        case .anthropic:
            // Anthropic's Messages API accepts text and images, not audio input.
            throw CloudError.unsupportedAudio
        }
    }

    private func onePass(_ audio: Data, route: CloudRoute, context: CleanupContext, scope: Scope) async throws -> String {
        let account = route.provider
        let instruction = "Listen to this recording and return the finished written dictation. Do the transcription and cleanup in this one response. "
            + refinementInstruction(context)
        switch account.api {
        case .openAI:
            let payload = Self.audioChatPayload(audio: audio, modelID: route.model.modelID, instruction: instruction)
            return try chatText(try await sendJSON(account, route.model, path: "chat/completions", payload: payload, scope: scope))
        case .google:
            guard ((audio.count + 2) / 3) * 4 < 19_000_000 else { throw CloudError.audioTooLarge }
            let payload: [String: Any] = ["contents": [["parts": [
                ["text": instruction],
                ["inlineData": ["mimeType": "audio/wav", "data": audio.base64EncodedString()]],
            ]]]]
            return try geminiText(try await sendJSON(account, route.model, path: generatePath(route), payload: payload, scope: scope))
        case .anthropic:
            throw CloudError.unsupportedAudio
        }
    }

    static func audioChatPayload(audio: Data, modelID: String, instruction: String) -> [String: Any] {
        ["model": modelID, "modalities": ["text"], "messages": [["role": "user", "content": [
            ["type": "text", "text": instruction],
            ["type": "input_audio", "input_audio": ["data": audio.base64EncodedString(), "format": "wav"]],
        ]]]]
    }

    private func refine(_ text: String, route: CloudRoute, context: CleanupContext, scope: Scope) async throws -> String {
        let account = route.provider
        let instruction = refinementInstruction(context)
        switch account.api {
        case .openAI:
            let payload: [String: Any] = ["model": route.model.modelID, "messages": [
                ["role": "system", "content": instruction], ["role": "user", "content": text],
            ]]
            return try chatText(try await sendJSON(account, route.model, path: "chat/completions", payload: payload, scope: scope))
        case .google:
            let payload: [String: Any] = ["contents": [["parts": [["text": instruction + "\n\n" + text]]]]]
            return try geminiText(try await sendJSON(account, route.model, path: generatePath(route), payload: payload, scope: scope))
        case .anthropic:
            let payload: [String: Any] = ["model": route.model.modelID, "max_tokens": 4096,
                                          "system": instruction, "messages": [["role": "user", "content": text]]]
            let json = try await sendJSON(account, route.model, path: "messages", payload: payload, scope: scope)
            let blocks = json["content"] as? [[String: Any]]
            return try nonempty(blocks?.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined())
        }
    }

    private func generatePath(_ route: CloudRoute) -> String {
        "models/\(route.model.modelID):generateContent"
    }

    private func refinementInstruction(_ context: CleanupContext) -> String {
        var instruction = DictationCleanupPolicy.instruction
            + "\nThe destination is \(context.appName). \(context.appDescription)."
        switch context.writingContext {
        case .chat: instruction += " Keep casual language and contractions."
        case .email: instruction += " Use complete sentences and readable paragraphs without adding a greeting or signature."
        case .development: instruction += " Preserve technical names, identifiers, commands, and conventional capitalization. Do not turn prose into code."
        case .document: instruction += " Preserve the document's paragraphs and list structure."
        case .browser, .general: instruction += " Match the speaker's tone."
        }
        if context.transcriptionLanguage == .hinglish {
            instruction += " Write Hindi words in Roman-script Hinglish. Keep English words in English."
        }
        if !context.vocabulary.isEmpty { instruction += " Correct terms: \(context.vocabulary.joined(separator: ", "))." }
        if !context.corrections.isEmpty {
            instruction += " Corrections: \(context.corrections.map { "\($0.said) means \($0.meant)" }.joined(separator: "; "))."
        }
        return instruction
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

    /// Every retry is a separate measured request. Streaming falls back to JSON
    /// for compatible servers that reject streaming parameters.
    private func sendJSON(
        _ account: CloudProvider, _ model: CloudModel, path: String, payload: [String: Any], scope: Scope
    ) async throws -> [String: Any] {
        var streaming = true
        var reasoning = model.reasoning != .automatic
        while true {
            var tuned = payload
            if reasoning { Self.applyReasoning(model, api: account.api, to: &tuned) }
            var endpoint = path
            var query: [(String, String)] = []
            if streaming {
                switch account.api {
                case .openAI:
                    tuned["stream"] = true
                    tuned["stream_options"] = ["include_usage": true]
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
                return try await perform(request, provider: account, modelID: model.modelID, scope: scope)
            } catch CloudError.http(let status) where [400, 404, 422].contains(status) {
                if streaming {
                    streaming = false
                    log.notice("\(account.name, privacy: .public) rejected streaming; retrying as JSON")
                } else if reasoning && status != 404 {
                    reasoning = false
                    log.notice("\(account.name, privacy: .public) rejected reasoning; retrying with model defaults")
                } else { throw CloudError.http(status) }
            }
        }
    }

    private func chatText(_ json: [String: Any]) throws -> String {
        let choices = json["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        if let text = message?["content"] as? String { return try nonempty(text) }
        let parts = message?["content"] as? [[String: Any]]
        return try nonempty(parts?.compactMap { $0["text"] as? String }.joined())
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

    private func send(_ account: CloudProvider, path: String, body: Data, contentType: String,
                      modelID: String, scope: Scope) async throws -> [String: Any] {
        var request = try request(account, path: path)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return try await perform(request, provider: account, modelID: modelID, scope: scope)
    }

    private func get(_ account: CloudProvider, path: String, query: [(String, String)]) async throws -> [String: Any] {
        var request = try request(account, path: path, query: query)
        request.timeoutInterval = 10
        return try await perform(request, provider: account, modelID: "",
                                 scope: Scope(label: "Model listing", stage: .models))
    }

    private func perform(_ request: URLRequest, provider: CloudProvider,
                         modelID: String, scope: Scope) async throws -> [String: Any] {
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
                Task {
                    if let price = await ModelPricing.shared.price(provider: provider, modelID: modelID,
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
            if http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true {
                var count = 0
                for try await byte in bytes {
                    try Task.checkCancellation()
                    count += 1
                    if count > 16_000_000 { throw CloudError.invalidResponse }
                    try stream.byte(byte, elapsed: (ContinuousClock.now - start).timeInterval)
                }
                try stream.finish(elapsed: (ContinuousClock.now - start).timeInterval)
                json = try stream.responseJSON()
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
            if scope.stage == .models { record.usage = TokenUsage(input: 0, output: 0) }
            record.status = .succeeded
            return json
        } catch {
            record.status = Task.isCancelled || error is CancellationError ? .cancelled : .failed
            // Keep request metadata, not payloads, response text, URLs, or credentials.
            record.error = error is CloudError ? error.localizedDescription : String(describing: type(of: error))
            throw error
        }
    }

    private func geminiText(_ json: [String: Any]) throws -> String {
        let candidates = json["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        return try nonempty(parts?.filter { $0["thought"] as? Bool != true }
            .compactMap { $0["text"] as? String }.joined())
    }

    private func nonempty(_ text: String?) throws -> String {
        guard let result = text?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else {
            throw CloudError.invalidResponse
        }
        return DictationCleanupPolicy.withoutEmDashes(result)
    }

    private static func isOffline(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dataNotAllowed].contains(error.code)
    }

    enum CloudError: LocalizedError {
        case invalidURL, invalidResponse, unsupportedAudio, audioTooLarge, http(Int)
        case skipped, noAudio, strayed
        var errorDescription: String? {
            switch self {
            case .invalidURL: "Use an HTTPS base URL, or HTTP on localhost."
            case .invalidResponse: "The provider returned no text."
            case .unsupportedAudio: "Anthropic Messages does not accept audio input."
            case .audioTooLarge: "The recording is too large for inline Gemini audio."
            case .http(401), .http(403): "The provider refused the API key."
            case .http(404): "Not found. Check the base URL and model ID."
            case .http(let status): "Provider returned HTTP \(status)."
            case .skipped: "Skipped: refinement is off or the speech was a command."
            case .noAudio: "No recorded audio to send."
            case .strayed: "The answer strayed from what was said."
            }
        }
    }
}
