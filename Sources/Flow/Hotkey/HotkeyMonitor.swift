import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import OSLog

/// Watches for the push-to-talk key being held.
///
/// This is an event tap rather than a registered hotkey because push-to-talk needs
/// both edges: a registered shortcut only ever tells you it fired. The tap is
/// listen-only, so the key keeps doing whatever it normally does.
@MainActor
final class HotkeyMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false
    private let log = Logger(subsystem: "sh.taf.flow", category: "hotkey")

    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    /// Escape, for a dictation you thought better of. Only consulted while one is running.
    var onCancel: () -> Void = {}
    /// Asked before Escape is treated as a cancel, so Escape stays Escape the rest of the time.
    var isDictating: () -> Bool = { false }

    /// Read fresh on every event so changing the setting takes effect immediately,
    /// without tearing the tap down.
    private var key: Hotkey { Settings.shared.hotkey }

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
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                // The tap callback runs on the main run loop, so this hop is safe.
                MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
                return Unmanaged.passUnretained(event)
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
    }

    /// Re-reads the setting. The tap itself does not care which key it is.
    func refresh() { log.info("now watching \(self.key.label, privacy: .public)") }

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS disables a tap that takes too long. Turn it back on rather than
        // silently losing the hotkey for the rest of the session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let hotkey = key

        // The tap is listen-only, so Escape still reaches whatever has focus. That is
        // fine: the panel is not focused, and cancelling is the only extra effect.
        if type == .keyDown, keyCode == kVK_Escape, isDictating() {
            onCancel()
            return
        }

        if hotkey.isModifierOnly {
            guard type == .flagsChanged, keyCode == hotkey.keyCode else { return }
            set(down: event.flags.contains(hotkey.flags))
        } else {
            guard type == .keyDown || type == .keyUp, keyCode == hotkey.keyCode else { return }
            if type == .keyDown {
                // Only the press edge checks modifiers: by key-up macOS has usually
                // cleared them already.
                let required = hotkey.flags.rawValue & Hotkey.modifierMask
                let present = event.flags.rawValue & Hotkey.modifierMask
                guard present & required == required else { return }
                set(down: true)
            } else {
                set(down: false)
            }
        }
    }

    private func set(down: Bool) {
        guard down != isDown else { return }
        isDown = down
        down ? onPress() : onRelease()
    }
}

