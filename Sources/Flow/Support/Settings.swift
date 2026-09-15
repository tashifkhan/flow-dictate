import AppKit
import Foundation
import Observation

/// Where the panel parks itself while you talk.
enum PanelPlacement: String, CaseIterable, Identifiable, Sendable {
    case bottomCenter, nearCursor

    var id: String { rawValue }
    var label: String { self == .bottomCenter ? "Bottom center" : "Near the cursor" }
}

/// Whether the hotkey is held down or pressed once.
enum HotkeyActivation: String, CaseIterable, Identifiable, Sendable {
    case hold, toggle

    var id: String { rawValue }
    var label: String { self == .hold ? "Hold to talk" : "Press to start and stop" }

    var detail: String {
        switch self {
        case .hold: "Recording lasts as long as you hold the key."
        case .toggle: "Press once to start. Press again, or \u{2318}\u{21A9}, to stop. Esc cancels."
        }
    }
}

/// How much panel you want on screen while you talk.
enum PanelSize: String, CaseIterable, Identifiable, Sendable {
    case compact, standard

    var id: String { rawValue }
    var label: String { self == .compact ? "Compact" : "Standard" }

    /// Positioning runs before the hosting view has laid out, so it needs a size up front.
    /// Compact leaves room around the HUD for its glass edge and the wider error pill.
    var frame: CGSize {
        self == .compact ? CGSize(width: 272, height: 112) : CGSize(width: 380, height: 128)
    }
}

/// How long one recording may run before Flow stops it as if the key came up.
enum RecordingLimit: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case threeMinutes = 180
    case fiveMinutes = 300
    case tenMinutes = 600

    var id: Int { rawValue }
    var label: String { self == .off ? "Never" : "\(rawValue / 60) minutes" }
    /// "3-minute", for "Stopped at the 3-minute limit".
    var noticeName: String { "\(rawValue / 60)-minute" }
}

/// What the main window shows on open.
enum OpenTo: String, CaseIterable, Identifiable, Sendable {
    case recent, newNote

    var id: String { rawValue }
    var label: String { self == .recent ? "Most recent" : "A new note" }
}

/// The recognizer locale and script Flow should produce.
enum TranscriptionLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, hinglish

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "Follow system language"
        case .hinglish: "Hinglish (Hindi + English)"
        }
    }
    var detail: String {
        switch self {
        case .system: "Uses the macOS dictation language and keeps its normal script."
        case .hinglish: "Listens with the Hindi model and writes Hindi in simple Roman letters while keeping English words unchanged."
        }
    }
    var locale: Locale {
        switch self {
        case .system: .current
        case .hinglish: Locale(identifier: "hi-IN")
        }
    }
}

