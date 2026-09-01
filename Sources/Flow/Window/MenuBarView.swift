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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            problems
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
                Waveform(levels: env.controller.levels.bars, isLive: true)
                    .frame(height: 20)
            }
        }
        .padding(12)
    }

    private var statusLine: String {
        switch env.controller.phase {
        case .idle: "Hold \(Settings.shared.hotkey.label) to talk"
        case .preparing(let f): f.map { "Downloading model, \(Int($0 * 100))%" } ?? "Getting ready"
        case .recording: "Listening"
        case .processing: "Cleaning up"
        case .inserted: "Inserted"
        case .copied: "Copied to clipboard"
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
            if let detail = env.controller.cleanupAvailability.detail {
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

    // MARK: - Recent

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
            VStack(alignment: .leading, spacing: 2) {
                Text(item.inserted)
                    .font(.callout)
                    .lineLimit(2)
                Text("\(item.appName) · \(item.createdAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
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
        .onTapGesture(perform: insert)
        .help("Insert at cursor")
    }
}
