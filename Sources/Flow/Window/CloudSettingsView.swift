import SwiftUI

/// The Models pane. It reads in the order a dictation runs: where it runs, the
/// cloud ladder from config 1 down to this Mac, then the providers behind the models.
struct CloudSettingsView: View {
    @State private var settings = Settings.shared
    @State private var editingProvider: ProviderSheet?
    @State private var editingConfig: ConfigSheet?

    var body: some View {
        Form {
            Section {
                Picker("Process speech on", selection: $settings.cloud.useCloud) {
                    Text("This Mac").tag(false)
                    Text("Cloud, then this Mac").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("Refine dictated text", isOn: $settings.cleanupEnabled)
            } header: {
                Text("How Flow turns speech into text")
            } footer: {
                Text(settings.cloud.useCloud
                     ? "Flow tries the configs below in order. When all of them fail, or you are offline, this Mac finishes the job."
                     : "Apple's transcriber and Apple Intelligence. Nothing leaves this Mac.")
                    .font(.caption)
            }

            if settings.cloud.useCloud {
                LadderSection(settings: settings, editConfig: { editingConfig = $0 })
                Section {
                    Toggle("Run all configs at the same time", isOn: $settings.cloud.parallelResults)
                } footer: {
                    Text(settings.cloud.parallelResults
                         ? "Flow pastes the highest config that succeeds, so config 1 whenever it works. Every other result waits in the menu bar under Last dictation, to copy or swap in. Costs one request per config."
                         : "Flow runs one config at a time and moves down only when one fails.")
                        .font(.caption)
                }
            }

            ProvidersSection(settings: settings, editProvider: { editingProvider = $0 })
        }
        .formStyle(.grouped)
        .sheet(item: $editingProvider) { sheet in
            ProviderEditor(providerID: sheet.id)
                .frame(minWidth: 560, minHeight: 600)
        }
        .sheet(item: $editingConfig) { sheet in
            ConfigEditor(sheet: sheet)
                .frame(minWidth: 560, minHeight: 500)
        }
    }
}

// MARK: - Ladder

private struct LadderSection: View {
    @Bindable var settings: Settings
    var editConfig: (ConfigSheet) -> Void

    private var configs: [CloudConfig] { settings.cloud.configs }