@MainActor @Observable
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    var hotkey: Hotkey {
        didSet {
            guard let data = try? JSONEncoder().encode(hotkey) else { return }
            defaults.set(data, forKey: K.hotkey)
        }
    }
    var activation: HotkeyActivation { didSet { defaults.set(activation.rawValue, forKey: K.activation) } }
    var placement: PanelPlacement { didSet { defaults.set(placement.rawValue, forKey: K.placement) } }
    /// Automatic priority lists, the system default, or one fixed device, all keyed by
    /// device UID, which survives reboots and re-pairings.
    var microphones: MicrophonePreferences {
        didSet {
            guard let data = try? JSONEncoder().encode(microphones) else { return }
            defaults.set(data, forKey: K.microphones)
        }
    }
    var panelSize: PanelSize { didSet { defaults.set(panelSize.rawValue, forKey: K.panelSize) } }
    /// Off by default. Worth turning on with press-to-toggle, where a forgotten
    /// recording is easy.
    var recordingLimit: RecordingLimit { didSet { defaults.set(recordingLimit.rawValue, forKey: K.recordingLimit) } }
    var retention: Retention { didSet { defaults.set(retention.rawValue, forKey: K.retention) } }
    var openTo: OpenTo { didSet { defaults.set(openTo.rawValue, forKey: K.openTo) } }
    var transcriptionLanguage: TranscriptionLanguage {
        didSet { defaults.set(transcriptionLanguage.rawValue, forKey: K.transcriptionLanguage) }
    }

    /// Cleanup is never load-bearing for insertion; this only turns off the attempt.
    var cleanupEnabled: Bool { didSet { defaults.set(cleanupEnabled, forKey: K.cleanup) } }
    /// Try the Accessibility direct-set path before falling back to paste.
    var preferAXInsert: Bool { didSet { defaults.set(preferAXInsert, forKey: K.ax) } }
    /// Card preview lines in the grid, 0 to 5.
    var previewLines: Int { didSet { defaults.set(previewLines, forKey: K.preview) } }
    var playSounds: Bool { didSet { defaults.set(playSounds, forKey: K.sounds) } }
    /// For people who launch things from the dock rather than the menu bar.
    var showDockIcon: Bool { didSet { defaults.set(showDockIcon, forKey: K.dock); applyActivationPolicy() } }
    /// Opt-in, per the plan's permissions table. Off by default; the panel already says so.
    var notifyOnInsert: Bool { didSet { defaults.set(notifyOnInsert, forKey: K.notify) } }
    /// Use a trained custom language model. Costs you `SpeechTranscriber`, since a
    /// custom model can only attach to `DictationTranscriber`.
    var useCustomLanguageModel: Bool { didSet { defaults.set(useCustomLanguageModel, forKey: K.customLM) } }
    /// Local HTTP API. Off by default; loopback only even when on.
    var apiEnabled: Bool { didSet { defaults.set(apiEnabled, forKey: K.api) } }
    var apiPort: Int { didSet { defaults.set(apiPort, forKey: K.apiPort) } }

    private enum K {
        static let hotkey = "hotkeyV2"
        static let legacyKey = "pushToTalkKey"
        static let activation = "hotkeyActivation"
        static let placement = "panelPlacement"
        /// Read only to migrate the old single-device picker.
        static let inputDevice = "inputDeviceUID"
        static let microphones = "microphonePreferences"
        static let panelSize = "panelSize"
        static let recordingLimit = "recordingLimit"
        static let retention = "retention"
        static let openTo = "openTo"
        static let transcriptionLanguage = "transcriptionLanguage"
        static let cleanup = "cleanupEnabled"
        static let ax = "preferAXInsert"
        static let preview = "previewLines"
        static let sounds = "playSounds"
        static let dock = "showDockIcon"
        static let notify = "notifyOnInsert"
        static let customLM = "useCustomLanguageModel"
        static let api = "apiEnabled"
        static let apiPort = "apiPort"
    }

    /// The menu bar stays the primary surface either way; this only adds the dock icon.
    func applyActivationPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    private init() {
        defaults.register(defaults: [
            K.cleanup: true, K.ax: true, K.preview: 3, K.sounds: true,
            K.dock: false, K.notify: false, K.customLM: false,
            K.api: false, K.apiPort: 8787,
        ])
        // Migrate the old three-way enum, which stored a bare name.
        if let data = defaults.data(forKey: K.hotkey),
           let decoded = try? JSONDecoder().decode(Hotkey.self, from: data) {
            hotkey = decoded
        } else {
            switch defaults.string(forKey: K.legacyKey) {
            case "rightOption": hotkey = .rightOption
            case "rightCommand": hotkey = .rightCommand
            default: hotkey = .fn
            }
        }
        activation = HotkeyActivation(rawValue: defaults.string(forKey: K.activation) ?? "") ?? .hold
        placement = PanelPlacement(rawValue: defaults.string(forKey: K.placement) ?? "") ?? .bottomCenter
        if let data = defaults.data(forKey: K.microphones),
           let decoded = try? JSONDecoder().decode(MicrophonePreferences.self, from: data) {
            microphones = decoded
        } else if let uid = defaults.string(forKey: K.inputDevice), !uid.isEmpty {
            // The old picker stored one UID. Keep that choice as a fixed device.
            let device = AudioDevices.device(uid: uid)?.saved
                ?? SavedMicrophone(uid: uid, name: "Microphone", transport: .other)
            microphones = MicrophonePreferences(selection: .fixed(device))
        } else {
            microphones = MicrophonePreferences()
        }
        panelSize = PanelSize(rawValue: defaults.string(forKey: K.panelSize) ?? "") ?? .compact
        recordingLimit = RecordingLimit(rawValue: defaults.integer(forKey: K.recordingLimit)) ?? .off
        retention = Retention(rawValue: defaults.string(forKey: K.retention) ?? "") ?? .ninetyDays
        openTo = OpenTo(rawValue: defaults.string(forKey: K.openTo) ?? "") ?? .recent
        transcriptionLanguage = TranscriptionLanguage(
            rawValue: defaults.string(forKey: K.transcriptionLanguage) ?? ""
        ) ?? .system
        cleanupEnabled = defaults.bool(forKey: K.cleanup)
        preferAXInsert = defaults.bool(forKey: K.ax)
        previewLines = defaults.integer(forKey: K.preview)
        playSounds = defaults.bool(forKey: K.sounds)
        showDockIcon = defaults.bool(forKey: K.dock)
        notifyOnInsert = defaults.bool(forKey: K.notify)
        useCustomLanguageModel = defaults.bool(forKey: K.customLM)
        apiEnabled = defaults.bool(forKey: K.api)
        apiPort = defaults.integer(forKey: K.apiPort)
    }
}
