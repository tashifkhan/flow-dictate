import Foundation
import Security

enum CloudAPI: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI, google, anthropic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAI: "OpenAI compatible"
        case .google: "Gemini compatible"
        case .anthropic: "Anthropic compatible"
        }
    }
    var defaultName: String {
        switch self {
        case .openAI: "OpenAI"
        case .google: "Google"
        case .anthropic: "Anthropic"
        }
    }
    var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .google: "https://generativelanguage.googleapis.com/v1beta"
        case .anthropic: "https://api.anthropic.com/v1"
        }
    }
    var acceptsAudio: Bool { self != .anthropic }
}

enum CloudReasoning: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic, off, low, medium, high
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Model default"
        case .off: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

/// Endpoint choice belongs to configuration, never to a list of model names.
enum CloudAudioInput: String, CaseIterable, Codable, Identifiable, Sendable {
    case transcription, multimodal
    var id: String { rawValue }
    var title: String {
        self == .transcription ? "Audio transcription API" : "Multimodal chat API"
    }
}

struct CloudProvider: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var api: CloudAPI
    var enabled = false
    var baseURL: String
    var apiKey = ""
    var pricingProviderID = ""
    var awaitingKeychainAccess = false

    init(api: CloudAPI, name: String? = nil) {
        self.name = name ?? api.defaultName
        self.api = api
        self.baseURL = api.defaultBaseURL
    }

    enum CodingKeys: String, CodingKey { case id, name, api, enabled, baseURL, pricingProviderID }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        api = try values.decode(CloudAPI.self, forKey: .api)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        pricingProviderID = try values.decodeIfPresent(String.self, forKey: .pricingProviderID) ?? ""
    }

    var isLocalhost: Bool {
        ["localhost", "127.0.0.1"].contains(URL(string: baseURL)?.host ?? "")
    }

    /// Why this provider cannot take requests yet, or nil when it can.
    var problem: String? {
        if !enabled { return "Provider off" }
        if baseURL.trimmingCharacters(in: .whitespaces).isEmpty { return "No URL" }
        if awaitingKeychainAccess && apiKey.isEmpty { return "Waiting for Keychain access" }
        if apiKey.isEmpty && !isLocalhost { return "No API key" }
        return nil
    }
}

/// A model ID on one provider. Configs point at models, so one model can appear in
/// several configs without being entered twice.
struct CloudModel: Codable, Identifiable, Sendable {
    var id = UUID()
    var providerID: UUID
    var name: String
    var modelID: String
    var reasoning: CloudReasoning = .automatic
    var audioInput: CloudAudioInput = .transcription

    init(providerID: UUID, name: String, modelID: String, reasoning: CloudReasoning = .automatic) {
        self.providerID = providerID
        self.name = name
        self.modelID = modelID
        self.reasoning = reasoning
    }

    enum CodingKeys: String, CodingKey { case id, providerID, name, modelID, reasoning, audioInput }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        providerID = try values.decode(UUID.self, forKey: .providerID)
        name = try values.decode(String.self, forKey: .name)
        modelID = try values.decode(String.self, forKey: .modelID)
        reasoning = try values.decodeIfPresent(CloudReasoning.self, forKey: .reasoning) ?? .automatic
        audioInput = try values.decodeIfPresent(CloudAudioInput.self, forKey: .audioInput) ?? .transcription
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? modelID : trimmed
    }
}

struct CloudRoute: Sendable {
    var provider: CloudProvider
    var model: CloudModel
    var label: String { "\(provider.name) · \(model.displayName)" }
}

/// One rung of the cloud ladder.
struct CloudConfig: Codable, Identifiable, Sendable {
    enum Kind: String, CaseIterable, Codable, Identifiable, Sendable {
        /// Audio and the cleanup prompt go to one model, which returns finished text.
        case onePass
        /// A transcriber, then a refiner. Either side can be this Mac.
        case twoPass
        var id: String { rawValue }
        var title: String { self == .onePass ? "1 pass" : "2 pass" }
    }

    var id = UUID()
    var kind: Kind
    /// The audio model, for one pass.
    var model: UUID?
    /// For two pass. Nil means this Mac does the step.
    var transcriber: UUID?
    var refiner: UUID?

    init(kind: Kind, model: UUID? = nil, transcriber: UUID? = nil, refiner: UUID? = nil) {
        self.kind = kind
        self.model = model
        self.transcriber = transcriber
        self.refiner = refiner
    }
}

/// A config whose models can all take requests now.
struct CloudRung: Sendable {
    var id = UUID()
    enum Step: Sendable {
        case onePass(CloudRoute)
        case twoPass(transcriber: CloudRoute?, refiner: CloudRoute?)
    }
    let step: Step

