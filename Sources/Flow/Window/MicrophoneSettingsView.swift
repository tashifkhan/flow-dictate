import AppKit
import SwiftUI

/// Which microphone Flow records from. Ported from Sotto's microphone page.
///
/// Automatic takes the first connected input in the active priority list, so a desk list
/// and a travel list can each keep their own order. Nothing here changes the macOS input.
struct MicrophoneSettingsView: View {
    @Bindable var env: AppEnvironment
    @State private var settings = Settings.shared
    @State private var editingProfile: ProfileEdit?
    @State private var confirmingRemoval = false

    var body: some View {
        let preferences = settings.microphones
        let profile = preferences.activeProfile
        let devices = env.devices.inputs
        let resolution = MicrophoneSelectionPolicy.resolve(
            preferences: preferences,
            available: devices.map(\.saved),
            systemDefaultUID: env.devices.systemDefaultUID
        )
        let preferredUIDs = Set(profile.priority.map(\.uid))
        let otherDevices = devices.filter { !preferredUIDs.contains($0.uid) }
        let resolvedDevice = devices.first { $0.uid == resolution.device?.uid }

        Form {
            Section("Input") {
                Picker("Choose input", selection: inputChoice) {
                    Text("Automatic · priority list").tag(MicrophoneChoice.automatic)
                    Text(systemDefaultLabel(devices)).tag(MicrophoneChoice.systemDefault)
                    Divider()
                    ForEach(devices) { device in
                        Text(device.label).tag(MicrophoneChoice.device(device.uid))
                    }
                    if case .fixed(let device) = preferences.selection,
                       !devices.contains(where: { $0.uid == device.uid }) {
                        Text("\(device.name) (disconnected)").tag(MicrophoneChoice.device(device.uid))
                    }
                }

                LabeledContent("Next dictation") {
                    Text(resolution.device?.name ?? "No microphone available")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text(selectionDetail(profile: profile, resolution: resolution))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let resolvedDevice, resolvedDevice.isTelephonyQuality {
                    Label(
                        "\(resolvedDevice.name) is in its 8 kHz call profile. Bluetooth speakers often deliver no audio at all here. Pick the built-in microphone if dictation comes back empty.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                profileToolbar(profile)

                if profile.priority.isEmpty {
                    Text("No priorities yet. Add a microphone from the connected inputs below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(profile.priority.enumerated()), id: \.element.uid) { position, device in
                    priorityRow(
                        device, position: position, count: profile.priority.count,
                        live: devices.first { $0.uid == device.uid },
                        isNext: preferences.selection == .automatic && resolution.device?.uid == device.uid
                    )
                }
            } header: {
                Text("Input priority")
            } footer: {
                Text("In Automatic, Flow records from the first connected microphone in this list. Disconnected microphones keep their place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !otherDevices.isEmpty {
                Section("Connected inputs") {
                    ForEach(otherDevices) { device in
                        HStack(spacing: 10) {
                            deviceLabel(device.saved, available: true)
                            Spacer(minLength: 8)
                            Button {
                                settings.microphones.addToPriority(device.saved)
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Add \(device.name) to \(profile.name)")
                            .accessibilityLabel("Add \(device.name) to the priority list")
                        }
                    }
                }
            }

            testSection(device: resolution.device)
        }
        .formStyle(.grouped)
        .sheet(item: $editingProfile) { edit in
            ProfileNameSheet(edit: edit)
        }
        .confirmationDialog("Delete the \(profile.name) list?", isPresented: $confirmingRemoval) {
            Button("Delete list", role: .destructive) {
                try? settings.microphones.removeProfile(settings.microphones.activeProfileID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only this saved order is removed. Your microphones and other lists stay as they are.")
        }
    }

    // MARK: - Pieces

    private func testSection(device: SavedMicrophone?) -> some View {
        let controller = env.controller
        let testing = controller.isTesting && controller.phase.isBusy
        return Section("Test") {
            HStack(spacing: 10) {
                Button(testing ? "Finish test" : "Test microphone", systemImage: testing ? "stop.fill" : "mic") {
                    env.toggleTest()
                }
                .disabled(device == nil || (controller.phase.isBusy && !testing))
                if testing {
                    Waveform(levels: controller.levels.bars, height: 18)
                }
                Spacer(minLength: 8)
                Text(device?.name ?? "No microphone available")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let heard = controller.lastTestTranscript {
                HStack(alignment: .top, spacing: 10) {
                    Text(heard.isEmpty ? "Nothing was heard." : heard)
                        .foregroundStyle(heard.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(heard, forType: .string)
                    }
                    .disabled(heard.isEmpty)
                }
            }

            Text("Records from the microphone above and shows what Flow heard, with list formatting and cleanup applied. Nothing is inserted or saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func profileToolbar(_ profile: MicrophoneProfile) -> some View {
        HStack(spacing: 8) {
            Picker("List", selection: Binding(
                get: { settings.microphones.activeProfileID },
                set: { settings.microphones.selectProfile($0) }
            )) {
                ForEach(settings.microphones.profiles) { item in
                    Text(item.name).tag(item.id)
                }
            }

            Button(settings.microphones.selection == .automatic ? "In use" : "Use list") {
                settings.microphones.selection = .automatic
            }
            .disabled(settings.microphones.selection == .automatic)
            .help("Record from the first connected microphone in this list")

            Button {
                editingProfile = ProfileEdit(profileID: nil, name: "")
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New priority list")
            .accessibilityLabel("New priority list")

            Menu {
                Button("Rename list\u{2026}") {
                    editingProfile = ProfileEdit(profileID: profile.id, name: profile.name)
                }
                Button("Delete list\u{2026}", role: .destructive) { confirmingRemoval = true }
                    .disabled(settings.microphones.profiles.count == 1)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Priority list options")
            .accessibilityLabel("Priority list options")
        }
    }

    private func priorityRow(_ device: SavedMicrophone, position: Int, count: Int,
                             live: AudioDevices.Device?, isNext: Bool) -> some View {
        HStack(spacing: 10) {
            Text("\(position + 1)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .leading)
            deviceLabel(live?.saved ?? device, available: live != nil)
            Spacer(minLength: 8)
            Text(isNext ? "Next dictation" : live == nil ? "Disconnected" : "Connected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Button {
                settings.microphones.movePriority(uid: device.uid, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(position == 0)
            .help("Move up")
            .accessibilityLabel("Move \(device.name) up")
            Button {
                settings.microphones.movePriority(uid: device.uid, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(position == count - 1)
            .help("Move down")
            .accessibilityLabel("Move \(device.name) down")
            Button {
                settings.microphones.removeFromPriority(uid: device.uid)
            } label: {
                Image(systemName: "minus.circle")
            }
            .help("Remove from this list")
            .accessibilityLabel("Remove \(device.name) from the priority list")
        }
        .buttonStyle(.borderless)
        .contextMenu {
            Button("Move to top") { settings.microphones.movePriorityToTop(uid: device.uid) }
                .disabled(position == 0)
            Button("Remove from priority list") { settings.microphones.removeFromPriority(uid: device.uid) }
        }
    }

    private func deviceLabel(_ device: SavedMicrophone, available: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: device.transport.symbol)
                .foregroundStyle(available ? Color.accentColor : Color.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(device.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(available ? Color.primary : Color.secondary)
        }
    }

    private func systemDefaultLabel(_ devices: [AudioDevices.Device]) -> String {
        devices.first { $0.uid == env.devices.systemDefaultUID }
            .map { "System default (\($0.name))" } ?? "System default"
    }

    /// Only the stable UID belongs in a Picker tag. Names change without the device changing.
    private var inputChoice: Binding<MicrophoneChoice> {
        Binding {
            switch settings.microphones.selection {
            case .automatic: .automatic
            case .systemDefault: .systemDefault
            case .fixed(let device): .device(device.uid)
            }
        } set: { choice in
            switch choice {
            case .automatic: settings.microphones.selection = .automatic
            case .systemDefault: settings.microphones.selection = .systemDefault
            case .device(let uid):
                if let device = env.devices.inputs.first(where: { $0.uid == uid }) {
                    settings.microphones.selection = .fixed(device.saved)
                }
            }
        }
    }

    private func selectionDetail(profile: MicrophoneProfile, resolution: MicrophoneResolution) -> String {
        if env.controller.phase.isBusy, let name = env.controller.recordingInputName {
            return "Current take: \(name). Changes apply to your next dictation."
        }
        switch resolution.reason {
        case .fallback(let requested):
            if let requested { return "\(requested.name) is disconnected. Flow uses it again when it reconnects." }
            return "The macOS input is unavailable, so Flow uses the first available microphone."
        case .unavailable: return "Connect an audio input to start dictating."
        case .priority: return "Flow uses the first connected microphone in \(profile.name)."
        case .fixed: return "Flow uses this microphone whenever it is connected."
        case .systemDefault:
            return settings.microphones.selection == .systemDefault
                ? "Follows the macOS input. Your system settings stay as they are."
                : "Using the macOS input until a microphone from the list is connected."
        }
    }
}

private enum MicrophoneChoice: Hashable {
    case automatic
    case systemDefault
    case device(String)
}

private struct ProfileEdit: Identifiable {
    let id = UUID()
    let profileID: String?
    let name: String
}

private struct ProfileNameSheet: View {
    let edit: ProfileEdit
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(edit.profileID == nil ? "New priority list" : "Rename priority list")
                .font(.headline)
            TextField("Name", text: $name, prompt: Text("Desk, travel\u{2026}"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
                .onChange(of: name) { _, _ in error = nil }
            Text(error ?? "Each list remembers its own microphone order.")
                .font(.caption)
                .foregroundStyle(error == nil ? Color.secondary : Color.orange)
                .frame(height: 30, alignment: .topLeading)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(edit.profileID == nil ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 350)
        .onAppear {
            name = edit.name
            focused = true
        }
    }

    private func save() {
        do {
            if let id = edit.profileID {
                try Settings.shared.microphones.renameProfile(id, to: name)
            } else {
                try Settings.shared.microphones.addProfile(named: name)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
