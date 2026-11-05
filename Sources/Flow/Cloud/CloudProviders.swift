import Foundation

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

enum CloudStreaming: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic, disabled
    var id: String { rawValue }
    var title: String { self == .automatic ? "Automatic" : "Off" }
}

struct CloudProvider: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var api: CloudAPI
    var enabled = false
    var baseURL: String
    var apiKey = ""
    var pricingProviderID = ""
    var streaming: CloudStreaming = .automatic
    var awaitingKeychainAccess = false

    init(api: CloudAPI, name: String? = nil) {
        self.name = name ?? api.defaultName
        self.api = api
        self.baseURL = api.defaultBaseURL
    }

    enum CodingKeys: String, CodingKey { case id, name, api, enabled, baseURL, pricingProviderID, streaming }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        api = try values.decode(CloudAPI.self, forKey: .api)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        pricingProviderID = try values.decodeIfPresent(String.self, forKey: .pricingProviderID) ?? ""
        streaming = try values.decodeIfPresent(CloudStreaming.self, forKey: .streaming) ?? .automatic
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