    var routes: [CloudRoute] {
        switch step {
        case .onePass(let route): [route]
        case .twoPass(let transcriber, let refiner): [transcriber, refiner].compactMap { $0 }
        }
    }

    var label: String {
        switch step {
        case .onePass(let route): route.label
        case .twoPass(let transcriber, let refiner):
            "\(transcriber?.label ?? "This Mac") → \(refiner?.label ?? "This Mac")"
        }
    }

    var sendsAudio: Bool {
        switch step {
        case .onePass: true
        case .twoPass(let transcriber, _): transcriber != nil
        }
    }
}

struct CloudSettings: Codable, Sendable {
    var providers = CloudAPI.allCases.map { CloudProvider(api: $0) }
    var models: [CloudModel] = []
    /// Off means every dictation stays on this Mac, whatever the ladder holds.
    var useCloud = false
    /// Tried top to bottom. This Mac is always the rung after the last one.
    var configs: [CloudConfig] = []
    /// Run every config at once. The top success is pasted; the rest go to the menu bar.
    var parallelResults = false

    init() {}

    enum CodingKeys: String, CodingKey {
        case providers, models, useCloud, configs, parallelResults
        // Earlier formats, read once to carry settings forward.
        case pipeline, transcriber, refiner, onePassFirst, onePassRoutes, transcriptionRoutes, refinementRoutes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        providers = try values.decode([CloudProvider].self, forKey: .providers)
        models = try values.decode([CloudModel].self, forKey: .models)
        parallelResults = try values.decodeIfPresent(Bool.self, forKey: .parallelResults) ?? false
        if let configs = try values.decodeIfPresent([CloudConfig].self, forKey: .configs) {
            self.configs = configs
            useCloud = try values.decodeIfPresent(Bool.self, forKey: .useCloud) ?? false
            return
        }
        // Per-step ladders from before configs existed.
        let onePass = try values.decodeIfPresent([UUID].self, forKey: .onePassRoutes) ?? []
        let transcription = try values.decodeIfPresent([UUID].self, forKey: .transcriptionRoutes) ?? []
        let refinement = try values.decodeIfPresent([UUID].self, forKey: .refinementRoutes) ?? []
        let pipeline = try values.decodeIfPresent(String.self, forKey: .pipeline)
        let cloudTranscriber = try values.decodeIfPresent(String.self, forKey: .transcriber).map { $0 == "cloud" }
            ?? (pipeline.map { $0 != "local" } ?? !transcription.isEmpty)
        let cloudRefiner = try values.decodeIfPresent(String.self, forKey: .refiner).map { $0 == "cloud" }
            ?? (pipeline.map { $0 != "local" } ?? !refinement.isEmpty)
        let onePassOn = try values.decodeIfPresent(Bool.self, forKey: .onePassFirst)
            ?? (pipeline.map { $0 == "onePass" } ?? !onePass.isEmpty)
        configs = Self.configs(onePass: onePassOn ? onePass : [],
                               transcription: cloudTranscriber ? transcription : [],
                               refinement: cloudRefiner ? refinement : [])
        useCloud = !configs.isEmpty
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(providers, forKey: .providers)
        try values.encode(models, forKey: .models)
        try values.encode(useCloud, forKey: .useCloud)
        try values.encode(configs, forKey: .configs)
        try values.encode(parallelResults, forKey: .parallelResults)
    }

    /// Turns per-step ladders into configs: one-pass models first, then each cloud
    /// transcriber paired with the top refiner, then refiners behind this Mac's transcript.
    static func configs(onePass: [UUID], transcription: [UUID], refinement: [UUID]) -> [CloudConfig] {
        var configs = onePass.map { CloudConfig(kind: .onePass, model: $0) }
        if transcription.isEmpty {
            configs += refinement.map { CloudConfig(kind: .twoPass, refiner: $0) }
        } else {
            configs += transcription.map { CloudConfig(kind: .twoPass, transcriber: $0, refiner: refinement.first) }
        }
        return configs
    }

    func model(_ id: UUID?) -> CloudModel? { id.flatMap { id in models.first { $0.id == id } } }
    func provider(_ id: UUID) -> CloudProvider? { providers.first { $0.id == id } }

