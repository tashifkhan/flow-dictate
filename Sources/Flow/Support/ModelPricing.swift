import Foundation
import OSLog

/// A pricing snapshot. USD per million tokens, saved with each completed call.
struct ModelPrice: Codable, Equatable, Sendable {
    var provider: String
    var model: String
    var fetchedAt: Date
    var input: Double
    var output: Double
    var cacheRead: Double?
    var cacheWrite: Double?
    var inputAudio: Double?
    var outputAudio: Double?
    var cacheReadAudio: Double?
    var sourceURL: String? = nil

    func inputCost(_ usage: TokenUsage) -> Double? {
        guard let total = usage.input else { return nil }
        // Cached audio pricing cannot be resolved without the modality/cache overlap.
        if usage.cachedInput > 0 && usage.audioInput > 0 { return nil }
        guard usage.cachedInput == 0 || cacheRead != nil,
              usage.cacheWrite == 0 || cacheWrite != nil,
              usage.audioInput == 0 || inputAudio != nil else { return nil }
        if usage.cacheWrite1h > 0 { return nil }
        let ordinary = max(0, total - usage.cachedInput - usage.cacheWrite - usage.audioInput)
        return (Double(ordinary) * input
                + Double(usage.cachedInput) * (cacheRead ?? 0)
                + Double(usage.cacheWrite) * (cacheWrite ?? 0)
                + Double(usage.audioInput) * (inputAudio ?? input)) / 1_000_000
    }
    func outputCost(_ usage: TokenUsage) -> Double? {
        guard let total = usage.output,
              usage.audioOutput == 0 || outputAudio != nil else { return nil }
        return (Double(max(0, total - usage.audioOutput)) * output
                + Double(usage.audioOutput) * (outputAudio ?? output)) / 1_000_000
    }
}

actor ModelPricing {
    static let shared = ModelPricing()
    private let log = Logger(subsystem: "sh.taf.flow", category: "pricing")
    private var catalog: [String: CatalogProvider] = [:]
    private var fetchedAt: Date?
    private var refreshTask: Task<Void, Never>?
    private var lastAttempt: Date?
    private let cacheURL: URL

    struct CatalogProvider: Decodable, Sendable {
        var api: String?
        var models: [String: CatalogModel]
    }
    struct CatalogModel: Decodable, Sendable {
        var cost: Cost?
        struct Cost: Decodable, Sendable {
            var input: Double?
            var output: Double?
            var cache_read: Double?
            var cache_write: Double?
            var input_audio: Double?
            var output_audio: Double?
            var cache_read_audio: Double?
            var context_over_200k: LongContext?
            var tiers: [Tier]?
            struct LongContext: Decodable, Sendable {
                var input: Double?
                var output: Double?
                var cache_read: Double?
                var cache_write: Double?
            }
            struct Tier: Decodable, Sendable {
                var input: Double?
                var output: Double?
                var cache_read: Double?
                var cache_write: Double?
                var tier: Limit
                struct Limit: Decodable, Sendable { var type: String; var size: Int }
            }
        }
    }

    private init() {
        cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Flow/models-dev-prices.json")
        if let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode([String: CatalogProvider].self, from: data) {
            catalog = saved
            fetchedAt = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate]) as? Date
        }
    }

    func refresh() async {
        if let refreshTask { await refreshTask.value; return }
        if let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < 86_400 { return }
        if let lastAttempt, Date.now.timeIntervalSince(lastAttempt) < 300 { return }
        lastAttempt = .now
        let task = Task { await self.download() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func download() async {
        do {
            var request = URLRequest(url: URL(string: "https://models.dev/api.json")!)
            request.setValue("Flow/1.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode([String: CatalogProvider].self, from: data)
            catalog = decoded
            fetchedAt = .now
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
        } catch { log.error("pricing refresh failed: \(error.localizedDescription, privacy: .public)") }
    }

    func price(provider: CloudProvider, modelID: String, inputTokens: Int?) async -> ModelPrice? {
        await refresh()
        return Self.lookup(provider: provider, modelID: modelID, inputTokens: inputTokens,
                           catalog: catalog, fetchedAt: fetchedAt ?? .now)
    }

    static func lookup(provider: CloudProvider, modelID: String, inputTokens: Int?,
                       catalog: [String: CatalogProvider], fetchedAt: Date) -> ModelPrice? {
        let override = provider.pricingProviderID.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URL(string: provider.baseURL)?.host?.lowercased() ?? ""
        let direct: [String: String] = [
            "api.openai.com": "openai", "generativelanguage.googleapis.com": "google",
            "api.anthropic.com": "anthropic", "api.groq.com": "groq",
        ]
        let providerID: String?
        if !override.isEmpty { providerID = override }
        else if let id = direct[host] { providerID = id }
        else {
            let matches = catalog.filter { URL(string: $0.value.api ?? "")?.host?.lowercased() == host }.map(\.key)
            providerID = matches.count == 1 ? matches[0] : nil
        }
        let normalized = modelID.hasPrefix("models/") ? String(modelID.dropFirst(7)) : modelID
        guard let providerID else { return nil }
        guard let cost = catalog[providerID]?.models[normalized]?.cost else {
            return officialFallback(providerID: providerID, host: host, modelID: normalized)
        }
        var input = cost.input
        var output = cost.output
        var read = cost.cache_read
        var write = cost.cache_write
        if let inputTokens {
            if let tier = cost.tiers?.filter({ $0.tier.type == "context" && inputTokens > $0.tier.size })
                .max(by: { $0.tier.size < $1.tier.size }) {
                input = tier.input ?? input; output = tier.output ?? output
                read = tier.cache_read ?? read; write = tier.cache_write ?? write
            } else if inputTokens > 200_000, let long = cost.context_over_200k {
                input = long.input ?? input; output = long.output ?? output
                read = long.cache_read ?? read; write = long.cache_write ?? write
            }
        }
        guard let input, let output, input >= 0, output >= 0 else { return nil }
        return ModelPrice(provider: providerID, model: normalized, fetchedAt: fetchedAt,
                          input: input, output: output, cacheRead: read, cacheWrite: write,
                          inputAudio: cost.input_audio, outputAudio: cost.output_audio, cacheReadAudio: cost.cache_read_audio)
    }

    /// Verified provider rates only fill missing catalog entries on the direct provider host.
    /// They never choose a model or assign Google's prices to a compatible proxy.
    static func officialFallback(providerID: String, host: String, modelID: String) -> ModelPrice? {
        guard providerID == "google", host == "generativelanguage.googleapis.com" else { return nil }
        let rates: (Double, Double)
        switch modelID {
        case "gemini-3.5-transcribe": rates = (2, 12)
        case "gemini-3.5-transcribe-live": rates = (3.5, 21)
        default: return nil
        }
        return ModelPrice(provider: providerID, model: modelID,
                          fetchedAt: ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!,
                          input: rates.0, output: rates.1, inputAudio: rates.0,
                          sourceURL: "https://ai.google.dev/gemini-api/docs/pricing#\(modelID)")
    }
}
