import Foundation

private final class RequestCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: CloudRequestRecord] = [:]
    private var lateValues: [CloudResult] = []
    private var previewValues: [String] = []
    private var previewWhileRunning = false
    func record(_ value: CloudRequestRecord) { lock.withLock { values[value.id] = value } }
    func late(_ value: CloudResult) { lock.withLock { lateValues.append(value) } }
    var requests: [CloudRequestRecord] { lock.withLock { Array(values.values) } }
    var results: [CloudResult] { lock.withLock { lateValues } }
    func preview(_ text: String) {
        lock.withLock {
            previewValues.append(text)
            if text == "Hello", values.values.contains(where: { $0.status == .running }) {
                previewWhileRunning = true
            }
        }
    }
    var previews: [String] { lock.withLock { previewValues } }
    var previewArrivedBeforeCompletion: Bool { lock.withLock { previewWhileRunning } }
    func clearPreviews() { lock.withLock { previewValues = []; previewWhileRunning = false } }
}

enum CloudHTTPCheck {
    static let context = CleanupContext(appName: "Test", bundleID: "test", axRole: "AXTextArea", appDescription: "test editor",
                                        writingContext: .general, transcriptionLanguage: .system)

    @MainActor
    static func run(baseURL: String, output: String) async -> Never {
        let collector = RequestCollector()
        let service = CloudService(recordRequest: collector.record)
        let id = UUID()
        let job = CloudService.Job(dictationID: id, audio: Data(), localRaw: "Hello world", refine: true, language: .system, parallel: false)
        var checks: [String: Bool] = [:]
        func rung(_ api: CloudAPI, _ model: String, streaming: CloudStreaming = .automatic,
                  reasoning: CloudReasoning = .automatic) -> CloudRung {
            var provider = CloudProvider(api: api); provider.baseURL = baseURL; provider.enabled = true
            provider.streaming = streaming
            let route = CloudRoute(provider: provider, model: CloudModel(providerID: provider.id, name: model,
                                                                         modelID: model, reasoning: reasoning))
            return CloudRung(step: .twoPass(transcriber: nil, refiner: route))
        }
        for api in [CloudAPI.openAI, .google, .anthropic] {
            collector.clearPreviews()
            let route = rung(api, "stream-" + api.rawValue)
            let result = await service.run([route], job: job, makeContext: { _ in context }, progress: { _ in }, late: { _ in },
                                           preview: { text in collector.preview(text) })
            let request = collector.requests.first { $0.configID == route.id }
            checks["\(api.rawValue) streamed output"] = result?.text == "Hello world."
            checks["\(api.rawValue) publishes partial text before completion"] = collector.previews.contains("Hello")
                && collector.previews.last == "Hello world." && collector.previewArrivedBeforeCompletion
            checks["\(api.rawValue) full request word speed"] = request?.outputWords == 2
                && request?.wordsPerSecond == request?.elapsed.map { 2 / $0 }
                && request?.wordsPerMinute == request?.elapsed.map { (2 / $0) * 60 }
            checks["\(api.rawValue) usage and first token"] = request?.usage.input == 100 && request?.usage.output == 20
                && request?.firstTokenLatency != nil && request?.generationDuration != nil
        }
        var audioProvider = CloudProvider(api: .openAI)
        audioProvider.baseURL = baseURL; audioProvider.enabled = true
        var audioModel = CloudModel(providerID: audioProvider.id, name: "Custom audio", modelID: "multimodal-transcriber")
        audioModel.audioInput = .multimodal
        var writerProvider = CloudProvider(api: .anthropic)
        writerProvider.baseURL = baseURL; writerProvider.enabled = true
        let crossProvider = CloudRung(step: .twoPass(
            transcriber: CloudRoute(provider: audioProvider, model: audioModel),
            refiner: CloudRoute(provider: writerProvider, model: CloudModel(providerID: writerProvider.id,
                name: "Custom refiner", modelID: "arbitrary-refiner"))))
        var audioJob = job; audioJob.audio = Data(repeating: 0, count: 46)
        let crossResult = await service.run([crossProvider], job: audioJob, makeContext: { _ in context }, progress: { _ in }, late: { _ in })
        let crossCalls = collector.requests.filter { $0.configID == crossProvider.id }
        checks["custom multimodal model transcribes through its configured chat endpoint"] = crossResult?.text == "Hello world."
        checks["two-pass stages across providers keep separate calls and the same version ID"] = crossCalls.count == 2
            && Set(crossCalls.map(\.stage)) == [.transcription, .refinement]
            && Set(crossCalls.map(\.providerID)).count == 2 && crossCalls.allSatisfy { $0.dictationID == id && $0.status == .succeeded }
        let retry = rung(.openAI, "reject-stream")
        let retryResult = await service.run([retry], job: job, makeContext: { _ in context }, progress: { _ in }, late: { _ in })
        let retries = collector.requests.filter { $0.configID == retry.id }
        checks["stream fallback logs two attempts"] = retryResult?.text == "Hello world."
            && retries.count == 2 && retries.contains { $0.status == .failed && $0.httpStatus == 501 }
        checks["JSON never fabricates first token latency"] = retries.first { $0.status == .succeeded }?.firstTokenLatency == nil
        let retryAgain = await service.run([retry], job: job, makeContext: { _ in context }, progress: { _ in }, late: { _ in })
        checks["unsupported streaming is remembered per route"] = retryAgain?.text == "Hello world."
            && collector.requests.filter { $0.configID == retry.id }.count == 3
        await service.resetStreamingSupport(providerID: retry.routes[0].provider.id)
        _ = await service.run([retry], job: job, makeContext: { _ in context }, progress: { _ in }, late: { _ in })
        checks["support can be rechecked"] = collector.requests.filter { $0.configID == retry.id }.count == 5
        var supportedModel = retry.routes[0]
        supportedModel.model.modelID = "supported-same-provider"
        let supportedRung = CloudRung(step: .twoPass(transcriber: nil, refiner: supportedModel))
        collector.clearPreviews()
        _ = await service.run([supportedRung], job: job, makeContext: { _ in context }, progress: { _ in }, late: { _ in },
                              preview: { collector.preview($0) })
        checks["one unsupported model does not disable another model"] = collector.previews.contains("Hello")
        for api in [CloudAPI.google, .anthropic] {
            let route = rung(api, "reject-stream-" + api.rawValue)
            collector.clearPreviews()
            let response = await service.run([route], job: job, makeContext: { _ in context }, progress: { _ in }, late: { _ in },
                                              preview: { collector.preview($0) })
            checks["\(api.rawValue) unsupported stream uses a direct response"] = response?.text == "Hello world."
                && collector.previews.isEmpty && collector.requests.filter { $0.configID == route.id }.count == 2
        }
        let ignored = rung(.openAI, "ignore-stream")
        collector.clearPreviews()
        for _ in 0..<2 {
            _ = await service.run([ignored], job: job, makeContext: { _ in context }, progress: { _ in }, late: { _ in },
                                  preview: { collector.preview($0) })
        }
        checks["JSON responses to streaming requests never publish partials"] = collector.previews.isEmpty
        for api in [CloudAPI.openAI, .google, .anthropic] {
            collector.clearPreviews()
            let off = rung(api, "disabled-" + api.rawValue, streaming: .disabled)
            let complete = await service.run([off], job: job, makeContext: { _ in context }, progress: { _ in }, late: { _ in },
                                             preview: { collector.preview($0) })
            checks["\(api.rawValue) Off buffers even unsolicited SSE"] = complete?.text == "Hello world."
                && collector.previews.isEmpty
        }
        collector.clearPreviews()
        let options = rung(.openAI, "reject-usage-options")
        for _ in 0..<2 {
            _ = await service.run([options], job: job, makeContext: { _ in context }, progress: { _ in }, late: { _ in },
                                  preview: { collector.preview($0) })
        }
        checks["optional usage rejection preserves streaming and is remembered"] = collector.previews.contains("Hello")
            && collector.requests.filter { $0.configID == options.id }.count == 3
        collector.clearPreviews()
        let reasoning = rung(.openAI, "reject-reasoning", reasoning: .high)
        _ = await service.run([reasoning], job: job, makeContext: { _ in context }, progress: { _ in }, late: { _ in },
                              preview: { collector.preview($0) })
        checks["reasoning rejection does not disable streaming"] = collector.previews.contains("Hello")
        if let (requestData, _) = try? await URLSession.shared.data(from: URL(string: baseURL + "/fixture-requests")!),
           let sent = try? JSONSerialization.jsonObject(with: requestData) as? [[String: Any]] {
            let offRequests = sent.filter { ($0["model"] as? String)?.hasPrefix("disabled-") == true }
            checks["Off omits streaming bodies, endpoints, and Accept headers"] = offRequests.count == 3
                && offRequests.allSatisfy { $0["stream"] as? Bool == false && $0["accept"] as? String != "text/event-stream" }
            checks["Off explicitly disables streaming in compatible JSON APIs"] = offRequests
                .filter { $0["model"] as? String != "disabled-google" }.allSatisfy { $0["streamField"] as? Bool == false }
            let ignoredRequests = sent.filter { $0["model"] as? String == "ignore-stream" }
            checks["ignored streaming switches the next request to direct JSON"] = ignoredRequests.count == 2
                && ignoredRequests[0]["stream"] as? Bool == true && ignoredRequests[1]["stream"] as? Bool == false
        } else { checks["fixture request metadata is available"] = false }
        let failed = rung(.openAI, "failed")
        let fallback = rung(.openAI, "fallback")
        let fallbackResult = await service.run([failed, fallback], job: job, makeContext: { _ in context }, progress: { _ in }, late: { _ in })
        checks["failed rung and successful fallback both logged"] = fallbackResult?.configID == fallback.id
            && collector.requests.contains { $0.configID == failed.id && $0.httpStatus == 429 && $0.status == .failed }
        let fast = rung(.openAI, "fast")
        let slow = rung(.openAI, "slow")
        var parallelJob = job; parallelJob.parallel = true
        let start = ContinuousClock.now
        let winner = await service.run([fast, slow], job: parallelJob, makeContext: { _ in context }, progress: { _ in }, late: collector.late)
        checks["parallel insertion does not await lower rung"] = winner?.configID == fast.id && (ContinuousClock.now - start) < .seconds(1)
        try? await Task.sleep(for: .milliseconds(1300))
        checks["parallel late output and request retain their IDs"] = collector.results.contains { $0.configID == slow.id }
            && collector.requests.contains { $0.configID == slow.id && $0.dictationID == id && $0.status == .succeeded }
        collector.clearPreviews()
        let preferred = rung(.openAI, "preferred-slow")
        let alternate = rung(.openAI, "alternate-fast")
        let priorityWinner = await service.run([preferred, alternate], job: parallelJob, makeContext: { _ in context },
                                              progress: { _ in }, late: { _ in }, preview: { text in collector.preview(text) })
        checks["parallel drafts come only from the highest-ranked active config"] = priorityWinner?.configID == preferred.id
            && collector.previews.contains("Hello") && !collector.previews.contains { $0.hasPrefix("world") }
        collector.clearPreviews()
        let strayed = rung(.openAI, "strayed")
        let recovered = await service.run([strayed, fallback], job: job, makeContext: { _ in context }, progress: { _ in },
                                          late: { _ in }, preview: { text in collector.preview(text) })
        checks["rejected streamed drafts clear before fallback"] = recovered?.configID == fallback.id
            && collector.previews.contains("Invented") && collector.previews.contains("") && collector.previews.last == "Hello world."
        var emailJob = job
        emailJob.localRaw = "Add my email here"
        var emailContext = context
        emailContext.substitutions = DictationSubstitutions(rules: [.init(from: "my email", to: "person@example.com")])
        let savedEmailContext = emailContext
        let emailResult = await service.run([rung(.openAI, "echo-input")], job: emailJob,
                                            makeContext: { _ in savedEmailContext }, progress: { _ in }, late: { _ in })
        checks["saved email reaches the refiner and survives source validation"] = emailResult?.text == "person@example.com"
        let wrongEmail = rung(.openAI, "wrong-email")
        let correctEmail = rung(.openAI, "echo-input")
        let faithfulEmail = await service.run([wrongEmail, correctEmail], job: emailJob,
                                              makeContext: { _ in savedEmailContext }, progress: { _ in }, late: { _ in })
        checks["a changed saved email is rejected even when word overlap passes"] = faithfulEmail?.configID == correctEmail.id
            && faithfulEmail?.text == "person@example.com"
        var aliasJob = job
        aliasJob.localRaw = "alpha"
        var aliasContext = context
        aliasContext.substitutions = DictationSubstitutions(rules: [.init(from: "alpha", to: "beta"), .init(from: "beta", to: "gamma")])
        let savedAliasContext = aliasContext
        let aliasResult = await service.run([rung(.openAI, "echo-input")], job: aliasJob,
                                            makeContext: { _ in savedAliasContext }, progress: { _ in }, late: { _ in })
        checks["cloud refinement does not cascade replacement rules"] = aliasResult?.text == "beta"
        let cancellation = rung(.openAI, "cancel")
        let task = Task { await service.run([cancellation], job: job, makeContext: { _ in context }, progress: { _ in }, late: { _ in }) }
        try? await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let cancelled = await task.value
        checks["cancelled request is logged without insertion"] = cancelled == nil
            && collector.requests.contains { $0.configID == cancellation.id && $0.status == .cancelled }
        let data = try? JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys, .prettyPrinted])
        if let data { try? data.write(to: URL(fileURLWithPath: output), options: .atomic) }
        for key in checks.keys.sorted() { print("\(checks[key] == true ? "ok" : "FAIL") \(key)") }
        exit(checks.values.allSatisfy { $0 } ? 0 : 1)
    }
}
