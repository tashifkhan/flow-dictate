import AppKit
import SwiftUI

/// What the sidebar can select.
enum SidebarItem: Hashable {
    case setup
    case stats
    case dictations
    case pinned
    case notes
    case note(UUID)
    case settings(SettingsPane)
}

/// Two view modes, toggled from the toolbar: a Messages-style list, and a grid where
/// every dictation or note is a floating glass card.
enum ViewMode: String {
    case list, grid
}

/// The app's face. Borrowed wholesale from the Siri app's shape: edge-to-edge sidebar
/// with colored icons, uniform toolbar, pins at the top.
struct MainWindow: View {
    @Bindable var env: AppEnvironment
    @State private var selection: SidebarItem? = .dictations
    @State private var mode: ViewMode = .list
    @AppStorage("viewMode") private var storedMode = ViewMode.list.rawValue

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .searchable(text: searchQuery, placement: .toolbar, prompt: "Search dictations and notes")
        .toolbar { toolbar }
        .onAppear(perform: configure)
        .onChange(of: env.openNoteID) { _, id in
            if let id { selection = .note(id) }
        }
        .onChange(of: mode) { _, new in storedMode = new.rawValue }
    }

    /// `library` is a `let` on the environment, so the search field binds through it
    /// rather than to it.
    private var searchQuery: Binding<String> {
        Binding(get: { env.library.query }, set: { env.library.query = $0 })
    }

    private func configure() {
        mode = ViewMode(rawValue: storedMode) ?? .list
        env.refreshPermissionState()

        // Nothing else in the app matters until Flow can hear you and type for you.
        if env.needsSetup {
            selection = .setup
            return
        }
        if Settings.shared.openTo == .newNote, env.openNoteID == nil {
            let note = env.library.newNote()
            env.openNoteID = note.id
            selection = .note(note.id)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                if env.needsSetup {
                    Label("Finish setup", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .tag(SidebarItem.setup)
                } else {
                    Label("Setup", systemImage: "checkmark.circle")
                        .tag(SidebarItem.setup)
                }

                label("All Dictations", "waveform", .blue, count: env.library.dictations.count)
                    .tag(SidebarItem.dictations)
                Label("Statistics", systemImage: "chart.bar.xaxis")
                    .tag(SidebarItem.stats)
                label("Pinned", "pin.fill", .orange, count: env.library.pinnedDictations.count)
                    .tag(SidebarItem.pinned)
            }

            Section("Settings") {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.icon)
                        .tag(SidebarItem.settings(pane))
                }
            }

            Section("Scratchpad") {
                label("All Notes", "square.and.pencil", .purple, count: env.library.notes.count)
                    .tag(SidebarItem.notes)

                // Grouped by day, newest first.
                ForEach(env.library.notesByDay(), id: \.day) { group in
                    DisclosureGroup {
                        ForEach(group.notes) { note in
                            Label(note.displayTitle, systemImage: note.pinned ? "pin.fill" : "doc.text")
                                .lineLimit(1)
                                .tag(SidebarItem.note(note.id))
                        }
                    } label: {
                        Text(group.day.formatted(.dateTime.weekday(.wide).month().day()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    private func label(_ title: String, _ icon: String, _ tint: Color, count: Int) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .foregroundStyle(.primary)
                .symbolRenderingMode(.hierarchical)
                .tint(tint)
            Spacer()
            Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                Circle()
                    .fill(env.controller.cleanupAvailability.isAvailable ? .green : .orange)
                    .frame(width: 7, height: 7)
                Text(env.controller.cleanupAvailability.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .setup:
            SetupView(env: env)
        case .stats:
            StatsView(env: env)
        case .dictations:
            DictationBrowser(env: env, mode: mode, items: env.library.dictations, title: "All Dictations")
        case .pinned:
            DictationBrowser(env: env, mode: mode, items: env.library.pinnedDictations, title: "Pinned")
        case .notes:
            NoteBrowser(env: env, mode: mode)
        case .note(let id):
            if let note = env.library.note(id) {
                NoteEditor(env: env, note: note)
                    .id(id)
            } else {
                ContentUnavailableView("Note deleted", systemImage: "trash")
            }
        case .settings(let pane):
            SettingsView(env: env, pane: pane)
        case nil:
            ContentUnavailableView("Pick something on the left", systemImage: "sidebar.left")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $mode) {
                Image(systemName: "list.bullet").tag(ViewMode.list)
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .help("List or grid")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                let note = env.library.newNote()
                env.openNoteID = note.id
                selection = .note(note.id)
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            }
            .help("New note (⇧⌘N)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { env.toggleFromUI() } label: {
                Label("Dictate", systemImage: env.controller.phase.isBusy ? "stop.circle" : "mic")
            }
            .help("Start a dictation")
        }
    }
}
