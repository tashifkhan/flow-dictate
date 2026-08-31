import AppKit
import SwiftUI

/// Click, then press the key you want to hold to talk.
///
/// Accepts either a bare modifier (fn, right ⌥ — the nicest thing to hold) or a key
/// with at least one modifier. A bare letter is refused: this is a global watcher, and
/// binding it to "T" would fire every time you typed one.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    var onChange: () -> Void

    @State private var recording = false
    @State private var monitor: Any?
    @State private var rejected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    recording ? stop() : start()
                } label: {
                    Text(recording ? "Press a key…" : hotkey.label)
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

    private func start() {
        rejected = nil
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
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func capture(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))

        if event.type == .flagsChanged {
            // Only take a modifier on the way down.
            guard let candidate = Hotkey.modifierOnly(keyCode: keyCode),
                  flags.contains(candidate.flags) else { return }
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
