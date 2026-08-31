import ApplicationServices
import AVFoundation
import AppKit
import Foundation

/// The three prompts Flow ever shows, and where to send people when they say no.
enum Permissions {
    /// Needed for the event tap that watches the push-to-talk key, and for synthesising
    /// the paste. Without it Flow can listen but never type.
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt. Returns the state before the prompt, so callers can
    /// tell "already granted" from "just asked".
    @discardableResult
    static func requestAccessibility() -> Bool {
        // The constant is an imported global var, so it is not concurrency-safe to
        // touch; its value is stable and documented.
        let options = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static var micStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var hasMicrophone: Bool { micStatus == .authorized }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func revealFlowInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openAppleIntelligenceSettings() {
        open("x-apple.systempreferences:com.apple.AppleIntelligence-Settings.extension")
    }

    static func openLanguageSettings() {
        open("x-apple.systempreferences:com.apple.Localization-Settings.extension")
    }

    static func openSoftwareUpdate() {
        open("x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
