import Foundation

/// A microphone as Flow remembers it: the stable Core Audio UID plus display metadata.
///
/// Never the numeric `AudioDeviceID`, which macOS hands out again when a device reconnects.
struct SavedMicrophone: Codable, Hashable, Identifiable, Sendable {
    let uid: String
    let name: String
    let transport: AudioInputTransport
    var id: String { uid }

    init(uid: String, name: String, transport: AudioInputTransport) {
        self.uid = uid
        self.name = name
        self.transport = transport
    }

    private enum CodingKeys: String, CodingKey { case uid, name, transport }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let uid = try values.decode(String.self, forKey: .uid)
        guard !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .uid, in: values, debugDescription: "A saved microphone needs a stable UID."
            )
        }
        self.init(
            uid: uid,
            name: (try? values.decode(String.self, forKey: .name)) ?? "Microphone",
            transport: (try? values.decode(AudioInputTransport.self, forKey: .transport)) ?? .other
        )
    }
}

/// A named microphone order, such as "Desk" or "Travel".
struct MicrophoneProfile: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var priority: [SavedMicrophone]

    static let defaultProfile = MicrophoneProfile(id: "default", name: "Default")

    init(id: String = UUID().uuidString, name: String, priority: [SavedMicrophone] = []) {
        self.id = id
        self.name = name
        self.priority = priority
    }

    private enum CodingKeys: String, CodingKey { case id, name, priority }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? values.decode(String.self, forKey: .id)) ?? "",
            name: (try? values.decode(String.self, forKey: .name)) ?? "",
            priority: (try? values.decode(LossyArray<SavedMicrophone>.self, forKey: .priority))?.values ?? []
        )
    }
}

enum MicrophoneSelection: Hashable, Codable, Sendable {
    /// The first connected microphone in the active priority list.
    case automatic
    /// Whatever macOS has selected under Sound › Input.
    case systemDefault
    /// One device, used whenever it is connected.
    case fixed(SavedMicrophone)

    private enum CodingKeys: String, CodingKey { case mode, device }

    init(from decoder: Decoder) throws {
        guard let values = try? decoder.container(keyedBy: CodingKeys.self),
              let mode = try? values.decode(String.self, forKey: .mode) else {
            self = .automatic
            return
        }
        switch mode {
        case "systemDefault": self = .systemDefault
        case "fixed":
            if let device = try? values.decode(SavedMicrophone.self, forKey: .device) {
                self = .fixed(device)
            } else {
                self = .automatic
            }
        default: self = .automatic
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic: try values.encode("automatic", forKey: .mode)
        case .systemDefault: try values.encode("systemDefault", forKey: .mode)
        case .fixed(let device):
            try values.encode("fixed", forKey: .mode)
            try values.encode(device, forKey: .device)
        }
    }
}

enum MicrophoneProfileError: LocalizedError, Equatable {
    case emptyName, duplicateName, lastProfile, missingProfile

    var errorDescription: String? {
        switch self {
        case .emptyName: "Give the priority list a name."
        case .duplicateName: "A priority list already has that name."
        case .lastProfile: "Keep at least one priority list."
        case .missingProfile: "That priority list is no longer available."
        }
    }
}

/// Every microphone choice Flow saves. Ported from Sotto.
struct MicrophonePreferences: Codable, Equatable, Sendable {
    var profiles: [MicrophoneProfile]
    var activeProfileID: String
    var selection: MicrophoneSelection

    init(profiles: [MicrophoneProfile] = [.defaultProfile], activeProfileID: String? = nil,
         selection: MicrophoneSelection = .automatic) {
        var profileIDs = Set<String>()
        let validProfiles = profiles.compactMap { profile -> MicrophoneProfile? in
            guard !profile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  profileIDs.insert(profile.id).inserted else { return nil }
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return MicrophoneProfile(id: profile.id, name: name.isEmpty ? "Default" : name,
                                     priority: Self.uniqueDevices(profile.priority))
        }
        self.profiles = validProfiles.isEmpty ? [.defaultProfile] : validProfiles
        self.activeProfileID = self.profiles.first(where: { $0.id == activeProfileID })?.id ?? self.profiles[0].id
        if case .fixed(let device) = selection {
            self.selection = Self.uniqueDevices([device]).first.map(MicrophoneSelection.fixed) ?? .automatic
        } else {
            self.selection = selection
        }
    }

    var activeProfile: MicrophoneProfile {
        profiles.first(where: { $0.id == activeProfileID }) ?? profiles.first ?? .defaultProfile
    }

    /// Apply after edits. Disconnected favorites stay in their original order.
    func normalized() -> Self {
        Self(profiles: profiles, activeProfileID: activeProfileID, selection: selection)
    }

    private enum CodingKeys: String, CodingKey { case profiles, activeProfileID, selection }

    init(from decoder: Decoder) throws {
        guard let values = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init()
            return
        }
        self.init(
            profiles: (try? values.decode(LossyArray<MicrophoneProfile>.self, forKey: .profiles))?.values ?? [],
            activeProfileID: try? values.decode(String.self, forKey: .activeProfileID),
            selection: (try? values.decode(MicrophoneSelection.self, forKey: .selection)) ?? .automatic
        )
    }

    fileprivate static func uniqueDevices(_ devices: [SavedMicrophone]) -> [SavedMicrophone] {
        var uids = Set<String>()
        return devices.compactMap { device in
            guard !device.uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  uids.insert(device.uid).inserted else { return nil }
            let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return SavedMicrophone(uid: device.uid, name: name.isEmpty ? "Microphone" : name,
                                   transport: device.transport)
        }
    }
}

