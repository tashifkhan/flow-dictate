import AppKit
import Foundation
import Observation
import OSLog

/// Everything long-lived, in one place, created once at launch.
@MainActor @Observable
final class AppEnvironment {
    let library: Library
    let lexicon: Lexicon
    let controller: DictationController
    let presenter: PanelPresenter
    private let hotkey = HotkeyMonitor()
    /// Assigned in `init`, because `@Observable` has no room for a lazy stored property
    /// and the server needs a reference back to this environment.
    private(set) var server: FlowServer!
    private let log = Logger(subsystem: "sh.taf.flow", category: "app")

    /// Surfaced in the menu bar when the hotkey cannot be installed.
    private(set) var startupProblem: String?

    /// Mirrored into observable state, because TCC grants happen outside the app and
    /// nothing notifies us when they land.
    private(set) var hasAccessibility = Permissions.hasAccessibility
    private(set) var hasMicrophone = Permissions.hasMicrophone

    /// True until Flow can both hear you and type for you.
    var needsSetup: Bool { !hasAccessibility || !hasMicrophone }

    /// Re-reads permission state; the setup screen polls this while it is open.
    func refreshPermissionState() {
        let accessibility = Permissions.hasAccessibility
        let microphone = Permissions.hasMicrophone
        if accessibility != hasAccessibility { hasAccessibility = accessibility }
        if microphone != hasMicrophone { hasMicrophone = microphone }

        // The event tap could not be installed before the grant; try again now.
        if accessibility, startupProblem != nil {
            startupProblem = nil
            try? hotkey.start()
        }
    }

    /// Selected in the main window; also where `flowclone://note` lands.
    var openNoteID: UUID?
    /// Highlighted in the history browser, so ⇧⌘V knows what to re-insert.
    var selectedDictationID: UUID?

    /// The dictation ⇧⌘V would put back at the cursor: whatever is selected, or the
    /// most recent one if nothing is.
    var reinsertCandidate: DictationRecord? {
        if let selectedDictationID, let match = library.dictations.first(where: { $0.id == selectedDictationID }) {
            return match
        }
        return library.recent(1).first
    }

    /// The scenes and the app delegate both need this, and they are created in an
    /// order SwiftUI does not promise, so it lives here.
    static let shared = AppEnvironment()

    private var started = false

    private init() {
        let library = Library.make()
        let lexicon = Lexicon()
        self.library = library
        self.lexicon = lexicon
        let controller = DictationController(library: library, lexicon: lexicon)
        self.controller = controller
        self.presenter = PanelPresenter(controller: controller)
        self.server = FlowServer(env: self)
    }

    func start() {
        guard !started else { return }
        started = true
        controller.warmUp()

        // The panel follows the dictation, not the other way round.
        hotkey.onPress = { [weak self] in
            guard let self else { return }
            self.controller.begin()
            self.presenter.show()
        }
        hotkey.onRelease = { [weak self] in
            guard let self else { return }
            self.controller.end()
            self.hidePanelWhenSettled()
        }

        // The event tap needs Accessibility, and a tap created without it stays quiet
        // rather than failing loudly. Ask first so the state is honest.
        if !Permissions.hasAccessibility {
            Permissions.requestAccessibility()
            startupProblem = Inserter.InsertError.noAccessibility.localizedDescription
        } else {
            do {
                try hotkey.start()
            } catch {
                startupProblem = error.localizedDescription
                log.error("hotkey unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }

        hotkey.isDictating = { [weak self] in self?.controller.phase.isBusy ?? false }
        hotkey.onCancel = { [weak self] in
            self?.controller.cancel()
            self?.presenter.hide()
        }

        applyServerSetting()
        observePhase()

        controller.onNoteText = { [weak self] id, text in
            self?.appendToNote(id, text: text)
        }
    }

    func hotkeyChanged() { hotkey.refresh() }

    /// Starts or stops the local API to match the setting.
    func applyServerSetting() {
        if Settings.shared.apiEnabled {
            server.start(port: UInt16(clamping: Settings.shared.apiPort))
        } else {
            server.stop()
        }
    }

    /// Start a dictation without the keyboard, for the days the hotkey feels far away.
    func toggleFromUI() {
        switch controller.phase {
        case .idle, .failed, .inserted:
            controller.begin()
            presenter.show()
        case .recording, .preparing:
            controller.end()
            hidePanelWhenSettled()
        case .processing:
            break
        }
    }

    /// The panel follows the dictation and nothing else, so it has to disappear on its
    /// own when the dictation is over — including when it ended in an error that has
    /// since timed out. Without this it sits on screen saying "Hold fn to talk" forever.
    private func observePhase() {
        withObservationTracking {
            _ = controller.phase
        } onChange: {
            Task { @MainActor in
                if self.controller.phase == .idle { self.presenter.hide() }
                self.observePhase()
            }
        }
    }

    private func hidePanelWhenSettled() {
        Task {
            // Give the panel long enough to show the result before it collapses.
            while controller.phase.isBusy { try? await Task.sleep(for: .milliseconds(80)) }
            try? await Task.sleep(for: .milliseconds(800))
            if !controller.phase.isBusy { presenter.hide() }
        }
    }

    private func appendToNote(_ id: UUID, text: String) {
        guard var note = library.note(id) else { return }
        if note.text.isEmpty {
            note.text = text
        } else {
            let separator = note.text.hasSuffix(" ") || note.text.hasSuffix("\n") ? "" : " "
            note.text += separator + text
        }
        library.save(note)
    }

    // MARK: - URL scheme

    /// `flowclone://toggle`, `flowclone://history`, `flowclone://note`.
    func handle(_ url: URL) {
        guard url.scheme == "flowclone" else { return }
        let action = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        switch action {
        case "toggle":
            toggleFromUI()
        case "history":
            openMainWindow()
        case "note":
            let note = library.newNote()
            openNoteID = note.id
            openMainWindow()
        default:
            log.info("unknown url action \(action, privacy: .public)")
        }
    }

    /// Set by the scene, which is the only place `openWindow` is reachable.
    var showMainWindow: (() -> Void)?

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        showMainWindow?()
    }
}
