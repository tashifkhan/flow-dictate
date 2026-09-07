import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import OSLog

/// Watches for the push-to-talk key being held.
///
/// This is an event tap rather than a registered hotkey because push-to-talk needs
/// both edges: a registered shortcut only ever tells you it fired. Claimed key
/// presses are consumed so they cannot also run a command in the foreground app.
@MainActor
final class HotkeyMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false
    private var consumedKeys: Set<Int> = []
    private let log = Logger(subsystem: "sh.taf.flow", category: "hotkey")

    // An active event tap must return before querying another app through AX.
    // Queue actions in order; only the consume/pass decision runs in the callback.
    var dispatchAction: (@escaping @MainActor () -> Void) -> Void = { action in
        DispatchQueue.main.async { action() }
    }

    var onPress: @MainActor () -> Void = {}
    var onRelease: @MainActor () -> Void = {}
    /// Toggle mode: one edge, meaning "start if idle, stop if running".
    var onToggle: @MainActor () -> Void = {}
    /// ⌘↩ while recording: stop and insert, without reaching for the hotkey again.
    var onStop: @MainActor () -> Void = {}
    /// Escape, for a dictation you thought better of. Only consulted while one is running.
    var onCancel: @MainActor () -> Void = {}
    /// Asked before Escape is treated as a cancel, so Escape stays Escape the rest of the time.
    var isDictating: () -> Bool = { false }

    /// Read fresh on every event so changing the setting takes effect immediately,
    /// without tearing the tap down.
    private var key: Hotkey { Settings.shared.hotkey }
    private var activation: HotkeyActivation { Settings.shared.activation }

    enum HotkeyError: Error, LocalizedError {
        case tapFailed
        var errorDescription: String? {
            "Flow couldn't watch the keyboard. Grant Accessibility access in System Settings › Privacy & Security › Accessibility."
        }
    }

    func start() throws {
        guard tap == nil else { return }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                // The tap callback runs on the main run loop, so this hop is safe.
                let consumed = MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
                return consumed ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            throw HotkeyError.tapFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
        log.info("watching \(self.key.label, privacy: .public)")
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isDown = false
        consumedKeys.removeAll()
    }

    /// Re-reads the setting. The tap itself does not care which key it is.
    func refresh() { log.info("now watching \(self.key.label, privacy: .public)") }

    /// Returns true when the event belongs to Flow and must not reach another app.
    func handle(type: CGEventType, event: CGEvent, hotkey override: Hotkey? = nil) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == Inserter.eventMarker { return false }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let hotkey = override ?? key

        // Keep owning the entire press after recording ends, even if modifiers are
        // released first or an autorepeat arrives after transcription finishes.
        if type == .keyUp, consumedKeys.remove(keyCode) != nil {
            if keyCode == hotkey.keyCode { set(down: false) }
            return true
        }
        if type == .keyDown, consumedKeys.contains(keyCode) { return true }

        if type == .keyDown, keyCode == kVK_Escape, isDictating() {
            consumedKeys.insert(keyCode)
            dispatchAction(onCancel)
            return true
        }

        if type == .keyDown, keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter,
           event.flags.contains(.maskCommand), isDictating() {
            consumedKeys.insert(keyCode)
            dispatchAction(onStop)
            return true
        }

        if hotkey.isModifierOnly {
            // Modifier changes must still reach apps so their modifier state stays valid.
            guard type == .flagsChanged, keyCode == hotkey.keyCode else { return false }
            set(down: event.flags.contains(hotkey.flags))
        } else if type == .keyDown, keyCode == hotkey.keyCode {
            let required = hotkey.flags.rawValue & Hotkey.modifierMask
            let present = event.flags.rawValue & Hotkey.modifierMask
            guard present & required == required else { return false }
            consumedKeys.insert(keyCode)
            set(down: true)
            return true
        }
        return false
    }

    private func set(down: Bool) {
        guard down != isDown else { return }
        isDown = down

        // Toggle mode acts on the press edge and ignores the release entirely, so the
        // key can be tapped rather than held.
        guard activation == .hold else {
            if down { dispatchAction(onToggle) }
            return
        }
        dispatchAction(down ? onPress : onRelease)
    }
}