// MARK: - Edits

extension MicrophonePreferences {
    mutating func selectProfile(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
    }

    mutating func addProfile(named name: String) throws {
        let name = try validatedName(name)
        let profile = MicrophoneProfile(name: name)
        profiles.append(profile)
        activeProfileID = profile.id
    }

    mutating func renameProfile(_ id: String, to name: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw MicrophoneProfileError.missingProfile }
        profiles[index].name = try validatedName(name, excluding: id)
    }

    mutating func removeProfile(_ id: String) throws {
        guard profiles.contains(where: { $0.id == id }) else { throw MicrophoneProfileError.missingProfile }
        guard profiles.count > 1 else { throw MicrophoneProfileError.lastProfile }
        profiles.removeAll { $0.id == id }
        self = normalized()
    }

    mutating func addToPriority(_ device: SavedMicrophone) {
        editPriority { entries in
            guard !entries.contains(where: { $0.uid == device.uid }) else { return }
            entries.append(device)
        }
    }

    mutating func removeFromPriority(uid: String) {
        editPriority { $0.removeAll { $0.uid == uid } }
    }

    mutating func movePriority(uid: String, by offset: Int) {
        editPriority { entries in
            guard [-1, 1].contains(offset), let index = entries.firstIndex(where: { $0.uid == uid }),
                  entries.indices.contains(index + offset) else { return }
            entries.swapAt(index, index + offset)
        }
    }

    mutating func movePriorityToTop(uid: String) {
        editPriority { entries in
            guard let index = entries.firstIndex(where: { $0.uid == uid }), index > 0 else { return }
            entries.insert(entries.remove(at: index), at: 0)
        }
    }

    /// Picks up renamed devices without forgetting offline favorites or their order.
    func refreshingNames(from connected: [SavedMicrophone]) -> Self {
        let byUID = Dictionary(connected.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        var next = self
        for index in next.profiles.indices {
            next.profiles[index].priority = next.profiles[index].priority.map { byUID[$0.uid] ?? $0 }
        }
        if case .fixed(let device) = next.selection, let live = byUID[device.uid] {
            next.selection = .fixed(live)
        }
        return next.normalized()
    }

    private mutating func editPriority(_ edit: (inout [SavedMicrophone]) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        edit(&profiles[index].priority)
        self = normalized()
    }

    private func validatedName(_ name: String, excluding id: String? = nil) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MicrophoneProfileError.emptyName }
        guard !profiles.contains(where: {
            $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else { throw MicrophoneProfileError.duplicateName }
        return name
    }
}

// MARK: - Resolution

enum MicrophoneResolutionReason: Equatable, Sendable {
    case priority
    case fixed
    case systemDefault
    /// The chosen device was absent, or macOS had no default input.
    case fallback(requested: SavedMicrophone?)
    case unavailable
}

struct MicrophoneResolution: Equatable, Sendable {
    let device: SavedMicrophone?
    let reason: MicrophoneResolutionReason
}

/// Picks the input for the next recording. Never edits preferences or the macOS default.
enum MicrophoneSelectionPolicy {
    static func resolve(preferences: MicrophonePreferences, available: [SavedMicrophone],
                        systemDefaultUID: String?) -> MicrophoneResolution {
        let preferences = preferences.normalized()
        let available = MicrophonePreferences.uniqueDevices(available)
        let systemDefault = available.first(where: { $0.uid == systemDefaultUID })
        // Core Audio's enumeration order is not a preference, so sort for a stable fallback.
        let fallback = systemDefault ?? available.min(by: { $0.uid < $1.uid })
        guard let fallback else { return MicrophoneResolution(device: nil, reason: .unavailable) }
        let defaultReason: MicrophoneResolutionReason = systemDefault == nil ? .fallback(requested: nil) : .systemDefault

        switch preferences.selection {
        case .automatic:
            for preferred in preferences.activeProfile.priority {
                if let device = available.first(where: { $0.uid == preferred.uid }) {
                    return MicrophoneResolution(device: device, reason: .priority)
                }
            }
            return MicrophoneResolution(device: fallback, reason: defaultReason)
        case .systemDefault:
            return MicrophoneResolution(device: fallback, reason: defaultReason)
        case .fixed(let requested):
            if let device = available.first(where: { $0.uid == requested.uid }) {
                return MicrophoneResolution(device: device, reason: .fixed)
            }
            return MicrophoneResolution(device: fallback, reason: .fallback(requested: requested))
        }
    }
}

/// Keeps the valid saved entries instead of losing every preference to one bad record.
private struct LossyArray<Element: Decodable>: Decodable {
    let values: [Element]

    init(from decoder: Decoder) throws {
        var items = try decoder.unkeyedContainer()
        var decoded: [Element] = []
        while !items.isAtEnd {
            let item = try items.superDecoder()
            if let value = try? Element(from: item) { decoded.append(value) }
        }
        values = decoded
    }
}
