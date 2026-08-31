import AppKit
import SwiftUI

/// Dictations, as a Messages-style list or a grid of glass cards.
struct DictationBrowser: View {
    @Bindable var env: AppEnvironment
    var mode: ViewMode
    var items: [DictationRecord]
    var title: String

    /// Selection lives on the environment so ⇧⌘V can reach it from the menu bar.
    private var selection: Binding<UUID?> {
        Binding(get: { env.selectedDictationID }, set: { env.selectedDictationID = $0 })
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label(env.library.query.isEmpty ? "Nothing here yet" : "No matches",
                          systemImage: "waveform")
                } description: {
                    Text(env.library.query.isEmpty
                         ? "Hold \(Settings.shared.hotkey.label) anywhere and talk."
                         : "Nothing matches “\(env.library.query)”.")
                }
            } else if mode == .list {
                list
            } else {
                grid
            }
        }
        .navigationTitle(title)
    }

    private var list: some View {
        List(selection: selection) {
            ForEach(env.library.dictationsByDay().filter { day in
                day.notes.contains { item in items.contains(item) }
            }, id: \.day) { group in
                Section(group.day.formatted(.dateTime.weekday(.wide).month().day())) {
                    ForEach(group.notes.filter { items.contains($0) }) { item in
                        DictationRow(item: item, env: env)
                            .tag(item.id)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                ForEach(items) { item in
                    DictationCard(item: item, env: env)
                        .onTapGesture { env.selectedDictationID = item.id }
                        .overlay {
                            if env.selectedDictationID == item.id {
                                RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(.tint, lineWidth: 2)
                            }
                        }
                }
            }
            .padding(20)
        }
    }
}

private struct DictationRow: View {
    var item: DictationRecord
    @Bindable var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.inserted)
                .font(.body)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(item.appName)
                Text("·")
                Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                if item.duration > 0 {
                    Text("·")
                    Text("\(item.duration, format: .number.precision(.fractionLength(1)))s")
                }
                if !item.wasCleaned {
                    Text("·")
                    Text("raw").foregroundStyle(.orange)
                }
                if item.pinned {
                    Image(systemName: "pin.fill").foregroundStyle(.tint)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contextMenu { DictationMenu(item: item, env: env) }
    }
}

private struct DictationCard: View {
    var item: DictationRecord
    @Bindable var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(item.appName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if item.pinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tint)
                }
            }
            Text(item.inserted)
                .font(.callout)
                .lineLimit(max(Settings.shared.previewLines, 1))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .contextMenu { DictationMenu(item: item, env: env) }
    }
}

private struct DictationMenu: View {
    var item: DictationRecord
    @Bindable var env: AppEnvironment

    var body: some View {
        Button("Insert at Cursor") { env.controller.reinsert(item.inserted) }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.inserted, forType: .string)
        }
        Button(item.pinned ? "Unpin" : "Pin") { env.library.togglePin(item) }
        if item.wasCleaned {
            Divider()
            Section("Raw transcript") { Text(item.raw) }
        }
        Divider()
        Button("Delete", role: .destructive) { env.library.delete(item) }
    }
}

/// The scratchpad, same two view modes.
struct NoteBrowser: View {
    @Bindable var env: AppEnvironment
    var mode: ViewMode

    var body: some View {
        Group {
            if env.library.notes.isEmpty {
                ContentUnavailableView {
                    Label("No notes yet", systemImage: "square.and.pencil")
                } description: {
                    Text("Capture a shower thought by voice; find it next week by search.")
                } actions: {
                    Button("New Note") {
                        let note = env.library.newNote()
                        env.openNoteID = note.id
                    }
                }
            } else if mode == .list {
                List {
                    ForEach(env.library.notesByDay(), id: \.day) { group in
                        Section(group.day.formatted(.dateTime.weekday(.wide).month().day())) {
                            ForEach(group.notes) { note in
                                Button {
                                    env.openNoteID = note.id
                                } label: {
                                    NoteRow(note: note)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { NoteMenu(note: note, env: env) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                        ForEach(env.library.notes) { note in
                            Button { env.openNoteID = note.id } label: {
                                NoteCard(note: note)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { NoteMenu(note: note, env: env) }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Scratchpad")
    }
}

private struct NoteRow: View {
    var note: NoteRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(note.displayTitle).font(.body.weight(.medium)).lineLimit(1)
                if note.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tint) }
            }
            if let summary = note.summary, !summary.isEmpty {
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else if !note.body.isEmpty {
                Text(note.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

private struct NoteCard: View {
    var note: NoteRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(note.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                if note.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tint) }
            }
            Text(note.summary?.nilIfEmpty ?? note.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(max(Settings.shared.previewLines, 1))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

private struct NoteMenu: View {
    var note: NoteRecord
    @Bindable var env: AppEnvironment

    var body: some View {
        Button("Open") { env.openNoteID = note.id }
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(note.text, forType: .string)
        }
        Button(note.pinned ? "Unpin" : "Pin") { env.library.togglePin(note) }
        Divider()
        Button("Delete", role: .destructive) { env.library.delete(note) }
    }
}
