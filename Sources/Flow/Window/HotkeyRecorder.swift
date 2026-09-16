import AppKit
import SwiftUI

/// Click, then press the key or keys you want to hold to talk.
///
/// Accepts a bare modifier (fn, right ⌥ — the nicest thing to hold), several modifiers
/// held together (⌃⇧⌥), or a key with at least one modifier. Modifiers are saved when
/// you let go of them, so a chord is not cut short by whichever key went down first.
/// A bare letter is refused: this is a global watcher, and binding it to "T" would fire
/// every time you typed one.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    var onChange: () -> Void

    @State private var recording = false
    @State private var monitor: Any?
    @State private var rejected: String?
    /// Every modifier held since the last full release, and the first key pressed.
    @State private var held: CGEventFlags = []
    @State private var firstModifier: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    recording ? stop() : start()
                } label: {
                    Text(recording ? recordingLabel : hotkey.label)
                        .font(.body.monospaced())
                        .frame(minWidth: 130)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.bordered)
                .tint(recording ? .accentColor : nil)

                if recording {
                    Button("Cancel", action: stop).buttonStyle(.link)
                } else {
                    Menu("Presets") {
                        ForEach(Hotkey.presets, id: \.self) { preset in
                            Button(preset.label) {
                                hotkey = preset
                                onChange()
                            }
                        }
                    }
                    .fixedSize()
                }
            }

            if let rejected {
                Text(rejected).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stop)
    }

    private var recordingLabel: String {
        held.isEmpty ? "Press keys…" : Hotkey.modifierSymbols(held) + "…"
    }

    private func start() {
        rejected = nil
        held = []
        firstModifier = nil
        recording = true
        // Local monitor: the settings window is key while you are recording, and a
        // global tap here would capture keystrokes meant for other apps.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            capture(event)
            return nil  // swallow it, so recording ⌘Q does not quit
        }
    }

    private func stop() {
        recording = false
        held = []
        firstModifier = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func capture(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))

        if event.type == .flagsChanged {
            guard Hotkey.modifierFlag(forKeyCode: keyCode) != nil else { return }
            let present = CGEventFlags(rawValue: flags.rawValue & Hotkey.modifierMask)
            if !present.isEmpty {
                // Still pressing: grow the chord and wait for the release.
                if firstModifier == nil { firstModifier = keyCode }
                held.insert(present)
                rejected = nil
                return
            }
            // Everything is up: save whatever was held at its widest.
            guard let first = firstModifier,
                  let candidate = Hotkey.modifiers(keyCode: first, flags: held) else { return }
            hotkey = candidate
            finish()
            return
        }

        if keyCode == kVK_Escape_ {
            stop()
            return
        }

        let modifiers = flags.rawValue & Hotkey.modifierMask
        guard modifiers != 0 else {
            rejected = "Add a modifier — a bare key would fire while you type."
            return
        }
        hotkey = Hotkey.combo(keyCode: keyCode, flags: flags)
        finish()
    }

    private func finish() {
        stop()
        onChange()
    }

    private let kVK_Escape_ = 53
}
