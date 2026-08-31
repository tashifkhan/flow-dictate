import AppKit
import Foundation
import Observation

/// Where the panel parks itself while you talk.
enum PanelPlacement: String, CaseIterable, Identifiable, Sendable {
    case bottomCenter, nearCursor

    var id: String { rawValue }
    var label: String { self == .bottomCenter ? "Bottom center" : "Near the cursor" }
}

/// What the main window shows on open.
enum OpenTo: String, CaseIterable, Identifiable, Sendable {
    case recent, newNote

    var id: String { rawValue }
    var label: String { self == .recent ? "Most recent" : "A new note" }
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
    var placement: PanelPlacement { didSet { defaults.set(placement.rawValue, forKey: K.placement) } }
    var retention: Retention { didSet { defaults.set(retention.rawValue, forKey: K.retention) } }
    var openTo: OpenTo { didSet { defaults.set(openTo.rawValue, forKey: K.openTo) } }

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
        static let placement = "panelPlacement"
        static let retention = "retention"
        static let openTo = "openTo"
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
        placement = PanelPlacement(rawValue: defaults.string(forKey: K.placement) ?? "") ?? .bottomCenter
        retention = Retention(rawValue: defaults.string(forKey: K.retention) ?? "") ?? .ninetyDays
        openTo = OpenTo(rawValue: defaults.string(forKey: K.openTo) ?? "") ?? .recent
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
