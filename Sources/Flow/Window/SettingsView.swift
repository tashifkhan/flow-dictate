import AppKit
import SwiftUI

/// Settings, mirrored from the Siri app's shape: behaviour, appearance, retention.
struct SettingsView: View {
    @Bindable var env: AppEnvironment
    @State private var settings = Settings.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var newWord = ""

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            api.tabItem { Label("API", systemImage: "terminal") }
            vocabulary.tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
            privacy.tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 480, height: 400)
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section {
                LabeledContent("Hold to talk") {
                    HotkeyRecorder(hotkey: $settings.hotkey) { env.hotkeyChanged() }
                }

                Picker("Panel appears", selection: $settings.placement) {
                    ForEach(PanelPlacement.allCases) { Text($0.label).tag($0) }
                }

                Toggle("Play a sound when text lands", isOn: $settings.playSounds)

                Toggle("Notify when text is inserted", isOn: $settings.notifyOnInsert)
                    .onChange(of: settings.notifyOnInsert) { _, on in
                        guard on else { return }
                        // Ask only when it is switched on, so the prompt has a reason.
                        Task {
                            if await !Toast.requestAuthorization() { settings.notifyOnInsert = false }
                        }
                    }
            } header: {
                Text("Dictation")
            } footer: {
                Text("Push-to-talk only. A toggle invites you to forget it is recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Text") {
                Toggle("Clean up with Apple Intelligence", isOn: $settings.cleanupEnabled)
                Text(env.controller.cleanupAvailability.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Insert directly when the app supports it", isOn: $settings.preferAXInsert)
                Text("Otherwise Flow pastes, which is what makes Electron apps behave.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("App") {
                Toggle("Launch at start up", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        loginError = LoginItem.set(enabled)
                        if loginError != nil { launchAtLogin = LoginItem.isEnabled }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }

                Toggle("Show a dock icon", isOn: $settings.showDockIcon)

                Picker("Open window to", selection: $settings.openTo) {
                    ForEach(OpenTo.allCases) { Text($0.label).tag($0) }
                }

                Stepper("Card preview lines: \(settings.previewLines)",
                        value: $settings.previewLines, in: 0...5)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - API

    private var api: some View {
        Form {
            Section {
                Toggle("Enable the local API", isOn: $settings.apiEnabled)
                    .onChange(of: settings.apiEnabled) { env.applyServerSetting() }

                LabeledContent("Port") {
                    TextField("", value: $settings.apiPort, format: .number.grouping(.never))
                        .frame(width: 80)
                        .onSubmit { env.applyServerSetting() }
                }

                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(env.server.isRunning ? .green : .secondary)
                            .frame(width: 7, height: 7)
                        Text(env.server.isRunning ? "Listening on 127.0.0.1:\(settings.apiPort)" : "Stopped")
                    }
                }

                if let error = env.server.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Local HTTP API")
            } footer: {
                Text("Bound to 127.0.0.1, so nothing off this Mac can reach it. Every endpoint except /v1/health needs the token below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Token") {
                HStack {
                    Text(FlowServer.token)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(FlowServer.token, forType: .string)
                    }
                    Button("Regenerate") { FlowServer.regenerateToken() }
                }
            }

            Section("Try it") {
                Text("curl -H \"Authorization: Bearer $TOKEN\" \\\n  http://127.0.0.1:\(settings.apiPort)/v1/stats")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text("Endpoints: /v1/health, /v1/stats, /v1/activity, /v1/history, /v1/notes, /v1/dictate, /v1/insert")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Vocabulary

    private var vocabulary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Names and jargon the model mangles. These are given to the recogniser and to the cleanup pass.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Add a word", text: $newWord)
                    .onSubmit(addWord)
                Button("Add", action: addWord)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            trainingBox

            List {
                Section("Custom words") {
                    if env.lexicon.words.isEmpty {
                        Text("None yet.").foregroundStyle(.secondary)
                    }
                    ForEach(env.lexicon.words, id: \.self) { word in
                        HStack {
                            Text(word)
                            Spacer()
                            Button {
                                env.lexicon.removeWord(word)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Recent corrections") {
                    if env.lexicon.recent.isEmpty {
                        Text("Say \"replace X with Y\" and it lands here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(env.lexicon.recent) { correction in
                        HStack {
                            Text(correction.from).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                            Text(correction.to)
                            Spacer()
                            Button {
                                env.lexicon.removeCorrection(correction)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding()
    }

    /// The heavier custom-vocabulary fix, with its cost stated plainly.
    private var trainingBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Train a custom speech model on these words", isOn: $settings.useCustomLanguageModel)
                    .onChange(of: settings.useCustomLanguageModel) { env.controller.customModelSettingChanged() }

                Text("A custom model only attaches to the fallback transcriber, so turning this on trades \(Text("SpeechTranscriber").italic()) for a worse one. Try the word list alone first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(env.controller.hasTrainedModel ? "Retrain" : "Train now") {
                        env.controller.trainCustomModel()
                    }
                    .disabled(env.controller.isTraining || env.lexicon.words.isEmpty)

                    if env.controller.hasTrainedModel {
                        Button("Discard model") { env.controller.discardCustomModel() }
                    }
                    if env.controller.isTraining {
                        ProgressView().controlSize(.small)
                        Text("Training, this takes a few minutes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = env.controller.trainingError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }

                LabeledContent("In use", value: env.controller.transcriberLabel)
                    .font(.caption)
            }
            .padding(4)
        }
    }

    private func addWord() {
        env.lexicon.addWord(newWord)
        newWord = ""
    }

    // MARK: - Privacy

    private var privacy: some View {
        Form {
            Section {
                Picker("Keep history for", selection: $settings.retention) {
                    ForEach(Retention.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: settings.retention) { env.library.applyRetention() }
                Text("Pinned dictations are never purged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("History")
            }

            Section("On this Mac") {
                LabeledContent("Transcription", value: env.controller.transcriberLabel)
                LabeledContent("Cleanup", value: env.controller.cleanupAvailability.label)
                LabeledContent("Network", value: "Model download only")
                Text("Audio never leaves this Mac. Flow makes no network calls at dictation time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                LabeledContent("Microphone") {
                    permissionRow(granted: Permissions.hasMicrophone, open: Permissions.openMicrophoneSettings)
                }
                LabeledContent("Accessibility") {
                    permissionRow(granted: Permissions.hasAccessibility, open: Permissions.openAccessibilitySettings)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(granted: Bool, open: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Button(granted ? "Granted" : "Grant…", action: open)
                .buttonStyle(.link)
        }
    }
}
