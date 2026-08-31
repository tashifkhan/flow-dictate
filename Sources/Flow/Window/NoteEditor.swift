import AppKit
import SwiftUI

/// A note, with the mic in the corner. Dictation runs the same pipeline and lands in
/// the note instead of another app.
struct NoteEditor: View {
    @Bindable var env: AppEnvironment
    @State private var text: String
    @State private var summarising = false
    @State private var summaryError: String?

    private let noteID: UUID
    private let createdAt: Date

    init(env: AppEnvironment, note: NoteRecord) {
        self.env = env
        self.noteID = note.id
        self.createdAt = note.createdAt
        _text = State(initialValue: note.text)
    }

    private var note: NoteRecord? { env.library.note(noteID) }

    var body: some View {
        VStack(spacing: 0) {
            summaryBar
            editor
        }
        .navigationTitle(note?.displayTitle ?? "Note")
        .navigationSubtitle(createdAt.formatted(date: .abbreviated, time: .shortened))
        .toolbar { toolbar }
        .onAppear { env.controller.target = .note(noteID) }
        .onDisappear {
            save()
            env.controller.target = .cursor
        }
        // Dictated text arrives through the store, so pull it back into the editor.
        .onChange(of: note?.text) { _, new in
            if let new, new != text { text = new }
        }
        .onChange(of: text) { _, _ in scheduleSave() }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var summaryBar: some View {
        if let summary = note?.summary, !summary.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text(summary).font(.callout)
                Spacer()
                Button {
                    var updated = note!
                    updated.summary = nil
                    env.library.save(updated)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.tint.opacity(0.08))
        }
        if let summaryError {
            Text(summaryError)
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    private var editor: some View {
        ZStack(alignment: .bottomTrailing) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(16)

            micButton
                .padding(20)
        }
    }

    private var micButton: some View {
        Button {
            env.toggleFromUI()
        } label: {
            ZStack {
                if env.controller.phase == .recording {
                    Waveform(levels: env.controller.levels.bars, isLive: true, tint: .white)
                        .frame(width: 40, height: 18)
                } else {
                    Image(systemName: "mic.fill").font(.system(size: 16))
                }
            }
            .frame(width: 56, height: 44)
        }
        .buttonStyle(.glassProminent)
        .help(env.controller.phase.isBusy ? "Stop dictating" : "Dictate into this note")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                guard let note else { return }
                env.library.togglePin(note)
            } label: {
                Label("Pin", systemImage: note?.pinned == true ? "pin.fill" : "pin")
            }
            .help(note?.pinned == true ? "Unpin" : "Pin")
        }
        ToolbarItem {
            Button(action: summarise) {
                if summarising {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Summarise", systemImage: "sparkles")
                }
            }
            .disabled(summarising || text.trimmingCharacters(in: .whitespacesAndNewlines).count < 40
                      || !env.controller.cleanupAvailability.isAvailable)
            .help(env.controller.cleanupAvailability.isAvailable
                  ? "Summarise this note"
                  : env.controller.cleanupAvailability.label)
        }
        ToolbarItem {
            Button(role: .destructive) {
                guard let note else { return }
                env.library.delete(note)
                env.openNoteID = nil
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    /// On demand only. A surprise summary burning battery while you type is not a feature.
    private func summarise() {
        guard let note else { return }
        summarising = true
        summaryError = nil
        let body = text
        Task {
            defer { summarising = false }
            do {
                let result = try await CleanupService().summarize(body)
                var updated = note
                updated.summary = result.summary
                if updated.title.isEmpty { updated.title = result.title }
                env.library.save(updated)
            } catch {
                summaryError = error.localizedDescription
            }
        }
    }

    @State private var saveTask: Task<Void, Never>?

    /// Debounced: a note being typed into should not hit the database per keystroke.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        guard var note else { return }
        guard note.text != text else { return }
        note.text = text
        env.library.save(note)
    }
}
