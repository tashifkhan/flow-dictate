import AppKit
import SwiftUI

@main
struct FlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var env: AppEnvironment { .shared }

    var body: some Scene {
        MenuBarExtra {
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
        .defaultLaunchBehavior(AppEnvironment.shared.needsSetup ? .presented : .automatic)
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if CommandLine.arguments.contains("--self-check") { SelfCheck.run() }
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
            Settings.shared.applyActivationPolicy()
            AppEnvironment.shared.start()
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