    var body: some View {
        Section {
            if configs.isEmpty {
                Text("No cloud configs yet. Until you add one, dictation stays on this Mac.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(configs.enumerated()), id: \.element.id) { index, config in
                row(index: index, config: config)
            }
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last: This Mac")
                    Text(settings.cleanupEnabled
                         ? "Apple's transcriber, then Apple Intelligence. Always on, can't be removed."
                         : "Apple's transcriber. Always on, can't be removed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.tertiary)
            }
            HStack(spacing: 16) {
                Button {
                    editConfig(ConfigSheet(configID: nil, kind: .onePass))
                } label: {
                    Label("Add a 1-pass config", systemImage: "plus")
                }
                Button {
                    editConfig(ConfigSheet(configID: nil, kind: .twoPass))
                } label: {
                    Label("Add a 2-pass config", systemImage: "plus")
                }
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Cloud ladder, tried top to bottom")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("1 pass sends the audio and cleanup prompt to one model, like Rambler. 2 pass transcribes first, then refines. Either step of a 2-pass config can run on this Mac.")
                if !NetworkStatus.shared.isOnline {
                    Label("This Mac is offline. Dictation uses the last rung until it reconnects.", systemImage: "wifi.slash")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
        }
    }

    private func row(index: Int, config: CloudConfig) -> some View {
        let problem: String? = {
            if case .failure(let problem) = settings.cloud.rung(config) { return problem.message }
            if config.kind == .onePass && !settings.cleanupEnabled { return "Needs refinement on" }
            return nil
        }()
        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(index == 0 ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 22)
                .background(index == 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(config.kind.title)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: .rect(cornerRadius: 4))
                    Text(summary(config)).lineLimit(1)
                }
                Text(detail(config)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .help("Try earlier")
            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == configs.count - 1)
                .help("Try later")
            Button { editConfig(ConfigSheet(configID: config.id, kind: config.kind)) } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help("Edit config")
            Button { settings.cloud.configs.removeAll { $0.id == config.id } } label: {
                Image(systemName: "xmark")
            }
            .help("Remove from the ladder. Its models stay on their providers.")
        }
        .buttonStyle(.borderless)
    }

    private func name(_ id: UUID?) -> String {
        guard let id else { return "This Mac" }
        return settings.cloud.model(id)?.displayName ?? "Deleted model"
    }

    private func providerName(_ id: UUID?) -> String {
        guard let id else { return "on device" }
        return settings.cloud.model(id).flatMap { settings.cloud.provider($0.providerID)?.name } ?? "missing"
    }

    private func summary(_ config: CloudConfig) -> String {
        switch config.kind {
        case .onePass: name(config.model)
        case .twoPass: "\(name(config.transcriber)) → \(name(config.refiner))"
        }
    }

    private func detail(_ config: CloudConfig) -> String {
        switch config.kind {
        case .onePass: "\(providerName(config.model)) · audio in, finished text out"
        case .twoPass: "Transcribe: \(providerName(config.transcriber)) · Refine: \(providerName(config.refiner))"
        }
    }

    private func move(_ index: Int, by offset: Int) {
        settings.cloud.configs.swapAt(index, index + offset)
    }
}

// MARK: - Config editor

private struct ConfigSheet: Identifiable {
    let configID: UUID?
    let kind: CloudConfig.Kind
    var id: String { configID?.uuidString ?? "new-\(kind.rawValue)" }
}

private struct ConfigEditor: View {
    let sheet: ConfigSheet
    @State private var settings = Settings.shared
    @State private var kind: CloudConfig.Kind
    @State private var model: UUID?
    @State private var transcriber: UUID?
    @State private var refiner: UUID?
    @State private var addingModel: ModelSheet?
    @Environment(\.dismiss) private var dismiss

    init(sheet: ConfigSheet) {
        self.sheet = sheet
        let config = sheet.configID.flatMap { id in Settings.shared.cloud.configs.first { $0.id == id } }
        _kind = State(initialValue: config?.kind ?? sheet.kind)
        _model = State(initialValue: config?.model)
        _transcriber = State(initialValue: config?.transcriber)
        _refiner = State(initialValue: config?.refiner)
    }

    private var draft: CloudConfig {
        CloudConfig(kind: kind, model: model, transcriber: transcriber, refiner: refiner)
    }

    private var problem: String? {
        if case .failure(let problem) = settings.cloud.rung(draft) { return problem.message }
        return nil
    }

