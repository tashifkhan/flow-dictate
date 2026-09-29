import AppKit
import SwiftUI

/// The quick surface: status, the last few dictations, and the way into everything else.
struct MenuBarView: View {
    @Bindable var env: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    /// The supported way in since macOS 14. The `showSettingsWindow:` selector this
    /// replaced is private, was renamed once already, and fails silently when it stops
    /// matching — which looks exactly like the menu item doing nothing.
    @Environment(\.openSettings) private var openSettings
    @State private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            problems
            results
            recent
            Divider()
            footer
        }
        .frame(width: 360)
        .onAppear {
            env.showMainWindow = { openWindow(id: FlowApp.mainWindowID) }
            env.controller.refreshCleanupAvailability()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Flow").font(.headline)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(env.controller.phase.isBusy ? "Stop" : "Talk") { env.toggleFromUI() }
                    .buttonStyle(.glass)
            }

            if env.controller.phase == .recording {
                Waveform(levels: env.controller.levels.bars, height: 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            engines
        }
        .padding(12)
    }

    /// Where the next dictation runs. Takes effect on the next recording; one already
    /// running keeps the settings it started with.
    private var engines: some View {
        Picker("Process on", selection: $settings.cloud.useCloud) {
            Text("This Mac").tag(false)
            Text("Cloud, then this Mac").tag(true)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
    }

    private var statusLine: String {
        switch env.controller.phase {
        case .idle: "Hold \(Settings.shared.hotkey.label) to talk"
        case .preparing(let f): f.map { "Downloading model, \(Int($0 * 100))%" } ?? "Getting ready"
        case .recording: "Listening"
        case .processing: env.controller.processingDetail ?? "Cleaning up"
        case .inserted: "Inserted"
        case .copied: "Copied to clipboard"
        case .tested: "Microphone test complete"
        case .listUpdated: "List updated"
        case .unconfirmed: "Check insertion. Also copied to clipboard"
        case .failed(let m): m
        }
    }

    // MARK: - Nags

    @ViewBuilder
    private var problems: some View {
        VStack(spacing: 0) {
            if !Permissions.hasAccessibility {
                nag("Flow needs Accessibility access to type at your cursor.",
                    action: "Open Settings", perform: Permissions.openAccessibilitySettings)
            }
            if Permissions.micStatus == .denied {
                nag("Microphone access is off, so there is nothing to transcribe.",
                    action: "Open Settings", perform: Permissions.openMicrophoneSettings)
            }
            if cloudUnready {
                nag("No cloud config is ready, so Flow is using this Mac.",
                    action: "Models", perform: openModels)
            }
            if Settings.shared.cleanupEnabled && !Settings.shared.cloud.refinesInCloud,
               let detail = env.controller.cleanupAvailability.detail {
                if case .unsupportedLanguage = env.controller.cleanupAvailability {
                    nag(detail, action: "Language settings", perform: Permissions.openLanguageSettings)
                } else {
                    nag(detail,
                        action: env.controller.cleanupAvailability == .appleIntelligenceOff ? "Open Settings" : nil,
                        perform: Permissions.openAppleIntelligenceSettings)
                }
            }
            if let problem = env.startupProblem {
                nag(problem, action: nil, perform: {})
            }
        }
    }

    private func nag(_ message: String, action: String?, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message).font(.caption).foregroundStyle(.secondary)
            if let action {
                Button(action, action: perform)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }

    /// Cloud is on, but no config on the ladder can run.
    private var cloudUnready: Bool {
        settings.cloud.useCloud && settings.cloud.readyRungs.isEmpty
    }

    private func openModels() {
        env.openSettingsPane = .models
        openWindow(id: FlowApp.mainWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Recent

    /// Parallel models' answers for the last dictation. Clicking one swaps it in.
    @ViewBuilder
    private var results: some View {
        let results = env.controller.results
        if results.count > 1 {
            VStack(alignment: .leading, spacing: 2) {
                Text("Last dictation · pick another result")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                ForEach(results) { result in
                    ResultRow(result: result,
                              inserted: result.id == env.controller.insertedResultID,
                              disabled: env.controller.phase.isBusy) {
                        env.controller.useResult(result.id)
                        env.presenter.show()
                    }
                }
            }
            .padding(.bottom, 6)
            Divider()
        }
    }

    /// One row is a two-line title plus a caption; 52 is the honest average of the
    /// one-line and two-line cases.
    private static let rowHeight: CGFloat = 52
    /// Tall enough to browse, short enough that the menu never runs off a laptop screen.
    private static let maxListHeight: CGFloat = 380

    @ViewBuilder
    private var recent: some View {
        let items = env.library.recent(50)
        if items.isEmpty {
            Text("Nothing dictated yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        MenuBarRow(item: item) {
                            env.controller.reinsert(item.inserted)
                            env.presenter.show()
                        } pin: {
                            env.library.togglePin(item)
                        }
                    }
                }
            }
            // A ScrollView has no intrinsic height, so in this VStack it collapses to a
            // single clipped row no matter what maxHeight says. Size it to the content
            // instead, and only then cap it.
            .frame(height: min(CGFloat(items.count) * Self.rowHeight, Self.maxListHeight))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            menuButton("Copy Last Dictation", "doc.on.doc") {
                guard let last = env.library.recent(1).first else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(last.inserted, forType: .string)
            }
            .disabled(env.library.recent(1).isEmpty || env.controller.phase.isBusy)
            menuButton("Flow Window", "macwindow") {
                openWindow(id: FlowApp.mainWindowID)
                NSApp.activate(ignoringOtherApps: true)
            }
            menuButton("New Note", "square.and.pencil") {
                let note = env.library.newNote()
                env.openNoteID = note.id
                openWindow(id: FlowApp.mainWindowID)
                NSApp.activate(ignoringOtherApps: true)
            }
            menuButton("Settings…", "gearshape") {
                // Accessory apps are not active when the menu is clicked, and the
                // settings window opens behind everything if we do not fix that first.
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Divider().padding(.vertical, 4)
            menuButton("Quit Flow", "power") { NSApp.terminate(nil) }
        }
        .padding(6)
    }

    private func menuButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

private struct MenuBarRow: View {
    var item: DictationRecord
    var insert: () -> Void
    var pin: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: insert) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.inserted)
                        .font(.callout)
                        .lineLimit(2)
                    Text("\(item.appName) · \(item.createdAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Insert at cursor")
            Button(action: copy) {
                Image(systemName: "doc.on.doc")
                    .frame(width: 24, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy to clipboard")
            .accessibilityLabel("Copy dictation to clipboard")
            if item.pinned || hovering {
                Button(action: pin) {
                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.plain)
                .foregroundStyle(item.pinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(.rect)
        .background(hovering ? AnyShapeStyle(.selection.opacity(0.5)) : AnyShapeStyle(.clear))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy", action: copy)
            Button("Insert at Cursor", action: insert)
            Button(item.pinned ? "Unpin" : "Pin", action: pin)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.inserted, forType: .string)
    }
}

private struct ResultRow: View {
    var result: CloudResult
    var inserted: Bool
    var disabled: Bool
    var use: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: inserted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(inserted ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .padding(.top, 1)
            Button(action: use) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(result.text)
                        .font(.callout)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(inserted || disabled)
            .help(inserted ? "This is the text Flow inserted" : "Replace the inserted text with this result, or copy it if you have typed since")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").frame(width: 24, height: 24).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy to clipboard")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(hovering && !inserted ? AnyShapeStyle(.selection.opacity(0.5)) : AnyShapeStyle(.clear))
        .onHover { hovering = $0 }
    }
}
