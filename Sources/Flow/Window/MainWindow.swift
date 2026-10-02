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
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @AppStorage("viewMode") private var storedMode = ViewMode.list.rawValue

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
        .onChange(of: env.openSettingsPane) { _, pane in
            if let pane { selection = .settings(pane) }
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
        if let pane = env.openSettingsPane {
            selection = .settings(pane)
            return
        }

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
                label("Statistics", "chart.bar.xaxis", .green, count: todayWords, compact: true)
                    .help("\(todayWords.formatted()) words dictated today")
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
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
    }

    /// From the daily totals, so it does not change with the search field.
    private var todayWords: Int {
        let today = Calendar.current.startOfDay(for: .now)
        return env.library.dailyStats.first { $0.day == today }?.words ?? 0
    }

    private func label(_ title: String, _ icon: String, _ tint: Color, count: Int, compact: Bool = false) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .foregroundStyle(.primary)
                .symbolRenderingMode(.hierarchical)
                .tint(tint)
            Spacer()
            Text(compact ? Stats.compactCount(count) : "\(count)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
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

    private var showsBrowserLayoutPicker: Bool {
        switch selection {
        case .dictations, .pinned, .notes: true
        default: false
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if showsBrowserLayoutPicker {
            ToolbarItem(placement: .primaryAction) {
                Picker("View", selection: $mode) {
                    Image(systemName: "list.bullet").tag(ViewMode.list)
                    Image(systemName: "square.grid.2x2").tag(ViewMode.grid)
                }
                .pickerStyle(.segmented)
                .help("Show as a list or a grid of cards")
            }
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
                Label(env.controller.phase.isBusy ? "Stop" : "Dictate",
                      systemImage: env.controller.phase.isBusy ? "stop.circle.fill" : "mic")
                    .foregroundStyle(env.controller.phase.isBusy ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .help(env.controller.phase.isBusy ? "Stop and insert" : "Start a dictation (⇧⌘D)")
        }
    }
}
