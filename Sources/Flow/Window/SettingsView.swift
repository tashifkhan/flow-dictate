import AppKit
import UniformTypeIdentifiers
import SwiftUI

/// One pane of Settings. Named so the main window's sidebar can address them
/// individually instead of duplicating the controls.
enum SettingsPane: String, CaseIterable, Hashable, Identifiable {
    case general, microphone, models, vocabulary, api, privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .microphone: "Microphone"
        case .models: "Models"
        case .vocabulary: "Vocabulary"
        case .api: "API"
        case .privacy: "Privacy"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .microphone: "mic"
        case .models: "cpu"
        case .vocabulary: "character.book.closed"
        case .api: "terminal"
        case .privacy: "hand.raised"
        }
    }
}

/// Settings, mirrored from System Settings: grouped rows, each with a small coloured icon.
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
    @State private var wordFilter = ""
    @State private var token = FlowServer.token
    @State private var confirmingRegenerate = false

    var body: some View {
        if let pane {
            // Embedded: fill whatever the host gives us, no fixed frame.
            content(for: pane)
                .navigationTitle(pane.title)
        } else {
            TabView {
                general.tabItem { Label("General", systemImage: "gearshape") }
                MicrophoneSettingsView(env: env).tabItem { Label("Microphone", systemImage: "mic") }
                CloudSettingsView().tabItem { Label("Models", systemImage: "cpu") }
                api.tabItem { Label("API", systemImage: "terminal") }
                vocabulary.tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
                privacy.tabItem { Label("Privacy", systemImage: "hand.raised") }
            }
            .frame(width: 560, height: 500)
        }
    }

    @ViewBuilder
    private func content(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: general
        case .microphone: MicrophoneSettingsView(env: env)
        case .models: CloudSettingsView()
        case .vocabulary: vocabulary
        case .api: api
        case .privacy: privacy
        }
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section {
                LabeledContent {
                    HotkeyRecorder(hotkey: $settings.hotkey) { env.hotkeyChanged() }
                } label: {
                    SettingLabel(settings.activation == .hold ? "Hold to talk" : "Start and stop", icon: "keyboard", color: .gray)
                }

                Picker(selection: $settings.activation) {
                    ForEach(HotkeyActivation.allCases) { Text($0.label).tag($0) }
                } label: {
                    SettingLabel("Trigger", icon: "hand.tap.fill", color: .blue)
                }
                .onChange(of: settings.activation) { _, _ in env.hotkeyChanged() }

                LabeledContent {
                    Text("Escape, or the \u{00D7} on the panel")
                        .foregroundStyle(.secondary)
                } label: {
                    SettingLabel("Stop a dictation", icon: "escape", color: .gray)
                }

                Picker(selection: $settings.recordingLimit) {
                    ForEach(RecordingLimit.allCases) { Text($0.label).tag($0) }
                } label: {
                    SettingLabel("Stop recording after", icon: "timer", color: .orange)
                }
                .help("A safety net for a dictation you forgot was running")
            } header: {
                Text("Shortcut")
            } footer: {
                Text(settings.activation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(selection: $settings.transcriptionLanguage) {
                    ForEach(TranscriptionLanguage.allCases) { Text($0.label).tag($0) }
                } label: {
                    SettingLabel("Language", icon: "globe", color: .blue)
                }
                .onChange(of: settings.transcriptionLanguage) { _, _ in
                    env.controller.transcriptionLanguageChanged()
                }
            } header: {
                Text("Language")
            } footer: {
                Text(settings.transcriptionLanguage.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Panel") {
                Picker(selection: $settings.placement) {
                    ForEach(PanelPlacement.allCases) { Text($0.label).tag($0) }
                } label: {
                    SettingLabel("Panel appears", icon: "rectangle.bottomhalf.inset.filled", color: .purple)
                }
                Picker(selection: $settings.panelSize) {
                    ForEach(PanelSize.allCases) { Text($0.label).tag($0) }
                } label: {
                    SettingLabel("Panel size", icon: "arrow.up.left.and.arrow.down.right", color: .purple)
                }
            }

            Section {
                Toggle(isOn: $settings.cleanupEnabled) {
                    HStack(spacing: 8) {
                        SettingLabel("Refine dictated text", icon: "wand.and.stars", color: .indigo)
                        if settings.cleanupEnabled && !env.controller.cleanupAvailability.isAvailable {
                            Chip(env.controller.cleanupAvailability.label, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                        }
                    }
                }
                .help("Remove filler and false starts, apply spoken corrections, and format lists")
                Toggle(isOn: $settings.preferAXInsert) {
                    SettingLabel("Insert directly when the app supports it", icon: "text.cursor", color: .teal)
                }
                .help("Otherwise Flow pastes, which is what makes Electron apps behave.")
            } header: {
                Text("Text")
            } footer: {
                Text("When direct insertion is off or unsupported, Flow pastes. That is what makes Electron apps behave.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Feedback") {
                Toggle(isOn: $settings.playSounds) {
                    SettingLabel("Play a sound when text lands", icon: "speaker.wave.2.fill", color: .pink)
                }
                Toggle(isOn: $settings.notifyOnInsert) {
                    SettingLabel("Notify when text is inserted", icon: "bell.badge.fill", color: .red)
                }
                .onChange(of: settings.notifyOnInsert) { _, on in
                    guard on else { return }
                    // Ask only when it is switched on, so the prompt has a reason.
                    Task {
                        if await !Toast.requestAuthorization() { settings.notifyOnInsert = false }
                    }
                }
            }

            Section("App") {
                Toggle(isOn: $launchAtLogin) {
                    SettingLabel("Launch at login", icon: "power", color: .green)
                }
                .onChange(of: launchAtLogin) { _, enabled in
                    loginError = LoginItem.set(enabled)
                    if loginError != nil { launchAtLogin = LoginItem.isEnabled }
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }

                Toggle(isOn: $settings.showDockIcon) {
                    SettingLabel("Show a dock icon", icon: "dock.rectangle", color: .gray)
                }

                Picker(selection: $settings.openTo) {
                    ForEach(OpenTo.allCases) { Text($0.label).tag($0) }
                } label: {
                    SettingLabel("Open window to", icon: "macwindow", color: .blue)
                }

                LabeledContent {
                    Stepper(value: $settings.previewLines, in: 0...5) {
                        Text(settings.previewLines == 0 ? "Automatic" : Fmt.count(settings.previewLines, "line"))
                            .monospacedDigit()
                    }
                } label: {
                    SettingLabel("Card preview lines", icon: "text.alignleft", color: .gray)
                }
                .help("How much text grid cards show. Automatic shows four lines.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - API

    private struct Endpoint {
        var method: String
        var path: String
        var detail: String
        var key: String { method + " " + path }
    }

    private static let endpoints: [Endpoint] = [
        Endpoint(method: "GET", path: "/v1/health", detail: "Version and setup state. No token."),
        Endpoint(method: "GET", path: "/v1/stats?range=", detail: "today, week, month, year, allTime"),
        Endpoint(method: "GET", path: "/v1/activity", detail: "Words per day"),
        Endpoint(method: "GET", path: "/v1/history?q=&limit=", detail: "Dictations, raw and cleaned"),
        Endpoint(method: "GET", path: "/v1/notes", detail: "Scratchpad notes"),
        Endpoint(method: "POST", path: "/v1/notes", detail: "{\"text\":\"…\"} adds a note"),
        Endpoint(method: "POST", path: "/v1/dictate", detail: "start, stop, toggle, or cancel"),
        Endpoint(method: "POST", path: "/v1/insert", detail: "{\"text\":\"…\"} types at the cursor"),
    ]

    private var api: some View {
        let example = "curl -H \"Authorization: Bearer $TOKEN\" \\\n  http://127.0.0.1:\(settings.apiPort)/v1/stats"
        return Form {
            Section {
                Toggle(isOn: $settings.apiEnabled) {
                    SettingLabel("Enable the local API", icon: "terminal.fill", color: .gray)
                }
                .onChange(of: settings.apiEnabled) { env.applyServerSetting() }

                LabeledContent {
                    TextField("Port", value: $settings.apiPort, format: .number.grouping(.never))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onSubmit { env.applyServerSetting() }
                } label: {
                    SettingLabel("Port", icon: "number", color: .blue)
                }
                .help("Press Return to apply a new port")

                LabeledContent {
                    Chip(env.server.isRunning ? "Listening on 127.0.0.1:\(settings.apiPort)" : "Stopped",
                         systemImage: env.server.isRunning ? "checkmark.circle.fill" : "pause.circle",
                         tint: env.server.isRunning ? .green : nil)
                } label: {
                    SettingLabel("Status", icon: "dot.radiowaves.left.and.right", color: .green)
                }

                if let error = env.server.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Local HTTP API")
            } footer: {
                Text("Bound to 127.0.0.1, so nothing off this Mac can reach it. Every endpoint except /v1/health needs the token below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Token") {
                HStack(spacing: 8) {
                    Text(token)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                    Spacer(minLength: 8)
                    CopyButton(text: token, label: "Copy token")
                    Button("Regenerate\u{2026}") { confirmingRegenerate = true }
                        .help("Make a new token. The old one stops working.")
                }
            }
            .confirmationDialog("Regenerate the API token?", isPresented: $confirmingRegenerate) {
                Button("Regenerate", role: .destructive) {
                    FlowServer.regenerateToken()
                    token = FlowServer.token
                }
            } message: {
                Text("Scripts and shortcuts using the current token stop working until you give them the new one.")
            }

            Section {
                HStack(alignment: .top) {
                    Text(example)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CopyButton(text: example.replacingOccurrences(of: "$TOKEN", with: token), label: "Copy with token", iconOnly: true)
                        .buttonStyle(.borderless)
                        .help("Copy this command with your token filled in")
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            } header: {
                Text("Try it")
            }

            Section("Endpoints") {
                ForEach(Self.endpoints, id: \.key) { endpoint in
                    HStack(spacing: 10) {
                        Text(endpoint.method)
                            .font(.caption2.weight(.bold).monospaced())
                            .foregroundStyle(endpoint.method == "GET" ? Color.blue : Color.green)
                            .frame(width: 38, alignment: .leading)
                        Text(endpoint.path)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Text(endpoint.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Vocabulary

    private var filteredWords: [String] {
        let query = wordFilter.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty ? env.lexicon.words : env.lexicon.words.filter { $0.lowercased().contains(query) }
    }

    private var vocabulary: some View {
        Form {
            Section {
                HStack {
                    TextField("Add a word, or paste a list", text: $newWord, prompt: Text("Add a word, or paste a list"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addWord)
                    Button("Add", action: addWord)
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let note = dictionaryNote {
                    Label(note, systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if env.lexicon.words.isEmpty {
                    Text("None yet. Add names, product terms, and jargon the recogniser gets wrong.")
                        .foregroundStyle(.secondary)
                } else {
                    if env.lexicon.words.count > 24 {
                        TextField("Filter words", text: $wordFilter, prompt: Text("Filter words"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    FlowLayout(spacing: 6) {
                        ForEach(filteredWords, id: \.self) { word in
                            WordChip(word: word) { env.lexicon.removeWord(word) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack {
                    Text("Custom words · \(env.lexicon.words.count)")
                    Spacer()
                    Button("Import\u{2026}", action: importWords)
                        .help("Add words from a text or CSV file")
                    Button("Export\u{2026}", action: exportWords)
                        .disabled(env.lexicon.words.isEmpty)
                        .help("Save the list as a text file, one word per line")
                }
                .buttonStyle(.borderless)
                .font(.callout)
            } footer: {
                Text("Given to the recogniser and to the cleanup pass.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Your own replacement rules. Until now these only appeared by saying
            // "replace X with Y" mid-dictation, which is a poor way to enter a glossary.
            Section {
                HStack {
                    TextField("Heard as", text: $newFrom, prompt: Text("Heard as"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    TextField("Write instead", text: $newCorrection, prompt: Text("Write instead"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addCorrection)
                    Button("Add", action: addCorrection)
                        .disabled(
                            newFrom.trimmingCharacters(in: .whitespaces).isEmpty
                                || newCorrection.trimmingCharacters(in: .whitespaces).isEmpty
                        )
                }
                ForEach(env.lexicon.corrections.reversed()) { correction in
                    HStack(spacing: 10) {
                        Text(correction.from).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        Text(correction.to)
                        Spacer()
                        Button {
                            env.lexicon.removeCorrection(correction)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this replacement")
                        .accessibilityLabel("Remove replacement for \(correction.from)")
                    }
                }
            } header: {
                Text("Replacements · \(env.lexicon.corrections.count)")
            } footer: {
                Text("You can also say \"replace X with Y\" while dictating.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            trainingSection
        }
        .formStyle(.grouped)
    }

    /// The heavier custom-vocabulary fix, with its cost stated plainly.
    private var trainingSection: some View {
        Section {
            Toggle(isOn: $settings.useCustomLanguageModel) {
                SettingLabel("Train a custom speech model on these words", icon: "brain", color: .purple)
            }
            .onChange(of: settings.useCustomLanguageModel) { env.controller.customModelSettingChanged() }

            HStack(spacing: 8) {
                Button(env.controller.hasTrainedModel ? "Retrain" : "Train now") {
                    env.controller.trainCustomModel()
                }
                .disabled(env.controller.isTraining || env.lexicon.words.isEmpty)
                .help(env.lexicon.words.isEmpty ? "Add some words first" : "Build a model from your words and past corrections")

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
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            LabeledContent("In use", value: env.controller.transcriberLabel)
        } header: {
            Text("Custom speech model")
        } footer: {
            Text("A custom model only attaches to the fallback transcriber, so turning this on trades \(Text("SpeechTranscriber").italic()) for a worse one. Try the word list alone first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                // No vertical fixedSize: the window takes its minimum height from
                // this pane, and a fixed-height paragraph measured at zero width is
                // one character per line, taller than the screen.
                .frame(maxWidth: .infinity, alignment: .leading)
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
                Picker(selection: $settings.retention) {
                    ForEach(Retention.allCases) { Text($0.label).tag($0) }
                } label: {
                    SettingLabel("Keep history for", icon: "clock.arrow.circlepath", color: .blue)
                }
                .onChange(of: settings.retention) { env.library.applyRetention() }
            } header: {
                Text("History")
            } footer: {
                Text("Pinned dictations are never purged. Statistics keep their daily totals after the text is gone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Text(env.controller.transcriberLabel).foregroundStyle(.secondary)
                } label: {
                    SettingLabel("Transcription", icon: "waveform", color: .blue)
                }
                LabeledContent {
                    Text(env.controller.cleanupAvailability.label).foregroundStyle(.secondary)
                } label: {
                    SettingLabel("Cleanup", icon: "wand.and.stars", color: .indigo)
                }
                LabeledContent {
                    Chip(settings.cloud.usesCloud ? "Cloud models selected" : "Model download only",
                         systemImage: settings.cloud.usesCloud ? "cloud" : "lock.fill",
                         tint: settings.cloud.usesCloud ? .orange : .green)
                } label: {
                    SettingLabel("Network", icon: "network", color: .gray)
                }
            } header: {
                Text("On this Mac")
            } footer: {
                Text((settings.cloud.sendsAudio
                      ? "Recorded audio goes to the cloud models on the Models page."
                      : "Audio stays on this Mac during dictation.")
                     + (settings.cloud.refinesInCloud && !settings.cloud.sendsAudio
                        ? " Transcript text goes to your refinement models." : "")
                     + (settings.cloud.usesCloud ? " When they fail or you are offline, Flow uses the on-device models." : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                LabeledContent {
                    permissionRow(granted: Permissions.hasMicrophone, open: Permissions.openMicrophoneSettings)
                } label: {
                    SettingLabel("Microphone", icon: "mic.fill", color: .red)
                }
                .help("So there is something to transcribe")
                LabeledContent {
                    permissionRow(granted: Permissions.hasAccessibility, open: Permissions.openAccessibilitySettings)
                } label: {
                    SettingLabel("Accessibility", icon: "accessibility", color: .blue)
                }
                .help("So Flow can watch your shortcut and type at the cursor")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func permissionRow(granted: Bool, open: @escaping () -> Void) -> some View {
        if granted {
            Chip("Granted", systemImage: "checkmark.circle.fill", tint: .green)
        } else {
            HStack(spacing: 8) {
                Chip("Missing", systemImage: "xmark.circle.fill", tint: .orange)
                Button("Grant\u{2026}", action: open)
                    .controlSize(.small)
                    .help("Open the right page of System Settings")
            }
        }
    }
}

/// A removable word in the vocabulary list.
private struct WordChip: View {
    var word: String
    var remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(word).font(.callout)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(hovering ? .secondary : .tertiary)
            .help("Remove \(word)")
            .accessibilityLabel("Remove \(word)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quaternary.opacity(0.6)), in: Capsule())
        .onHover { hovering = $0 }
    }
}
