import Foundation

enum CloudLiveCheck {
    @MainActor
    static func run(audio: String, output: String) async -> Never {
        await Settings.shared.loadCloudKeys()
        let library = AppEnvironment.shared.library
        let cloud = CloudService()
        let cleanup = CleanupService()
        let spoken = "um we need three changes first fix login second add tests third update docs and let's meet Thursday sorry Friday at three"
        var report: [String: Any] = [:]
        let local = await cleanup.clean(spoken, context: CloudHTTPCheck.context)
        report["local"] = local.text
        do {
            let audioData = try Data(contentsOf: URL(fileURLWithPath: audio))
            let settings = Settings.shared.cloud
            report["providers"] = settings.providers.map { ["name": $0.name, "problem": $0.problem ?? "Ready"] }
            guard !settings.readyRungs.isEmpty else {
                throw CloudService.CloudError.skipped
            }
            let candidates = Array(settings.readyRungs.prefix(1))
            for rung in candidates {
                let dictationID = UUID()
                let job = CloudService.Job(dictationID: dictationID, audio: audioData, localRaw: spoken,
                                          refine: true, language: .system, parallel: false)
                let value = await cloud.run([rung], job: job, makeContext: { _ in CloudHTTPCheck.context }, progress: { _ in }, late: { _ in })
                await ModelPricing.shared.refresh()
                try? await Task.sleep(for: .milliseconds(250))
                report[rung.label] = ["text": value?.text ?? "No accepted result", "requests": library.requests(for: dictationID).map { request in
                    ["status": request.status.rawValue, "input": RequestDisplay.tokens(request.usage.input),
                     "output": RequestDisplay.tokens(request.usage.output), "cost": RequestDisplay.money(request.estimatedCost),
                     "elapsed": RequestDisplay.seconds(request.elapsed), "firstToken": RequestDisplay.seconds(request.firstTokenLatency)]
                }]
            }
        } catch { report["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        exit(report["error"] == nil ? 0 : 1)
    }
}
