import Foundation

private final class RequestCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: CloudRequestRecord] = [:]
    private var lateValues: [CloudResult] = []
    func record(_ value: CloudRequestRecord) { lock.withLock { values[value.id] = value } }
    func late(_ value: CloudResult) { lock.withLock { lateValues.append(value) } }
    var requests: [CloudRequestRecord] { lock.withLock { Array(values.values) } }
    var results: [CloudResult] { lock.withLock { lateValues } }
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
        func rung(_ api: CloudAPI, _ model: String) -> CloudRung {
            var provider = CloudProvider(api: api); provider.baseURL = baseURL; provider.enabled = true
            let route = CloudRoute(provider: provider, model: CloudModel(providerID: provider.id, name: model, modelID: model))
            return CloudRung(step: .twoPass(transcriber: nil, refiner: route))
        }
        for api in [CloudAPI.openAI, .google, .anthropic] {
            let route = rung(api, "stream-" + api.rawValue)
            let result = await service.run([route], job: job, makeContext: { _ in context }, progress: { _ in }, late: { _ in })
            let request = collector.requests.first { $0.configID == route.id }
            checks["\(api.rawValue) streamed output"] = result?.text == "Hello world."
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
            && retries.count == 2 && retries.contains { $0.status == .failed && $0.httpStatus == 400 }
        checks["JSON never fabricates first token latency"] = retries.first { $0.status == .succeeded }?.firstTokenLatency == nil
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
