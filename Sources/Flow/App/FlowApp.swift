import AppKit
import SwiftUI

@main
struct FlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var env: AppEnvironment { .shared }

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!Settings.isDiagnosticRun)) {
            MenuBarView(env: env)
        } label: {
            // Filled while it is listening, so the menu bar agrees with the mic dot.
            Image(systemName: env.controller.phase.isBusy ? "waveform.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.window)

        Window("Flow", id: Self.mainWindowID) {
            MainWindow(env: env)
        }
        .defaultSize(width: 900, height: 620)
        .windowResizability(.contentMinSize)
        // A menu bar accessory has no window at launch, which leaves a half-configured
        // Flow with no way to say what is wrong. Show the window until setup is done.
        .defaultLaunchBehavior(Settings.isDemo ? .presented : Settings.isDiagnosticRun ? .suppressed
                               : AppEnvironment.shared.needsSetup ? .presented : .automatic)
        .commands { FlowCommands(env: env) }

        // Qualified: Flow has its own `Settings` model type.
        SwiftUI.Settings {
            SettingsView(env: env)
        }
    }

    static let mainWindowID = "main"
}

/// Menu bar apps get their URL callbacks through the app delegate; SwiftUI's
/// `onOpenURL` only fires for scenes that happen to be on screen.
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Dismissing the floating dictation panel must never quit the menu bar app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Flow owns a global hotkey even with every window hidden.
            ProcessInfo.processInfo.disableAutomaticTermination("Flow waits for the dictation hotkey")
            if CommandLine.arguments.contains("--self-check") { SelfCheck.run() }
            if let index = CommandLine.arguments.firstIndex(of: "--check-audio-capture"),
               CommandLine.arguments.indices.contains(index + 1) {
                let output = CommandLine.arguments[index + 1]
                Task { await AudioCaptureCheck.run(output: output) }
                return
            }
            if let index = CommandLine.arguments.firstIndex(of: "--demo-screenshots"),
               CommandLine.arguments.indices.contains(index + 1) {
                let directory = CommandLine.arguments[index + 1]
                guard Settings.isDemo else {
                    print("--demo-screenshots runs only in a copy whose bundle ID is sh.taf.flow.demo. Use scripts/screenshots.sh.")
                    exit(2)
                }
                Task { await DemoScreenshots.run(directory: directory) }
                return
            }
            if CommandLine.arguments.contains("--print-prompts") {
                print(PromptLibrary.sample())
                exit(0)
            }
            if CommandLine.arguments.contains("--check-streaming") {
                Task { await StreamingCheck.run() }
                return
            }
            if let index = CommandLine.arguments.firstIndex(of: "--check-panel"),
               CommandLine.arguments.indices.contains(index + 1) {
                let directory = CommandLine.arguments[index + 1]
                Task { await PanelCheck.run(directory: directory) }
                return
            }
            if let index = CommandLine.arguments.firstIndex(of: "--check-electron-insertion"),
               CommandLine.arguments.indices.contains(index + 1) {
                let directory = CommandLine.arguments[index + 1]
                Task { await ElectronInsertionCheck.run(directory: directory) }
                return
            }
            if let index = CommandLine.arguments.firstIndex(of: "--check-target-insertion"),
               CommandLine.arguments.indices.contains(index + 2) {
                let bundleID = CommandLine.arguments[index + 1]
                let output = CommandLine.arguments[index + 2]
                Task { await TargetInsertionCheck.run(bundleID: bundleID, output: output) }
                return
            }
            if let index = CommandLine.arguments.firstIndex(of: "--check-cloud-live"),
               CommandLine.arguments.indices.contains(index + 2) {
                let audio = CommandLine.arguments[index + 1]
                let output = CommandLine.arguments[index + 2]
                Task { await CloudLiveCheck.run(audio: audio, output: output) }
                return
            }
            if let index = CommandLine.arguments.firstIndex(of: "--check-cloud-http"),
               CommandLine.arguments.indices.contains(index + 2) {
                let baseURL = CommandLine.arguments[index + 1]
                let output = CommandLine.arguments[index + 2]
                Task { await CloudHTTPCheck.run(baseURL: baseURL, output: output) }
                return
            }
            if let index = CommandLine.arguments.firstIndex(of: "--check-insertion"),
               CommandLine.arguments.indices.contains(index + 1) {
                let output = CommandLine.arguments[index + 1]
                Task { await SelfCheck.checkInsertion(output: output) }
                return
            }
            if let index = CommandLine.arguments.firstIndex(of: "--probe-focus"),
               CommandLine.arguments.indices.contains(index + 2) {
                let bundleID = CommandLine.arguments[index + 1]
                let output = CommandLine.arguments[index + 2]
                Task { await SelfCheck.probeFocus(bundleID: bundleID, output: output) }
                return
            }
            // A development build and the installed app have the same bundle id but
            // can still be launched from different paths. Without this guard both own
            // the global hotkey and both insert the same dictation. The oldest process
            // wins, so a newly launched duplicate exits before installing its event tap.
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let runningPIDs = NSRunningApplication.runningApplications(
                withBundleIdentifier: Bundle.main.bundleIdentifier ?? "sh.taf.flow"
            ).map(\.processIdentifier)
            if Self.shouldYieldToExistingInstance(currentPID: currentPID, runningPIDs: runningPIDs) {
                NSApp.terminate(nil)
                return
            }
            // Accessory by default; the menu bar is the primary surface. A setting can
            // add the dock icon back for people who launch things that way.
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged(_:)),
                                                       name: name, object: nil)
            }
            Settings.shared.applyActivationPolicy()
            AppEnvironment.shared.start()
        }
    }

    @MainActor @objc private func windowVisibilityChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if notification.name == NSWindow.willCloseNotification {
            Settings.shared.windowWillClose(window)
        } else if notification.name == NSWindow.didBecomeKeyNotification {
            Settings.shared.windowDidOpen(window)
        } else {
            Settings.shared.applyActivationPolicy()
        }
    }

    static func shouldYieldToExistingInstance(currentPID: pid_t, runningPIDs: [pid_t]) -> Bool {
        guard let oldest = runningPIDs.min() else { return false }
        return oldest != currentPID
    }


    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            urls.forEach(AppEnvironment.shared.handle)
        }
    }
}

/// The in-app shortcuts. The global push-to-talk key is an event tap, not a command.
struct FlowCommands: Commands {
    var env: AppEnvironment

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Note") {
                let note = env.library.newNote()
                env.openNoteID = note.id
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Start Dictation") { env.toggleFromUI() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }

        CommandGroup(after: .pasteboard) {
            Button("Insert at Cursor") {
                guard let candidate = env.reinsertCandidate else { return }
                env.controller.reinsert(candidate.inserted)
                env.presenter.show()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(env.reinsertCandidate == nil)
        }
    }
}
