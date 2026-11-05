import Foundation
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

/// Dictation's cloud ladder: picks configs, builds prompts, and checks each answer
/// against what was said. Requests go through `CloudClient`.
actor CloudService {
    private let client: CloudClient

    /// Requests land in the app's request log unless a check collects them.
    static let recordToLibrary: CloudClient.RecordRequest = { request in
        Task { @MainActor in AppEnvironment.shared.library.recordRequest(request) }
    }
    init(recordRequest: @escaping CloudClient.RecordRequest = CloudService.recordToLibrary) {
        client = CloudClient(recordRequest: recordRequest)
    }

    func resetStreamingSupport(providerID: UUID) async {
        await client.resetStreamingSupport(providerID: providerID)
    }

    /// The model IDs a provider serves, for the model picker and as a connection test.
    func listModels(_ provider: CloudProvider) async throws -> [String] {
        try await client.listModels(provider)
    }

    private nonisolated let log = Logger(subsystem: "sh.taf.flow", category: "cloud")

    /// Called with "Refining with Anthropic · Sonnet" as work starts.
    typealias Progress = @Sendable (String) -> Void
    /// Cumulative text snapshots from the selected config's writing stage.
    typealias Preview = CloudClient.Preview
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
        progress: @escaping Progress, late: @escaping Late, preview: @escaping Preview = { _ in }
    ) async -> RungOutcome? {
        // Offline, only servers on this Mac can answer. Skip the rest without waiting.
        let rungs = NetworkStatus.shared.isOnline ? all : all.filter { $0.routes.allSatisfy(\.provider.isLocalhost) }
        if rungs.count < all.count { log.notice("offline, skipping \(all.count - rungs.count) cloud config(s)") }
        guard !rungs.isEmpty else { return nil }

        if !job.parallel || rungs.count == 1 {
            for (index, rung) in rungs.enumerated() {
                do {
                    return try await attempt(rung, number: index + 1, job: job, makeContext: makeContext, progress: progress, preview: preview)
                } catch {
                    // Cancelled requests fail fast; without this, Escape would walk the
                    // whole ladder and hand back to this Mac.
                    if Task.isCancelled { return nil }
                    await preview("")
                    log.error("config \(index + 1) (\(rung.label, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
                    if CloudError.isOffline(error) { break }
                }
            }
            return nil
        }

        let selection = CloudPreviewSelection(preview: preview)
        let quiet: Progress = { _ in }
        let tasks = rungs.enumerated().map { index, rung in
            Task<RungOutcome?, Never> {
                do {
                    return try await self.attempt(rung, number: index + 1, job: job, makeContext: makeContext, progress: quiet,
                                                  preview: { text in await selection.update(index: index, text: text) })
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
                await selection.activate(index: index)
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
        _ rung: CloudRung, number: Int, job: Job, makeContext: MakeContext, progress: Progress, preview: @escaping Preview
    ) async throws -> RungOutcome {
        let label = "\(number). \(rung.label)"
        let scope = CloudRequestScope(dictationID: job.dictationID, configID: rung.id, label: label, stage: .onePass)
        switch rung.step {
        case .onePass(let route):
            // Spoken commands ("scratch that") need this Mac's cleanup to act on them.
            guard job.refine, !CleanupService.soundsLikeCommand(job.localRaw) else { throw LadderError.skipped }
            guard job.audio.count > 44 else { throw LadderError.noAudio }
            progress("Writing with \(route.label)")
            var context = await makeContext(job.localRaw)
            // The audio writer preserves alias phrases. Resolve explicit user rules
            // once here, after transcription, just as the two-pass route does.
            context.corrections = []
            let substitutions = context.substitutions
            let text = try await onePass(job.audio, route: route, context: context, scope: scope,
                                         preview: { text in await preview(substitutions.apply(text)) })
            let resolved = context.substitutions.apply(text)
            guard job.localRaw.isEmpty || (Self.faithful(resolved, to: context.substitutions.apply(job.localRaw), language: job.language)
                && context.substitutions.preservesValues(in: resolved, source: job.localRaw)) else {
                throw LadderError.strayed
            }
            return RungOutcome(label: label, raw: job.localRaw.isEmpty ? text : job.localRaw, text: resolved,
                               usesCloud: true, configID: rung.id)

        case .twoPass(let transcriber, let refiner):
            var raw = job.localRaw
            if let transcriber {
                guard job.audio.count > 44 else { throw LadderError.noAudio }
                progress("Transcribing with \(transcriber.label)")
                raw = try await transcribe(job.audio, route: transcriber, language: job.language, scope: scope.stage(.transcription))
            }
            guard !raw.isEmpty else { throw CloudError.invalidResponse }
            guard job.refine, let refiner, !CleanupService.soundsLikeCommand(raw) else {
                return RungOutcome(label: label, raw: raw, text: nil, usesCloud: transcriber != nil, configID: rung.id)
            }
            progress("Refining with \(refiner.label)")
            let context = await makeContext(raw)
            let resolvedRaw = context.substitutions.apply(raw)
            let text = context.substitutions.normalizeVocabulary(in: try await refine(resolvedRaw, route: refiner, context: context, scope: scope.stage(.refinement), preview: preview))
            guard Self.faithful(text, to: resolvedRaw, language: job.language),
                  context.substitutions.preservesValues(in: text, source: raw) else { throw LadderError.strayed }
            return RungOutcome(label: label, raw: raw, text: text, usesCloud: true, configID: rung.id)
        }
    }

    /// The same guard this Mac's cleanup uses: no dropped facts, no invented answers.
    private static func faithful(_ text: String, to spoken: String, language: TranscriptionLanguage) -> Bool {
        CleanupService.isFaithful(text, to: spoken)
            && (language == .hinglish || CleanupService.drawsFromSpeech(text, spoken: spoken))
    }

    // MARK: - Requests

    private func transcribe(_ audio: Data, route: CloudRoute, language: TranscriptionLanguage, scope: CloudRequestScope) async throws -> String {
        let account = route.provider
        switch account.api {
        case .openAI:
            if route.model.audioInput == .multimodal {
                let instruction = PromptLibrary.render(language == .hinglish ? "cloud-transcription.hinglish" : "cloud-transcription.plain")
                let payload = CloudClient.audioChatPayload(audio: audio, modelID: route.model.modelID, instruction: instruction)
                return try Self.cleaned(CloudClient.chatText(try await client.sendJSON(account, route.model, path: "chat/completions", payload: payload, scope: scope)))
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
            let json = try await client.send(account, path: "audio/transcriptions", body: body,
                                      contentType: "multipart/form-data; boundary=\(boundary)", modelID: route.model.modelID, scope: scope)
            return try Self.cleaned(CloudClient.nonempty(json["text"] as? String))
        case .google:
            guard ((audio.count + 2) / 3) * 4 < 19_000_000 else { throw CloudError.audioTooLarge }
            let prompt = PromptLibrary.render(language == .hinglish ? "cloud-transcription.hinglish" : "cloud-transcription.plain")
            let payload: [String: Any] = ["contents": [["parts": [
                ["text": prompt],
                ["inlineData": ["mimeType": "audio/wav", "data": audio.base64EncodedString()]],
            ]]]]
            return try Self.cleaned(CloudClient.geminiText(try await client.sendJSON(account, route.model, path: CloudClient.generatePath(route.model), payload: payload, scope: scope)))
        case .anthropic:
            // Anthropic's Messages API accepts text and images, not audio input.
            throw CloudError.unsupportedAudio
        }
    }

    private func onePass(_ audio: Data, route: CloudRoute, context: CleanupContext, scope: CloudRequestScope, preview: @escaping Preview) async throws -> String {
        let account = route.provider
        let instruction = Self.refinementInstruction(context, audio: true)
        switch account.api {
        case .openAI:
            let payload = CloudClient.audioChatPayload(audio: audio, modelID: route.model.modelID, instruction: instruction)
            return try Self.cleaned(CloudClient.chatText(try await client.sendJSON(account, route.model, path: "chat/completions", payload: payload, scope: scope, preview: preview)))
        case .google:
            guard ((audio.count + 2) / 3) * 4 < 19_000_000 else { throw CloudError.audioTooLarge }
            let payload: [String: Any] = ["contents": [["parts": [
                ["text": instruction],
                ["inlineData": ["mimeType": "audio/wav", "data": audio.base64EncodedString()]],
            ]]]]
            return try Self.cleaned(CloudClient.geminiText(try await client.sendJSON(account, route.model, path: CloudClient.generatePath(route.model), payload: payload, scope: scope, preview: preview)))
        case .anthropic:
            throw CloudError.unsupportedAudio
        }
    }

    private func refine(_ text: String, route: CloudRoute, context: CleanupContext, scope: CloudRequestScope, preview: @escaping Preview) async throws -> String {
        let account = route.provider
        let instruction = Self.refinementInstruction(context)
        switch account.api {
        case .openAI:
            let payload: [String: Any] = ["model": route.model.modelID, "messages": [
                ["role": "system", "content": instruction], ["role": "user", "content": text],
            ]]
            return try Self.cleaned(CloudClient.chatText(try await client.sendJSON(account, route.model, path: "chat/completions", payload: payload, scope: scope, preview: preview)))
        case .google:
            let payload: [String: Any] = ["contents": [["parts": [["text": instruction + "\n\n" + text]]]]]
            return try Self.cleaned(CloudClient.geminiText(try await client.sendJSON(account, route.model, path: CloudClient.generatePath(route.model), payload: payload, scope: scope, preview: preview)))
        case .anthropic:
            let payload: [String: Any] = ["model": route.model.modelID, "max_tokens": 4096,
                                          "system": instruction, "messages": [["role": "user", "content": text]]]
            return try Self.cleaned(CloudClient.anthropicText(
                try await client.sendJSON(account, route.model, path: "messages", payload: payload, scope: scope, preview: preview)))
        }
    }

    /// The text lives in `Prompts/cloud-cleanup.md`. With `audio`, the model gets the
    /// recording and transcribes and cleans it in one response.
    static func refinementInstruction(_ context: CleanupContext, audio: Bool = false) -> String {
        let body = PromptLibrary.render("cloud-cleanup.body", [
            "app_name": context.appName,
            "cleanup_rules": DictationCleanupPolicy.instruction,
            "style": PromptLibrary.render("cloud-cleanup.style." + context.writingContext.promptStyle),
            "context": DictationCleanupPolicy.contextBlocks(for: context, includeLastInsert: false),
        ])
        return PromptLibrary.render(audio ? "cloud-cleanup.audio" : "cloud-cleanup.transcript", [
            "app_name": context.appName,
            "app_description": context.appDescription,
            "body": body,
        ])
    }

    /// Dictation text never carries em dashes, whichever model wrote it.
    private static func cleaned(_ text: String) -> String {
        DictationCleanupPolicy.withoutEmDashes(text)
    }

    enum LadderError: LocalizedError {
        case skipped, noAudio, strayed
        var errorDescription: String? {
            switch self {
            case .skipped: "Skipped: refinement is off or the speech was a command."
            case .noAudio: "No recorded audio to send."
            case .strayed: "The answer strayed from what was said."
            }
        }
    }
}

/// Parallel configs may finish in any order. Only the currently preferred config
/// can publish a draft; later configs keep their latest snapshot until selected.
private actor CloudPreviewSelection {
    let preview: CloudService.Preview
    private var active = 0
    private var snapshots: [Int: String] = [:]
    init(preview: @escaping CloudService.Preview) { self.preview = preview }
    func activate(index: Int) async {
        active = index
        await preview(snapshots[index] ?? "")
    }
    func update(index: Int, text: String) async {
        snapshots[index] = text
        if index == active { await preview(text) }
    }
}