    private var canSave: Bool {
        kind == .onePass ? model != nil : transcriber != nil || refiner != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(CloudConfig.Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(kind == .onePass
                         ? "One audio model hears the recording and returns finished text. Fastest, and closest to Rambler."
                         : "One model transcribes, another refines. Set either step to This Mac to keep it local.")
                        .font(.caption)
                }

                Section {
                    switch kind {
                    case .onePass:
                        modelPicker("Model", selection: $model, audio: true, allowLocal: false)
                    case .twoPass:
                        modelPicker("Transcribe with", selection: $transcriber, audio: true, allowLocal: true)
                        modelPicker("Refine with", selection: $refiner, audio: false, allowLocal: true)
                    }
                    Button {
                        addingModel = ModelSheet(modelID: nil, providerID: nil)
                    } label: {
                        Label("New model…", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    if let problem, canSave {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } footer: {
                    Text(kind == .onePass
                         ? "Only providers that take audio are listed. Anthropic's API has no audio input."
                         : "Transcription needs a provider that takes audio. Refinement works with any chat model.")
                        .font(.caption)
                }

                if let configID = sheet.configID {
                    Section {
                        Button("Remove config", role: .destructive) {
                            settings.cloud.configs.removeAll { $0.id == configID }
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(sheet.configID == nil ? "Add a config" : "Edit config")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sheet.configID == nil ? "Add" : "Save") { save() }
                        .disabled(!canSave)
                }
            }
            .sheet(item: $addingModel) { sheet in
                ModelEditor(sheet: sheet) { id in
                    // Put the new model where it fits.
                    let audio = settings.cloud.model(id)
                        .flatMap { settings.cloud.provider($0.providerID) }?.api.acceptsAudio ?? false
                    switch kind {
                    case .onePass: if audio { model = id }
                    case .twoPass:
                        if audio && transcriber == nil { transcriber = id } else { refiner = id }
                    }
                }
                .frame(minWidth: 540, minHeight: 460)
            }
        }
    }

    /// Models grouped under their providers, with This Mac first where allowed.
    private func modelPicker(_ title: String, selection: Binding<UUID?>, audio: Bool, allowLocal: Bool) -> some View {
        Picker(title, selection: selection) {
            if allowLocal {
                Text("This Mac").tag(UUID?.none)
            } else if selection.wrappedValue == nil {
                Text("Choose a model").tag(UUID?.none)
            }
            ForEach(settings.cloud.providers.filter { !audio || $0.api.acceptsAudio }) { provider in
                let models = settings.cloud.models.filter { $0.providerID == provider.id }
                if !models.isEmpty {
                    Section(provider.name) {
                        ForEach(models) { model in
                            Text(model.displayName).tag(Optional(model.id))
                        }
                    }
                }
            }
        }
    }

    private func save() {
        var config = draft
        if kind == .onePass {
            config.transcriber = nil
            config.refiner = nil
        } else {
            config.model = nil
        }
        if let id = sheet.configID, let index = settings.cloud.configs.firstIndex(where: { $0.id == id }) {
            config.id = id
            settings.cloud.configs[index] = config
        } else {
            settings.cloud.configs.append(config)
        }
        dismiss()
    }
}

// MARK: - Providers

private struct ProvidersSection: View {
    @Bindable var settings: Settings
    var editProvider: (ProviderSheet) -> Void

    var body: some View {
        Section {
            ForEach(settings.cloud.providers) { provider in
                Button { editProvider(ProviderSheet(id: provider.id)) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "server.rack").foregroundStyle(.secondary).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name.isEmpty ? "Unnamed provider" : provider.name)
                            Text("\(provider.api.title) · \(URL(string: provider.baseURL)?.host ?? provider.baseURL)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        let count = settings.cloud.models.filter { $0.providerID == provider.id }.count
                        Text(count == 1 ? "1 model" : "\(count) models")
                            .font(.caption).foregroundStyle(.secondary)
                        StatusBadge(problem: provider.problem)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Button {
                let provider = CloudProvider(api: .openAI, name: "New provider")
                settings.cloud.providers.append(provider)
                editProvider(ProviderSheet(id: provider.id))
            } label: {
                Label("Add a provider", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Providers and models")
        } footer: {
            Text("A provider is an endpoint and a key, and holds the models you use in configs. Name it anything, and point the base URL at any server that speaks the OpenAI, Gemini, or Anthropic API. Keys are kept in the macOS Keychain.")
                .font(.caption)
        }
    }
}

private struct StatusBadge: View {
    var problem: String?

    var body: some View {
        Text(problem ?? "Ready")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(problem == nil ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
            .background(problem == nil ? AnyShapeStyle(.green.opacity(0.15)) : AnyShapeStyle(.orange.opacity(0.15)),
                        in: Capsule())
    }
}

private struct ProviderSheet: Identifiable {
    let id: UUID
}

private struct ModelSheet: Identifiable {
    let modelID: UUID?
    /// For a new model, the provider it goes on.
    let providerID: UUID?
    var id: String { modelID?.uuidString ?? "new-\(providerID?.uuidString ?? "")" }
}

// MARK: - Provider editor

private struct ProviderEditor: View {
    let providerID: UUID
    @State private var settings = Settings.shared
    @State private var editingModel: ModelSheet?
    @State private var test: TestState = .idle
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    private enum TestState: Equatable {
        case idle, running, passed(Int), failed(String)
    }

    private var index: Int? { settings.cloud.providers.firstIndex { $0.id == providerID } }

    var body: some View {
        NavigationStack {
            Form {
                if let index {
                    connection(index)
                    models(settings.cloud.providers[index])
                    Section {
                        Button("Delete provider and its models", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(index.map { settings.cloud.providers[$0].name } ?? "Provider")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Delete this provider and its models?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) {
                    settings.cloud.removeProvider(providerID)
                    dismiss()
                }
            }
            .sheet(item: $editingModel) { sheet in
                ModelEditor(sheet: sheet).frame(minWidth: 540, minHeight: 460)
            }
        }
    }

    @ViewBuilder
    private func connection(_ index: Int) -> some View {
        let provider = $settings.cloud.providers[index]
        Section {
            TextField("Name", text: provider.name, prompt: Text("OpenRouter, Groq, Work proxy…"))
            Picker("API format", selection: provider.api) {
                ForEach(CloudAPI.allCases) { api in Text(api.title).tag(api) }
            }
            .onChange(of: provider.wrappedValue.api) { old, new in
                // A URL still at the old format's default follows the format.
                if provider.wrappedValue.baseURL == old.defaultBaseURL { provider.wrappedValue.baseURL = new.defaultBaseURL }
            }
            // A plain row, like Name. Wrapping it with a Reset button that came and went
            // as you typed rebuilt the field and dropped focus after one keystroke.
            TextField("Base URL", text: provider.baseURL, prompt: Text(provider.wrappedValue.api.defaultBaseURL))
                .autocorrectionDisabled()
            SecureField("API key", text: provider.apiKey,
                        prompt: Text(provider.wrappedValue.isLocalhost ? "Optional on localhost" : "Required"))
                .onChange(of: provider.wrappedValue.apiKey) { old, new in
                    if old.isEmpty && !new.isEmpty { provider.wrappedValue.enabled = true }
                    test = .idle
                }
            Toggle("Use this provider", isOn: provider.enabled)
            HStack {
                Button("Test connection") { runTest(provider.wrappedValue) }
                    .disabled(test == .running)
                Button("Reset URL") { provider.wrappedValue.baseURL = provider.wrappedValue.api.defaultBaseURL }
                    .disabled(provider.wrappedValue.baseURL == provider.wrappedValue.api.defaultBaseURL)
                    .help("Go back to \(provider.wrappedValue.api.defaultBaseURL)")
                switch test {
                case .idle: EmptyView()
                case .running: ProgressView().controlSize(.small)
                case .passed(let count):
                    Label("Connected. \(count) models available.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red).font(.caption)
                }
            }
        } header: {
            Text("Connection")
        } footer: {
            Text(provider.wrappedValue.api.acceptsAudio
                 ? "The format sets the request shape. Any compatible server works."
                 : "Anthropic-format providers can only refine. Their API has no audio input.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private func models(_ provider: CloudProvider) -> some View {
        Section {
            let models = settings.cloud.models.filter { $0.providerID == provider.id }
            if models.isEmpty {
                Text("No models yet.").foregroundStyle(.secondary)
            }
            ForEach(models) { model in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName)
                        Text(usage(model)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit") { editingModel = ModelSheet(modelID: model.id, providerID: nil) }
                        .buttonStyle(.borderless)
                }
            }
            Button {
                editingModel = ModelSheet(modelID: nil, providerID: provider.id)
            } label: {
                Label("Add a model", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Models on this provider")
        }
    }

    private func usage(_ model: CloudModel) -> String {
        let numbers = settings.cloud.configs.enumerated().filter { _, config in
            [config.model, config.transcriber, config.refiner].contains(model.id)
        }.map { "\($0.offset + 1)" }
        let where_ = numbers.isEmpty ? "Not in the ladder" : "In config " + numbers.joined(separator: ", ")
        return model.modelID == model.displayName ? where_ : "\(model.modelID) · \(where_)"
    }

    private func runTest(_ provider: CloudProvider) {
        test = .running
        Task {
            do {
                let models = try await CloudService().listModels(provider)
                test = .passed(models.count)
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Model editor

private struct ModelEditor: View {
    let sheet: ModelSheet
    var onSave: ((UUID) -> Void)?
    @State private var settings = Settings.shared
    @State private var providerID: UUID
    @State private var name: String
    @State private var apiModelID: String
    @State private var reasoning: CloudReasoning
    @State private var available: [String] = []
    @State private var loadError: String?
    @State private var loading = false
    @Environment(\.dismiss) private var dismiss

    init(sheet: ModelSheet, onSave: ((UUID) -> Void)? = nil) {
        self.sheet = sheet
        self.onSave = onSave
        let cloud = Settings.shared.cloud
        let model = cloud.model(sheet.modelID)
        _providerID = State(initialValue: model?.providerID ?? sheet.providerID
            ?? cloud.providers.first { $0.problem == nil }?.id ?? cloud.providers.first?.id ?? UUID())
        _name = State(initialValue: model?.name ?? "")
        _apiModelID = State(initialValue: model?.modelID ?? "")
        _reasoning = State(initialValue: model?.reasoning ?? .automatic)
    }

    private var provider: CloudProvider? { settings.cloud.provider(providerID) }
    private var trimmedID: String { apiModelID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { provider != nil && !trimmedID.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    Picker("Provider", selection: $providerID) {
                        ForEach(settings.cloud.providers) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                    .onChange(of: providerID) { _, _ in
                        available = []
                        loadModels()
                    }
                    if let problem = provider?.problem {
                        Label("\(problem). Set this provider up under Providers before its models can run.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                Section("Model") {
                    LabeledContent("Model ID") {
                        HStack {
                            TextField("Model ID", text: $apiModelID, prompt: Text("Exact ID, for example gpt-4o-transcribe"))
                                .labelsHidden()
                            Menu {
                                if available.isEmpty {
                                    Text(loading ? "Loading…" : "No list loaded")
                                }
                                ForEach(filteredModels, id: \.self) { id in
                                    Button(id) { apiModelID = id }
                                }
                            } label: {
                                Image(systemName: "list.bullet")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Pick from the provider's model list")
                            Button { loadModels() } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless)
                                .disabled(loading || provider == nil)
                                .help("Reload the model list")
                        }
                    }
                    if let loadError {
                        Text("Couldn't load the model list: \(loadError) You can still type an ID.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !available.isEmpty {
                        Text("\(available.count) models on this provider. Type to filter the list.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Display name", text: $name, prompt: Text("Optional"))
                    Picker("Reasoning", selection: $reasoning) {
                        ForEach(CloudReasoning.allCases) { level in Text(level.title).tag(level) }
                    }
                    Text("Lower is faster, which matters for dictation. If the endpoint rejects the setting, Flow retries without it.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let modelID = sheet.modelID {
                    Section {
                        Button("Delete model", role: .destructive) {
                            settings.cloud.removeModel(modelID)
                            dismiss()
                        }
                    } footer: {
                        Text("Configs that only used this model are removed from the ladder.").font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(sheet.modelID == nil ? "Add a model" : "Edit model")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sheet.modelID == nil ? "Add" : "Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: loadModels)
        }
    }

    private var filteredModels: [String] {
        let query = trimmedID.lowercased()
        let matches = query.isEmpty ? available : available.filter { $0.lowercased().contains(query) }
        return Array((matches.isEmpty ? available : matches).prefix(80))
    }

    private func loadModels() {
        guard let provider, provider.problem == nil || provider.problem == "Provider off" else { return }
        loading = true
        loadError = nil
        Task {
            do {
                available = try await CloudService().listModels(provider)
            } catch {
                loadError = error.localizedDescription
            }
            loading = false
        }
    }

    private func save() {
        guard canSave else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id: UUID
        if let modelID = sheet.modelID, let index = settings.cloud.models.firstIndex(where: { $0.id == modelID }) {
            settings.cloud.models[index].providerID = providerID
            settings.cloud.models[index].name = cleanName
            settings.cloud.models[index].modelID = trimmedID
            settings.cloud.models[index].reasoning = reasoning
            id = modelID
        } else {
            let model = CloudModel(providerID: providerID, name: cleanName, modelID: trimmedID, reasoning: reasoning)
            settings.cloud.models.append(model)
            id = model.id
        }
        onSave?(id)
        dismiss()
    }
}
