import AppKit
import Combine
import SwiftUI

/// The first thing you see until Flow can actually do its job.
///
/// Flow is a menu bar accessory, so without this there is no window at launch and no
/// way to find out why holding the key does nothing. This is that answer, in one page.
struct SetupView: View {
    @Bindable var env: AppEnvironment
    @State private var tick = 0

    /// Permissions are granted outside the app, so poll while this view is on screen.
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                steps
                status
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("Setup")
        .onReceive(poll) { _ in
            tick += 1
            env.refreshPermissionState()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tint)
            Text(env.needsSetup ? missingPermissionTitle : "Flow is ready")
                .font(.largeTitle.weight(.semibold))
            Text(env.needsSetup
                 ? "Flow can't type at your cursor until macOS lets it. Both prompts are one-time."
                 : "Hold \(Settings.shared.hotkey.label) anywhere, talk, and let go.")
                .foregroundStyle(.secondary)
        }
    }

    private var missingPermissionTitle: String {
        let count = (env.hasMicrophone ? 0 : 1) + (env.hasAccessibility ? 0 : 1)
        return count == 1 ? "One thing left" : "Two things left"
    }

    // MARK: - Permission steps

    private var steps: some View {
        VStack(spacing: 12) {
            step(
                number: 1,
                title: "Microphone",
                detail: "So there is something to transcribe.",
                granted: env.hasMicrophone,
                denied: Permissions.micStatus == .denied,
                action: "Allow microphone"
            ) {
                if Permissions.micStatus == .denied {
                    Permissions.openMicrophoneSettings()
                } else {
                    Task { _ = await AudioCapture.requestMicAccess(); env.refreshPermissionState() }
                }
            }

            step(
                number: 2,
                title: "Accessibility",
                detail: "So Flow can watch the push-to-talk key and type at your cursor.",
                granted: env.hasAccessibility,
                denied: false,
                action: "Open Accessibility settings"
            ) {
                Permissions.requestAccessibility()
                Permissions.openAccessibilitySettings()
            }

            if !env.hasAccessibility {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "Flow must be in the list and its switch must be on. Adding Flow.app without turning on the switch does not grant access. Flow detects approval without a relaunch.",
                        systemImage: "plus.app"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    Button("Show Flow.app in Finder", action: Permissions.revealFlowInFinder)
                        .buttonStyle(.link)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.orange.opacity(0.12), in: .rect(cornerRadius: 10))
            }
        }
    }

    private func step(
        number: Int, title: String, detail: String,
        granted: Bool, denied: Bool, action: String,
        perform: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(granted ? AnyShapeStyle(.green) : AnyShapeStyle(.quaternary))
                    .frame(width: 26, height: 26)
                if granted {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption.weight(.semibold))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(granted ? "Granted" : detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if denied {
                    Text("Currently denied — you'll need to switch it on in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            if !granted {
                Button(action, action: perform)
                    .buttonStyle(.glassProminent)
                    .fixedSize()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
    }

    // MARK: - Engine status

    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Engine").font(.headline)

            row("Transcription", env.controller.transcriberLabel, ok: true)
            row("Speech model", env.controller.assetStatusLabel,
                ok: env.controller.assetStatusLabel == "Installed")
            row("Cleanup", env.controller.cleanupAvailability.label,
                ok: env.controller.cleanupAvailability.isAvailable)

            if let detail = env.controller.cleanupAvailability.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
                cleanupActions
            }

            if let problem = env.startupProblem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }

            Divider().padding(.vertical, 4)

            HStack {
                Button {
                    env.toggleFromUI()
                } label: {
                    Label(env.controller.phase.isBusy ? "Stop" : "Try a dictation", systemImage: "mic")
                }
                .buttonStyle(.glassProminent)
                .disabled(!env.hasMicrophone)

                if case .failed(let message) = env.controller.phase {
                    Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
                } else if case .inserted = env.controller.phase {
                    Label("That worked", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                } else if !env.controller.transcript.isEmpty {
                    Text(env.controller.transcript).font(.caption).lineLimit(2)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private var cleanupActions: some View {
        HStack(spacing: 12) {
            if case .unsupportedLanguage = env.controller.cleanupAvailability {
                Button("Open Language & Region", action: Permissions.openLanguageSettings)
                    .buttonStyle(.link)
                Button("Open Siri settings", action: Permissions.openAppleIntelligenceSettings)
                    .buttonStyle(.link)
            } else if env.controller.cleanupAvailability == .modelNotReady &&
                        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
                Button("Open Siri settings", action: Permissions.openAppleIntelligenceSettings)
                    .buttonStyle(.link)
                Button("Open Software Update", action: Permissions.openSoftwareUpdate)
                    .buttonStyle(.link)
            } else if env.controller.cleanupAvailability == .appleIntelligenceOff ||
                        env.controller.cleanupAvailability == .modelNotReady {
                Button("Open Apple Intelligence settings", action: Permissions.openAppleIntelligenceSettings)
                    .buttonStyle(.link)
            }
            Button("Check again", action: env.controller.refreshCleanupAvailability)
                .buttonStyle(.link)
        }
        .font(.caption)
    }

    private func row(_ label: String, _ value: String, ok: Bool) -> some View {
        HStack {
            Circle().fill(ok ? .green : .orange).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}
