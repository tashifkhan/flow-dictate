import AppKit
import UniformTypeIdentifiers
import SwiftUI

/// One pane of Settings. Named so the main window's sidebar can address them
/// individually instead of duplicating the controls.
enum SettingsPane: String, CaseIterable, Hashable, Identifiable {
    case general, vocabulary, api, privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .vocabulary: "Vocabulary"
        case .api: "API"
        case .privacy: "Privacy"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .vocabulary: "character.book.closed"
        case .api: "terminal"
        case .privacy: "hand.raised"
        }
    }
}

/// Settings, mirrored from the Siri app's shape: behaviour, appearance, retention.
///
/// Renders the full tabbed window by default, or a single pane when `pane` is set, so
/// the Settings window and the main window's sidebar share one implementation.
struct SettingsView: View {
    @Bindable var env: AppEnvironment
    var pane: SettingsPane?
    @State private var settings = Settings.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var newWord = ""
    @State private var newFrom = ""
    @State private var newCorrection = ""
    /// Transient feedback for a bulk add or an import: "added 34 words".
    @State private var dictionaryNote: String?

    var body: some View {
        if let pane {
            // Embedded: fill whatever the host gives us, no fixed frame.
            content(for: pane)
                .navigationTitle(pane.title)
        } else {
            TabView {
                general.tabItem { Label("General", systemImage: "gearshape") }
                api.tabItem { Label("API", systemImage: "terminal") }
                vocabulary.tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
                privacy.tabItem { Label("Privacy", systemImage: "hand.raised") }
            }
            .frame(width: 480, height: 400)
        }
    }

    @ViewBuilder
    private func content(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: general
        case .vocabulary: vocabulary
        case .api: api
        case .privacy: privacy
        }
    }

    // MARK: - General

    /// Read once when the pane appears. Devices come and go, but re-enumerating on every
    /// redraw makes the picker flicker while it is open.
    @State private var inputDevices: [AudioDevices.Device] = []

    private var defaultInputLabel: String {
        if let d = AudioDevices.systemDefaultInput {
            return "System default (\(d.name))"
        }
        return "System default"
    }

    private var general: some View {
        Form {
            Section {
                LabeledContent(settings.activation == .hold ? "Hold to talk" : "Start and stop") {
                    HotkeyRecorder(hotkey: $settings.hotkey) { env.hotkeyChanged() }
                }

                Picker("Trigger", selection: $settings.activation) {
                    ForEach(HotkeyActivation.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: settings.activation) { _, _ in env.hotkeyChanged() }

                Text(settings.activation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Panel appears", selection: $settings.placement) {
                    ForEach(PanelPlacement.allCases) { Text($0.label).tag($0) }
                }

                Picker("Panel size", selection: $settings.panelSize) {
                    ForEach(PanelSize.allCases) { Text($0.label).tag($0) }
                }

                Picker("Microphone", selection: $settings.inputDeviceUID) {
                    Text(defaultInputLabel).tag("")
                    Divider()
                    ForEach(inputDevices) { Text($0.label).tag($0.uid) }
                }
                .onAppear { inputDevices = AudioDevices.inputs() }

                Picker("Language", selection: $settings.transcriptionLanguage) {
                    ForEach(TranscriptionLanguage.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: settings.transcriptionLanguage) { _, _ in
                    env.controller.transcriptionLanguageChanged()
                }

                Text(settings.transcriptionLanguage.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let chosen = AudioDevices.device(uid: settings.inputDeviceUID) ?? AudioDevices.systemDefaultInput,
                   chosen.isTelephonyQuality {
                    Label(
                        "\(chosen.name) is in its 8 kHz call profile. Bluetooth speakers often deliver no audio at all here — pick the built-in microphone if dictation comes back empty.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                LabeledContent("Stop a dictation") {
                    Text("Escape, or the \u{00D7} on the panel")
                        .foregroundStyle(.secondary)
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
                TextField("Add a word, or paste a list", text: $newWord)
                    .onSubmit(addWord)
                Button("Add", action: addWord)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Import\u{2026}", action: importWords)
                Button("Export\u{2026}", action: exportWords)
                    .disabled(env.lexicon.words.isEmpty)
            }

            if let note = dictionaryNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }

            // Your own replacement rules. Until now these only appeared by saying
            // "replace X with Y" mid-dictation, which is a poor way to enter a glossary.
            HStack {
                TextField("Heard as", text: $newFrom)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                TextField("Write instead", text: $newCorrection)
                    .onSubmit(addCorrection)
                Button("Add", action: addCorrection)
                    .disabled(
                        newFrom.trimmingCharacters(in: .whitespaces).isEmpty
                            || newCorrection.trimmingCharacters(in: .whitespaces).isEmpty
                    )
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

                Section("Replacements") {
                    if env.lexicon.corrections.isEmpty {
                        Text("Add one above, or say \"replace X with Y\" while dictating.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(env.lexicon.corrections.reversed()) { correction in
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
        // The field doubles as a paste target, so always go through the bulk path.
        let added = env.lexicon.addWords(newWord)
        note(added == 0 ? "Already in the dictionary." : "Added \(added) word\(added == 1 ? "" : "s").")
        newWord = ""
    }

    private func addCorrection() {
        env.lexicon.record(from: newFrom, to: newCorrection)
        newFrom = ""
        newCorrection = ""
    }

    /// One word per line. Also accepts the comma- and tab-separated shapes people
    /// actually have lying around, since the parser handles them anyway.
    private func importWords() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a word list. One per line, or comma separated."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let added = env.lexicon.addWords(try String(contentsOf: url, encoding: .utf8))
            note("Imported \(added) new word\(added == 1 ? "" : "s") from \(url.lastPathComponent).")
        } catch {
            note("Could not read that file: \(error.localizedDescription)")
        }
    }

    private func exportWords() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "flow-dictionary.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try env.lexicon.exportedWords.write(to: url, atomically: true, encoding: .utf8)
            note("Exported \(env.lexicon.words.count) words.")
        } catch {
            note("Could not write that file: \(error.localizedDescription)")
        }
    }

    /// Feedback that clears itself, so the pane does not accumulate stale notices.
    private func note(_ message: String) {
        dictionaryNote = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            dictionaryNote = nil
        }
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