    private func route(_ id: UUID?, audio: Bool) -> Result<CloudRoute?, ConfigProblem> {
        guard let id else { return .success(nil) }
        guard let model = model(id), let provider = provider(model.providerID) else { return .failure(.init("Missing model")) }
        if audio && !provider.api.acceptsAudio { return .failure(.init("\(provider.name) takes no audio")) }
        if let problem = provider.problem { return .failure(.init("\(provider.name): \(problem.lowercased())")) }
        if model.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .failure(.init("No model ID")) }
        return .success(CloudRoute(provider: provider, model: model))
    }

    struct ConfigProblem: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// A config ready to run, or why it can't.
    func rung(_ config: CloudConfig) -> Result<CloudRung, ConfigProblem> {
        switch config.kind {
        case .onePass:
            guard config.model != nil else { return .failure(.init("Pick a model")) }
            return route(config.model, audio: true).flatMap { route in
                route.map { .success(CloudRung(id: config.id, step: .onePass($0))) } ?? .failure(.init("Pick a model"))
            }
        case .twoPass:
            guard config.transcriber != nil || config.refiner != nil else {
                return .failure(.init("Pick a cloud model for at least one step"))
            }
            return route(config.transcriber, audio: true).flatMap { transcriber in
                route(config.refiner, audio: false).map { refiner in
                    CloudRung(id: config.id, step: .twoPass(transcriber: transcriber, refiner: refiner))
                }
            }
        }
    }

    /// The ladder a dictation walks, with configs that can't run skipped. Empty when
    /// the cloud is off, which leaves only this Mac.
    var readyRungs: [CloudRung] {
        guard useCloud else { return [] }
        return configs.compactMap { try? rung($0).get() }
    }

    var sendsAudio: Bool { readyRungs.contains(where: \.sendsAudio) }
    var refinesInCloud: Bool {
        readyRungs.contains { rung in
            if case .twoPass(_, nil) = rung.step { return false }
            return true
        }
    }
    var usesCloud: Bool { !readyRungs.isEmpty }

    mutating func removeProvider(_ id: UUID) {
        for model in models where model.providerID == id { removeModel(model.id) }
        providers.removeAll { $0.id == id }
    }

    /// Deletes a model and drops configs left with nothing in the cloud.
    mutating func removeModel(_ id: UUID) {
        models.removeAll { $0.id == id }
        for index in configs.indices {
            if configs[index].model == id { configs[index].model = nil }
            if configs[index].transcriber == id { configs[index].transcriber = nil }
            if configs[index].refiner == id { configs[index].refiner = nil }
        }
        configs.removeAll { config in
            config.kind == .onePass ? config.model == nil : config.transcriber == nil && config.refiner == nil
        }
    }
}

enum CloudKeys {
    private static let service = "sh.taf.flow.cloud"
    static func read(_ id: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func write(_ key: String, id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    /// Deletes every key whose provider no longer exists.
    static func prune(keeping ids: [String]) {
        let keep = Set(ids)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }
        for account in items.compactMap({ $0[kSecAttrAccount as String] as? String }) where !keep.contains(account) {
            write("", id: account)
        }
    }
}

/// Reads the first cloud settings format so existing keys and configured models survive.
private struct LegacyCloudSettings: Decodable {
    struct Account: Decodable {
        var provider: String
        var enabled: Bool
        var baseURL: String
        var transcriptionModel: String
        var refinementModel: String
    }
    var accounts: [Account]
    var transcriptionOrder: [String]
    var refinementOrder: [String]
    var parallelResults: Bool
}

extension CloudSettings {
    static func migrated(from data: Data) -> CloudSettings? {
        guard let old = try? JSONDecoder().decode(LegacyCloudSettings.self, from: data) else { return nil }
        var settings = CloudSettings()
        settings.parallelResults = old.parallelResults
        var transcription: [(order: Int, id: UUID)] = []
        var refinement: [(order: Int, id: UUID)] = []
        for account in old.accounts {
            let api: CloudAPI
            switch account.provider {
            case "openai": api = .openAI
            case "google": api = .google
            case "anthropic": api = .anthropic
            default: continue
            }
            guard let index = settings.providers.firstIndex(where: { $0.api == api }) else { continue }
            settings.providers[index].enabled = account.enabled
            settings.providers[index].baseURL = account.baseURL
            // Settings writes the key under the provider's new ID once it has saved these.
            let key = CloudKeys.read(account.provider)
            settings.providers[index].apiKey = key
            guard account.enabled || !key.isEmpty else { continue }
            let id = settings.providers[index].id
            if api.acceptsAudio, !account.transcriptionModel.isEmpty {
                let model = CloudModel(providerID: id, name: "", modelID: account.transcriptionModel)
                settings.models.append(model)
                if let order = old.transcriptionOrder.firstIndex(of: account.provider) { transcription.append((order, model.id)) }
            }
            if !account.refinementModel.isEmpty {
                let model = CloudModel(providerID: id, name: "", modelID: account.refinementModel)
                settings.models.append(model)
                if let order = old.refinementOrder.firstIndex(of: account.provider) { refinement.append((order, model.id)) }
            }
        }
        settings.configs = configs(onePass: [],
                                   transcription: transcription.sorted { $0.order < $1.order }.map(\.id),
                                   refinement: refinement.sorted { $0.order < $1.order }.map(\.id))
        settings.useCloud = !settings.configs.isEmpty
        return settings
    }
}
