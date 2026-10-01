import Foundation

enum CloudTelemetryCheck {
    @MainActor
    static func run() -> (checks: Int, failures: Int) {
        var checks = 0
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1 }
            print("  \(condition ? "ok  " : "FAIL")  \(label)")
        }
        print("\ncloud telemetry and raw history")
        let openAI = TokenUsage.parse(["usage": ["prompt_tokens": 1000, "completion_tokens": 200,
            "prompt_tokens_details": ["cached_tokens": 100], "completion_tokens_details": ["reasoning_tokens": 50]]], api: .openAI)
        expect(openAI.input == 1000 && openAI.output == 200 && openAI.visibleOutput == 150,
               "OpenAI reasoning is a subset of billed output")
        let google = TokenUsage.parse(["usageMetadata": ["promptTokenCount": 100, "candidatesTokenCount": 20,
            "thoughtsTokenCount": 10, "promptTokensDetails": [["modality": "AUDIO", "tokenCount": 80]]]], api: .google)
        expect(google.output == 30 && google.visibleOutput == 20 && google.audioInput == 80,
               "Gemini thinking is added to candidates and audio usage stays separate")
        let anthropic = TokenUsage.parse(["usage": ["input_tokens": 100, "output_tokens": 40,
            "cache_read_input_tokens": 200, "cache_creation_input_tokens": 50]], api: .anthropic)
        expect(anthropic.input == 350 && anthropic.output == 40,
               "Anthropic normalized input includes cache reads and writes")
        expect(TokenUsage.parse([:], api: .openAI).input == nil, "missing usage is unknown")
        var audioModel = CloudModel(providerID: UUID(), name: "Custom audio", modelID: "future-audio-model")
        audioModel.audioInput = .multimodal
        let audioData = try? JSONEncoder().encode(audioModel)
        expect(audioData.flatMap { try? JSONDecoder().decode(CloudModel.self, from: $0) }?.audioInput == .multimodal,
               "a custom model's multimodal transcriber endpoint survives settings persistence")
        if let audioData, var legacy = try? JSONSerialization.jsonObject(with: audioData) as? [String: Any] {
            legacy.removeValue(forKey: "audioInput")
            let old = try? JSONSerialization.data(withJSONObject: legacy)
            expect(old.flatMap { try? JSONDecoder().decode(CloudModel.self, from: $0) }?.audioInput == .transcription,
                   "legacy models keep their existing audio endpoint")
        }
        var locked = CloudProvider(api: .google); locked.enabled = true; locked.awaitingKeychainAccess = true
        expect(locked.problem == "Waiting for Keychain access", "pending authorization is distinct from a missing cloud key")
        let lockedData = try? JSONEncoder().encode(locked)
        expect(lockedData.flatMap { try? JSONDecoder().decode(CloudProvider.self, from: $0) }?.awaitingKeychainAccess == false,
               "temporary Keychain state is not written into saved provider settings")
        let nativeUsage = TokenUsage.parse(["usage": ["total_input_tokens": 70, "total_output_tokens": 0,
            "input_tokens_by_modality": [["modality": "audio", "tokens": 69]]]], api: .google)
        expect(nativeUsage.input == 70 && nativeUsage.output == 0 && nativeUsage.audioInput == 69,
               "native transcription logs Google's reported counts without guessing output from text")
        let price = ModelPrice(provider: "test", model: "model", fetchedAt: .now, input: 1, output: 4,
                               cacheRead: 0.1, cacheWrite: 1.25, inputAudio: 2)
        expect(abs((price.inputCost(openAI) ?? -1) - 0.00091) < 0.00000001,
               "cached input uses its own discounted price")
        expect(abs((price.outputCost(openAI) ?? -1) - 0.0008) < 0.00000001,
               "reasoning output is billed once")
        expect(abs((price.inputCost(google) ?? -1) - 0.00018) < 0.00000001,
               "audio input uses the audio rate")
        expect(price.inputCost(TokenUsage(input: 100, cachedInput: 10, audioInput: 20)) == nil,
               "unknown audio and cache overlap is not guessed")
        expect(price.inputCost(TokenUsage()) == nil && price.outputCost(TokenUsage()) == nil,
               "prices never fabricate missing token counts")
        do {
            let catalogJSON = #"{"openai":{"models":{"model":{"cost":{"input":1,"output":4,"tiers":[{"input":2,"output":8,"tier":{"type":"context","size":200000}}]}}}}}"#
            let catalog = try JSONDecoder().decode([String: ModelPricing.CatalogProvider].self, from: Data(catalogJSON.utf8))
            var provider = CloudProvider(api: .openAI)
            expect(ModelPricing.lookup(provider: provider, modelID: "model", inputTokens: 300000,
                                       catalog: catalog, fetchedAt: .now)?.input == 2,
                   "long-context prices use the matching tier")
            provider.baseURL = "https://proxy.example/v1"
            expect(ModelPricing.lookup(provider: provider, modelID: "model", inputTokens: 10,
                                       catalog: catalog, fetchedAt: .now) == nil,
                   "compatible proxies do not inherit another provider's prices")
            provider.pricingProviderID = "openai"
            expect(ModelPricing.lookup(provider: provider, modelID: "model", inputTokens: 10,
                                       catalog: catalog, fetchedAt: .now)?.input == 1,
                   "an explicit catalog provider resolves a custom endpoint")
            expect(ModelPricing.lookup(provider: provider, modelID: "missing", inputTokens: 10,
                                       catalog: catalog, fetchedAt: .now) == nil,
                   "model names must match instead of borrowing similar prices")

            var googleProvider = CloudProvider(api: .google)
            let official = ModelPricing.lookup(provider: googleProvider, modelID: "models/gemini-3.5-transcribe",
                                               inputTokens: 1500, catalog: [:], fetchedAt: .now)
            expect(official?.input == 2 && official?.output == 12 && official?.inputAudio == 2
                   && official?.sourceURL?.contains("ai.google.dev") == true,
                   "missing Transcribe catalog entry uses verified Google rates with attribution")
            expect(abs((official?.inputCost(TokenUsage(input: 1500, audioInput: 1500)) ?? -1) - 0.003) < 0.00000001,
                   "verified audio price applies to reported audio tokens")
            expect(ModelPricing.lookup(provider: googleProvider, modelID: "gemini-3.5-transcribe-live",
                                       inputTokens: 10, catalog: [:], fetchedAt: .now)?.output == 21,
                   "live Transcribe keeps its separate price")
            let newer = try JSONDecoder().decode([String: ModelPricing.CatalogProvider].self,
                from: Data(#"{"google":{"models":{"gemini-3.5-transcribe":{"cost":{"input":1,"output":6}}}}}"#.utf8))
            expect(ModelPricing.lookup(provider: googleProvider, modelID: "gemini-3.5-transcribe",
                                       inputTokens: 10, catalog: newer, fetchedAt: .now)?.input == 1,
                   "catalog updates take precedence over verified fallback rates")
            googleProvider.baseURL = "https://proxy.example/v1"
            googleProvider.pricingProviderID = "google"
            expect(ModelPricing.lookup(provider: googleProvider, modelID: "gemini-3.5-transcribe",
                                       inputTokens: 10, catalog: [:], fetchedAt: .now) == nil,
                   "official fallback never assigns direct Google rates to a proxy")
            let oldSnapshot = #"{"provider":"google","model":"old","fetchedAt":0,"input":1,"output":2}"#
            expect(try JSONDecoder().decode(ModelPrice.self, from: Data(oldSnapshot.utf8)).sourceURL == nil,
                   "existing price snapshots decode without the new source field")

            var stream = CloudStream(api: .openAI)
            try stream.line("data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}", elapsed: 0.2)
            try stream.line("", elapsed: 0.2)
            try stream.line("data: {\"choices\":[{\"delta\":{\"content\":\" world.\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":3}}", elapsed: 0.7)
            try stream.line("", elapsed: 0.7)
            expect(stream.text == "Hello world." && stream.firstOutput == 0.2 && stream.lastOutput == 0.7,
                   "SSE measures actual text arrival and joins incremental output")
            expect(stream.usage.output == 3 && (try? stream.responseJSON()) != nil,
                   "SSE keeps final usage and a complete provider response")
            var claudeStream = CloudStream(api: .anthropic)
            claudeStream.consume(["type": "message_start", "message": ["usage": ["input_tokens": 100,
                "cache_read_input_tokens": 200, "output_tokens": 1]]], elapsed: 0.1)
            claudeStream.consume(["type": "content_block_delta", "delta": ["type": "thinking_delta", "thinking": "hidden"]], elapsed: 0.2)
            claudeStream.consume(["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Hello."]], elapsed: 0.3)
            claudeStream.consume(["type": "message_delta", "usage": ["output_tokens": 20]], elapsed: 0.4)
            claudeStream.consume(["type": "message_stop"], elapsed: 0.5)
            expect(claudeStream.firstOutput == 0.3 && claudeStream.usage.input == 300 && claudeStream.usage.output == 20,
                   "Anthropic output updates keep initial cached-input counts and ignore thinking for latency")
            expect(claudeStream.usage.visibleOutput == nil, "unseparated thinking cannot produce a fake visible-token speed")
            var geminiStream = CloudStream(api: .google)
            geminiStream.consume(["candidates": [["content": ["parts": [["thought": true, "text": "Hidden"]]]]]], elapsed: 0.1)
            geminiStream.consume(["candidates": [["content": ["parts": [["text": "Hello."]]], "finishReason": "STOP"]],
                "usageMetadata": ["promptTokenCount": 5, "candidatesTokenCount": 2, "thoughtsTokenCount": 10]], elapsed: 0.8)
            expect(geminiStream.text == "Hello." && geminiStream.firstOutput == 0.8 && geminiStream.usage.output == 12,
                   "Gemini excludes thought parts while keeping their billable usage")
            var unfinished = CloudStream(api: .openAI)
            unfinished.consume(["choices": [["delta": ["content": "Partial"]]]], elapsed: 0.1)
            expect((try? unfinished.responseJSON()) == nil, "interrupted streams cannot insert partial text")

            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("flow-cost-check-\(UUID()).sqlite")
            defer { try? FileManager.default.removeItem(at: url) }
            let store = try SQLiteStore(url: url)
            let library = Library(store: store)
            let raw = "um Apple raw\u{2014}keep unchanged"
            let local = DictationVersion(source: .local, label: "Local transcription", text: "Apple raw, keep unchanged.")
            let configID = UUID()
            let cloud = DictationVersion(source: .cloud, label: "Cloud", text: "Apple raw, keep unchanged.", configID: configID)
            let record = DictationRecord(raw: "cloud raw", cleaned: cloud.text, appBundleID: "", appName: "Test", duration: 2,
                                         versions: [local, cloud], appleRaw: raw, processingDuration: 0.5)
            var call = CloudRequestRecord(dictationID: record.id, configID: configID, configLabel: "test",
                providerID: provider.id, providerName: "Test", modelID: "model", stage: .refinement)
            library.recordRequest(call)
            call.status = .succeeded; call.usage = openAI; call.price = price
            call.elapsed = 2; call.firstTokenLatency = 0.5; call.generationDuration = 1.5
            library.recordRequest(call)
            library.add(record)
            let reopened = try SQLiteStore(url: url)
            let saved = try reopened.dictations(matching: nil, limit: nil).first!
            expect(saved.rawTranscription == raw && saved.totalDuration == 2.5 && saved.versions == [local, cloud],
                   "untouched Apple raw, local, cloud, and processing timing survive reopening")
            expect(try reopened.cloudRequests().count == 1, "updating usage or pricing does not count the request twice")
            expect(library.requests(for: record.id, configID: configID).first?.id == call.id,
                   "per-version costs link to their exact configuration")
            expect(call.tokensPerSecond == 100 && call.effectiveTokensPerSecond == 75,
                   "generation speed and whole-request speed have different denominators")
            var failed = call; failed.id = UUID(); failed.status = .failed; failed.usage = TokenUsage()
            library.recordRequest(failed)
            let summary = CloudCostSummary(requests: library.cloudRequests)
            expect(summary.calls == 2 && summary.unpricedCalls == 1 && summary.knownCost > 0,
                   "failed calls count and unknown costs are excluded from known spend")
            library.delete(record)
            library.recordRequest(call)
            expect(try reopened.cloudRequests().count == 2 && reopened.cloudRequests().allSatisfy { $0.dictationID == nil },
                   "deleting transcripts keeps cost records and late updates cannot restore their links")
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 19800)!
            let anchor = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
            call.startedAt = anchor
            failed.startedAt = anchor.addingTimeInterval(-1)
            expect(CostPeriod.day.requests([call, failed], at: anchor, calendar: calendar).count == 1,
                   "daily costs respect local midnight")
            expect(CostPeriod.month.requests([call, failed], at: anchor, calendar: calendar).count == 1,
                   "monthly costs respect calendar month boundaries")
            let noon = anchor.addingTimeInterval(12 * 3600)
            let samples = [0, -7, -30, -365, -500].map { offset in
                var sample = call
                sample.id = UUID()
                sample.startedAt = calendar.date(byAdding: .day, value: offset, to: anchor)!
                return sample
            }
            let counts = StatsRange.allCases.map { $0.requests(samples, at: noon, calendar: calendar).count }
            expect(counts == [1, 2, 3, 4, 5], "every statistics range includes cloud calls using the same local-day cutoff")
            var future = call; future.startedAt = calendar.date(byAdding: .day, value: 1, to: anchor)!
            var modelListing = call; modelListing.stage = .models
            expect(StatsRange.allTime.requests([call, future, modelListing], at: noon, calendar: calendar).count == 1,
                   "statistics excludes future days and model-listing calls")
        } catch {
            checks += 1; failures += 1
            print("  FAIL  cloud telemetry checks threw \(error)")
        }
        expect(DictationCleanupPolicy.withoutEmDashes("a\u{2014}b \u{2014} c") == "a, b, c",
               "em dashes are removed even if a model ignores the prompt")
        expect(CleanupService.isFaithful("- Milk\n- Eggs\n- Rice", to: "buy milk eggs and rice make that a bullet list"),
               "applying a spoken formatting direction does not trigger the truncation guard")
        expect(CleanupService.isFaithful("Ship Friday.", to: "the release should be sent Friday with the latest changes make this shorter"),
               "explicit shortening can remove prose without being rejected as truncation")
        expect(!CleanupService.soundsLikeCommand("Can you please change the sidebar to use one icon?"),
               "ordinary requests remain message content")
        expect(CleanupService.soundsLikeCommand("Make this more professional."), "standalone rewrites have the previous insertion as their target")
        return (checks, failures)
    }
}
